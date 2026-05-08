use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection, Error, TransactionBehavior};

use crate::{NonceStatus, StoreError, UserOpStatus, UserOperation};

const TABLE: &str = "user_operations";

impl PartialEq for UserOperation {
    fn eq(&self, other: &Self) -> bool {
        self.user_op_hash == other.user_op_hash
            && self.chain_id == other.chain_id
            && self.entry_point == other.entry_point
            && self.sender == other.sender
            && self.nonce == other.nonce
            && self.user_op_json == other.user_op_json
            && self.status == other.status
            && self.created_at == other.created_at
            && self.updated_at == other.updated_at
    }
}

impl Eq for UserOperation {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UserOpInsertOutcome {
    Inserted,
    AlreadyExists(UserOperation),
}

pub(crate) fn user_op_insert(
    conn: &mut Connection,
    op: UserOperation,
) -> Result<UserOpInsertOutcome, StoreError> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let inserted = tx.execute(
        "INSERT OR IGNORE INTO user_operations (user_op_hash, chain_id, entry_point, sender, nonce, user_op_json, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        params![
            &op.user_op_hash,
            op.chain_id,
            &op.entry_point,
            &op.sender,
            &op.nonce,
            &op.user_op_json,
            op.status.as_str(),
            op.created_at,
            op.updated_at,
        ],
    )?;

    let outcome = match inserted {
        0 => {
            let existing =
                user_op_get(&tx, &op.user_op_hash)?.ok_or(StoreError::DataIntegrity {
                    table: TABLE,
                    reason: "insert ignored but existing row missing",
                })?;
            UserOpInsertOutcome::AlreadyExists(existing)
        }
        1 => UserOpInsertOutcome::Inserted,
        _ => {
            return Err(StoreError::DataIntegrity {
                table: TABLE,
                reason: "unexpected insert row count",
            });
        }
    };

    tx.commit()?;
    Ok(outcome)
}

pub(crate) fn user_op_insert_abandon_nonce_on_exists(
    conn: &mut Connection,
    op: UserOperation,
    nonce_chain_id: u64,
    nonce_bundler_address: &str,
    nonce: u64,
) -> Result<UserOpInsertOutcome, StoreError> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let inserted = tx.execute(
        "INSERT OR IGNORE INTO user_operations (user_op_hash, chain_id, entry_point, sender, nonce, user_op_json, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        params![
            &op.user_op_hash,
            op.chain_id,
            &op.entry_point,
            &op.sender,
            &op.nonce,
            &op.user_op_json,
            op.status.as_str(),
            op.created_at,
            op.updated_at,
        ],
    )?;

    let outcome = match inserted {
        0 => {
            let existing =
                user_op_get(&tx, &op.user_op_hash)?.ok_or(StoreError::DataIntegrity {
                    table: TABLE,
                    reason: "insert ignored but existing row missing",
                })?;
            let deleted = tx.execute(
                "DELETE FROM nonce_reservations WHERE chain_id = ? AND bundler_address = ? AND nonce = ? AND status = ?",
                params![
                    nonce_chain_id,
                    nonce_bundler_address,
                    nonce,
                    NonceStatus::Reserved.as_str(),
                ],
            )?;
            if deleted == 0 {
                return Err(StoreError::DataIntegrity {
                    table: "nonce_reservations",
                    reason: "no reserved nonce row to release after duplicate user op",
                });
            }
            UserOpInsertOutcome::AlreadyExists(existing)
        }
        1 => UserOpInsertOutcome::Inserted,
        _ => {
            return Err(StoreError::DataIntegrity {
                table: TABLE,
                reason: "unexpected insert row count",
            });
        }
    };

    tx.commit()?;
    Ok(outcome)
}

