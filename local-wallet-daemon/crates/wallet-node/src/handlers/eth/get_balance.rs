use serde::de::Error as DeError;
use serde::{Deserialize, Deserializer, Serialize};
use wallet_chain::{Address, BlockTag, U256};
use wallet_node_api::JsonRpcError;

use super::map_chain_error;
use crate::state::DaemonState;

#[derive(Deserialize)]
struct WireParams(String, BlockTag);

pub struct Params(Address, BlockTag);

impl<'de> Deserialize<'de> for Params {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let WireParams(address, block) = WireParams::deserialize(deserializer)?;
        let address = address
            .parse::<Address>()
            .map_err(|error| DeError::custom(format!("invalid address: {error}")))?;

        Ok(Self(address, block))
    }
}

#[derive(Serialize)]
pub struct Output(U256);

pub async fn handle(
    state: &DaemonState,
    params: serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let Params(address, block) =
        serde_json::from_value(params).map_err(|e| JsonRpcError::parse_error(&e.to_string()))?;
    let value = state
        .chain
        .eth_get_balance(address, block)
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
    use wallet_chain::{Address, BlockTag, ChainError, MockChainAdapter, U256};

    use super::*;
    use crate::auth::Token;
    use crate::config::Config;
    use crate::paths::Paths;
    use crate::state::TransportInfo;

    #[tokio::test]
    async fn returns_balance_as_hex_quantity() {
        let chain = Arc::new(MockChainAdapter::new());
        let address = address(0x11);
        chain.set_balance(address, BlockTag::Latest, U256::from(0x2a));
        let state = test_state(chain);

        let result = handle(&state, json!([format!("{address:#x}"), "latest"]))
            .await
            .expect("handler succeeds");

        assert_eq!(result, json!("0x2a"));
    }

    #[tokio::test]
    async fn maps_stale_chain_error() {
        let chain = Arc::new(MockChainAdapter::new());
        chain.inject_error(Box::new(|| ChainError::Stale {
            helios_head: 100,
            exec_head: 110,
        }));
        let address = address(0x11);
        let state = test_state(chain);

        let err = handle(&state, json!([format!("{address:#x}"), "latest"]))
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
