use crate::adapter::ChainAdapter;
use crate::error::ChainError;
use crate::types::{
    Address, Block, BlockHeader, BlockTag, Bytes, CallRequest, StateOverride, TransactionReceipt,
    B256, U256,
};
use async_trait::async_trait;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard};

type ErrorFactory = Box<dyn Fn() -> ChainError + Send + Sync>;

#[derive(Default)]
pub struct MockChainAdapter {
    state: Mutex<MockState>,
    balance_calls: AtomicU64,
    code_calls: AtomicU64,
    storage_calls: AtomicU64,
    transaction_count_calls: AtomicU64,
    call_calls: AtomicU64,
    estimate_gas_calls: AtomicU64,
    receipt_calls: AtomicU64,
    block_calls: AtomicU64,
    current_head_calls: AtomicU64,
    execution_rpc_head_calls: AtomicU64,
    current_gas_price_calls: AtomicU64,
    current_max_priority_fee_calls: AtomicU64,
    is_synced_calls: AtomicU64,
}

#[derive(Default)]
struct MockState {
    balances: BTreeMap<(Address, BlockTag), U256>,
    codes: BTreeMap<(Address, BlockTag), Bytes>,
    storage: BTreeMap<(Address, B256, BlockTag), B256>,
    nonces: BTreeMap<(Address, BlockTag), u64>,
    calls: BTreeMap<(CallRequest, BlockTag, Option<StateOverride>), Bytes>,
    call_reverts: BTreeMap<(CallRequest, BlockTag, Option<StateOverride>), Bytes>,
    gas_estimates: BTreeMap<(CallRequest, Option<BlockTag>, Option<StateOverride>), u64>,
    receipts: BTreeMap<B256, TransactionReceipt>,
    blocks: BTreeMap<(BlockTag, bool), Block>,
    current_head: Option<BlockHeader>,
    execution_rpc_head: u64,
    synced: bool,
    current_gas_price: Option<U256>,
    current_max_priority_fee_per_gas: Option<U256>,
    error_factory: Option<ErrorFactory>,
    current_head_error_factory: Option<ErrorFactory>,
}