pub(crate) fn user_op_get(
    conn: &Connection,
    user_op_hash: &str,
) -> Result<Option<UserOperation>, StoreError> {
    match conn.query_row(
        "SELECT user_op_hash, chain_id, entry_point, sender, nonce, user_op_json, status, created_at, updated_at FROM user_operations WHERE user_op_hash = ?",
        params![user_op_hash],
        |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, u64>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, String>(6)?,
                row.get::<_, i64>(7)?,
                row.get::<_, i64>(8)?,
            ))
        },
    ) {
        Ok(row) => Ok(Some(user_operation_from_row(row)?)),
        Err(Error::QueryReturnedNoRows) => Ok(None),
        Err(err) => Err(err.into()),
    }
}

pub(crate) fn user_op_set_status(
    conn: &Connection,
    user_op_hash: &str,
    status: UserOpStatus,
) -> Result<(), StoreError> {
    let updated = conn.execute(
        "UPDATE user_operations SET status = ?, updated_at = ? WHERE user_op_hash = ?",
        params![status.as_str(), now_unix_seconds(), user_op_hash],
    )?;

    if updated == 0 {
        return Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "no row to update",
        });
    }

    Ok(())
}

#[cfg(test)]
pub(crate) fn user_ops_list_pending(conn: &Connection) -> Result<Vec<UserOperation>, StoreError> {
    let mut stmt = conn.prepare(
        "SELECT user_op_hash, chain_id, entry_point, sender, nonce, user_op_json, status, created_at, updated_at FROM user_operations WHERE status IN ('received', 'simulated', 'submitted', 'pending') ORDER BY updated_at",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, u64>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, String>(4)?,
            row.get::<_, String>(5)?,
            row.get::<_, String>(6)?,
            row.get::<_, i64>(7)?,
            row.get::<_, i64>(8)?,
        ))
    })?;

    let mut ops = Vec::new();
    for row in rows {
        ops.push(user_operation_from_row(row?)?);
    }

    Ok(ops)
}

