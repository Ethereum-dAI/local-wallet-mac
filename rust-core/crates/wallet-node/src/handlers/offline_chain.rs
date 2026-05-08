use std::future::Future;
use std::pin::Pin;

use wallet_chain::{
    Address, Block, BlockHeader, BlockTag, Bytes, CallRequest, ChainAdapter, ChainError,
    StateOverride, TransactionReceipt, B256, U256,
};

const OFFLINE_REASON: &str = "checkpoint_too_old";
type ChainFuture<'a, T> = Pin<Box<dyn Future<Output = Result<T, ChainError>> + Send + 'a>>;
type BoolFuture<'a> = Pin<Box<dyn Future<Output = bool> + Send + 'a>>;

#[derive(Debug, Default)]
pub struct OfflineChainAdapter;

impl OfflineChainAdapter {
    pub fn new() -> Self {
        Self
    }
}

impl ChainAdapter for OfflineChainAdapter {
    fn eth_get_balance<'life0, 'async_trait>(
        &'life0 self,
        _address: Address,
        _block: BlockTag,
    ) -> ChainFuture<'async_trait, U256>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async { Err(offline_error()) })
    }

    fn eth_get_code<'life0, 'async_trait>(
        &'life0 self,
        _address: Address,
        _block: BlockTag,
    ) -> ChainFuture<'async_trait, Bytes>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async { Err(offline_error()) })
    }

    fn eth_get_storage_at<'life0, 'async_trait>(
        &'life0 self,
        _address: Address,
        _slot: B256,
        _block: BlockTag,
    ) -> ChainFuture<'async_trait, B256>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async { Err(offline_error()) })
    }

    fn eth_get_transaction_count<'life0, 'async_trait>(
        &'life0 self,
        _address: Address,
        _block: BlockTag,
    ) -> ChainFuture<'async_trait, u64>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async { Err(offline_error()) })
    }

    fn eth_call<'life0, 'async_trait>(
        &'life0 self,
        _tx: CallRequest,
        _block: BlockTag,
        _state_overrides: Option<StateOverride>,
    ) -> ChainFuture<'async_trait, Bytes>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async { Err(offline_error()) })
    }

    fn eth_estimate_gas<'life0, 'async_trait>(
        &'life0 self,
        _tx: CallRequest,
        _block: Option<BlockTag>,
        _state_overrides: Option<StateOverride>,
    ) -> ChainFuture<'async_trait, u64>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async { Err(offline_error()) })
    }

    fn eth_get_transaction_receipt<'life0, 'async_trait>(
        &'life0 self,
        _tx_hash: B256,
    ) -> ChainFuture<'async_trait, Option<TransactionReceipt>>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async { Err(offline_error()) })
    }

    fn eth_get_block_by_number<'life0, 'async_trait>(
        &'life0 self,
        _block: BlockTag,
        _full_txs: bool,
    ) -> ChainFuture<'async_trait, Option<Block>>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async { Err(offline_error()) })
    }

    fn current_head<'life0, 'async_trait>(&'life0 self) -> ChainFuture<'async_trait, BlockHeader>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async { Err(offline_error()) })
    }

    fn execution_rpc_head<'life0, 'async_trait>(&'life0 self) -> ChainFuture<'async_trait, u64>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async { Err(offline_error()) })
    }

    fn current_gas_price<'life0, 'async_trait>(&'life0 self) -> ChainFuture<'async_trait, U256>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async { Err(offline_error()) })
    }

    fn current_max_priority_fee_per_gas<'life0, 'async_trait>(
        &'life0 self,
    ) -> ChainFuture<'async_trait, U256>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async { Err(offline_error()) })
    }

    fn is_synced<'life0, 'async_trait>(&'life0 self) -> BoolFuture<'async_trait>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async { false })
    }

    fn offline_reason(&self) -> Option<&'static str> {
        Some(OFFLINE_REASON)
    }
}

fn offline_error() -> ChainError {
    ChainError::CheckpointTooOld {
        reason: OFFLINE_REASON.to_owned(),
    }
}
