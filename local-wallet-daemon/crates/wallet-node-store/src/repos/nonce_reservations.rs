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

    let reused_terminal = tx.execute(
        "UPDATE nonce_reservations
            SET status = 'reserved',
                user_op_hash = NULL,
                tx_hash = NULL,
                updated_at = ?
          WHERE chain_id = ?
            AND bundler_address = ?
            AND nonce = ?
            AND status IN ('failed', 'abandoned')",
        params![now, chain_id, bundler_address, next],
    )?;
    if reused_terminal > 0 {
        tx.commit()?;
        return Ok(next);
    }

    tx.execute(
        "INSERT INTO nonce_reservations (chain_id, bundler_address, nonce, status, user_op_hash, tx_hash, created_at, updated_at) VALUES (?, ?, ?, 'reserved', NULL, NULL, ?, ?)",
        params![chain_id, bundler_address, next, now, now],
    )?;
    tx.commit()?;

    Ok(next)
}

/// Reserves a relayer nonce and binds it to a UserOperation hash. A retry after
/// a process crash reuses the same still-reserved nonce instead of creating a
/// gap before the atomically persisted submission bundle.
pub(crate) fn reserve_next_nonce_for_user_op(
    conn: &mut Connection,
    chain_id: u64,
    bundler_address: &str,
    confirmed_nonce: u64,
    user_op_hash: &str,
) -> Result<u64, StoreError> {
    if user_op_hash.is_empty() {
        return Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "empty user operation hash for nonce reservation",
        });
    }
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let (matching_count, matching_min, matching_max): (u64, Option<i64>, Option<i64>) = tx
        .query_row(
            "SELECT COUNT(*), MIN(nonce), MAX(nonce)
               FROM nonce_reservations
              WHERE chain_id = ?
                AND bundler_address = ?
                AND status = 'reserved'
                AND user_op_hash = ?
                AND tx_hash IS NULL",
            params![chain_id, bundler_address, user_op_hash],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )?;
    if matching_count > 1 || matching_min != matching_max {
        return Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "multiple reserved nonces for user operation",
        });
    }
    if let Some(existing) = matching_min {
        if existing < 0 {
            return Err(StoreError::DataIntegrity {
                table: TABLE,
                reason: "negative nonce in local rows",
            });
        }
        let existing = existing as u64;
        if existing >= confirmed_nonce {
            tx.commit()?;
            return Ok(existing);
        }
        let updated = tx.execute(
            "UPDATE nonce_reservations
                SET status = 'abandoned', updated_at = ?
              WHERE chain_id = ?
                AND bundler_address = ?
                AND nonce = ?
                AND status = 'reserved'
                AND user_op_hash = ?
                AND tx_hash IS NULL",
            params![
                now_unix_seconds(),
                chain_id,
                bundler_address,
                existing,
                user_op_hash
            ],
        )?;
        if updated != 1 {
            return Err(StoreError::DataIntegrity {
                table: TABLE,
                reason: "failed to abandon stale user operation nonce",
            });
        }
    }

    // A bound reservation with no durable UserOperation or submitted
    // transaction cannot have reached the network: raw submission happens only
    // after the atomic submission bundle commits. Reclaim such reservations
    // from crashed/failed *other* operations before choosing the next nonce.
    // The exact operation above keeps its reservation for deterministic retry.
    release_orphaned_prebundle_nonces_for_scope(
        &tx,
        chain_id,
        bundler_address,
        Some(user_op_hash),
    )?;

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
        Some(highest) => std::cmp::max(
            confirmed_nonce,
            (highest as u64)
                .checked_add(1)
                .ok_or(StoreError::DataIntegrity {
                    table: TABLE,
                    reason: "nonce space exhausted",
                })?,
        ),
        None => confirmed_nonce,
    };
    let now = now_unix_seconds();
    let reused_terminal = tx.execute(
        "UPDATE nonce_reservations
            SET status = 'reserved',
                user_op_hash = ?,
                tx_hash = NULL,
                updated_at = ?
          WHERE chain_id = ?
            AND bundler_address = ?
            AND nonce = ?
            AND status IN ('failed', 'abandoned')",
        params![user_op_hash, now, chain_id, bundler_address, next],
    )?;
    if reused_terminal == 0 {
        tx.execute(
            "INSERT INTO nonce_reservations (chain_id, bundler_address, nonce, status, user_op_hash, tx_hash, created_at, updated_at) VALUES (?, ?, ?, 'reserved', ?, NULL, ?, ?)",
            params![chain_id, bundler_address, next, user_op_hash, now, now],
        )?;
    }
    tx.commit()?;
    Ok(next)
}