fn user_operation_from_row(
    row: (
        String,
        u64,
        String,
        String,
        String,
        String,
        String,
        i64,
        i64,
    ),
) -> Result<UserOperation, StoreError> {
    let (
        user_op_hash,
        chain_id,
        entry_point,
        sender,
        nonce,
        user_op_json,
        status,
        created_at,
        updated_at,
    ) = row;

    Ok(UserOperation {
        user_op_hash,
        chain_id,
        entry_point,
        sender,
        nonce,
        user_op_json,
        status: UserOpStatus::from_str(&status, TABLE)?,
        created_at,
        updated_at,
    })
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
    use crate::{db, migrations};

    fn migrated_in_memory_conn() -> rusqlite::Connection {
        let mut conn = db::open_in_memory().unwrap();
        migrations::apply(&mut conn).unwrap();
        conn
    }

    fn user_op(hash: &str, sender: &str, status: UserOpStatus, updated_at: i64) -> UserOperation {
        UserOperation {
            user_op_hash: hash.to_owned(),
            chain_id: 1,
            entry_point: "0xentrypoint".to_owned(),
            sender: sender.to_owned(),
            nonce: "0x01".to_owned(),
            user_op_json: format!(r#"{{"hash":"{hash}","sender":"{sender}"}}"#),
            status,
            created_at: updated_at,
            updated_at,
        }
    }

    #[test]
    fn insert_returns_inserted_on_first_call() {
        let mut conn = migrated_in_memory_conn();

        let outcome = user_op_insert(
            &mut conn,
            user_op("0xaaaa", "0xS1", UserOpStatus::Received, 1),
        )
        .unwrap();

        assert_eq!(outcome, UserOpInsertOutcome::Inserted);
    }

    #[test]
    fn insert_returns_already_exists_on_duplicate_user_op_hash() {
        let mut conn = migrated_in_memory_conn();

        user_op_insert(
            &mut conn,
            user_op("0xaaaa", "0xS1", UserOpStatus::Received, 1),
        )
        .unwrap();
        let outcome = user_op_insert(
            &mut conn,
            UserOperation {
                entry_point: "0xotherentrypoint".to_owned(),
                sender: "0xS2".to_owned(),
                nonce: "0x02".to_owned(),
                user_op_json: r#"{"second":true}"#.to_owned(),
                status: UserOpStatus::Submitted,
                created_at: 2,
                updated_at: 2,
                ..user_op("0xaaaa", "0xS2", UserOpStatus::Submitted, 2)
            },
        )
        .unwrap();

        match outcome {
            UserOpInsertOutcome::AlreadyExists(existing) => {
                assert_eq!(existing.sender, "0xS1");
            }
            other => panic!("expected AlreadyExists, got {other:?}"),
        }
    }

    #[test]
    fn insert_releases_reserved_nonce_atomically_on_duplicate_user_op_hash() {
        let mut conn = migrated_in_memory_conn();

        user_op_insert(
            &mut conn,
            user_op("0xaaaa", "0xS1", UserOpStatus::Received, 1),
        )
        .unwrap();
        conn.execute(
            "INSERT INTO nonce_reservations (chain_id, bundler_address, nonce, status, user_op_hash, tx_hash, created_at, updated_at) VALUES (?, ?, ?, 'reserved', NULL, NULL, ?, ?)",
            params![1_u64, "0xbeef", 7_u64, 1_i64, 1_i64],
        )
        .unwrap();

        let outcome = user_op_insert_abandon_nonce_on_exists(
            &mut conn,
            user_op("0xaaaa", "0xS2", UserOpStatus::Submitted, 2),
            1,
            "0xbeef",
            7,
        )
        .unwrap();
        let nonce_rows: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM nonce_reservations WHERE chain_id = ? AND bundler_address = ? AND nonce = ?",
                params![1_u64, "0xbeef", 7_u64],
                |row| row.get(0),
            )
            .unwrap();

        assert!(matches!(outcome, UserOpInsertOutcome::AlreadyExists(_)));
        assert_eq!(nonce_rows, 0);
    }

    #[test]
    fn get_returns_none_for_missing_hash() {
        let conn = migrated_in_memory_conn();

        assert_eq!(user_op_get(&conn, "0xmissing").unwrap(), None);
    }

    #[test]
    fn set_status_persists() {
        let mut conn = migrated_in_memory_conn();
        user_op_insert(
            &mut conn,
            user_op("0xaaaa", "0xS1", UserOpStatus::Received, 1),
        )
        .unwrap();

        user_op_set_status(&conn, "0xaaaa", UserOpStatus::Submitted).unwrap();
        let op = user_op_get(&conn, "0xaaaa").unwrap().unwrap();

        assert_eq!(op.status, UserOpStatus::Submitted);
    }

    #[test]
    fn list_pending_filters_terminal() {
        let mut conn = migrated_in_memory_conn();
        let statuses = [
            ("0x01", UserOpStatus::Received),
            ("0x02", UserOpStatus::Simulated),
            ("0x03", UserOpStatus::Submitted),
            ("0x04", UserOpStatus::Included),
            ("0x05", UserOpStatus::Reverted),
            ("0x06", UserOpStatus::Failed),
            ("0x07", UserOpStatus::Pending),
        ];

        for (idx, (hash, status)) in statuses.into_iter().enumerate() {
            user_op_insert(
                &mut conn,
                user_op(hash, &format!("0xS{idx}"), status, idx as i64),
            )
            .unwrap();
        }

        let ops = user_ops_list_pending(&conn).unwrap();

        assert_eq!(ops.len(), 4);
        assert_eq!(ops[0].status, UserOpStatus::Received);
        assert_eq!(ops[1].status, UserOpStatus::Simulated);
        assert_eq!(ops[2].status, UserOpStatus::Submitted);
        assert_eq!(ops[3].status, UserOpStatus::Pending);
    }

    #[test]
    fn set_status_no_row_returns_data_integrity() {
        let conn = migrated_in_memory_conn();

        match user_op_set_status(&conn, "0xmissing", UserOpStatus::Submitted).unwrap_err() {
            StoreError::DataIntegrity { table, reason } => {
                assert_eq!(table, TABLE);
                assert_eq!(reason, "no row to update");
            }
            other => panic!("expected DataIntegrity, got {other:?}"),
        }
    }
}
