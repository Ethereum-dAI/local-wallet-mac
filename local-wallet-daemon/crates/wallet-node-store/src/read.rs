use std::path::Path;

use rusqlite::{Connection, OpenFlags};

use crate::{StoreError, UserOpStatus};

const USER_OPERATIONS_TABLE: &str = "user_operations";

/// Used for diagnostic queries that do not go through the actor. Multiple read-only connections can run concurrently with the writer in WAL mode.
pub fn open_read_only(path: &Path) -> Result<Connection, StoreError> {
    let conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    conn.pragma_update(None, "busy_timeout", 5000_i64)?;
    Ok(conn)
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingOperation {
    pub user_op_hash: String,
    pub sender: String,
    pub nonce: String,
    pub status: UserOpStatus,
    pub tx_hash: Option<String>,
    pub submitted_at_block: Option<u64>,
    pub last_error: Option<String>,
}

pub fn pending_operations(conn: &Connection) -> Result<Vec<PendingOperation>, StoreError> {
    let mut stmt = conn.prepare(
        r#"SELECT u.user_op_hash, u.sender, u.nonce, u.status, s.tx_hash, s.submitted_at_block, d.last_error
FROM user_operations u
LEFT JOIN submitted_transactions s ON s.user_op_hash = u.user_op_hash
LEFT JOIN operation_diagnostics d ON d.subject_type = 'user_operation' AND d.subject_id = u.user_op_hash
WHERE u.status IN ("received","simulated","submitted","pending")
ORDER BY u.updated_at"#,
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, Option<String>>(4)?,
            row.get::<_, Option<i64>>(5)?,
            row.get::<_, Option<String>>(6)?,
        ))
    })?;

    let mut ops = Vec::new();
    for row in rows {
        let (user_op_hash, sender, nonce, status, tx_hash, submitted_at_block, last_error) = row?;
        ops.push(PendingOperation {
            user_op_hash,
            sender,
            nonce,
            status: UserOpStatus::from_str(&status, USER_OPERATIONS_TABLE)?,
            tx_hash,
            submitted_at_block: submitted_at_block.map(|block| block as u64),
            last_error,
        });
    }

    Ok(ops)
}

#[cfg(test)]
mod tests {
    use std::{
        path::{Path, PathBuf},
        time::{SystemTime, UNIX_EPOCH},
    };

    use rusqlite::params;

    use super::*;
    use crate::{db, migrations, SubmittedTxStatus};

    fn migrated_in_memory_conn() -> rusqlite::Connection {
        let mut conn = db::open_in_memory().unwrap();
        migrations::apply(&mut conn).unwrap();
        conn
    }

    fn insert_user_op(
        conn: &Connection,
        hash: &str,
        sender: &str,
        nonce: &str,
        status: UserOpStatus,
        updated_at: i64,
    ) {
        conn.execute(
            "INSERT INTO user_operations (user_op_hash, chain_id, entry_point, sender, nonce, user_op_json, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params![
                hash,
                1_u64,
                "0xentrypoint",
                sender,
                nonce,
                format!(r#"{{"hash":"{hash}"}}"#),
                status.as_str(),
                updated_at,
                updated_at,
            ],
        )
        .unwrap();
    }

