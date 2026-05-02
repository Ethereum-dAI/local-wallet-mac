use std::sync::{Arc, Mutex};

use tokio::{
    sync::{
        mpsc::{self, error::TrySendError},
        oneshot,
    },
    task::JoinHandle,
};

use crate::{
    command::StoreCommand, BundlerAccount, BundlerLifecycle, NonceReservation, NonceStatus,
    PendingOperation, StoreError, SubmittedTransaction, SubmittedTxStatus, UserOpInsertOutcome,
    UserOpStatus, UserOperation, UserOperationReceipt,
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
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::BundlerAccountInsert {
            chain_id,
            address: address.to_owned(),
            key_ref: key_ref.to_owned(),
            reply: reply_tx,
        })
        .await?;
        reply_rx.await.map_err(|_| StoreError::Backpressure)?
    }

    pub async fn bundler_account_active(
        &self,
        chain_id: u64,
    ) -> Result<Option<BundlerAccount>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::BundlerAccountActive {
            chain_id,
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
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::BundlerAccountSetLifecycle {
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
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::BundlerAccountList {
            chain_id,
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

    pub async fn submitted_txs_list_for_watcher(
        &self,
    ) -> Result<Vec<SubmittedTransaction>, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::SubmittedTxsListForWatcher { reply: reply_tx })
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

    pub async fn receipt_insert(&self, receipt: UserOperationReceipt) -> Result<(), StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::ReceiptInsert {
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

    pub async fn receipts_clear_tentative(&self) -> Result<usize, StoreError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.send_command(StoreCommand::ReceiptsClearTentative { reply: reply_tx })
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
