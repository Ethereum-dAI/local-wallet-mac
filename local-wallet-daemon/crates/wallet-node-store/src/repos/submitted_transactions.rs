use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection, Error};

use crate::{AbandonedSubmission, StoreError, SubmittedTransaction, SubmittedTxStatus};

const TABLE: &str = "submitted_transactions";
const INSERT_SQL: &str = "INSERT INTO submitted_transactions (tx_hash, user_op_hash, chain_id, bundler_address, nonce, raw_tx, max_fee_per_gas, max_priority_fee_per_gas, status, replacement_of, submitted_at_block, recovery_attempts, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
const SELECT_COLUMNS: &str = "tx_hash, user_op_hash, chain_id, bundler_address, nonce, raw_tx, max_fee_per_gas, max_priority_fee_per_gas, status, replacement_of, submitted_at_block, recovery_attempts, created_at, updated_at";
type SubmittedTxRow = (
    String,
    String,
    u64,
    String,
    u64,
    String,
    String,
    String,
    String,
    Option<String>,
    Option<i64>,
    u32,
    i64,
    i64,
);

pub(crate) fn submitted_tx_insert(
    conn: &Connection,
    tx: SubmittedTransaction,
) -> Result<(), StoreError> {
    insert_submitted_tx(conn, tx)
}

pub(crate) fn submitted_tx_get(
    conn: &Connection,
    tx_hash: &str,
) -> Result<Option<SubmittedTransaction>, StoreError> {
    match conn.query_row(
        &format!("SELECT {SELECT_COLUMNS} FROM submitted_transactions WHERE tx_hash = ?"),
        params![tx_hash],
        |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, u64>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, u64>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, String>(6)?,
                row.get::<_, String>(7)?,
                row.get::<_, String>(8)?,
                row.get::<_, Option<String>>(9)?,
                row.get::<_, Option<i64>>(10)?,
                row.get::<_, u32>(11)?,
                row.get::<_, i64>(12)?,
                row.get::<_, i64>(13)?,
            ))
        },
    ) {
        Ok(row) => Ok(Some(submitted_tx_from_row(row)?)),
        Err(Error::QueryReturnedNoRows) => Ok(None),
        Err(err) => Err(err.into()),
    }
}

pub(crate) fn submitted_tx_set_status(
    conn: &Connection,
    tx_hash: &str,
    status: SubmittedTxStatus,
) -> Result<(), StoreError> {
    let updated = conn.execute(
        "UPDATE submitted_transactions SET status = ?, updated_at = ? WHERE tx_hash = ?",
        params![status.as_str(), now_unix_seconds(), tx_hash],
    )?;

    if updated == 0 {
        return Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "no row to update",
        });
    }

    Ok(())
}

pub(crate) fn submitted_tx_increment_recovery_attempts(
    conn: &Connection,
    tx_hash: &str,
) -> Result<u32, StoreError> {
    let updated = conn.execute(
        "UPDATE submitted_transactions SET recovery_attempts = recovery_attempts + 1, updated_at = ? WHERE tx_hash = ?",
        params![now_unix_seconds(), tx_hash],
    )?;

    if updated == 0 {
        return Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "no row to update",
        });
    }

    let attempts = conn.query_row(
        "SELECT recovery_attempts FROM submitted_transactions WHERE tx_hash = ?",
        params![tx_hash],
        |row| row.get::<_, u32>(0),
    )?;
    Ok(attempts)
}

pub(crate) fn submitted_txs_list_for_watcher(
    conn: &Connection,
) -> Result<Vec<SubmittedTransaction>, StoreError> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {SELECT_COLUMNS} FROM submitted_transactions WHERE status IN ('submitting', 'submitted') ORDER BY updated_at"
    ))?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, u64>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, u64>(4)?,
            row.get::<_, String>(5)?,
            row.get::<_, String>(6)?,
            row.get::<_, String>(7)?,
            row.get::<_, String>(8)?,
            row.get::<_, Option<String>>(9)?,
            row.get::<_, Option<i64>>(10)?,
            row.get::<_, u32>(11)?,
            row.get::<_, i64>(12)?,
            row.get::<_, i64>(13)?,
        ))
    })?;

    let mut txs = Vec::new();
    for row in rows {
        txs.push(submitted_tx_from_row(row?)?);
    }

    Ok(txs)
}

