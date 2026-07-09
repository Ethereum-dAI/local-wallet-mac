use std::sync::{Arc, Mutex};

use tokio::{
    sync::{
        mpsc::{self, error::TrySendError},
        oneshot,
    },
    task::JoinHandle,
};

use crate::DEFAULT_OWNER_SCOPE;
use crate::{
    command::StoreCommand, AbandonedSubmission, BundlerAccount, BundlerLifecycle, NonceReservation,
    NonceStatus, PendingOperation, RelayerKeyAuditEvent, StoreAuditReport, StoreAuditRunSummary,
    StoreError, SubmittedTransaction, SubmittedTxStatus, UserOpInsertOutcome, UserOpStatus,
    UserOperation, UserOperationReceipt,
};

#[derive(Clone)]
pub struct StoreHandle {
    pub(crate) tx: mpsc::Sender<StoreCommand>,
    pub(crate) join: Arc<Mutex<Option<JoinHandle<()>>>>,
}

impl StoreHandle {
    pub async fn ping(&self) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::Ping { reply: reply_tx })
            .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)
    }

    pub async fn meta_get(&self, key: &str) -> Result<Option<String>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::MetaGet {
            key: key.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn meta_set(&self, key: &str, value: &str) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::MetaSet {
            key: key.to_owned(),
            value: value.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn meta_delete(&self, key: &str) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::MetaDelete {
            key: key.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn bundler_account_insert(
        &self,
        chain_id: u64,
        address: &str,
        key_ref: &str,
    ) -> Result<(), StoreError> {
        self.bundler_account_insert_for_owner(
            DEFAULT_OWNER_SCOPE,
            chain_id,
            address,
            key_ref,
            BundlerLifecycle::Active,
        )
        .await
    }

    pub async fn bundler_account_insert_for_owner(
        &self,
        owner_scope: &str,
        chain_id: u64,
        address: &str,
        key_ref: &str,
        lifecycle: BundlerLifecycle,
    ) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::BundlerAccountInsert {
            owner_scope: owner_scope.to_owned(),
            chain_id,
            address: address.to_owned(),
            key_ref: key_ref.to_owned(),
            lifecycle,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn bundler_account_active(
        &self,
        chain_id: u64,
    ) -> Result<Option<BundlerAccount>, StoreError> {
        self.bundler_account_active_for_owner(DEFAULT_OWNER_SCOPE, chain_id)
            .await
    }

    pub async fn bundler_account_active_for_owner(
        &self,
        owner_scope: &str,
        chain_id: u64,
    ) -> Result<Option<BundlerAccount>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::BundlerAccountActive {
            owner_scope: owner_scope.to_owned(),
            chain_id,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn bundler_account_pending_funding_for_owner(
        &self,
        owner_scope: &str,
        chain_id: u64,
    ) -> Result<Option<BundlerAccount>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::BundlerAccountPendingFunding {
            owner_scope: owner_scope.to_owned(),
            chain_id,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn bundler_account_activate_pending_for_owner(
        &self,
        owner_scope: &str,
        chain_id: u64,
        pending_address: &str,
    ) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::BundlerAccountActivatePending {
            owner_scope: owner_scope.to_owned(),
            chain_id,
            pending_address: pending_address.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn bundler_account_replace_active_for_owner(
        &self,
        owner_scope: &str,
        chain_id: u64,
        old_address: &str,
        new_address: &str,
        new_key_ref: &str,
    ) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::BundlerAccountReplaceActive {
            owner_scope: owner_scope.to_owned(),
            chain_id,
            old_address: old_address.to_owned(),
            new_address: new_address.to_owned(),
            new_key_ref: new_key_ref.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn bundler_account_set_lifecycle(
        &self,
        chain_id: u64,
        address: &str,
        new_state: BundlerLifecycle,
    ) -> Result<(), StoreError> {
        self.bundler_account_set_lifecycle_for_owner(
            DEFAULT_OWNER_SCOPE,
            chain_id,
            address,
            new_state,
        )
        .await
    }

    pub async fn bundler_account_set_lifecycle_for_owner(
        &self,
        owner_scope: &str,
        chain_id: u64,
        address: &str,
        new_state: BundlerLifecycle,
    ) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::BundlerAccountSetLifecycle {
            owner_scope: owner_scope.to_owned(),
            chain_id,
            address: address.to_owned(),
            new_state,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn bundler_account_list(
        &self,
        chain_id: u64,
    ) -> Result<Vec<BundlerAccount>, StoreError> {
        self.bundler_account_list_for_owner(DEFAULT_OWNER_SCOPE, chain_id)
            .await
    }

    pub async fn bundler_account_list_for_owner(
        &self,
        owner_scope: &str,
        chain_id: u64,
    ) -> Result<Vec<BundlerAccount>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::BundlerAccountList {
            owner_scope: owner_scope.to_owned(),
            chain_id,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn bundler_account_mark_used_for_owner(
        &self,
        owner_scope: &str,
        chain_id: u64,
        address: &str,
    ) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::BundlerAccountMarkUsed {
            owner_scope: owner_scope.to_owned(),
            chain_id,
            address: address.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn relayer_key_audit_insert(
        &self,
        event: RelayerKeyAuditEvent,
    ) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::RelayerKeyAuditInsert {
            event,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn relayer_key_audit_list(
        &self,
        owner_scope: &str,
        chain_id: u64,
        limit: u64,
    ) -> Result<Vec<RelayerKeyAuditEvent>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::RelayerKeyAuditList {
            owner_scope: owner_scope.to_owned(),
            chain_id,
            limit,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn reserve_next_nonce(
        &self,
        chain_id: u64,
        bundler_address: &str,
        confirmed_nonce: u64,
    ) -> Result<u64, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::NonceReserveNext {
            chain_id,
            bundler_address: bundler_address.to_owned(),
            confirmed_nonce,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn nonce_attach_tx_hash(
        &self,
        chain_id: u64,
        bundler_address: &str,
        nonce: u64,
        tx_hash: &str,
    ) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::NonceAttachTxHash {
            chain_id,
            bundler_address: bundler_address.to_owned(),
            nonce,
            tx_hash: tx_hash.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn nonce_set_status(
        &self,
        chain_id: u64,
        bundler_address: &str,
        nonce: u64,
        status: NonceStatus,
    ) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::NonceSetStatus {
            chain_id,
            bundler_address: bundler_address.to_owned(),
            nonce,
            status,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn nonces_list_pending(
        &self,
        chain_id: u64,
        bundler_address: &str,
    ) -> Result<Vec<NonceReservation>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::NoncesListPending {
            chain_id,
            bundler_address: bundler_address.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn user_op_insert(
        &self,
        op: UserOperation,
    ) -> Result<UserOpInsertOutcome, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::UserOpInsert {
            op,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn user_op_insert_abandon_nonce_on_exists(
        &self,
        op: UserOperation,
        nonce_chain_id: u64,
        nonce_bundler_address: &str,
        nonce: u64,
    ) -> Result<UserOpInsertOutcome, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::UserOpInsertAbandonNonceOnExists {
            op,
            nonce_chain_id,
            nonce_bundler_address: nonce_bundler_address.to_owned(),
            nonce,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn user_op_get(
        &self,
        user_op_hash: &str,
    ) -> Result<Option<UserOperation>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::UserOpGet {
            user_op_hash: user_op_hash.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn user_op_set_status(
        &self,
        user_op_hash: &str,
        status: UserOpStatus,
    ) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::UserOpSetStatus {
            user_op_hash: user_op_hash.to_owned(),
            status,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn user_ops_list_pending(&self) -> Result<Vec<PendingOperation>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::UserOpsListPending { reply: reply_tx })
            .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn submitted_tx_insert(&self, tx: SubmittedTransaction) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::SubmittedTxInsert {
            tx,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn submitted_tx_get(
        &self,
        tx_hash: &str,
    ) -> Result<Option<SubmittedTransaction>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::SubmittedTxGet {
            tx_hash: tx_hash.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn submitted_tx_set_status(
        &self,
        tx_hash: &str,
        status: SubmittedTxStatus,
    ) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::SubmittedTxSetStatus {
            tx_hash: tx_hash.to_owned(),
            status,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn submitted_tx_increment_recovery_attempts(
        &self,
        tx_hash: &str,
    ) -> Result<u32, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::SubmittedTxIncrementRecoveryAttempts {
            tx_hash: tx_hash.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn submitted_txs_list_for_watcher(
        &self,
    ) -> Result<Vec<SubmittedTransaction>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::SubmittedTxsListForWatcher { reply: reply_tx })
            .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn submitted_txs_list_all(&self) -> Result<Vec<SubmittedTransaction>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::SubmittedTxsListAll { reply: reply_tx })
            .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn submitted_txs_abandon_for_bundler(
        &self,
        chain_id: u64,
        bundler_address: &str,
    ) -> Result<Vec<AbandonedSubmission>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::SubmittedTxsAbandonForBundler {
            chain_id,
            bundler_address: bundler_address.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn submitted_txs_replace(
        &self,
        old_tx_hash: &str,
        new_tx: SubmittedTransaction,
    ) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::SubmittedTxsReplace {
            old_tx_hash: old_tx_hash.to_owned(),
            new_tx,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn submitted_txs_rescue_replace(
        &self,
        old_tx_hash: &str,
        new_tx: SubmittedTransaction,
    ) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::SubmittedTxsRescueReplace {
            old_tx_hash: old_tx_hash.to_owned(),
            new_tx,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn receipt_insert(&self, receipt: UserOperationReceipt) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::ReceiptInsert {
            receipt,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn receipt_upsert(&self, receipt: UserOperationReceipt) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::ReceiptUpsert {
            receipt,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn receipt_get(
        &self,
        user_op_hash: &str,
    ) -> Result<Option<UserOperationReceipt>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::ReceiptGet {
            user_op_hash: user_op_hash.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn receipts_list_canonical(&self) -> Result<Vec<UserOperationReceipt>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::ReceiptsListCanonical { reply: reply_tx })
            .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn receipts_clear_tentative(&self) -> Result<usize, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::ReceiptsClearTentative { reply: reply_tx })
            .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn receipt_mark_tentative(&self, user_op_hash: &str) -> Result<usize, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::ReceiptMarkTentative {
            user_op_hash: user_op_hash.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn receipt_mark_invalidated(&self, user_op_hash: &str) -> Result<usize, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::ReceiptMarkInvalidated {
            user_op_hash: user_op_hash.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn receipt_delete_tentative(&self, user_op_hash: &str) -> Result<usize, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::ReceiptDeleteTentative {
            user_op_hash: user_op_hash.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn audit_store(&self) -> Result<StoreAuditReport, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::AuditStore { reply: reply_tx })
            .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn audit_report_persist(
        &self,
        chain_id: u64,
        synced: bool,
        report: StoreAuditReport,
    ) -> Result<i64, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::AuditReportPersist {
            chain_id,
            synced,
            report,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn audit_history_list(
        &self,
        limit: u64,
    ) -> Result<Vec<StoreAuditRunSummary>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::AuditHistoryList {
            limit,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn audit_report_get(
        &self,
        run_id: i64,
    ) -> Result<Option<StoreAuditReport>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::AuditReportGet {
            run_id,
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn diagnostic_set(
        &self,
        subject_type: &str,
        subject_id: &str,
        last_error: &str,
    ) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::DiagnosticSet {
            subject_type: subject_type.to_owned(),
            subject_id: subject_id.to_owned(),
            last_error: last_error.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn diagnostic_clear(
        &self,
        subject_type: &str,
        subject_id: &str,
    ) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::DiagnosticClear {
            subject_type: subject_type.to_owned(),
            subject_id: subject_id.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn diagnostic_get(
        &self,
        subject_type: &str,
        subject_id: &str,
    ) -> Result<Option<String>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::DiagnosticGet {
            subject_type: subject_type.to_owned(),
            subject_id: subject_id.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn shutdown_and_wait(&self) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::Shutdown { reply: reply_tx })
            .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?;

        let join = self
            .join
            .lock()
            .map_err(|_| StoreError::Backpressure)?
            .take();

        if let Some(join) = join {
            join.await.map_err(|_| StoreError::Backpressure)?;
        }

        Ok(())
    }

    async fn send_command(&self, cmd: StoreCommand) -> Result<(), StoreError> {
        match self.tx.try_send(cmd) {
            Ok(()) => Ok(()),
            Err(TrySendError::Full(_)) => Err(StoreError::Backpressure),
            Err(TrySendError::Closed(_)) => Err(StoreError::Backpressure),
        }
    }
}
