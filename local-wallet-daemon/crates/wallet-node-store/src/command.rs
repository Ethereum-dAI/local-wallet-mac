use tokio::sync::oneshot;

use crate::{
    AbandonedSubmission, BundlerAccount, BundlerLifecycle, NonceReservation, NonceStatus,
    PendingOperation, RelayerKeyAuditEvent, StoreAuditReport, StoreAuditRunSummary, StoreError,
    SubmittedTransaction, SubmittedTxStatus, UserOpInsertOutcome, UserOpStatus, UserOperation,
    UserOperationReceipt,
};

pub enum StoreCommand {
    Ping {
        reply: oneshot::Sender<()>,
    },
    MetaGet {
        key: String,
        reply: oneshot::Sender<Result<Option<String>, StoreError>>,
    },
    MetaSet {
        key: String,
        value: String,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    MetaDelete {
        key: String,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    BundlerAccountInsert {
        owner_scope: String,
        chain_id: u64,
        address: String,
        key_ref: String,
        lifecycle: BundlerLifecycle,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    BundlerAccountActive {
        owner_scope: String,
        chain_id: u64,
        reply: oneshot::Sender<Result<Option<BundlerAccount>, StoreError>>,
    },
    BundlerAccountPendingFunding {
        owner_scope: String,
        chain_id: u64,
        reply: oneshot::Sender<Result<Option<BundlerAccount>, StoreError>>,
    },
    BundlerAccountActivatePending {
        owner_scope: String,
        chain_id: u64,
        pending_address: String,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    BundlerAccountReplaceActive {
        owner_scope: String,
        chain_id: u64,
        old_address: String,
        new_address: String,
        new_key_ref: String,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    BundlerAccountSetLifecycle {
        owner_scope: String,
        chain_id: u64,
        address: String,
        new_state: BundlerLifecycle,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    BundlerAccountList {
        owner_scope: String,
        chain_id: u64,
        reply: oneshot::Sender<Result<Vec<BundlerAccount>, StoreError>>,
    },
    BundlerAccountMarkUsed {
        owner_scope: String,
        chain_id: u64,
        address: String,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    RelayerKeyAuditInsert {
        event: RelayerKeyAuditEvent,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    RelayerKeyAuditList {
        owner_scope: String,
        chain_id: u64,
        limit: u64,
        reply: oneshot::Sender<Result<Vec<RelayerKeyAuditEvent>, StoreError>>,
    },
    NonceReserveNext {
        chain_id: u64,
        bundler_address: String,
        confirmed_nonce: u64,
        reply: oneshot::Sender<Result<u64, StoreError>>,
    },
    NonceAttachTxHash {
        chain_id: u64,
        bundler_address: String,
        nonce: u64,
        tx_hash: String,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    NonceSetStatus {
        chain_id: u64,
        bundler_address: String,
        nonce: u64,
        status: NonceStatus,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    NoncesListPending {
        chain_id: u64,
        bundler_address: String,
        reply: oneshot::Sender<Result<Vec<NonceReservation>, StoreError>>,
    },
    UserOpInsert {
        op: UserOperation,
        reply: oneshot::Sender<Result<UserOpInsertOutcome, StoreError>>,
    },
    UserOpInsertAbandonNonceOnExists {
        op: UserOperation,
        nonce_chain_id: u64,
        nonce_bundler_address: String,
        nonce: u64,
        reply: oneshot::Sender<Result<UserOpInsertOutcome, StoreError>>,
    },
    UserOpGet {
        user_op_hash: String,
        reply: oneshot::Sender<Result<Option<UserOperation>, StoreError>>,
    },
    UserOpSetStatus {
        user_op_hash: String,
        status: UserOpStatus,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    UserOpsListPending {
        reply: oneshot::Sender<Result<Vec<PendingOperation>, StoreError>>,
    },
    SubmittedTxInsert {
        tx: SubmittedTransaction,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    SubmittedTxGet {
        tx_hash: String,
        reply: oneshot::Sender<Result<Option<SubmittedTransaction>, StoreError>>,
    },
    SubmittedTxSetStatus {
        tx_hash: String,
        status: SubmittedTxStatus,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    SubmittedTxIncrementRecoveryAttempts {
        tx_hash: String,
        reply: oneshot::Sender<Result<u32, StoreError>>,
    },
    SubmittedTxsListForWatcher {
        reply: oneshot::Sender<Result<Vec<SubmittedTransaction>, StoreError>>,
    },
    SubmittedTxsListAll {
        reply: oneshot::Sender<Result<Vec<SubmittedTransaction>, StoreError>>,
    },
    SubmittedTxsAbandonForBundler {
        chain_id: u64,
        bundler_address: String,
        reply: oneshot::Sender<Result<Vec<AbandonedSubmission>, StoreError>>,
    },
    SubmittedTxsReplace {
        old_tx_hash: String,
        new_tx: SubmittedTransaction,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    SubmittedTxsRescueReplace {
        old_tx_hash: String,
        new_tx: SubmittedTransaction,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    ReceiptInsert {
        receipt: UserOperationReceipt,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    ReceiptUpsert {
        receipt: UserOperationReceipt,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    ReceiptGet {
        user_op_hash: String,
        reply: oneshot::Sender<Result<Option<UserOperationReceipt>, StoreError>>,
    },
    ReceiptsListCanonical {
        reply: oneshot::Sender<Result<Vec<UserOperationReceipt>, StoreError>>,
    },
    ReceiptsClearTentative {
        reply: oneshot::Sender<Result<usize, StoreError>>,
    },
    ReceiptMarkTentative {
        user_op_hash: String,
        reply: oneshot::Sender<Result<usize, StoreError>>,
    },
    ReceiptMarkInvalidated {
        user_op_hash: String,
        reply: oneshot::Sender<Result<usize, StoreError>>,
    },
    ReceiptDeleteTentative {
        user_op_hash: String,
        reply: oneshot::Sender<Result<usize, StoreError>>,
    },
    AuditStore {
        reply: oneshot::Sender<Result<StoreAuditReport, StoreError>>,
    },
    AuditReportPersist {
        chain_id: u64,
        synced: bool,
        report: StoreAuditReport,
        reply: oneshot::Sender<Result<i64, StoreError>>,
    },
    AuditHistoryList {
        limit: u64,
        reply: oneshot::Sender<Result<Vec<StoreAuditRunSummary>, StoreError>>,
    },
    AuditReportGet {
        run_id: i64,
        reply: oneshot::Sender<Result<Option<StoreAuditReport>, StoreError>>,
    },
    DiagnosticSet {
        subject_type: String,
        subject_id: String,
        last_error: String,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    DiagnosticClear {
        subject_type: String,
        subject_id: String,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    DiagnosticGet {
        subject_type: String,
        subject_id: String,
        reply: oneshot::Sender<Result<Option<String>, StoreError>>,
    },
    Shutdown {
        reply: oneshot::Sender<()>,
    },
}