impl MockChainAdapter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_synced(synced: bool) -> Self {
        let adapter = Self::new();
        adapter.set_synced(synced);
        adapter
    }

    pub fn set_balance(&self, address: Address, block: BlockTag, value: U256) -> &Self {
        self.state().balances.insert((address, block), value);
        self
    }

    pub fn set_code(&self, address: Address, block: BlockTag, code: Bytes) -> &Self {
        self.state().codes.insert((address, block), code);
        self
    }

    pub fn set_storage_at(
        &self,
        address: Address,
        slot: B256,
        block: BlockTag,
        value: B256,
    ) -> &Self {
        self.state().storage.insert((address, slot, block), value);
        self
    }

    pub fn set_transaction_count(&self, address: Address, block: BlockTag, nonce: u64) -> &Self {
        self.state().nonces.insert((address, block), nonce);
        self
    }

    pub fn set_call_response(
        &self,
        tx: CallRequest,
        block: BlockTag,
        state_overrides: Option<StateOverride>,
        response: Bytes,
    ) -> &Self {
        self.state()
            .calls
            .insert((tx, block, state_overrides), response);
        self
    }

    pub fn set_call_revert(
        &self,
        tx: CallRequest,
        block: BlockTag,
        state_overrides: Option<StateOverride>,
        revert_data: Bytes,
    ) -> &Self {
        self.state()
            .call_reverts
            .insert((tx, block, state_overrides), revert_data);
        self
    }

    pub fn set_gas_estimate(
        &self,
        tx: CallRequest,
        block: Option<BlockTag>,
        state_overrides: Option<StateOverride>,
        gas: u64,
    ) -> &Self {
        self.state()
            .gas_estimates
            .insert((tx, block, state_overrides), gas);
        self
    }

    pub fn set_transaction_receipt(&self, tx_hash: B256, receipt: TransactionReceipt) -> &Self {
        self.state().receipts.insert(tx_hash, receipt);
        self
    }

    pub fn set_block(&self, block: BlockTag, full_txs: bool, response: Block) -> &Self {
        self.state().blocks.insert((block, full_txs), response);
        self
    }

    pub fn set_current_head(&self, header: BlockHeader) -> &Self {
        self.state().current_head = Some(header);
        self
    }

    pub fn set_execution_rpc_head(&self, head: u64) -> &Self {
        self.state().execution_rpc_head = head;
        self
    }

    pub fn set_synced(&self, synced: bool) -> &Self {
        self.state().synced = synced;
        self
    }

    pub fn set_current_gas_price(&self, value: U256) -> &Self {
        self.state().current_gas_price = Some(value);
        self
    }

    pub fn set_current_max_priority_fee_per_gas(&self, value: U256) -> &Self {
        self.state().current_max_priority_fee_per_gas = Some(value);
        self
    }

    pub fn inject_error(&self, error_factory: ErrorFactory) -> &Self {
        self.state().error_factory = Some(error_factory);
        self
    }

    pub fn inject_current_head_error(&self, error_factory: ErrorFactory) -> &Self {
        self.state().current_head_error_factory = Some(error_factory);
        self
    }

    pub fn clear_error(&self) -> &Self {
        self.state().error_factory = None;
        self
    }

    pub fn balance_call_count(&self) -> u64 {
        self.balance_calls.load(Ordering::SeqCst)
    }

    pub fn code_call_count(&self) -> u64 {
        self.code_calls.load(Ordering::SeqCst)
    }

    pub fn storage_call_count(&self) -> u64 {
        self.storage_calls.load(Ordering::SeqCst)
    }

    pub fn transaction_count_call_count(&self) -> u64 {
        self.transaction_count_calls.load(Ordering::SeqCst)
    }

    pub fn call_call_count(&self) -> u64 {
        self.call_calls.load(Ordering::SeqCst)
    }

    pub fn estimate_gas_call_count(&self) -> u64 {
        self.estimate_gas_calls.load(Ordering::SeqCst)
    }

    pub fn receipt_call_count(&self) -> u64 {
        self.receipt_calls.load(Ordering::SeqCst)
    }

    pub fn block_call_count(&self) -> u64 {
        self.block_calls.load(Ordering::SeqCst)
    }

    pub fn current_head_call_count(&self) -> u64 {
        self.current_head_calls.load(Ordering::SeqCst)
    }

    pub fn execution_rpc_head_call_count(&self) -> u64 {
        self.execution_rpc_head_calls.load(Ordering::SeqCst)
    }

    pub fn current_gas_price_call_count(&self) -> u64 {
        self.current_gas_price_calls.load(Ordering::SeqCst)
    }

    pub fn current_max_priority_fee_call_count(&self) -> u64 {
        self.current_max_priority_fee_calls.load(Ordering::SeqCst)
    }

    pub fn is_synced_call_count(&self) -> u64 {
        self.is_synced_calls.load(Ordering::SeqCst)
    }

    fn state(&self) -> MutexGuard<'_, MockState> {
        self.state
            .lock()
            .expect("mock chain adapter mutex should not be poisoned")
    }

    fn injected_error(state: &MockState) -> Option<ChainError> {
        state.error_factory.as_ref().map(|factory| factory())
    }
}

#[async_trait]
impl ChainAdapter for MockChainAdapter {
    async fn eth_get_balance(&self, address: Address, block: BlockTag) -> Result<U256, ChainError> {
        self.balance_calls.fetch_add(1, Ordering::SeqCst);
        let state = self.state();
        if let Some(error) = Self::injected_error(&state) {
            return Err(error);
        }
        Ok(*state.balances.get(&(address, block)).unwrap_or(&U256::ZERO))
    }

    async fn eth_get_code(&self, address: Address, block: BlockTag) -> Result<Bytes, ChainError> {
        self.code_calls.fetch_add(1, Ordering::SeqCst);
        let state = self.state();
        if let Some(error) = Self::injected_error(&state) {
            return Err(error);
        }
        Ok(state
            .codes
            .get(&(address, block))
            .cloned()
            .unwrap_or_default())
    }

    async fn eth_get_storage_at(
        &self,
        address: Address,
        slot: B256,
        block: BlockTag,
    ) -> Result<B256, ChainError> {
        self.storage_calls.fetch_add(1, Ordering::SeqCst);
        let state = self.state();
        if let Some(error) = Self::injected_error(&state) {
            return Err(error);
        }
        Ok(*state
            .storage
            .get(&(address, slot, block))
            .unwrap_or(&B256::ZERO))
    }

