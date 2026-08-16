use rusqlite::{params, Connection, TransactionBehavior};

use crate::{
    StoreError, SubmittedTransaction, SubmittedTxStatus, UserOpInsertOutcome, UserOpStatus,
    UserOperation,
};

const TABLE: &str = "submission_bundle";

pub(crate) fn persist_submission_bundle(
    conn: &mut Connection,
    op: UserOperation,
    submitted_tx: SubmittedTransaction,
    nonce_chain_id: u64,
    nonce_bundler_address: &str,
    nonce: u64,
) -> Result<UserOpInsertOutcome, StoreError> {
    persist_submission_bundle_inner(
        conn,
        op,
        submitted_tx,
        nonce_chain_id,
        nonce_bundler_address,
        nonce,
        None,
    )
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PersistFailpoint {
    UserOp,
    SubmittedTx,
    NonceAttachment,
    NonceStatus,
}

fn persist_submission_bundle_inner(
    conn: &mut Connection,
    op: UserOperation,
    submitted_tx: SubmittedTransaction,
    nonce_chain_id: u64,
    nonce_bundler_address: &str,
    nonce: u64,
    failpoint: Option<PersistFailpoint>,
) -> Result<UserOpInsertOutcome, StoreError> {
    validate_bundle(
        &op,
        &submitted_tx,
        nonce_chain_id,
        nonce_bundler_address,
        nonce,
    )?;
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;

    if let Some(existing) = super::user_operations::user_op_get(&tx, &op.user_op_hash)? {
        if existing.status != UserOpStatus::Failed {
            let matching: u64 = tx.query_row(
                "SELECT COUNT(*)
                   FROM submitted_transactions
                  WHERE user_op_hash = ?
                    AND chain_id = ?
                    AND lower(bundler_address) = lower(?)",
                params![&op.user_op_hash, nonce_chain_id, nonce_bundler_address],
                |row| row.get(0),
            )?;
            if matching == 0 {
                return Err(StoreError::DataIntegrity {
                    table: TABLE,
                    reason: "existing user operation has no authority-bound submission",
                });
            }
            tx.commit()?;
            return Ok(UserOpInsertOutcome::AlreadyExists(existing));
        }
    }

    let reservation: (String, Option<String>, Option<String>) = tx.query_row(
        "SELECT status, user_op_hash, tx_hash
           FROM nonce_reservations
          WHERE chain_id = ? AND bundler_address = ? AND nonce = ?",
        params![nonce_chain_id, nonce_bundler_address, nonce],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    )?;
    if reservation.0 != "reserved"
        || reservation.1.as_deref() != Some(op.user_op_hash.as_str())
        || reservation.2.is_some()
    {
        return Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "nonce reservation is not bound to user operation",
        });
    }

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
    if inserted == 0 {
        let updated = tx.execute(
            "UPDATE user_operations
                SET chain_id = ?, entry_point = ?, sender = ?, nonce = ?, user_op_json = ?,
                    status = ?, updated_at = ?
              WHERE user_op_hash = ? AND status = ?",
            params![
                op.chain_id,
                &op.entry_point,
                &op.sender,
                &op.nonce,
                &op.user_op_json,
                op.status.as_str(),
                op.updated_at,
                &op.user_op_hash,
                UserOpStatus::Failed.as_str(),
            ],
        )?;
        if updated != 1 {
            return Err(StoreError::DataIntegrity {
                table: TABLE,
                reason: "failed user operation could not be replaced",
            });
        }
    }
    fail_at(failpoint, PersistFailpoint::UserOp)?;

    let submitted_at_block = submitted_tx.submitted_at_block.map(|block| block as i64);
    tx.execute(
        "INSERT INTO submitted_transactions (tx_hash, user_op_hash, chain_id, bundler_address, nonce, raw_tx, max_fee_per_gas, max_priority_fee_per_gas, status, replacement_of, submitted_at_block, recovery_attempts, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        params![
            &submitted_tx.tx_hash,
            &submitted_tx.user_op_hash,
            submitted_tx.chain_id,
            &submitted_tx.bundler_address,
            submitted_tx.nonce,
            &submitted_tx.raw_tx,
            &submitted_tx.max_fee_per_gas,
            &submitted_tx.max_priority_fee_per_gas,
            submitted_tx.status.as_str(),
            &submitted_tx.replacement_of,
            submitted_at_block,
            submitted_tx.recovery_attempts,
            submitted_tx.created_at,
            submitted_tx.updated_at,
        ],
    )?;
    fail_at(failpoint, PersistFailpoint::SubmittedTx)?;

    let attached = tx.execute(
        "UPDATE nonce_reservations
            SET tx_hash = ?, updated_at = ?
          WHERE chain_id = ?
            AND bundler_address = ?
            AND nonce = ?
            AND status = 'reserved'
            AND user_op_hash = ?
            AND tx_hash IS NULL",
        params![
            &submitted_tx.tx_hash,
            submitted_tx.updated_at,
            nonce_chain_id,
            nonce_bundler_address,
            nonce,
            &op.user_op_hash,
        ],
    )?;
    if attached != 1 {
        return Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "failed to attach submission to reserved nonce",
        });
    }
    fail_at(failpoint, PersistFailpoint::NonceAttachment)?;

    let status_updated = tx.execute(
        "UPDATE nonce_reservations
            SET status = 'submitted', updated_at = ?
          WHERE chain_id = ?
            AND bundler_address = ?
            AND nonce = ?
            AND status = 'reserved'
            AND user_op_hash = ?
            AND tx_hash = ?",
        params![
            submitted_tx.updated_at,
            nonce_chain_id,
            nonce_bundler_address,
            nonce,
            &op.user_op_hash,
            &submitted_tx.tx_hash,
        ],
    )?;
    if status_updated != 1 {
        return Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "failed to commit submitted nonce status",
        });
    }
    fail_at(failpoint, PersistFailpoint::NonceStatus)?;

    tx.commit()?;
    Ok(UserOpInsertOutcome::Inserted)
}