/// Releases one pre-broadcast reservation after local build/sign/persist
/// failure. The evidence predicates are intentionally redundant: a nonce is
/// never recycled if any UserOperation, transaction, or tx hash could indicate
/// that it progressed beyond the pre-bundle phase.
pub(crate) fn release_prebundle_nonce(
    conn: &mut Connection,
    chain_id: u64,
    bundler_address: &str,
    nonce: u64,
    user_op_hash: &str,
) -> Result<bool, StoreError> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let updated = tx.execute(
        "UPDATE nonce_reservations
            SET status = 'abandoned', updated_at = ?
          WHERE chain_id = ?
            AND lower(bundler_address) = lower(?)
            AND nonce = ?
            AND status = 'reserved'
            AND user_op_hash = ?
            AND tx_hash IS NULL
            AND NOT EXISTS (
                SELECT 1 FROM user_operations AS user_op
                 WHERE user_op.user_op_hash = nonce_reservations.user_op_hash
            )
            AND NOT EXISTS (
                SELECT 1 FROM submitted_transactions AS submitted
                 WHERE submitted.user_op_hash = nonce_reservations.user_op_hash
                    OR (
                        submitted.chain_id = nonce_reservations.chain_id
                        AND lower(submitted.bundler_address) = lower(nonce_reservations.bundler_address)
                        AND submitted.nonce = nonce_reservations.nonce
                    )
            )
            AND NOT EXISTS (
                SELECT 1 FROM user_operation_receipts AS receipt
                 WHERE receipt.user_op_hash = nonce_reservations.user_op_hash
            )",
        params![
            now_unix_seconds(),
            chain_id,
            bundler_address,
            nonce,
            user_op_hash
        ],
    )?;
    tx.commit()?;
    Ok(updated == 1)
}

/// Startup recovery for process death between durable nonce reservation and
/// atomic submission-bundle persistence.
pub(crate) fn release_orphaned_prebundle_nonces(
    conn: &mut Connection,
) -> Result<usize, StoreError> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let updated = release_orphaned_prebundle_nonces_matching(&tx, None, None, None)?;
    tx.commit()?;
    Ok(updated)
}

fn release_orphaned_prebundle_nonces_for_scope(
    conn: &Connection,
    chain_id: u64,
    bundler_address: &str,
    excluded_user_op_hash: Option<&str>,
) -> Result<usize, StoreError> {
    release_orphaned_prebundle_nonces_matching(
        conn,
        Some(chain_id),
        Some(bundler_address),
        excluded_user_op_hash,
    )
}

