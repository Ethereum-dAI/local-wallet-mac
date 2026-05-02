use wallet_chain::{BlockTag, CallRequest};
use wallet_node_api::JsonRpcError;

use super::map_chain_error;
use crate::state::DaemonState;

pub async fn handle(
    state: &DaemonState,
    params: serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let (tx, block) = parse_params(params)?;
    let value = state
        .chain
        .eth_estimate_gas(tx, block, None)
        .await
        .map_err(map_chain_error)?;

    Ok(serde_json::Value::String(format!("0x{value:x}")))
}

fn parse_params(
    params: serde_json::Value,
) -> Result<(CallRequest, Option<BlockTag>), JsonRpcError> {
    let values: Vec<serde_json::Value> =
        serde_json::from_value(params).map_err(|e| JsonRpcError::parse_error(&e.to_string()))?;
    let [tx] = values.as_slice() else {
        let [tx, block] = values.as_slice() else {
            return Err(JsonRpcError::parse_error(
                "eth_estimateGas expects [transaction] or [transaction, block]",
            ));
        };
        return Ok((
            serde_json::from_value(tx.clone())
                .map_err(|e| JsonRpcError::parse_error(&e.to_string()))?,
            Some(
                serde_json::from_value(block.clone())
                    .map_err(|e| JsonRpcError::parse_error(&e.to_string()))?,
            ),
        ));
    };

    Ok((
        serde_json::from_value(tx.clone())
            .map_err(|e| JsonRpcError::parse_error(&e.to_string()))?,
        None,
    ))
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::Arc;

    use serde_json::json;
    use tokio::sync::watch;
    use wallet_chain::{Address, BlockTag, Bytes, CallRequest, ChainError, MockChainAdapter, U256};

    use super::*;
    use crate::auth::Token;
    use crate::config::Config;
    use crate::paths::Paths;
    use crate::state::TransportInfo;

    #[tokio::test]
    async fn returns_estimate_as_hex_quantity_with_default_block() {
        let chain = Arc::new(MockChainAdapter::new());
        let tx = CallRequest {
            to: Some(address(0x22)),
            data: Some(Bytes::from(vec![0xaa, 0xbb])),
            value: Some(U256::from(1)),
            ..CallRequest::default()
        };
        chain.set_gas_estimate(tx.clone(), None, None, 51_000);
        let state = test_state(chain);

        let result = handle(
            &state,
            json!([{
                "to": format!("{:#x}", address(0x22)),
                "data": "0xaabb",
                "value": "0x1"
            }]),
        )
        .await
        .expect("handler succeeds");

        assert_eq!(result, json!("0xc738"));
    }

    #[tokio::test]
    async fn passes_optional_block_to_chain_adapter() {
        let chain = Arc::new(MockChainAdapter::new());
        let tx = CallRequest {
            to: Some(address(0x22)),
            ..CallRequest::default()
        };
        chain.set_gas_estimate(tx.clone(), Some(BlockTag::Latest), None, 21_000);
        let state = test_state(chain);

        let result = handle(
            &state,
            json!([{
                "to": format!("{:#x}", address(0x22))
            }, "latest"]),
        )
        .await
        .expect("handler succeeds");

        assert_eq!(result, json!("0x5208"));
    }

    #[tokio::test]
    async fn maps_stale_chain_error() {
        let chain = Arc::new(MockChainAdapter::new());
        chain.inject_error(Box::new(|| ChainError::Stale {
            helios_head: 100,
            exec_head: 110,
        }));
        let state = test_state(chain);

        let err = handle(&state, json!([{}]))
            .await
            .expect_err("handler returns stale error");

        assert_eq!(err.code, -32010);
        assert_eq!(err.data.expect("stale data")["heliosHead"], 100);
    }

    fn address(byte: u8) -> Address {
        Address::from([byte; 20])
    }

    fn test_state(chain: Arc<dyn wallet_chain::ChainAdapter>) -> DaemonState {
        let (shutdown_tx, _shutdown_rx) = watch::channel(false);

        DaemonState::new(
            Arc::new(Token::generate()),
            Arc::new(Config::default()),
            Arc::new(Paths {
                app_support_dir: PathBuf::from("/tmp/wallet-node-test"),
                socket_path: PathBuf::from("/tmp/wallet-node-test/wallet-node.sock"),
                db_path: PathBuf::from("/tmp/wallet-node-test/node.sqlite"),
                helios_dir: PathBuf::from("/tmp/wallet-node-test/helios"),
                logs_dir: PathBuf::from("/tmp/wallet-node-test/logs"),
                config_path: PathBuf::from("/tmp/wallet-node-test/config.toml"),
            }),
            shutdown_tx,
            (TransportInfo::http(), chain),
        )
    }
}