fn validate_bundle(
    op: &UserOperation,
    submitted_tx: &SubmittedTransaction,
    nonce_chain_id: u64,
    nonce_bundler_address: &str,
    nonce: u64,
) -> Result<(), StoreError> {
    if op.user_op_hash != submitted_tx.user_op_hash
        || op.chain_id != nonce_chain_id
        || submitted_tx.chain_id != nonce_chain_id
        || !submitted_tx
            .bundler_address
            .eq_ignore_ascii_case(nonce_bundler_address)
        || submitted_tx.nonce != nonce
        || op.status != UserOpStatus::Submitted
        || submitted_tx.status != SubmittedTxStatus::Submitting
    {
        return Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "submission bundle fields do not agree",
        });
    }
    Ok(())
}

fn fail_at(
    configured: Option<PersistFailpoint>,
    current: PersistFailpoint,
) -> Result<(), StoreError> {
    if configured == Some(current) {
        return Err(StoreError::DataIntegrity {
            table: TABLE,
            reason: "injected submission bundle failure",
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{db, migrations, NonceStatus};

    const HASH: &str = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const TX_HASH: &str = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const BUNDLER: &str = "0xbeef000000000000000000000000000000000000";

    fn migrated_connection() -> Connection {
        let mut conn = db::open_in_memory().unwrap();
        migrations::apply(&mut conn).unwrap();
        conn
    }

    fn user_op() -> UserOperation {
        UserOperation {
            user_op_hash: HASH.to_string(),
            chain_id: 1,
            entry_point: "0x0000000071727de22e5e9d8baf0edac6f37da032".to_string(),
            sender: "0xd73c7780b1c1da1586a8332d5499f36b7cbb33c2".to_string(),
            nonce: "0x1".to_string(),
            user_op_json: "{}".to_string(),
            status: UserOpStatus::Submitted,
            created_at: 1,
            updated_at: 1,
        }
    }

    fn submitted_tx(nonce: u64) -> SubmittedTransaction {
        SubmittedTransaction {
            tx_hash: TX_HASH.to_string(),
            user_op_hash: HASH.to_string(),
            chain_id: 1,
            bundler_address: BUNDLER.to_string(),
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
        }
    }

    #[test]
    fn submission_bundle_rolls_back_every_precommit_failure_and_reuses_nonce() {
        for failpoint in [
            PersistFailpoint::UserOp,
            PersistFailpoint::SubmittedTx,
            PersistFailpoint::NonceAttachment,
            PersistFailpoint::NonceStatus,
        ] {
            let mut conn = migrated_connection();
            let nonce = super::super::nonce_reservations::reserve_next_nonce_for_user_op(
                &mut conn, 1, BUNDLER, 7, HASH,
            )
            .unwrap();
            assert_eq!(nonce, 7);

            let result = persist_submission_bundle_inner(
                &mut conn,
                user_op(),
                submitted_tx(nonce),
                1,
                BUNDLER,
                nonce,
                Some(failpoint),
            );
            assert!(result.is_err(), "{failpoint:?}");
            assert!(super::super::user_operations::user_op_get(&conn, HASH)
                .unwrap()
                .is_none());
            assert!(
                super::super::submitted_transactions::submitted_tx_get(&conn, TX_HASH)
                    .unwrap()
                    .is_none()
            );
            let reservations =
                super::super::nonce_reservations::nonces_list_pending(&conn, 1, BUNDLER).unwrap();
            assert_eq!(reservations.len(), 1);
            assert_eq!(reservations[0].nonce, 7);
            assert_eq!(reservations[0].status, NonceStatus::Reserved);
            assert_eq!(reservations[0].user_op_hash.as_deref(), Some(HASH));
            assert!(reservations[0].tx_hash.is_none());

            let retried = super::super::nonce_reservations::reserve_next_nonce_for_user_op(
                &mut conn, 1, BUNDLER, 7, HASH,
            )
            .unwrap();
            assert_eq!(retried, nonce);
        }
    }

    #[test]
    fn submission_bundle_commit_is_complete_and_restart_retry_is_idempotent() {
        let mut conn = migrated_connection();
        let nonce = super::super::nonce_reservations::reserve_next_nonce_for_user_op(
            &mut conn, 1, BUNDLER, 7, HASH,
        )
        .unwrap();
        let inserted =
            persist_submission_bundle(&mut conn, user_op(), submitted_tx(nonce), 1, BUNDLER, nonce)
                .unwrap();
        assert!(matches!(inserted, UserOpInsertOutcome::Inserted));
        assert!(super::super::user_operations::user_op_get(&conn, HASH)
            .unwrap()
            .is_some());
        assert!(
            super::super::submitted_transactions::submitted_tx_get(&conn, TX_HASH)
                .unwrap()
                .is_some()
        );
        let reservations =
            super::super::nonce_reservations::nonces_list_pending(&conn, 1, BUNDLER).unwrap();
        assert_eq!(reservations.len(), 1);
        assert_eq!(reservations[0].status, NonceStatus::Submitted);
        assert_eq!(reservations[0].user_op_hash.as_deref(), Some(HASH));
        assert_eq!(reservations[0].tx_hash.as_deref(), Some(TX_HASH));

        let retry =
            persist_submission_bundle(&mut conn, user_op(), submitted_tx(nonce), 1, BUNDLER, nonce)
                .unwrap();
        assert!(matches!(retry, UserOpInsertOutcome::AlreadyExists(_)));
    }
}
