use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection, TransactionBehavior};

use crate::{NonceReservation, NonceStatus, StoreError};

const TABLE: &str = "nonce_reservations";

pub(crate) fn reserve_next_nonce(
    conn: &mut Connection,
    chain_id: u64,
    bundler_address: &str,
    confirmed_nonce: u64,
) -> Result<u64, StoreError> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let (lowest_local, highest_local): (Option<i64>, Option<i64>) = tx.query_row(
        "SELECT MIN(nonce), MAX(nonce) FROM nonce_reservations WHERE chain_id = ? AND bundler_address = ? AND status IN ('reserved', 'submitted')",
        params![chain_id, bundler_address],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;

    if lowest_local.is_some_and(|nonce| nonce < 0) {
        return Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "negative nonce in local rows",
        });
    }

    let next = match highest_local {
        Some(highest) => std::cmp::max(confirmed_nonce, (highest as u64) + 1),
        None => confirmed_nonce,
    };
    let now = now_unix_seconds();

    tx.execute(
        "INSERT INTO nonce_reservations (chain_id, bundler_address, nonce, status, user_op_hash, tx_hash, created_at, updated_at) VALUES (?, ?, ?, 'reserved', NULL, NULL, ?, ?)",
        params![chain_id, bundler_address, next, now, now],
    )?;
    tx.commit()?;

    Ok(next)
}

pub(crate) fn nonce_attach_tx_hash(
    conn: &Connection,
    chain_id: u64,
    bundler_address: &str,
    nonce: u64,
    tx_hash: &str,
) -> Result<(), StoreError> {
    let updated = conn.execute(
        "UPDATE nonce_reservations SET tx_hash = ?, updated_at = ? WHERE chain_id = ? AND bundler_address = ? AND nonce = ?",
        params![tx_hash, now_unix_seconds(), chain_id, bundler_address, nonce],
    )?;

    if updated == 0 {
        return Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "no row to attach tx hash to",
        });
    }

    Ok(())
}

pub(crate) fn nonce_set_status(
    conn: &Connection,
    chain_id: u64,
    bundler_address: &str,
    nonce: u64,
    status: NonceStatus,
) -> Result<(), StoreError> {
    let updated = conn.execute(
        "UPDATE nonce_reservations SET status = ?, updated_at = ? WHERE chain_id = ? AND bundler_address = ? AND nonce = ?",
        params![status.as_str(), now_unix_seconds(), chain_id, bundler_address, nonce],
    )?;

    if updated == 0 {
        return Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "no row to set status on",
        });
    }

    Ok(())
}

pub(crate) fn nonces_list_pending(
    conn: &Connection,
    chain_id: u64,
    bundler_address: &str,
) -> Result<Vec<NonceReservation>, StoreError> {
    let mut stmt = conn.prepare(
        "SELECT chain_id, bundler_address, nonce, status, user_op_hash, tx_hash, created_at, updated_at FROM nonce_reservations WHERE chain_id = ? AND bundler_address = ? AND status IN ('reserved', 'submitted') ORDER BY nonce",
    )?;
    let rows = stmt.query_map(params![chain_id, bundler_address], |row| {
        Ok((
            row.get::<_, u64>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, i64>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, Option<String>>(4)?,
            row.get::<_, Option<String>>(5)?,
            row.get::<_, i64>(6)?,
            row.get::<_, i64>(7)?,
        ))
    })?;

    let mut reservations = Vec::new();
    for row in rows {
        let (
            chain_id,
            bundler_address,
            nonce,
            status,
            user_op_hash,
            tx_hash,
            created_at,
            updated_at,
        ) = row?;
        if nonce < 0 {
            return Err(StoreError::DataIntegrity {
                table: TABLE,
                reason: "negative nonce in local rows",
            });
        }

        reservations.push(NonceReservation {
            chain_id,
            bundler_address,
            nonce: nonce as u64,
            status: NonceStatus::from_str(&status, TABLE)?,
            user_op_hash,
            tx_hash,
            created_at,
            updated_at,
        });
    }

    Ok(reservations)
}

