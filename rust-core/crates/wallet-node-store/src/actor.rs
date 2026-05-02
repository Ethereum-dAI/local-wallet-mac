use std::sync::{Arc, Mutex};

use rusqlite::Connection;
use tokio::sync::mpsc;

use crate::{command::StoreCommand, StoreHandle};

pub struct StoreActor {
    conn: Connection,
}

impl StoreActor {
    pub fn start(conn: Connection) -> StoreHandle {
        let (tx, mut rx) = mpsc::channel::<StoreCommand>(64);

        // TODO(perf): each rusqlite call is brief; if profiling shows actor blocking the runtime, revisit to spawn_blocking.
        let join = tokio::spawn(async move {
            let mut actor = StoreActor { conn };

            loop {
                match rx.recv().await {
                    Some(cmd) => {
                        if actor.handle(cmd) {
                            break;
                        }
                    }
                    None => break,
                }
            }

            actor.checkpoint();
        });

        StoreHandle {
            tx,
            join: Arc::new(Mutex::new(Some(join))),
        }
    }

    fn handle(&mut self, cmd: StoreCommand) -> bool {
        match cmd {
            StoreCommand::Ping { reply } => {
                let _ = reply.send(());
                false
            }
            StoreCommand::MetaGet { key, reply } => {
                let _ = reply.send(crate::repos::daemon_meta::meta_get(&self.conn, &key));
                false
            }
            StoreCommand::MetaSet { key, value, reply } => {
                let _ = reply.send(crate::repos::daemon_meta::meta_set(
                    &self.conn, &key, &value,
                ));
                false
            }
            StoreCommand::MetaDelete { key, reply } => {
                let _ = reply.send(crate::repos::daemon_meta::meta_delete(&self.conn, &key));
                false
            }
            StoreCommand::BundlerAccountInsert {
                chain_id,
                address,
                key_ref,
                reply,
            } => {
                let _ = reply.send(crate::repos::bundler_accounts::bundler_account_insert(
                    &self.conn, chain_id, &address, &key_ref,
                ));
                false
            }
            StoreCommand::BundlerAccountActive { chain_id, reply } => {
                let _ = reply.send(crate::repos::bundler_accounts::bundler_account_active(
                    &self.conn, chain_id,
                ));
                false
            }
            StoreCommand::BundlerAccountSetLifecycle {
                chain_id,
                address,
                new_state,
                reply,
            } => {
                let _ = reply.send(
                    crate::repos::bundler_accounts::bundler_account_set_lifecycle(
                        &self.conn, chain_id, &address, new_state,
                    ),
                );
                false
            }
            StoreCommand::BundlerAccountList { chain_id, reply } => {
                let _ = reply.send(crate::repos::bundler_accounts::bundler_account_list(
                    &self.conn, chain_id,
                ));
                false
            }
            StoreCommand::NonceReserveNext {
                chain_id,
                bundler_address,
                confirmed_nonce,
                reply,
            } => {
                let _ = reply.send(crate::repos::nonce_reservations::reserve_next_nonce(
                    &mut self.conn,
                    chain_id,
                    &bundler_address,
                    confirmed_nonce,
                ));
                false
            }
            StoreCommand::NonceAttachTxHash {
                chain_id,
                bundler_address,
                nonce,
                tx_hash,
                reply,
            } => {
                let _ = reply.send(crate::repos::nonce_reservations::nonce_attach_tx_hash(
                    &self.conn,
                    chain_id,
                    &bundler_address,
                    nonce,
                    &tx_hash,
                ));
                false
            }
            StoreCommand::NonceSetStatus {
                chain_id,
                bundler_address,
                nonce,
                status,
                reply,
            } => {
                let _ = reply.send(crate::repos::nonce_reservations::nonce_set_status(
                    &self.conn,
                    chain_id,
                    &bundler_address,
                    nonce,
                    status,
                ));
                false
            }
            StoreCommand::NoncesListPending {
                chain_id,
                bundler_address,
                reply,
            } => {
                let _ = reply.send(crate::repos::nonce_reservations::nonces_list_pending(
                    &self.conn,
                    chain_id,
                    &bundler_address,
                ));
                false
            }
            StoreCommand::UserOpInsert { op, reply } => {
                let _ = reply.send(crate::repos::user_operations::user_op_insert(
                    &mut self.conn,
                    op,
                ));
                false
            }
            StoreCommand::UserOpGet {
                user_op_hash,
                reply,
            } => {
                let _ = reply.send(crate::repos::user_operations::user_op_get(
                    &self.conn,
                    &user_op_hash,
                ));
                false
            }
            StoreCommand::UserOpSetStatus {
                user_op_hash,
                status,
                reply,
            } => {
                let _ = reply.send(crate::repos::user_operations::user_op_set_status(
                    &self.conn,
                    &user_op_hash,
                    status,
                ));
                false
            }
            StoreCommand::UserOpsListPending { reply } => {
                let _ = reply.send(crate::read::pending_operations(&self.conn));
                false
            }
            StoreCommand::SubmittedTxInsert { tx, reply } => {
                let _ = reply.send(crate::repos::submitted_transactions::submitted_tx_insert(
                    &self.conn, tx,
                ));
                false
            }
            StoreCommand::SubmittedTxGet { tx_hash, reply } => {
                let _ = reply.send(crate::repos::submitted_transactions::submitted_tx_get(
                    &self.conn, &tx_hash,
                ));
                false
            }
            StoreCommand::SubmittedTxSetStatus {
                tx_hash,
                status,
                reply,
            } => {
                let _ = reply.send(
                    crate::repos::submitted_transactions::submitted_tx_set_status(
                        &self.conn, &tx_hash, status,
                    ),
                );
                false
            }
            StoreCommand::SubmittedTxsListForWatcher { reply } => {
                let _ = reply.send(
                    crate::repos::submitted_transactions::submitted_txs_list_for_watcher(
                        &self.conn,
                    ),
                );
                false
            }
            StoreCommand::SubmittedTxsReplace {
                old_tx_hash,
                new_tx,
                reply,
            } => {
                let _ = reply.send(crate::repos::submitted_transactions::submitted_txs_replace(
                    &mut self.conn,
                    &old_tx_hash,
                    new_tx,
                ));
                false
            }
            StoreCommand::ReceiptInsert { receipt, reply } => {
                let _ = reply.send(crate::repos::user_operation_receipts::receipt_insert(
                    &self.conn, receipt,
                ));
                false
            }
            StoreCommand::ReceiptGet {
                user_op_hash,
                reply,
            } => {
                let _ = reply.send(crate::repos::user_operation_receipts::receipt_get(
                    &self.conn,
                    &user_op_hash,
                ));
                false
            }
            StoreCommand::ReceiptsClearTentative { reply } => {
                let _ = reply.send(
                    crate::repos::user_operation_receipts::receipts_clear_tentative(&self.conn),
                );
                false
            }
            StoreCommand::Shutdown { reply } => {
                self.checkpoint();
                let _ = reply.send(());
                true
            }
        }
    }