pub(crate) fn submitted_txs_list_all(
    conn: &Connection,
) -> Result<Vec<SubmittedTransaction>, StoreError> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {SELECT_COLUMNS} FROM submitted_transactions ORDER BY updated_at"
    ))?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, u64>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, u64>(4)?,
            row.get::<_, String>(5)?,
            row.get::<_, String>(6)?,
            row.get::<_, String>(7)?,
            row.get::<_, String>(8)?,
            row.get::<_, Option<String>>(9)?,
            row.get::<_, Option<i64>>(10)?,
            row.get::<_, u32>(11)?,
            row.get::<_, i64>(12)?,
            row.get::<_, i64>(13)?,
        ))
    })?;

    let mut txs = Vec::new();
    for row in rows {
        txs.push(submitted_tx_from_row(row?)?);
    }

    Ok(txs)
}

pub(crate) fn submitted_txs_abandon_for_bundler(
    conn: &mut Connection,
    chain_id: u64,
    bundler_address: &str,
) -> Result<Vec<AbandonedSubmission>, StoreError> {
    let tx = conn.transaction()?;
    let mut abandoned = Vec::new();
    {
        let mut stmt = tx.prepare(
            "SELECT tx_hash, nonce FROM submitted_transactions \
             WHERE chain_id = ? AND lower(bundler_address) = lower(?) \
             AND status IN ('submitting', 'submitted') \
             ORDER BY nonce, tx_hash",
        )?;
        let rows = stmt.query_map(params![chain_id, bundler_address], |row| {
            Ok(AbandonedSubmission {
                tx_hash: row.get::<_, String>(0)?,
                nonce: row.get::<_, u64>(1)?,
            })
        })?;
        for row in rows {
            abandoned.push(row?);
        }
    }

    if !abandoned.is_empty() {
        tx.execute(
            "UPDATE submitted_transactions \
             SET status = 'abandoned', updated_at = ? \
             WHERE chain_id = ? AND lower(bundler_address) = lower(?) \
             AND status IN ('submitting', 'submitted')",
            params![now_unix_seconds(), chain_id, bundler_address],
        )?;
    }

    tx.commit()?;
    Ok(abandoned)
}

pub(crate) fn submitted_txs_replace(
    conn: &mut Connection,
    old_tx_hash: &str,
    new_tx: SubmittedTransaction,
) -> Result<(), StoreError> {
    submitted_txs_replace_inner(conn, old_tx_hash, new_tx, false)
}

pub(crate) fn submitted_txs_rescue_replace(
    conn: &mut Connection,
    old_tx_hash: &str,
    new_tx: SubmittedTransaction,
) -> Result<(), StoreError> {
    submitted_txs_replace_inner(conn, old_tx_hash, new_tx, true)
}

fn submitted_txs_replace_inner(
    conn: &mut Connection,
    old_tx_hash: &str,
    new_tx: SubmittedTransaction,
    allow_terminal_rescue: bool,
) -> Result<(), StoreError> {
    let tx = conn.transaction()?;
    let old_status = match tx.query_row(
        "SELECT status FROM submitted_transactions WHERE tx_hash = ?",
        params![old_tx_hash],
        |row| row.get::<_, String>(0),
    ) {
        Ok(status) => SubmittedTxStatus::from_str(&status, TABLE)?,
        Err(Error::QueryReturnedNoRows) => {
            return Err(StoreError::DataIntegrity {
                table: TABLE,
                reason: "cannot replace terminal-state tx",
            });
        }
        Err(err) => return Err(err.into()),
    };

    if matches!(
        old_status,
        SubmittedTxStatus::Included | SubmittedTxStatus::Failed | SubmittedTxStatus::Dropped
    ) && !(allow_terminal_rescue
        && matches!(
            old_status,
            SubmittedTxStatus::Failed | SubmittedTxStatus::Dropped
        ))
    {
        return Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "cannot replace terminal-state tx",
        });
    }

    insert_submitted_tx(&tx, new_tx)?;

    let updated = tx.execute(
        "UPDATE submitted_transactions SET status = 'replaced', updated_at = ? WHERE tx_hash = ?",
        params![now_unix_seconds(), old_tx_hash],
    )?;
    if updated != 1 {
        return Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "unexpected replace update row count",
        });
    }

    tx.commit()?;
    Ok(())
}

fn insert_submitted_tx(conn: &Connection, tx: SubmittedTransaction) -> Result<(), StoreError> {
    // cast preserves bit pattern; block numbers never exceed i64::MAX in practice
    let submitted_at_block = tx.submitted_at_block.map(|block| block as i64);
    conn.execute(
        INSERT_SQL,
        params![
            &tx.tx_hash,
            &tx.user_op_hash,
            tx.chain_id,
            &tx.bundler_address,
            tx.nonce,
            &tx.raw_tx,
            &tx.max_fee_per_gas,
            &tx.max_priority_fee_per_gas,
            tx.status.as_str(),
            &tx.replacement_of,
            submitted_at_block,
            tx.recovery_attempts,
            tx.created_at,
            tx.updated_at,
        ],
    )?;
    Ok(())
}