fn release_orphaned_prebundle_nonces_matching(
    conn: &Connection,
    chain_id: Option<u64>,
    bundler_address: Option<&str>,
    excluded_user_op_hash: Option<&str>,
) -> Result<usize, StoreError> {
    let mut candidate_statement = conn.prepare(
        "SELECT DISTINCT reservation.user_op_hash
           FROM nonce_reservations AS reservation
          WHERE reservation.status = 'reserved'
            AND reservation.user_op_hash IS NOT NULL
            AND reservation.tx_hash IS NULL
            AND (? IS NULL OR reservation.chain_id = ?)
            AND (? IS NULL OR lower(reservation.bundler_address) = lower(?))
            AND (? IS NULL OR reservation.user_op_hash <> ?)
            AND NOT EXISTS (
                SELECT 1 FROM submitted_transactions AS submitted
                 WHERE submitted.user_op_hash = reservation.user_op_hash
                    OR (
                        submitted.chain_id = reservation.chain_id
                        AND lower(submitted.bundler_address) = lower(reservation.bundler_address)
                        AND submitted.nonce = reservation.nonce
                    )
            )
            AND NOT EXISTS (
                SELECT 1 FROM user_operation_receipts AS receipt
                 WHERE receipt.user_op_hash = reservation.user_op_hash
            )",
    )?;
    let candidate_rows = candidate_statement.query_map(
        params![
            chain_id,
            chain_id,
            bundler_address,
            bundler_address,
            excluded_user_op_hash,
            excluded_user_op_hash,
        ],
        |row| row.get::<_, String>(0),
    )?;
    let mut candidate_hashes = Vec::new();
    for row in candidate_rows {
        candidate_hashes.push(row?);
    }
    drop(candidate_statement);

    // Older releases persisted the UserOperation before the submitted
    // transaction. With no tx/receipt evidence, that crash state is known not
    // to have reached raw submission; mark it terminal before recycling the
    // reservation. This update and the reservation update run in one caller
    // transaction.
    for user_op_hash in &candidate_hashes {
        conn.execute(
            "UPDATE user_operations
                SET status = 'failed', updated_at = ?
              WHERE user_op_hash = ? AND status <> 'failed'",
            params![now_unix_seconds(), user_op_hash],
        )?;
    }

    conn.execute(
        "UPDATE nonce_reservations
            SET status = 'abandoned', updated_at = ?
          WHERE status = 'reserved'
            AND user_op_hash IS NOT NULL
            AND tx_hash IS NULL
            AND (? IS NULL OR chain_id = ?)
            AND (? IS NULL OR lower(bundler_address) = lower(?))
            AND (? IS NULL OR user_op_hash <> ?)
            AND NOT EXISTS (
                SELECT 1 FROM user_operations AS user_op
                 WHERE user_op.user_op_hash = nonce_reservations.user_op_hash
                   AND user_op.status <> 'failed'
            )
            AND NOT EXISTS (
                SELECT 1 FROM submitted_transactions AS submitted
                 WHERE submitted.user_op_hash = nonce_reservations.user_op_hash
                    OR (
                        submitted.chain_id = nonce_reservations.chain_id
                        AND lower(submitted.bundler_address) = lower(nonce_reservations.bundler_address)
                        AND submitted.nonce = nonce_reservations.nonce
                    )
            )
            AND NOT EXISTS (
                SELECT 1 FROM user_operation_receipts AS receipt
                 WHERE receipt.user_op_hash = nonce_reservations.user_op_hash
            )",
        params![
            now_unix_seconds(),
            chain_id,
            chain_id,
            bundler_address,
            bundler_address,
            excluded_user_op_hash,
            excluded_user_op_hash,
        ],
    )
    .map_err(StoreError::from)
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
    use crate::{
        db, migrations, StoreActor, SubmittedTransaction, SubmittedTxStatus, UserOpStatus,
        UserOperation,
    };

    const USER_OP_A: &str = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const USER_OP_B: &str = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

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
    fn reserve_reuses_failed_confirmed_nonce() {
        let mut conn = migrated_in_memory_conn();
        insert_nonce(&conn, 3, NonceStatus::Failed);

        assert_eq!(reserve_next_nonce(&mut conn, 1, "0xbeef", 3).unwrap(), 3);
        let (status, tx_hash): (String, Option<String>) = conn
            .query_row(
                "SELECT status, tx_hash FROM nonce_reservations WHERE chain_id = ? AND bundler_address = ? AND nonce = ?",
                params![1_u64, "0xbeef", 3_u64],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();

        assert_eq!(status, "reserved");
        assert_eq!(tx_hash, None);
    }

    #[test]
    fn reserve_reuses_abandoned_confirmed_nonce() {
        let mut conn = migrated_in_memory_conn();
        insert_nonce(&conn, 3, NonceStatus::Abandoned);

        assert_eq!(reserve_next_nonce(&mut conn, 1, "0xbeef", 3).unwrap(), 3);
        let status: String = conn
            .query_row(
                "SELECT status FROM nonce_reservations WHERE chain_id = ? AND bundler_address = ? AND nonce = ?",
                params![1_u64, "0xbeef", 3_u64],
                |row| row.get(0),
            )
            .unwrap();

        assert_eq!(status, "reserved");
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

    #[test]
    fn exact_user_operation_retry_reuses_prebundle_reservation() {
        let mut conn = migrated_in_memory_conn();

        let first = reserve_next_nonce_for_user_op(&mut conn, 1, "0xbeef", 7, USER_OP_A)
            .expect("reserve first nonce");
        let retry = reserve_next_nonce_for_user_op(&mut conn, 1, "0xbeef", 7, USER_OP_A)
            .expect("retry exact operation");

        assert_eq!(first, 7);
        assert_eq!(retry, first);
        let pending = nonces_list_pending(&conn, 1, "0xbeef").unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].user_op_hash.as_deref(), Some(USER_OP_A));
    }

    #[test]
    fn unrelated_operation_reclaims_evidence_free_prebundle_nonce_without_gap() {
        let mut conn = migrated_in_memory_conn();
        assert_eq!(
            reserve_next_nonce_for_user_op(&mut conn, 1, "0xbeef", 7, USER_OP_A).unwrap(),
            7
        );

        let unrelated =
            reserve_next_nonce_for_user_op(&mut conn, 1, "0xbeef", 7, USER_OP_B).unwrap();

        assert_eq!(unrelated, 7);
        let pending = nonces_list_pending(&conn, 1, "0xbeef").unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].user_op_hash.as_deref(), Some(USER_OP_B));
    }

    #[test]
    fn cleanup_recovers_legacy_user_operation_without_submission_evidence() {
        let mut conn = migrated_in_memory_conn();
        let nonce = reserve_next_nonce_for_user_op(&mut conn, 1, "0xbeef", 7, USER_OP_A).unwrap();
        super::super::user_operations::user_op_insert(
            &mut conn,
            UserOperation {
                user_op_hash: USER_OP_A.to_string(),
                chain_id: 1,
                entry_point: "0xentry".to_string(),
                sender: "0xsender".to_string(),
                nonce: "0x0".to_string(),
                user_op_json: "{}".to_string(),
                status: UserOpStatus::Submitted,
                created_at: 1,
                updated_at: 1,
            },
        )
        .unwrap();

        assert!(!release_prebundle_nonce(&mut conn, 1, "0xbeef", nonce, USER_OP_A).unwrap());
        assert_eq!(release_orphaned_prebundle_nonces(&mut conn).unwrap(), 1);
        assert_eq!(
            super::super::user_operations::user_op_get(&conn, USER_OP_A)
                .unwrap()
                .unwrap()
                .status,
            UserOpStatus::Failed
        );
        assert!(nonces_list_pending(&conn, 1, "0xbeef").unwrap().is_empty());
    }

    #[test]
    fn cleanup_never_recycles_when_submitted_transaction_evidence_exists() {
        let mut conn = migrated_in_memory_conn();
        let nonce = reserve_next_nonce_for_user_op(&mut conn, 1, "0xbeef", 7, USER_OP_A).unwrap();
        super::super::user_operations::user_op_insert(
            &mut conn,
            UserOperation {
                user_op_hash: USER_OP_A.to_string(),
                chain_id: 1,
                entry_point: "0xentry".to_string(),
                sender: "0xsender".to_string(),
                nonce: "0x0".to_string(),
                user_op_json: "{}".to_string(),
                status: UserOpStatus::Submitted,
                created_at: 1,
                updated_at: 1,
            },
        )
        .unwrap();
        super::super::submitted_transactions::submitted_tx_insert(
            &conn,
            SubmittedTransaction {
                tx_hash: "0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
                    .to_string(),
                user_op_hash: USER_OP_A.to_string(),
                chain_id: 1,
                bundler_address: "0xbeef".to_string(),
                nonce,
                raw_tx: "0x02c0".to_string(),
                max_fee_per_gas: "0x40".to_string(),
                max_priority_fee_per_gas: "0x5".to_string(),
                status: SubmittedTxStatus::Submitting,
                replacement_of: None,
                submitted_at_block: Some(1),
                recovery_attempts: 0,
                created_at: 1,
                updated_at: 1,
            },
        )
        .unwrap();

        assert_eq!(release_orphaned_prebundle_nonces(&mut conn).unwrap(), 0);
        assert_eq!(
            super::super::user_operations::user_op_get(&conn, USER_OP_A)
                .unwrap()
                .unwrap()
                .status,
            UserOpStatus::Submitted
        );
        assert_eq!(nonces_list_pending(&conn, 1, "0xbeef").unwrap().len(), 1);
    }

    #[test]
    fn restart_cleanup_releases_crashed_prebundle_reservation_for_retirement() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let db_path = std::env::temp_dir().join(format!(
            "wallet-node-prebundle-recovery-{}-{unique}.sqlite",
            std::process::id()
        ));
        {
            let mut conn = db::open(&db_path).unwrap();
            migrations::apply(&mut conn).unwrap();
            assert_eq!(
                reserve_next_nonce_for_user_op(&mut conn, 1, "0xbeef", 7, USER_OP_A).unwrap(),
                7
            );
            super::super::user_operations::user_op_insert(
                &mut conn,
                UserOperation {
                    user_op_hash: USER_OP_A.to_string(),
                    chain_id: 1,
                    entry_point: "0xentry".to_string(),
                    sender: "0xsender".to_string(),
                    nonce: "0x0".to_string(),
                    user_op_json: "{}".to_string(),
                    status: UserOpStatus::Submitted,
                    created_at: 1,
                    updated_at: 1,
                },
            )
            .unwrap();
        }

        let mut restarted = db::open(&db_path).unwrap();
        migrations::apply(&mut restarted).unwrap();
        assert_eq!(
            release_orphaned_prebundle_nonces(&mut restarted).unwrap(),
            1
        );
        assert!(nonces_list_pending(&restarted, 1, "0xbeef")
            .unwrap()
            .is_empty());
        assert_eq!(
            super::super::user_operations::user_op_get(&restarted, USER_OP_A)
                .unwrap()
                .unwrap()
                .status,
            UserOpStatus::Failed
        );
        assert_eq!(
            reserve_next_nonce_for_user_op(&mut restarted, 1, "0xbeef", 7, USER_OP_B).unwrap(),
            7
        );
        drop(restarted);
        std::fs::remove_file(db_path).ok();
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