fn now_unix_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{db, migrations, StoreActor};

    fn migrated_in_memory_conn() -> rusqlite::Connection {
        let mut conn = db::open_in_memory().unwrap();
        migrations::apply(&mut conn).unwrap();
        conn
    }

    fn insert_nonce(conn: &Connection, nonce: u64, status: NonceStatus) {
        conn.execute(
            "INSERT INTO nonce_reservations (chain_id, bundler_address, nonce, status, user_op_hash, tx_hash, created_at, updated_at) VALUES (?, ?, ?, ?, NULL, NULL, ?, ?)",
            params![1_u64, "0xbeef", nonce, status.as_str(), 1_i64, 1_i64],
        )
        .unwrap();
    }

    #[test]
    fn reserve_chooses_confirmed_when_no_local() {
        let mut conn = migrated_in_memory_conn();

        let nonce = reserve_next_nonce(&mut conn, 1, "0xbeef", 10).unwrap();
        let status: String = conn
            .query_row(
                "SELECT status FROM nonce_reservations WHERE chain_id = ? AND bundler_address = ? AND nonce = ?",
                params![1_u64, "0xbeef", 10_u64],
                |row| row.get(0),
            )
            .unwrap();

        assert_eq!(nonce, 10);
        assert_eq!(status, "reserved");
    }

    #[test]
    fn reserve_advances_past_local_high() {
        let mut conn = migrated_in_memory_conn();
        insert_nonce(&conn, 12, NonceStatus::Reserved);

        assert_eq!(reserve_next_nonce(&mut conn, 1, "0xbeef", 10).unwrap(), 13);
    }

    #[test]
    fn reserve_advances_past_confirmed_when_local_lags() {
        let mut conn = migrated_in_memory_conn();
        insert_nonce(&conn, 5, NonceStatus::Reserved);

        assert_eq!(reserve_next_nonce(&mut conn, 1, "0xbeef", 20).unwrap(), 20);
    }

    #[test]
    fn reserve_skips_terminal_local() {
        let mut conn = migrated_in_memory_conn();
        insert_nonce(&conn, 12, NonceStatus::Included);

        assert_eq!(reserve_next_nonce(&mut conn, 1, "0xbeef", 10).unwrap(), 10);
    }

    #[test]
    fn attach_tx_hash_updates_row() {
        let conn = migrated_in_memory_conn();
        insert_nonce(&conn, 12, NonceStatus::Reserved);

        nonce_attach_tx_hash(&conn, 1, "0xbeef", 12, "0xtx").unwrap();
        let tx_hash: String = conn
            .query_row(
                "SELECT tx_hash FROM nonce_reservations WHERE chain_id = ? AND bundler_address = ? AND nonce = ?",
                params![1_u64, "0xbeef", 12_u64],
                |row| row.get(0),
            )
            .unwrap();

        assert_eq!(tx_hash, "0xtx");
    }

    #[test]
    fn set_status_persists() {
        let conn = migrated_in_memory_conn();
        insert_nonce(&conn, 12, NonceStatus::Reserved);

        nonce_set_status(&conn, 1, "0xbeef", 12, NonceStatus::Submitted).unwrap();
        let status: String = conn
            .query_row(
                "SELECT status FROM nonce_reservations WHERE chain_id = ? AND bundler_address = ? AND nonce = ?",
                params![1_u64, "0xbeef", 12_u64],
                |row| row.get(0),
            )
            .unwrap();

        assert_eq!(status, "submitted");
    }

    #[test]
    fn list_pending_filters_terminal() {
        let conn = migrated_in_memory_conn();
        insert_nonce(&conn, 4, NonceStatus::Included);
        insert_nonce(&conn, 3, NonceStatus::Submitted);
        insert_nonce(&conn, 2, NonceStatus::Reserved);
        insert_nonce(&conn, 5, NonceStatus::Failed);

        let nonces = nonces_list_pending(&conn, 1, "0xbeef").unwrap();

        assert_eq!(nonces.len(), 2);
        assert_eq!(nonces[0].nonce, 2);
        assert_eq!(nonces[0].status, NonceStatus::Reserved);
        assert_eq!(nonces[1].nonce, 3);
        assert_eq!(nonces[1].status, NonceStatus::Submitted);
    }

    #[tokio::test]
    #[ignore = "requires file-backed SQLite for BEGIN IMMEDIATE semantics; run with --include-ignored"]
    async fn concurrent_reservations_are_unique_and_consecutive() {
        let dir = std::env::temp_dir().join(format!(
            "wallet-node-test-{}-{}",
            std::process::id(),
            now_unix_seconds()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        let db_path = dir.join("nonce-test.sqlite");
        let mut conn = db::open(&db_path).unwrap();
        migrations::apply(&mut conn).unwrap();
        drop(conn);

        let conn = db::open(&db_path).unwrap();
        let handle = StoreActor::start(conn);

        let mut handles = Vec::new();
        for _ in 0..10 {
            let h = handle.clone();
            handles.push(tokio::spawn(async move {
                h.reserve_next_nonce(1, "0xbeef", 0).await
            }));
        }

        let mut results = Vec::new();
        for jh in handles {
            results.push(jh.await.unwrap().unwrap());
        }

        let mut sorted = results.clone();
        sorted.sort();
        assert_eq!(sorted, (0..10).collect::<Vec<u64>>(), "got: {results:?}");

        handle.shutdown_and_wait().await.unwrap();
        std::fs::remove_dir_all(&dir).ok();
    }
}