    fn insert_submitted_tx(
        conn: &Connection,
        tx_hash: &str,
        user_op_hash: &str,
        submitted_at_block: Option<u64>,
    ) {
        conn.execute(
            "INSERT INTO submitted_transactions (tx_hash, user_op_hash, chain_id, bundler_address, nonce, raw_tx, max_fee_per_gas, max_priority_fee_per_gas, status, replacement_of, submitted_at_block, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params![
                tx_hash,
                user_op_hash,
                1_u64,
                "0xbeef",
                1_u64,
                "0xraw",
                "0x3b9aca00",
                "0x3b9aca0",
                SubmittedTxStatus::Submitted.as_str(),
                Option::<String>::None,
                submitted_at_block.map(|block| block as i64),
                1_i64,
                1_i64,
            ],
        )
        .unwrap();
    }

    fn temp_db_path() -> PathBuf {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "wallet-node-store-read-test-{}-{now}.sqlite",
            std::process::id()
        ))
    }

    fn remove_sqlite_files(path: &Path) {
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(path.with_extension("sqlite-wal"));
        let _ = std::fs::remove_file(path.with_extension("sqlite-shm"));
    }

    #[test]
    fn pending_operations_empty_db_returns_empty_vec() {
        let conn = migrated_in_memory_conn();

        let ops = pending_operations(&conn).unwrap();

        assert!(ops.is_empty());
    }

    #[test]
    fn pending_operations_returns_received_only_no_submitted_tx() {
        let conn = migrated_in_memory_conn();
        insert_user_op(&conn, "0xaaa", "0xbbb", "0x1", UserOpStatus::Received, 1);

        let ops = pending_operations(&conn).unwrap();

        assert_eq!(ops.len(), 1);
        assert_eq!(ops[0].user_op_hash, "0xaaa");
        assert_eq!(ops[0].sender, "0xbbb");
        assert_eq!(ops[0].nonce, "0x1");
        assert_eq!(ops[0].status, UserOpStatus::Received);
        assert_eq!(ops[0].tx_hash, None);
        assert_eq!(ops[0].submitted_at_block, None);
        assert_eq!(ops[0].last_error, None);
    }

    #[test]
    fn pending_operations_returns_submitted_with_tx_hash() {
        let conn = migrated_in_memory_conn();
        insert_user_op(&conn, "0xaaa", "0xbbb", "0x1", UserOpStatus::Submitted, 1);
        insert_submitted_tx(&conn, "0xccc", "0xaaa", Some(1234));

        let ops = pending_operations(&conn).unwrap();

        assert_eq!(ops.len(), 1);
        assert_eq!(ops[0].user_op_hash, "0xaaa");
        assert_eq!(ops[0].status, UserOpStatus::Submitted);
        assert_eq!(ops[0].tx_hash, Some("0xccc".to_owned()));
        assert_eq!(ops[0].submitted_at_block, Some(1234));
    }

    #[test]
    fn pending_operations_excludes_terminal_user_ops() {
        let conn = migrated_in_memory_conn();
        for (idx, status) in [
            UserOpStatus::Included,
            UserOpStatus::Reverted,
            UserOpStatus::Failed,
        ]
        .into_iter()
        .enumerate()
        {
            insert_user_op(
                &conn,
                &format!("0xterminal{idx}"),
                "0xsender",
                "0x1",
                status,
                idx as i64,
            );
        }

        let ops = pending_operations(&conn).unwrap();

        assert!(ops.is_empty());
    }

    #[test]
    fn pending_operations_orders_by_updated_at() {
        let conn = migrated_in_memory_conn();
        insert_user_op(&conn, "0xthird", "0xs3", "0x3", UserOpStatus::Pending, 3);
        insert_user_op(&conn, "0xfirst", "0xs1", "0x1", UserOpStatus::Received, 1);
        insert_user_op(&conn, "0xsecond", "0xs2", "0x2", UserOpStatus::Simulated, 2);

        let ops = pending_operations(&conn).unwrap();
        let hashes: Vec<_> = ops.iter().map(|op| op.user_op_hash.as_str()).collect();

        assert_eq!(hashes, ["0xfirst", "0xsecond", "0xthird"]);
    }

    #[test]
    fn pending_operation_serializes_to_camel_case_json() {
        let op = PendingOperation {
            user_op_hash: "0xaaa".to_owned(),
            sender: "0xbbb".to_owned(),
            nonce: "0x1".to_owned(),
            status: UserOpStatus::Submitted,
            tx_hash: Some("0xccc".to_owned()),
            submitted_at_block: Some(1234),
            last_error: None,
        };

        let json = serde_json::to_string(&op).unwrap();

        assert_eq!(
            json,
            r#"{"userOpHash":"0xaaa","sender":"0xbbb","nonce":"0x1","status":"submitted","txHash":"0xccc","submittedAtBlock":1234,"lastError":null}"#
        );
    }

    #[test]
    fn pending_operations_returns_persisted_last_error() {
        let conn = migrated_in_memory_conn();
        insert_user_op(&conn, "0xaaa", "0xbbb", "0x1", UserOpStatus::Submitted, 1);
        conn.execute(
            "INSERT INTO operation_diagnostics (subject_type, subject_id, last_error, last_error_at) VALUES ('user_operation', '0xaaa', 'receipt_lookup_failed', 10)",
            [],
        )
        .unwrap();

        let ops = pending_operations(&conn).unwrap();

        assert_eq!(ops.len(), 1);
        assert_eq!(ops[0].last_error, Some("receipt_lookup_failed".to_string()));
    }

    #[test]
    #[ignore = "requires file-backed SQLite for SQLITE_OPEN_READ_ONLY; run with --include-ignored"]
    fn pending_operations_round_trips_through_open_read_only() {
        let path = temp_db_path();
        remove_sqlite_files(&path);

        {
            let mut conn = db::open(&path).unwrap();
            migrations::apply(&mut conn).unwrap();
            insert_user_op(&conn, "0xaaa", "0xbbb", "0x1", UserOpStatus::Submitted, 1);
            insert_submitted_tx(&conn, "0xccc", "0xaaa", Some(1234));
        }

        let conn = open_read_only(&path).unwrap();
        let ops = pending_operations(&conn).unwrap();

        assert_eq!(ops.len(), 1);
        assert_eq!(ops[0].user_op_hash, "0xaaa");
        assert_eq!(ops[0].tx_hash, Some("0xccc".to_owned()));
        assert_eq!(ops[0].submitted_at_block, Some(1234));

        remove_sqlite_files(&path);
    }
}
