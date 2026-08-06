use crate::state::DaemonState;

pub async fn handle(
    state: &DaemonState,
) -> Result<serde_json::Value, wallet_node_api::JsonRpcError> {
    let policy = super::policy_from_state(state)?;
    let max_fee_cap = policy.max_fee_per_gas;
    let priority_cap = policy.max_priority_fee_per_gas;

    // Fail closed when the chain reads fail. Answering an unreadable price with
    // the policy cap is indistinguishable from a real quote by magnitude, and the
    // caller prices a UserOperation with it: `required_prefund` multiplies by
    // `maxFeePerGas`, so a placeholder fee becomes a placeholder balance floor
    // that no amount of funding can satisfy. This is #49's failure mode -- a
    // silently substituted gas number reaching the chain -- one layer up from the
    // estimator #69 fixed.
    //
    // A value *above* the cap is a different case and still clamps below: the
    // price was read successfully, and the cap is a policy ceiling the operator
    // chose, not a number this handler invented.
    let chain_max_fee = state
        .chain
        .current_gas_price()
        .await
        .map_err(wallet_bundler::BundlerError::from)
        .map_err(super::map_bundler_error)?;
    let chain_priority = state
        .chain
        .current_max_priority_fee_per_gas()
        .await
        .map_err(wallet_bundler::BundlerError::from)
        .map_err(super::map_bundler_error)?;

    if chain_max_fee > max_fee_cap || chain_priority > priority_cap {
        if chain_max_fee > max_fee_cap {
            tracing::warn!(
                chain_value = %chain_max_fee,
                cap = %max_fee_cap,
                "pimlico_getUserOperationGasPrice gas price chain value above safety cap; using uniform cap fallback"
            );
        }
        if chain_priority > priority_cap {
            tracing::warn!(
                chain_value = %chain_priority,
                cap = %priority_cap,
                "pimlico_getUserOperationGasPrice priority fee chain value above safety cap; using uniform cap fallback"
            );
        }
        return Ok(wallet_bundler::pimlico_gas_price(
            (max_fee_cap, priority_cap),
            (max_fee_cap, priority_cap),
            (max_fee_cap, priority_cap),
        ));
    }

    let (standard_max_fee, standard_priority) = (chain_max_fee, chain_priority);

    let (slow_max_fee, _, fast_max_fee) = wallet_bundler::derive_fee_tiers(standard_max_fee);
    let (slow_priority, _, fast_priority) = wallet_bundler::derive_fee_tiers(standard_priority);

    Ok(wallet_bundler::pimlico_gas_price(
        (
            wallet_bundler::clamp_to_cap(slow_max_fee, max_fee_cap),
            wallet_bundler::clamp_to_cap(slow_priority, priority_cap),
        ),
        (standard_max_fee, standard_priority),
        (
            wallet_bundler::clamp_to_cap(fast_max_fee, max_fee_cap),
            wallet_bundler::clamp_to_cap(fast_priority, priority_cap),
        ),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use wallet_chain::{
        Address, Block, BlockHeader, BlockTag, Bytes, CallRequest, ChainAdapter, ChainError,
        MockChainAdapter, StateOverride, TransactionReceipt, B256, U256,
    };

    fn cap_max_fee() -> U256 {
        U256::from(10_000_000_000_u64)
    }

    fn cap_priority_fee() -> U256 {
        U256::from(1_000_000_000_u64)
    }

    fn state_with_chain(chain: Arc<dyn ChainAdapter>) -> crate::state::DaemonState {
        crate::state::DaemonState::for_tests(chain)
    }

    fn hex(value: U256) -> String {
        wallet_bundler::gas::u256_hex(value)
    }

    #[tokio::test]
    async fn returns_three_distinct_tiers_when_chain_succeeds_within_caps() {
        let chain = Arc::new(MockChainAdapter::new());
        chain.set_current_gas_price(U256::from(2_000_000_000_u64));
        chain.set_current_max_priority_fee_per_gas(U256::from(500_000_000_u64));
        let value = handle(&state_with_chain(chain)).await.unwrap();

        assert_eq!(
            value["standard"]["maxFeePerGas"],
            hex(U256::from(2_000_000_000_u64))
        );
        assert_eq!(
            value["standard"]["maxPriorityFeePerGas"],
            hex(U256::from(500_000_000_u64))
        );
        assert_eq!(
            value["slow"]["maxFeePerGas"],
            hex(U256::from(1_700_000_000_u64))
        );
        assert_eq!(
            value["slow"]["maxPriorityFeePerGas"],
            hex(U256::from(425_000_000_u64))
        );
        assert_eq!(
            value["fast"]["maxFeePerGas"],
            hex(U256::from(2_500_000_000_u64))
        );
        assert_eq!(
            value["fast"]["maxPriorityFeePerGas"],
            hex(U256::from(625_000_000_u64))
        );
    }

    #[tokio::test]
    async fn fast_tier_clamps_when_derived_125_percent_exceeds_cap() {
        let chain = Arc::new(MockChainAdapter::new());
        chain.set_current_gas_price(U256::from(9_000_000_000_u64));
        chain.set_current_max_priority_fee_per_gas(U256::from(900_000_000_u64));
        let value = handle(&state_with_chain(chain)).await.unwrap();

        assert_eq!(value["fast"]["maxFeePerGas"], hex(cap_max_fee()));
        assert_eq!(
            value["standard"]["maxFeePerGas"],
            hex(U256::from(9_000_000_000_u64))
        );
    }

    #[tokio::test]
    async fn falls_back_uniformly_when_chain_gas_price_exceeds_cap() {
        let chain = Arc::new(MockChainAdapter::new());
        chain.set_current_gas_price(U256::from(50_000_000_000_u64));
        chain.set_current_max_priority_fee_per_gas(U256::from(500_000_000_u64));
        let value = handle(&state_with_chain(chain)).await.unwrap();

        assert_uniform_cap_fallback(value);
    }

    #[tokio::test]
    async fn falls_back_uniformly_when_chain_priority_exceeds_cap() {
        let chain = Arc::new(MockChainAdapter::new());
        chain.set_current_gas_price(U256::from(2_000_000_000_u64));
        chain.set_current_max_priority_fee_per_gas(U256::from(5_000_000_000_u64));
        let value = handle(&state_with_chain(chain)).await.unwrap();

        assert_uniform_cap_fallback(value);
    }

    #[tokio::test]
    async fn fails_closed_when_both_calls_error() {
        // Not the cap fallback: an unreadable price answered with the cap is a
        // fabricated number the caller cannot tell apart from a quote, and it
        // becomes a fabricated `required_prefund` one layer up.
        let chain = Arc::new(MockChainAdapter::new());
        chain.inject_error(Box::new(|| ChainError::RpcError("simulated".into())));
        let error = handle(&state_with_chain(chain)).await.unwrap_err();

        assert_eq!(error.code, wallet_node_api::NOT_READY);
        assert_eq!(
            error.data.as_ref().and_then(|data| data["reason"].as_str()),
            Some("rpc_error")
        );
    }

    #[tokio::test]
    async fn fails_closed_when_only_the_gas_price_read_errors() {
        let inner = MockChainAdapter::new();
        inner.set_current_max_priority_fee_per_gas(U256::from(500_000_000_u64));
        let chain = Arc::new(GasPriceErrorChain { inner });
        let error = handle(&state_with_chain(chain)).await.unwrap_err();

        assert_eq!(error.code, wallet_node_api::NOT_READY);
    }

    fn assert_uniform_cap_fallback(value: serde_json::Value) {
        assert_eq!(value["slow"], value["standard"]);
        assert_eq!(value["standard"], value["fast"]);
        assert_eq!(value["fast"]["maxFeePerGas"], hex(cap_max_fee()));
        assert_eq!(
            value["fast"]["maxPriorityFeePerGas"],
            hex(cap_priority_fee())
        );
    }

    struct GasPriceErrorChain {
        inner: MockChainAdapter,
    }

    #[async_trait::async_trait]
    impl ChainAdapter for GasPriceErrorChain {
        async fn current_gas_price(&self) -> Result<U256, ChainError> {
            Err(ChainError::RpcError("simulated".into()))
        }

        async fn current_max_priority_fee_per_gas(&self) -> Result<U256, ChainError> {
            self.inner.current_max_priority_fee_per_gas().await
        }

        async fn eth_get_balance(
            &self,
            address: Address,
            block: BlockTag,
        ) -> Result<U256, ChainError> {
            self.inner.eth_get_balance(address, block).await
        }

        async fn eth_get_code(
            &self,
            address: Address,
            block: BlockTag,
        ) -> Result<Bytes, ChainError> {
            self.inner.eth_get_code(address, block).await
        }

        async fn eth_get_storage_at(
            &self,
            address: Address,
            slot: B256,
            block: BlockTag,
        ) -> Result<B256, ChainError> {
            self.inner.eth_get_storage_at(address, slot, block).await
        }

        async fn eth_get_transaction_count(
            &self,
            address: Address,
            block: BlockTag,
        ) -> Result<u64, ChainError> {
            self.inner.eth_get_transaction_count(address, block).await
        }

        async fn eth_call(
            &self,
            tx: CallRequest,
            block: BlockTag,
            state_overrides: Option<StateOverride>,
        ) -> Result<Bytes, ChainError> {
            self.inner.eth_call(tx, block, state_overrides).await
        }

        async fn eth_estimate_gas(
            &self,
            tx: CallRequest,
            block: Option<BlockTag>,
            state_overrides: Option<StateOverride>,
        ) -> Result<u64, ChainError> {
            self.inner
                .eth_estimate_gas(tx, block, state_overrides)
                .await
        }

        async fn eth_get_transaction_receipt(
            &self,
            tx_hash: B256,
        ) -> Result<Option<TransactionReceipt>, ChainError> {
            self.inner.eth_get_transaction_receipt(tx_hash).await
        }

        async fn eth_get_block_by_number(
            &self,
            block: BlockTag,
            full_txs: bool,
        ) -> Result<Option<Block>, ChainError> {
            self.inner.eth_get_block_by_number(block, full_txs).await
        }

        async fn current_head(&self) -> Result<BlockHeader, ChainError> {
            self.inner.current_head().await
        }

        async fn execution_rpc_head(&self) -> Result<u64, ChainError> {
            self.inner.execution_rpc_head().await
        }

        async fn is_synced(&self) -> bool {
            self.inner.is_synced().await
        }
    }
}
