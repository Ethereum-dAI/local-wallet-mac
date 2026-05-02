use serde::{Deserialize, Serialize};
use wallet_chain::{Block, BlockTag};
use wallet_node_api::JsonRpcError;

use super::map_chain_error;
use crate::state::DaemonState;

#[derive(Deserialize)]
pub struct Params(BlockTag, bool);

#[derive(Serialize)]
pub struct Output(Option<Block>);

pub async fn handle(
    state: &DaemonState,
    params: serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let Params(block, full_txs) =
        serde_json::from_value(params).map_err(|e| JsonRpcError::parse_error(&e.to_string()))?;
    let value = state
        .chain
        .eth_get_block_by_number(block, full_txs)
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
    use wallet_chain::{
        Block, BlockHeader, BlockTag, BlockTransaction, ChainError, MockChainAdapter, B256, U256,
    };

    use super::*;
    use crate::auth::Token;
    use crate::config::Config;
    use crate::paths::Paths;
    use crate::state::TransportInfo;

    #[tokio::test]
    async fn returns_block_or_null() {
        let chain = Arc::new(MockChainAdapter::new());
        let block = block(42);
        chain.set_block(BlockTag::Number(42), false, block.clone());
        let state = test_state(chain);

        let result = handle(&state, json!(["0x2a", false]))
            .await
            .expect("handler succeeds");
        let missing = handle(&state, json!(["0x2b", false]))
            .await
            .expect("missing block succeeds");

        assert_eq!(result["number"], json!("0x2a"));
        assert_eq!(result["hash"], json!(format!("{:#x}", block.header.hash)));
        assert_eq!(
            result["transactions"],
            json!([format!("{:#x}", hash(0x99))])
        );
        assert_eq!(missing, serde_json::Value::Null);
    }

    #[tokio::test]
    async fn maps_stale_chain_error() {
        let chain = Arc::new(MockChainAdapter::new());
        chain.inject_error(Box::new(|| ChainError::Stale {
            helios_head: 100,
            exec_head: 110,
        }));
        let state = test_state(chain);

        let err = handle(&state, json!(["latest", false]))
            .await
            .expect_err("handler returns stale error");

        assert_eq!(err.code, -32010);
        assert_eq!(err.data.expect("stale data")["heliosHead"], 100);
    }

    fn block(number: u64) -> Block {
        Block {
            header: BlockHeader {
                number,
                hash: hash(0x11),
                parent_hash: hash(0x22),
                timestamp: 1_700_000_000,
                state_root: Some(hash(0x33)),
                transactions_root: Some(hash(0x44)),
                receipts_root: Some(hash(0x55)),
                gas_used: Some(21_000),
                gas_limit: Some(30_000_000),
                base_fee_per_gas: Some(U256::from(1_000_000_000_u64)),
            },
            transactions: vec![BlockTransaction::Hash(hash(0x99))],
        }
    }

    fn hash(byte: u8) -> B256 {
        B256::from([byte; 32])
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