    async fn eth_get_transaction_count(
        &self,
        address: Address,
        block: BlockTag,
    ) -> Result<u64, ChainError> {
        self.transaction_count_calls.fetch_add(1, Ordering::SeqCst);
        let state = self.state();
        if let Some(error) = Self::injected_error(&state) {
            return Err(error);
        }
        Ok(*state.nonces.get(&(address, block)).unwrap_or(&0))
    }

    async fn eth_call(
        &self,
        tx: CallRequest,
        block: BlockTag,
        state_overrides: Option<StateOverride>,
    ) -> Result<Bytes, ChainError> {
        self.call_calls.fetch_add(1, Ordering::SeqCst);
        let state = self.state();
        if let Some(error) = Self::injected_error(&state) {
            return Err(error);
        }
        if let Some(revert_data) =
            state
                .call_reverts
                .get(&(tx.clone(), block, state_overrides.clone()))
        {
            return Err(ChainError::CallReverted(revert_data.clone()));
        }
        state
            .calls
            .get(&(tx, block, state_overrides))
            .cloned()
            .ok_or(ChainError::BlockNotFound)
    }

    async fn eth_estimate_gas(
        &self,
        tx: CallRequest,
        block: Option<BlockTag>,
        state_overrides: Option<StateOverride>,
    ) -> Result<u64, ChainError> {
        self.estimate_gas_calls.fetch_add(1, Ordering::SeqCst);
        let state = self.state();
        if let Some(error) = Self::injected_error(&state) {
            return Err(error);
        }
        state
            .gas_estimates
            .get(&(tx, block, state_overrides))
            .copied()
            .ok_or(ChainError::BlockNotFound)
    }

    async fn eth_get_transaction_receipt(
        &self,
        tx_hash: B256,
    ) -> Result<Option<TransactionReceipt>, ChainError> {
        self.receipt_calls.fetch_add(1, Ordering::SeqCst);
        let state = self.state();
        if let Some(error) = Self::injected_error(&state) {
            return Err(error);
        }
        Ok(state.receipts.get(&tx_hash).cloned())
    }

    async fn eth_get_block_by_number(
        &self,
        block: BlockTag,
        full_txs: bool,
    ) -> Result<Option<Block>, ChainError> {
        self.block_calls.fetch_add(1, Ordering::SeqCst);
        let state = self.state();
        if let Some(error) = Self::injected_error(&state) {
            return Err(error);
        }
        Ok(state.blocks.get(&(block, full_txs)).cloned())
    }

    async fn current_head(&self) -> Result<BlockHeader, ChainError> {
        self.current_head_calls.fetch_add(1, Ordering::SeqCst);
        let state = self.state();
        if let Some(error) = state
            .current_head_error_factory
            .as_ref()
            .map(|factory| factory())
        {
            return Err(error);
        }
        if let Some(error) = Self::injected_error(&state) {
            return Err(error);
        }
        state.current_head.clone().ok_or(ChainError::BlockNotFound)
    }

    async fn execution_rpc_head(&self) -> Result<u64, ChainError> {
        self.execution_rpc_head_calls.fetch_add(1, Ordering::SeqCst);
        let state = self.state();
        if let Some(error) = Self::injected_error(&state) {
            return Err(error);
        }
        Ok(state.execution_rpc_head)
    }

    async fn current_gas_price(&self) -> Result<U256, ChainError> {
        self.current_gas_price_calls.fetch_add(1, Ordering::SeqCst);
        let state = self.state();
        if let Some(error) = Self::injected_error(&state) {
            return Err(error);
        }
        Ok(state.current_gas_price.unwrap_or(U256::ZERO))
    }

    async fn current_max_priority_fee_per_gas(&self) -> Result<U256, ChainError> {
        self.current_max_priority_fee_calls
            .fetch_add(1, Ordering::SeqCst);
        let state = self.state();
        if let Some(error) = Self::injected_error(&state) {
            return Err(error);
        }
        Ok(state.current_max_priority_fee_per_gas.unwrap_or(U256::ZERO))
    }

