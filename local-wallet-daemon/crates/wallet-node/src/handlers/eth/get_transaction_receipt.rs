use serde::de::Error as DeError;
use serde::{Deserialize, Deserializer, Serialize};
use wallet_chain::{TransactionReceipt, B256 as TxHash};
use wallet_node_api::JsonRpcError;

use super::map_chain_error;
use crate::state::DaemonState;

pub struct Params(TxHash);

#[derive(Serialize)]
pub struct Output(Option<TransactionReceipt>);

impl<'de> Deserialize<'de> for Params {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let (tx_hash,) = <(String,)>::deserialize(deserializer)?;
        let tx_hash = tx_hash
            .parse::<TxHash>()
            .map_err(|error| DeError::custom(format!("invalid transaction hash: {error}")))?;

        Ok(Self(tx_hash))
    }
}

pub async fn handle(
    state: &DaemonState,
    params: serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let Params(tx_hash) =
        serde_json::from_value(params).map_err(|e| JsonRpcError::parse_error(&e.to_string()))?;
    let value = state
        .chain
        .eth_get_transaction_receipt(tx_hash)
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
        Address, Bytes, ChainError, Log, MockChainAdapter, TransactionReceipt, B256, U256,
    };

    use super::*;
    use crate::auth::Token;
    use crate::config::Config;
    use crate::paths::Paths;
    use crate::state::TransportInfo;

    #[tokio::test]
    async fn returns_receipt_or_null() {
        let chain = Arc::new(MockChainAdapter::new());
        let tx_hash = hash(0x99);
        chain.set_transaction_receipt(tx_hash, receipt(tx_hash));
        let state = test_state(chain);

        let result = handle(&state, json!([format!("{tx_hash:#x}")]))
            .await
            .expect("handler succeeds");
        let missing = handle(&state, json!([format!("{:#x}", hash(0x88))]))
            .await
            .expect("missing receipt succeeds");

        assert_eq!(result["transactionHash"], json!(format!("{tx_hash:#x}")));
        assert_eq!(result["from"], json!(format!("{:#x}", address(0x11))));
        assert_eq!(missing, serde_json::Value::Null);
    }

    #[tokio::test]
    async fn maps_stale_chain_error() {
        let chain = Arc::new(MockChainAdapter::new());
        chain.inject_error(Box::new(|| ChainError::Stale {
            helios_head: 100,
            exec_head: 110,
        }));
        let tx_hash = hash(0x99);
        let state = test_state(chain);

        let err = handle(&state, json!([format!("{tx_hash:#x}")]))
            .await
            .expect_err("handler returns stale error");

        assert_eq!(err.code, -32010);
        assert_eq!(err.data.expect("stale data")["heliosHead"], 100);
    }

    fn receipt(tx_hash: B256) -> TransactionReceipt {
        TransactionReceipt {
            transaction_hash: tx_hash,
            transaction_index: Some(0),
            block_hash: Some(hash(0x44)),
            block_number: Some(42),
            from: address(0x11),
            to: Some(address(0x22)),
            cumulative_gas_used: 21_000,
            gas_used: Some(21_000),
            contract_address: None,
            logs: vec![Log {
                address: address(0x33),
                topics: vec![hash(0x55)],
                data: Bytes::from(vec![0x01, 0x02]),
                block_hash: Some(hash(0x44)),
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

    fn address(byte: u8) -> Address {
        Address::from([byte; 20])
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