fn submitted_tx_from_row(row: SubmittedTxRow) -> Result<SubmittedTransaction, StoreError> {
    let (
        tx_hash,
        user_op_hash,
        chain_id,
        bundler_address,
        nonce,
        raw_tx,
        max_fee_per_gas,
        max_priority_fee_per_gas,
        status,
        replacement_of,
        submitted_at_block,
        recovery_attempts,
        created_at,
        updated_at,
    ) = row;

    Ok(SubmittedTransaction {
        tx_hash,
        user_op_hash,
        chain_id,
        bundler_address,
        nonce,
        raw_tx,
        max_fee_per_gas,
        max_priority_fee_per_gas,
        status: SubmittedTxStatus::from_str(&status, TABLE)?,
        submitted_at_block: submitted_at_block.map(|block| block as u64),
        replacement_of,
        recovery_attempts,
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

    fn submitted_tx(
        tx_hash: &str,
        status: SubmittedTxStatus,
        updated_at: i64,
    ) -> SubmittedTransaction {
        SubmittedTransaction {
            tx_hash: tx_hash.to_owned(),
            user_op_hash: format!("0xuserop{updated_at}"),
            chain_id: 1,
            bundler_address: "0xbeef".to_owned(),
            nonce: updated_at as u64,
            raw_tx: format!("0xraw{updated_at}"),
            max_fee_per_gas: "0x3b9aca00".to_owned(),
            max_priority_fee_per_gas: "0x3b9aca0".to_owned(),
            status,
            replacement_of: None,
            submitted_at_block: Some(100),
            recovery_attempts: 0,
            created_at: updated_at,
            updated_at,
        }
    }

    #[test]
    fn insert_get_round_trips_with_block_number_64bit() {
        let conn = migrated_in_memory_conn();
        let block_number = 2_u64.pow(33);
        let tx = SubmittedTransaction {
            submitted_at_block: Some(block_number),
            ..submitted_tx("0xaaa", SubmittedTxStatus::Submitted, 1)
        };

        submitted_tx_insert(&conn, tx).unwrap();
        let stored = submitted_tx_get(&conn, "0xaaa").unwrap().unwrap();

        assert_eq!(stored.submitted_at_block, Some(block_number));
    }

    #[test]
    fn insert_get_round_trips_with_no_block_number() {
        let conn = migrated_in_memory_conn();
        let tx = SubmittedTransaction {
            submitted_at_block: None,
            ..submitted_tx("0xaaa", SubmittedTxStatus::Submitted, 1)
        };

        submitted_tx_insert(&conn, tx).unwrap();
        let stored = submitted_tx_get(&conn, "0xaaa").unwrap().unwrap();

        assert_eq!(stored.submitted_at_block, None);
        assert_eq!(stored.recovery_attempts, 0);
    }

    #[test]
    fn set_status_persists() {
        let conn = migrated_in_memory_conn();
        submitted_tx_insert(
            &conn,
            submitted_tx("0xaaa", SubmittedTxStatus::Submitting, 1),
        )
        .unwrap();

        submitted_tx_set_status(&conn, "0xaaa", SubmittedTxStatus::Submitted).unwrap();
        let stored = submitted_tx_get(&conn, "0xaaa").unwrap().unwrap();

        assert_eq!(stored.status, SubmittedTxStatus::Submitted);
    }

    #[test]
    fn increment_recovery_attempts_bumps_and_returns_new_count() {
        let conn = migrated_in_memory_conn();
        submitted_tx_insert(
            &conn,
            submitted_tx("0xaaa", SubmittedTxStatus::Submitted, 1),
        )
        .unwrap();

        assert_eq!(
            submitted_tx_increment_recovery_attempts(&conn, "0xaaa").unwrap(),
            1
        );
        assert_eq!(
            submitted_tx_increment_recovery_attempts(&conn, "0xaaa").unwrap(),
            2
        );
        assert_eq!(
            submitted_tx_get(&conn, "0xaaa")
                .unwrap()
                .unwrap()
                .recovery_attempts,
            2
        );
        assert!(matches!(
            submitted_tx_increment_recovery_attempts(&conn, "0xmissing"),
            Err(StoreError::DataIntegrity { .. })
        ));
    }

    #[test]
    fn list_for_watcher_returns_only_pending() {
        let conn = migrated_in_memory_conn();
        let statuses = [
            ("0xsubmitting", SubmittedTxStatus::Submitting),
            ("0xsubmitted", SubmittedTxStatus::Submitted),
            ("0xincluded", SubmittedTxStatus::Included),
            ("0xdropped", SubmittedTxStatus::Dropped),
            ("0xreplaced", SubmittedTxStatus::Replaced),
            ("0xabandoned", SubmittedTxStatus::Abandoned),
            ("0xfailed", SubmittedTxStatus::Failed),
        ];

        for (idx, (hash, status)) in statuses.into_iter().enumerate() {
            submitted_tx_insert(&conn, submitted_tx(hash, status, idx as i64)).unwrap();
        }

        let txs = submitted_txs_list_for_watcher(&conn).unwrap();

        assert_eq!(txs.len(), 2);
        assert_eq!(txs[0].tx_hash, "0xsubmitting");
        assert_eq!(txs[0].status, SubmittedTxStatus::Submitting);
        assert_eq!(txs[1].tx_hash, "0xsubmitted");
        assert_eq!(txs[1].status, SubmittedTxStatus::Submitted);
    }

    #[test]
    fn replace_inserts_new_and_marks_old_replaced() {
        let mut conn = migrated_in_memory_conn();
        submitted_tx_insert(
            &conn,
            submitted_tx("0xaaa", SubmittedTxStatus::Submitted, 1),
        )
        .unwrap();

        submitted_txs_replace(
            &mut conn,
            "0xaaa",
            SubmittedTransaction {
                replacement_of: Some("0xaaa".to_owned()),
                ..submitted_tx("0xbbb", SubmittedTxStatus::Submitting, 2)
            },
        )
        .unwrap();

        let old_tx = submitted_tx_get(&conn, "0xaaa").unwrap().unwrap();
        let new_tx = submitted_tx_get(&conn, "0xbbb").unwrap().unwrap();
        assert_eq!(old_tx.status, SubmittedTxStatus::Replaced);
        assert_eq!(new_tx.status, SubmittedTxStatus::Submitting);
    }

    #[test]
    fn replace_atomicity_when_new_tx_hash_collides() {
        let mut conn = migrated_in_memory_conn();
        submitted_tx_insert(
            &conn,
            submitted_tx("0xaaa", SubmittedTxStatus::Submitted, 1),
        )
        .unwrap();
        submitted_tx_insert(
            &conn,
            submitted_tx("0xbbb", SubmittedTxStatus::Submitted, 2),
        )
        .unwrap();

        let result = submitted_txs_replace(
            &mut conn,
            "0xaaa",
            SubmittedTransaction {
                replacement_of: Some("0xaaa".to_owned()),
                ..submitted_tx("0xbbb", SubmittedTxStatus::Submitting, 3)
            },
        );

        assert!(result.is_err());
        let old_tx = submitted_tx_get(&conn, "0xaaa").unwrap().unwrap();
        assert_eq!(old_tx.status, SubmittedTxStatus::Submitted);
    }

    #[test]
    fn replace_terminal_state_returns_data_integrity() {
        let mut conn = migrated_in_memory_conn();
        submitted_tx_insert(&conn, submitted_tx("0xaaa", SubmittedTxStatus::Included, 1)).unwrap();

        match submitted_txs_replace(
            &mut conn,
            "0xaaa",
            SubmittedTransaction {
                replacement_of: Some("0xaaa".to_owned()),
                ..submitted_tx("0xbbb", SubmittedTxStatus::Submitting, 2)
            },
        )
        .unwrap_err()
        {
            StoreError::DataIntegrity { table, reason } => {
                assert_eq!(table, TABLE);
                assert_eq!(reason, "cannot replace terminal-state tx");
            }
            other => panic!("expected DataIntegrity, got {other:?}"),
        }
    }

    #[test]
    fn rescue_replace_allows_locally_dropped_or_failed_rows() {
        for terminal_status in [SubmittedTxStatus::Dropped, SubmittedTxStatus::Failed] {
            let mut conn = migrated_in_memory_conn();
            submitted_tx_insert(&conn, submitted_tx("0xaaa", terminal_status, 1)).unwrap();

            submitted_txs_rescue_replace(
                &mut conn,
                "0xaaa",
                SubmittedTransaction {
                    replacement_of: Some("0xaaa".to_owned()),
                    ..submitted_tx("0xbbb", SubmittedTxStatus::Submitting, 2)
                },
            )
            .unwrap();

            let old_tx = submitted_tx_get(&conn, "0xaaa").unwrap().unwrap();
            let new_tx = submitted_tx_get(&conn, "0xbbb").unwrap().unwrap();
            assert_eq!(old_tx.status, SubmittedTxStatus::Replaced);
            assert_eq!(new_tx.status, SubmittedTxStatus::Submitting);
        }
    }
}