    async fn is_synced(&self) -> bool {
        self.is_synced_calls.fetch_add(1, Ordering::SeqCst);
        self.state().synced
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{AccountOverride, BlockTransaction, Log, Transaction};

    fn address(byte: u8) -> Address {
        Address::from([byte; 20])
    }

    fn hash(byte: u8) -> B256 {
        B256::from([byte; 32])
    }

    fn header(number: u64) -> BlockHeader {
        BlockHeader {
            number,
            hash: hash(1),
            parent_hash: hash(2),
            timestamp: 1_700_000_000,
            state_root: Some(hash(3)),
            transactions_root: Some(hash(4)),
            receipts_root: Some(hash(5)),
            gas_used: Some(21_000),
            gas_limit: Some(30_000_000),
            base_fee_per_gas: Some(U256::from(1_000_000_000_u64)),
        }
    }

    fn receipt(tx_hash: B256) -> TransactionReceipt {
        TransactionReceipt {
            transaction_hash: tx_hash,
            transaction_index: Some(0),
            block_hash: Some(hash(1)),
            block_number: Some(42),
            from: address(1),
            to: Some(address(2)),
            cumulative_gas_used: 21_000,
            gas_used: Some(21_000),
            contract_address: None,
            logs: vec![Log {
                address: address(3),
                topics: vec![hash(4)],
                data: Bytes::from(vec![1, 2, 3]),
                block_hash: Some(hash(1)),
                block_number: Some(42),
                transaction_hash: Some(tx_hash),
                transaction_index: Some(0),
                log_index: Some(0),
                removed: Some(false),
            }],
            status: Some(1),
            effective_gas_price: Some(U256::from(1_000_000_000_u64)),
        }
    }

    #[tokio::test]
    async fn balance_setter_getter_and_count_work() {
        let adapter = MockChainAdapter::new();
        let account = address(1);
        adapter.set_balance(account, BlockTag::Latest, U256::from(7));

        assert_eq!(
            adapter
                .eth_get_balance(account, BlockTag::Latest)
                .await
                .unwrap(),
            U256::from(7)
        );
        assert_eq!(
            adapter
                .eth_get_balance(account, BlockTag::Latest)
                .await
                .unwrap(),
            U256::from(7)
        );
        assert_eq!(adapter.balance_call_count(), 2);
    }

    #[tokio::test]
    async fn unset_balance_code_and_nonce_return_zero_values() {
        let adapter = MockChainAdapter::new();
        let account = address(1);

        assert_eq!(
            adapter
                .eth_get_balance(account, BlockTag::Latest)
                .await
                .unwrap(),
            U256::ZERO
        );
        assert_eq!(
            adapter
                .eth_get_code(account, BlockTag::Latest)
                .await
                .unwrap(),
            Bytes::new()
        );
        assert_eq!(
            adapter
                .eth_get_transaction_count(account, BlockTag::Latest)
                .await
                .unwrap(),
            0
        );
    }

    #[tokio::test]
    async fn code_setter_getter_and_count_work() {
        let adapter = MockChainAdapter::new();
        let account = address(1);
        let code = Bytes::from(vec![0x60, 0x00]);
        adapter.set_code(account, BlockTag::Number(10), code.clone());

        assert_eq!(
            adapter
                .eth_get_code(account, BlockTag::Number(10))
                .await
                .unwrap(),
            code
        );
        assert_eq!(adapter.code_call_count(), 1);
    }

    #[tokio::test]
    async fn storage_setter_getter_and_count_work() {
        let adapter = MockChainAdapter::new();
        let account = address(1);
        adapter.set_storage_at(account, hash(2), BlockTag::Number(10), hash(3));

        assert_eq!(
            adapter
                .eth_get_storage_at(account, hash(2), BlockTag::Number(10))
                .await
                .unwrap(),
            hash(3)
        );
        assert_eq!(
            adapter
                .eth_get_storage_at(account, hash(4), BlockTag::Number(10))
                .await
                .unwrap(),
            B256::ZERO
        );
        assert_eq!(adapter.storage_call_count(), 2);
    }

    #[tokio::test]
    async fn nonce_setter_getter_and_count_work() {
        let adapter = MockChainAdapter::new();
        let account = address(1);
        adapter.set_transaction_count(account, BlockTag::Finalized, 12);

        assert_eq!(
            adapter
                .eth_get_transaction_count(account, BlockTag::Finalized)
                .await
                .unwrap(),
            12
        );
        assert_eq!(adapter.transaction_count_call_count(), 1);
    }

    #[tokio::test]
    async fn call_response_matches_request_block_and_overrides() {
        let adapter = MockChainAdapter::new();
        let tx = CallRequest {
            to: Some(address(2)),
            data: Some(Bytes::from(vec![0xaa, 0xbb])),
            ..CallRequest::default()
        };
        let mut overrides = StateOverride::new();
        overrides.insert(
            address(2),
            AccountOverride {
                code: Some(Bytes::from(vec![0x60, 0x01])),
                ..AccountOverride::default()
            },
        );
        let response = Bytes::from(vec![0xcc]);

        adapter.set_call_response(
            tx.clone(),
            BlockTag::Hash(hash(1)),
            Some(overrides.clone()),
            response.clone(),
        );

        assert_eq!(
            adapter
                .eth_call(tx.clone(), BlockTag::Hash(hash(1)), Some(overrides))
                .await
                .unwrap(),
            response
        );
        assert!(matches!(
            adapter.eth_call(tx, BlockTag::Latest, None).await,
            Err(ChainError::BlockNotFound)
        ));
        assert_eq!(adapter.call_call_count(), 2);
    }

    #[tokio::test]
    async fn call_revert_preserves_raw_revert_data() {
        let adapter = MockChainAdapter::new();
        let tx = CallRequest {
            to: Some(address(2)),
            data: Some(Bytes::from(vec![0xaa, 0xbb])),
            ..CallRequest::default()
        };
        let revert_data = Bytes::from(vec![0x12, 0x34]);
        adapter.set_call_revert(
            tx.clone(),
            BlockTag::Hash(hash(1)),
            None,
            revert_data.clone(),
        );

        match adapter
            .eth_call(tx, BlockTag::Hash(hash(1)), None)
            .await
            .unwrap_err()
        {
            ChainError::CallReverted(data) => assert_eq!(data, revert_data),
            other => panic!("expected CallReverted, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn gas_estimate_matches_request_block_and_overrides() {
        let adapter = MockChainAdapter::new();
        let tx = CallRequest {
            from: Some(address(1)),
            to: Some(address(2)),
            data: Some(Bytes::from(vec![0xaa, 0xbb])),
            ..CallRequest::default()
        };
        let mut overrides = StateOverride::new();
        overrides.insert(
            address(2),
            AccountOverride {
                code: Some(Bytes::from(vec![0x60, 0x01])),
                ..AccountOverride::default()
            },
        );

        adapter.set_gas_estimate(
            tx.clone(),
            Some(BlockTag::Hash(hash(1))),
            Some(overrides.clone()),
            51_000,
        );

        assert_eq!(
            adapter
                .eth_estimate_gas(tx.clone(), Some(BlockTag::Hash(hash(1))), Some(overrides))
                .await
                .unwrap(),
            51_000
        );
        assert!(matches!(
            adapter
                .eth_estimate_gas(tx, Some(BlockTag::Latest), None)
                .await,
            Err(ChainError::BlockNotFound)
        ));
        assert_eq!(adapter.estimate_gas_call_count(), 2);
    }

    #[tokio::test]
    async fn receipts_return_some_or_none_and_track_count() {
        let adapter = MockChainAdapter::new();
        let tx_hash = hash(9);
        let receipt = receipt(tx_hash);
        adapter.set_transaction_receipt(tx_hash, receipt.clone());

        assert_eq!(
            adapter.eth_get_transaction_receipt(tx_hash).await.unwrap(),
            Some(receipt)
        );
        assert_eq!(
            adapter.eth_get_transaction_receipt(hash(8)).await.unwrap(),
            None
        );
        assert_eq!(adapter.receipt_call_count(), 2);
    }

    #[tokio::test]
    async fn blocks_current_head_and_execution_head_work() {
        let adapter = MockChainAdapter::new();
        let header = header(42);
        let block = Block {
            header: header.clone(),
            transactions: vec![BlockTransaction::Hash(hash(9))],
        };
        adapter
            .set_block(BlockTag::Number(42), false, block.clone())
            .set_current_head(header.clone())
            .set_execution_rpc_head(43);

        assert_eq!(
            adapter
                .eth_get_block_by_number(BlockTag::Number(42), false)
                .await
                .unwrap(),
            Some(block)
        );
        assert_eq!(adapter.current_head().await.unwrap(), header);
        assert_eq!(adapter.execution_rpc_head().await.unwrap(), 43);
        assert_eq!(adapter.block_call_count(), 1);
        assert_eq!(adapter.current_head_call_count(), 1);
        assert_eq!(adapter.execution_rpc_head_call_count(), 1);
    }

    #[tokio::test]
    async fn full_transaction_blocks_are_supported() {
        let adapter = MockChainAdapter::new();
        let header = header(42);
        let tx = Transaction {
            hash: hash(10),
            nonce: Some(1),
            block_hash: Some(header.hash),
            block_number: Some(header.number),
            transaction_index: Some(0),
            from: address(1),
            to: Some(address(2)),
            value: Some(U256::from(10)),
            input: Some(Bytes::from(vec![0x12, 0x34])),
        };
        let block = Block {
            header,
            transactions: vec![BlockTransaction::Full(tx)],
        };
        adapter.set_block(BlockTag::Number(42), true, block.clone());

        assert_eq!(
            adapter
                .eth_get_block_by_number(BlockTag::Number(42), true)
                .await
                .unwrap(),
            Some(block)
        );
    }

    #[tokio::test]
    async fn synced_flag_and_count_work() {
        let adapter = MockChainAdapter::with_synced(true);
        assert!(adapter.is_synced().await);
        adapter.set_synced(false);
        assert!(!adapter.is_synced().await);
        assert_eq!(adapter.is_synced_call_count(), 2);
    }

    #[tokio::test]
    async fn injected_error_is_returned_by_read_methods() {
        let adapter = MockChainAdapter::new();
        adapter.inject_error(Box::new(|| ChainError::RpcError("boom".to_string())));

        assert!(matches!(
            adapter.eth_get_balance(address(1), BlockTag::Latest).await,
            Err(ChainError::RpcError(message)) if message == "boom"
        ));

        adapter.clear_error();
        assert_eq!(
            adapter
                .eth_get_balance(address(1), BlockTag::Latest)
                .await
                .unwrap(),
            U256::ZERO
        );
    }

    #[tokio::test]
    async fn returns_set_gas_price() {
        let adapter = MockChainAdapter::new();
        adapter.set_current_gas_price(U256::from(7_000_000_000_u64));

        assert_eq!(
            adapter.current_gas_price().await.unwrap(),
            U256::from(7_000_000_000_u64)
        );
        assert_eq!(adapter.current_gas_price_call_count(), 1);
    }

    #[tokio::test]
    async fn returns_set_max_priority_fee() {
        let adapter = MockChainAdapter::new();
        adapter.set_current_max_priority_fee_per_gas(U256::from(2_000_000_000_u64));

        assert_eq!(
            adapter.current_max_priority_fee_per_gas().await.unwrap(),
            U256::from(2_000_000_000_u64)
        );
        assert_eq!(adapter.current_max_priority_fee_call_count(), 1);
    }

    #[tokio::test]
    async fn unset_gas_price_and_priority_fee_return_zero_by_default() {
        let adapter = MockChainAdapter::new();

        assert_eq!(adapter.current_gas_price().await.unwrap(), U256::ZERO);
        assert_eq!(
            adapter.current_max_priority_fee_per_gas().await.unwrap(),
            U256::ZERO
        );
    }

    #[tokio::test]
    async fn error_factory_propagates_to_fee_sources() {
        let adapter = MockChainAdapter::new();
        adapter.inject_error(Box::new(|| ChainError::RpcError("simulated".into())));

        assert!(matches!(
            adapter.current_gas_price().await,
            Err(ChainError::RpcError(_))
        ));
        assert!(matches!(
            adapter.current_max_priority_fee_per_gas().await,
            Err(ChainError::RpcError(_))
        ));
    }

    #[test]
    fn mock_chain_adapter_is_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<MockChainAdapter>();
    }
}