    fn checkpoint(&self) {
        let _ = self.conn.execute("PRAGMA wal_checkpoint(TRUNCATE);", []);
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        db, migrations, BundlerLifecycle, StoreActor, StoreError, SubmittedTransaction,
        SubmittedTxStatus, UserOpInsertOutcome, UserOpStatus, UserOperation, UserOperationReceipt,
    };

    fn migrated_in_memory_conn() -> rusqlite::Connection {
        let mut conn = db::open_in_memory().unwrap();
        migrations::apply(&mut conn).unwrap();
        conn
    }

    fn receipt(user_op_hash: &str, tx_hash: &str, tentative: bool) -> UserOperationReceipt {
        UserOperationReceipt {
            user_op_hash: user_op_hash.to_owned(),
            tx_hash: tx_hash.to_owned(),
            success: true,
            actual_gas_cost: Some("0x5208".to_owned()),
            actual_gas_used: Some("0x100".to_owned()),
            revert_reason: None,
            receipt_json: format!(r#"{{"userOpHash":"{user_op_hash}","txHash":"{tx_hash}"}}"#),
            tentative,
            created_at: 1,
        }
    }

    #[tokio::test]
    async fn ping_round_trips() {
        let conn = migrated_in_memory_conn();
        let handle = StoreActor::start(conn);

        assert_eq!(handle.ping().await.unwrap(), ());
        handle.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn shutdown_checkpoints_and_exits() {
        let conn = migrated_in_memory_conn();
        let handle = StoreActor::start(conn);

        assert_eq!(handle.shutdown_and_wait().await.unwrap(), ());

        match handle.ping().await {
            Err(StoreError::Backpressure) => {}
            other => panic!("expected Backpressure after shutdown, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn meta_round_trip_through_actor() {
        let conn = migrated_in_memory_conn();
        let handle = StoreActor::start(conn);

        handle.meta_set("k", "v").await.unwrap();
        assert_eq!(handle.meta_get("k").await.unwrap(), Some("v".to_owned()));

        handle.meta_delete("k").await.unwrap();
        assert_eq!(handle.meta_get("k").await.unwrap(), None);

        handle.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn bundler_account_round_trip_through_actor() {
        let conn = migrated_in_memory_conn();
        let handle = StoreActor::start(conn);

        handle
            .bundler_account_insert(1, "0xabc", "bundler-eoa:1")
            .await
            .unwrap();
        let active = handle.bundler_account_active(1).await.unwrap().unwrap();
        assert_eq!(active.address, "0xabc");
        assert_eq!(active.lifecycle, BundlerLifecycle::Active);

        handle
            .bundler_account_set_lifecycle(1, "0xabc", BundlerLifecycle::Retiring)
            .await
            .unwrap();
        let accounts = handle.bundler_account_list(1).await.unwrap();
        assert_eq!(accounts.len(), 1);
        assert_eq!(accounts[0].lifecycle, BundlerLifecycle::Retiring);
        assert!(handle.bundler_account_active(1).await.unwrap().is_none());

        handle.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn nonce_reserve_round_trip_through_actor() {
        let conn = migrated_in_memory_conn();
        let handle = StoreActor::start(conn);

        assert_eq!(handle.reserve_next_nonce(1, "0xtest", 5).await.unwrap(), 5);
        assert_eq!(handle.reserve_next_nonce(1, "0xtest", 5).await.unwrap(), 6);

        let pending = handle.nonces_list_pending(1, "0xtest").await.unwrap();
        assert_eq!(pending.len(), 2);
        assert_eq!(pending[0].nonce, 5);
        assert_eq!(pending[1].nonce, 6);

        handle.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn user_op_insert_idempotent_through_actor() {
        let conn = migrated_in_memory_conn();
        let handle = StoreActor::start(conn);
        let op = UserOperation {
            user_op_hash: "0xaaaa".to_owned(),
            chain_id: 1,
            entry_point: "0xentrypoint".to_owned(),
            sender: "0xS1".to_owned(),
            nonce: "0x01".to_owned(),
            user_op_json: r#"{"first":true}"#.to_owned(),
            status: UserOpStatus::Received,
            created_at: 1,
            updated_at: 1,
        };

        assert_eq!(
            handle.user_op_insert(op.clone()).await.unwrap(),
            UserOpInsertOutcome::Inserted
        );
        let second = handle
            .user_op_insert(UserOperation {
                sender: "0xS2".to_owned(),
                user_op_json: r#"{"second":true}"#.to_owned(),
                updated_at: 2,
                ..op.clone()
            })
            .await
            .unwrap();

        match second {
            UserOpInsertOutcome::AlreadyExists(existing) => {
                assert_eq!(existing.sender, "0xS1");
            }
            other => panic!("expected AlreadyExists, got {other:?}"),
        }

        handle
            .user_op_set_status("0xaaaa", UserOpStatus::Submitted)
            .await
            .unwrap();
        let stored = handle.user_op_get("0xaaaa").await.unwrap().unwrap();
        assert_eq!(stored.status, UserOpStatus::Submitted);

        handle.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn submitted_tx_replace_through_actor() {
        let conn = migrated_in_memory_conn();
        let handle = StoreActor::start(conn);
        let old_tx = SubmittedTransaction {
            tx_hash: "0xaaa".to_owned(),
            user_op_hash: "0xuserop".to_owned(),
            chain_id: 1,
            bundler_address: "0xbeef".to_owned(),
            nonce: 7,
            raw_tx: "0xrawold".to_owned(),
            max_fee_per_gas: "0x3b9aca00".to_owned(),
            max_priority_fee_per_gas: "0x3b9aca0".to_owned(),
            status: SubmittedTxStatus::Submitted,
            replacement_of: None,
            submitted_at_block: Some(100),
            created_at: 1,
            updated_at: 1,
        };
        let new_tx = SubmittedTransaction {
            tx_hash: "0xbbb".to_owned(),
            raw_tx: "0xrawnew".to_owned(),
            status: SubmittedTxStatus::Submitting,
            replacement_of: Some("0xaaa".to_owned()),
            created_at: 2,
            updated_at: 2,
            ..old_tx.clone()
        };

        handle.submitted_tx_insert(old_tx).await.unwrap();
        handle.submitted_txs_replace("0xaaa", new_tx).await.unwrap();

        let old_stored = handle.submitted_tx_get("0xaaa").await.unwrap().unwrap();
        let new_stored = handle.submitted_tx_get("0xbbb").await.unwrap().unwrap();
        assert_eq!(old_stored.status, SubmittedTxStatus::Replaced);
        assert_eq!(new_stored.status, SubmittedTxStatus::Submitting);

        handle.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn receipt_clear_tentative_through_actor() {
        let conn = migrated_in_memory_conn();
        let handle = StoreActor::start(conn);

        handle
            .receipt_insert(receipt("0xtentative", "0xtx1", true))
            .await
            .unwrap();
        handle
            .receipt_insert(receipt("0xconfirmed", "0xtx2", false))
            .await
            .unwrap();

        assert_eq!(handle.receipts_clear_tentative().await.unwrap(), 1);
        assert!(handle.receipt_get("0xconfirmed").await.unwrap().is_some());
        assert!(handle.receipt_get("0xtentative").await.unwrap().is_none());

        handle.shutdown_and_wait().await.unwrap();
    }

    /// Dropping every `StoreHandle` closes the mpsc channel; the actor observes
    /// `rx.recv().await == None`, checkpoints, and exits naturally. This is not
    /// tested here to avoid adding test-only accessors for the private join
    /// handle.
    ///
    /// The full-inbox backpressure path is also not tested in this scaffold
    /// because the production channel capacity is intentionally fixed at 64 and
    /// there is no public API for constructing a smaller inbox without breaking
    /// encapsulation.
    #[allow(dead_code)]
    fn documented_omitted_tests() {}
}
