use serde::{Deserialize, Serialize, Serializer};
use wallet_chain::{BlockTag, Bytes, CallRequest};
use wallet_node_api::JsonRpcError;

use super::map_chain_error;
use crate::state::DaemonState;

#[derive(Deserialize)]
pub struct Params(CallRequest, BlockTag);

pub struct Output(Bytes);

impl Serialize for Output {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&format!("{:#x}", self.0))
    }
}

pub async fn handle(
    state: &DaemonState,
    params: serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let Params(tx, block) =
        serde_json::from_value(params).map_err(|e| JsonRpcError::parse_error(&e.to_string()))?;
    let value = state
        .chain
        .eth_call(tx, block, None)
        .await
        .map_err(map_chain_error)?;

    Ok(serde_json::to_value(Output(value)).expect("serialize succeeds"))
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
    async fn returns_call_output_as_hex_bytes() {
        let chain = Arc::new(MockChainAdapter::new());
        let tx = CallRequest {
            to: Some(address(0x22)),
            data: Some(Bytes::from(vec![0xaa, 0xbb])),
            value: Some(U256::from(1)),
            ..CallRequest::default()
        };
        chain.set_call_response(
            tx.clone(),
            BlockTag::Latest,
            None,
            Bytes::from(vec![0xcc, 0xdd]),
        );
        let state = test_state(chain);

        let result = handle(
            &state,
            json!([{
                "to": format!("{:#x}", address(0x22)),
                "data": "0xaabb",
                "value": "0x1"
            }, "latest"]),
        )
        .await
        .expect("handler succeeds");

        assert_eq!(result, json!("0xccdd"));
    }

    #[tokio::test]
    async fn maps_stale_chain_error() {
        let chain = Arc::new(MockChainAdapter::new());
        chain.inject_error(Box::new(|| ChainError::Stale {
            helios_head: 100,
            exec_head: 110,
        }));
        let state = test_state(chain);

        let err = handle(&state, json!([{}, "latest"]))
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
