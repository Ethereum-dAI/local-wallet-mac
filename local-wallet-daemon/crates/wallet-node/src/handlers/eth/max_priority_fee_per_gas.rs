use crate::state::DaemonState;

pub async fn handle(
    state: &DaemonState,
) -> Result<serde_json::Value, wallet_node_api::JsonRpcError> {
    let policy = crate::handlers::bundler::policy_from_state(state)?;
    let cap = policy.max_priority_fee_per_gas;
    let value = match state.chain.current_max_priority_fee_per_gas().await {
        Ok(value) if value <= cap => value,
        Ok(value) => {
            tracing::warn!(
                chain_value = %value,
                cap = %cap,
                "eth_maxPriorityFeePerGas chain value above safety cap; treating as suspicious and using cap as fallback"
            );
            cap
        }
        Err(error) => {
            tracing::warn!(
                error = %error,
                cap = %cap,
                "eth_maxPriorityFeePerGas chain read failed; falling back to policy cap"
            );
            cap
        }
    };
    Ok(serde_json::Value::String(wallet_bundler::gas::u256_hex(
        value,
    )))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use wallet_chain::{ChainAdapter, ChainError, MockChainAdapter, U256};

    fn cap_priority_fee() -> U256 {
        U256::from(1_000_000_000_u64)
    }

    fn state_with_chain(chain: Arc<dyn ChainAdapter>) -> crate::state::DaemonState {
        crate::state::DaemonState::for_tests(chain)
    }

    #[tokio::test]
    async fn returns_chain_value_when_at_or_below_cap() {
        let chain = Arc::new(MockChainAdapter::new());
        chain.set_current_max_priority_fee_per_gas(U256::from(500_000_000_u64));
        let value = handle(&state_with_chain(chain)).await.unwrap();

        assert_eq!(value.as_str(), Some("0x1dcd6500"));
    }

    #[tokio::test]
    async fn returns_chain_value_when_exactly_at_cap() {
        let chain = Arc::new(MockChainAdapter::new());
        chain.set_current_max_priority_fee_per_gas(cap_priority_fee());
        let value = handle(&state_with_chain(chain)).await.unwrap();
        let cap = wallet_bundler::gas::u256_hex(cap_priority_fee());

        assert_eq!(value.as_str(), Some(cap.as_str()));
    }

    #[tokio::test]
    async fn falls_back_to_cap_when_chain_value_exceeds_cap() {
        let chain = Arc::new(MockChainAdapter::new());
        chain.set_current_max_priority_fee_per_gas(U256::from(5_000_000_000_u64));
        let value = handle(&state_with_chain(chain)).await.unwrap();
        let cap = wallet_bundler::gas::u256_hex(cap_priority_fee());

        assert_eq!(value.as_str(), Some(cap.as_str()));
    }

    #[tokio::test]
    async fn falls_back_to_cap_when_chain_errors() {
        let chain = Arc::new(MockChainAdapter::new());
        chain.inject_error(Box::new(|| ChainError::RpcError("simulated".into())));
        let value = handle(&state_with_chain(chain)).await.unwrap();
        let cap = wallet_bundler::gas::u256_hex(cap_priority_fee());

        assert_eq!(value.as_str(), Some(cap.as_str()));
    }
}
