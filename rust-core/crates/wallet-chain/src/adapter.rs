use crate::error::ChainError;
use crate::types::{
    Address, Block, BlockHeader, BlockTag, Bytes, CallRequest, StateOverride, TransactionReceipt,
    B256, U256,
};
use async_trait::async_trait;

#[async_trait]
pub trait ChainAdapter: Send + Sync {
    async fn eth_get_balance(&self, address: Address, block: BlockTag) -> Result<U256, ChainError>;

    async fn eth_get_code(&self, address: Address, block: BlockTag) -> Result<Bytes, ChainError>;

    async fn eth_get_storage_at(
        &self,
        address: Address,
        slot: B256,
        block: BlockTag,
    ) -> Result<B256, ChainError>;

    async fn eth_get_transaction_count(
        &self,
        address: Address,
        block: BlockTag,
    ) -> Result<u64, ChainError>;

    async fn eth_call(
        &self,
        tx: CallRequest,
        block: BlockTag,
        state_overrides: Option<StateOverride>,
    ) -> Result<Bytes, ChainError>;

    async fn eth_estimate_gas(
        &self,
        tx: CallRequest,
        block: Option<BlockTag>,
        state_overrides: Option<StateOverride>,
    ) -> Result<u64, ChainError>;

    async fn eth_get_transaction_receipt(
        &self,
        tx_hash: B256,
    ) -> Result<Option<TransactionReceipt>, ChainError>;

    async fn eth_get_block_by_number(
        &self,
        block: BlockTag,
        full_txs: bool,
    ) -> Result<Option<Block>, ChainError>;

    async fn current_head(&self) -> Result<BlockHeader, ChainError>;

    async fn execution_rpc_head(&self) -> Result<u64, ChainError>;

    async fn is_synced(&self) -> bool;

    async fn shutdown(&self) {}

    fn offline_reason(&self) -> Option<&'static str> {
        None
    }

    async fn current_gas_price(&self) -> Result<U256, ChainError>;

    async fn current_max_priority_fee_per_gas(&self) -> Result<U256, ChainError>;
}
