use tokio::sync::oneshot;

use crate::{
    BundlerAccount, BundlerLifecycle, NonceReservation, NonceStatus, PendingOperation, StoreError,
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
        chain_id: u64,
        address: String,
        key_ref: String,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    BundlerAccountActive {
        chain_id: u64,
        reply: oneshot::Sender<Result<Option<BundlerAccount>, StoreError>>,
    },
    BundlerAccountSetLifecycle {
        chain_id: u64,
        address: String,
        new_state: BundlerLifecycle,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    BundlerAccountList {
        chain_id: u64,
        reply: oneshot::Sender<Result<Vec<BundlerAccount>, StoreError>>,
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
    SubmittedTxsListForWatcher {
        reply: oneshot::Sender<Result<Vec<SubmittedTransaction>, StoreError>>,
    },
    SubmittedTxsReplace {
        old_tx_hash: String,
        new_tx: SubmittedTransaction,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    ReceiptInsert {
        receipt: UserOperationReceipt,
        reply: oneshot::Sender<Result<(), StoreError>>,
    },
    ReceiptGet {
        user_op_hash: String,
        reply: oneshot::Sender<Result<Option<UserOperationReceipt>, StoreError>>,
    },
    ReceiptsClearTentative {
        reply: oneshot::Sender<Result<usize, StoreError>>,
    },
    Shutdown {
        reply: oneshot::Sender<()>,
    },
}
