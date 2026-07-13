use crate::adapter::ChainAdapter;
use crate::error::ChainError;
use crate::types::{
    Address, Block, BlockHeader, BlockTag, Bytes, CallRequest, StateOverride, TransactionReceipt,
    B256, U256,
};
use async_trait::async_trait;
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Value};
use std::time::Duration;

const DEFAULT_RPC_TIMEOUT: Duration = Duration::from_secs(20);

pub struct ExecutionRpcChainAdapter {
    client: reqwest::Client,
    rpc_url: String,
}

#[derive(Debug, Deserialize)]
struct RpcErrorBody {
    code: i64,
    message: String,
    data: Option<Value>,
}

impl ExecutionRpcChainAdapter {
    pub fn new(rpc_url: impl Into<String>) -> Self {
        Self {
            client: reqwest::Client::builder()
                .timeout(DEFAULT_RPC_TIMEOUT)
                .build()
                .expect("execution RPC client with default timeout should build"),
            rpc_url: rpc_url.into(),
        }
    }

    pub async fn validate_chain_id(&self, expected_chain_id: u64) -> Result<(), ChainError> {
        let value = self.rpc_result("eth_chainId", json!([])).await?;
        let actual_chain_id = parse_hex_u64_result("eth_chainId", value)?;
        if actual_chain_id == expected_chain_id {
            return Ok(());
        }
        Err(ChainError::RpcError(format!(
            "eth_chainId mismatch: expected {expected_chain_id}, got {actual_chain_id}"
        )))
    }

    async fn rpc_result(&self, method: &'static str, params: Value) -> Result<Value, ChainError> {
        let response = self
            .client
            .post(&self.rpc_url)
            .json(&json!({
                "jsonrpc": "2.0",
                "id": 1_u64,
                "method": method,
                "params": params,
            }))
            .send()
            .await
            .map_err(rpc_error)?;

        if !response.status().is_success() {
            return Err(ChainError::RpcError(format!(
                "{method} HTTP status {}",
                response.status()
            )));
        }

        let body = response.json::<Value>().await.map_err(rpc_error)?;
        if let Some(error) = body.get("error") {
            let parsed = serde_json::from_value::<RpcErrorBody>(error.clone())
                .map_err(|err| ChainError::RpcError(format!("{method} error parse: {err}")))?;
            return Err(rpc_error_body(method, parsed));
        }

        body.get("result")
            .cloned()
            .ok_or_else(|| ChainError::RpcError(format!("{method} missing result")))
    }

    async fn rpc_deserialize<T: DeserializeOwned>(
        &self,
        method: &'static str,
        params: Value,
    ) -> Result<T, ChainError> {
        let value = self.rpc_result(method, params).await?;
        serde_json::from_value(value)
            .map_err(|error| ChainError::RpcError(format!("{method} result parse: {error}")))
    }
}

#[async_trait]
impl ChainAdapter for ExecutionRpcChainAdapter {
    async fn eth_get_balance(&self, address: Address, block: BlockTag) -> Result<U256, ChainError> {
        let value = self
            .rpc_result("eth_getBalance", json!([address, block]))
            .await?;
        parse_hex_u256_result("eth_getBalance", value)
    }

    async fn eth_get_code(&self, address: Address, block: BlockTag) -> Result<Bytes, ChainError> {
        self.rpc_deserialize("eth_getCode", json!([address, block]))
            .await
    }

    async fn eth_get_storage_at(
        &self,
        address: Address,
        slot: B256,
        block: BlockTag,
    ) -> Result<B256, ChainError> {
        self.rpc_deserialize("eth_getStorageAt", json!([address, slot, block]))
            .await
    }

    async fn eth_get_transaction_count(
        &self,
        address: Address,
        block: BlockTag,
    ) -> Result<u64, ChainError> {
        let value = self
            .rpc_result("eth_getTransactionCount", json!([address, block]))
            .await?;
        parse_hex_u64_result("eth_getTransactionCount", value)
    }

    async fn eth_call(
        &self,
        tx: CallRequest,
        block: BlockTag,
        state_overrides: Option<StateOverride>,
    ) -> Result<Bytes, ChainError> {
        let params = if let Some(state_overrides) = state_overrides {
            json!([tx, block, state_overrides])
        } else {
            json!([tx, block])
        };
        self.rpc_deserialize("eth_call", params).await
    }

    async fn eth_estimate_gas(
        &self,
        tx: CallRequest,
        block: Option<BlockTag>,
        state_overrides: Option<StateOverride>,
    ) -> Result<u64, ChainError> {
        let params = match (block, state_overrides) {
            (Some(block), Some(state_overrides)) => json!([tx, block, state_overrides]),
            (Some(block), None) => json!([tx, block]),
            (None, Some(state_overrides)) => json!([tx, BlockTag::Latest, state_overrides]),
            (None, None) => json!([tx]),
        };
        let value = self.rpc_result("eth_estimateGas", params).await?;
        parse_hex_u64_result("eth_estimateGas", value)
    }

    async fn eth_get_transaction_receipt(
        &self,
        tx_hash: B256,
    ) -> Result<Option<TransactionReceipt>, ChainError> {
        let value = self
            .rpc_result("eth_getTransactionReceipt", json!([tx_hash]))
            .await?;
        if value.is_null() {
            return Ok(None);
        }
        serde_json::from_value(value).map(Some).map_err(|error| {
            ChainError::RpcError(format!("eth_getTransactionReceipt parse: {error}"))
        })
    }

    async fn eth_get_block_by_number(
        &self,
        block: BlockTag,
        full_txs: bool,
    ) -> Result<Option<Block>, ChainError> {
        let value = self
            .rpc_result("eth_getBlockByNumber", json!([block, full_txs]))
            .await?;
        if value.is_null() {
            return Ok(None);
        }
        serde_json::from_value(value)
            .map(Some)
            .map_err(|error| ChainError::RpcError(format!("eth_getBlockByNumber parse: {error}")))
    }

    async fn current_head(&self) -> Result<BlockHeader, ChainError> {
        self.eth_get_block_by_number(BlockTag::Latest, false)
            .await?
            .map(|block| block.header)
            .ok_or(ChainError::BlockNotFound)
    }

    async fn execution_rpc_head(&self) -> Result<u64, ChainError> {
        let value = self.rpc_result("eth_blockNumber", json!([])).await?;
        parse_hex_u64_result("eth_blockNumber", value)
    }

    async fn is_synced(&self) -> bool {
        self.execution_rpc_head().await.is_ok()
    }

    async fn current_gas_price(&self) -> Result<U256, ChainError> {
        let value = self.rpc_result("eth_gasPrice", json!([])).await?;
        parse_hex_u256_result("eth_gasPrice", value)
    }

    async fn current_max_priority_fee_per_gas(&self) -> Result<U256, ChainError> {
        let value = self
            .rpc_result("eth_maxPriorityFeePerGas", json!([]))
            .await?;
        parse_hex_u256_result("eth_maxPriorityFeePerGas", value)
    }
}

fn rpc_error_body(method: &'static str, error: RpcErrorBody) -> ChainError {
    if let Some(data) = error.data.as_ref().and_then(rpc_error_revert_data) {
        if let Ok(bytes) = data.parse::<Bytes>() {
            return ChainError::CallReverted(bytes);
        }
    }
    ChainError::RpcError(format!("{method} error {}: {}", error.code, error.message))
}

fn rpc_error_revert_data(error_data: &Value) -> Option<&str> {
    error_data
        .as_str()
        .or_else(|| error_data.get("data").and_then(Value::as_str))
}

fn parse_hex_u64_result(method: &'static str, value: Value) -> Result<u64, ChainError> {
    let raw = value
        .as_str()
        .ok_or_else(|| ChainError::RpcError(format!("{method} result is not a hex quantity")))?;
    let stripped = raw
        .strip_prefix("0x")
        .ok_or_else(|| ChainError::RpcError(format!("{method} invalid hex quantity: {raw}")))?;
    if stripped.is_empty() {
        return Ok(0);
    }
    u64::from_str_radix(stripped, 16)
        .map_err(|error| ChainError::RpcError(format!("{method} hex quantity: {error}")))
}

fn parse_hex_u256_result(method: &'static str, value: Value) -> Result<U256, ChainError> {
    let raw = value
        .as_str()
        .ok_or_else(|| ChainError::RpcError(format!("{method} result is not a hex quantity")))?;
    let stripped = raw.strip_prefix("0x").unwrap_or(raw);
    U256::from_str_radix(stripped, 16)
        .map_err(|error| ChainError::RpcError(format!("{method} hex quantity: {error}")))
}

fn rpc_error(error: impl std::fmt::Display) -> ChainError {
    ChainError::RpcError(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    fn address(byte: u8) -> Address {
        Address::from([byte; 20])
    }

    async fn serve_rpc_once(response: Value) -> (String, tokio::task::JoinHandle<Value>) {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind test rpc");
        let url = format!("http://{}", listener.local_addr().expect("local addr"));
        let handle = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.expect("accept rpc request");
            let mut buffer = Vec::new();
            let mut temp = [0_u8; 1024];
            loop {
                let read = stream.read(&mut temp).await.expect("read request");
                assert!(read > 0, "request closed before headers");
                buffer.extend_from_slice(&temp[..read]);
                if let Some(request) = try_parse_http_json_body(&buffer) {
                    let response_body = response.to_string();
                    let http_response = format!(
                        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{}",
                        response_body.len(),
                        response_body
                    );
                    stream
                        .write_all(http_response.as_bytes())
                        .await
                        .expect("write response");
                    return request;
                }
            }
        });
        (url, handle)
    }

    fn try_parse_http_json_body(buffer: &[u8]) -> Option<Value> {
        let header_end = buffer.windows(4).position(|window| window == b"\r\n\r\n")? + 4;
        let headers = std::str::from_utf8(&buffer[..header_end]).ok()?;
        let content_length = headers.lines().find_map(|line| {
            line.to_ascii_lowercase()
                .strip_prefix("content-length:")?
                .trim()
                .parse::<usize>()
                .ok()
        })?;
        if buffer.len() < header_end + content_length {
            return None;
        }
        serde_json::from_slice(&buffer[header_end..header_end + content_length]).ok()
    }

    #[tokio::test]
    async fn eth_call_uses_execution_rpc_endpoint() {
        let (url, request_handle) =
            serve_rpc_once(json!({ "jsonrpc": "2.0", "id": 1, "result": "0x1234" })).await;
        let adapter = ExecutionRpcChainAdapter::new(url);
        let result = adapter
            .eth_call(
                CallRequest {
                    to: Some(address(0x11)),
                    data: Some(Bytes::from(vec![0xab, 0xcd])),
                    ..CallRequest::default()
                },
                BlockTag::Latest,
                None,
            )
            .await
            .expect("eth_call succeeds");

        assert_eq!(result, Bytes::from(vec![0x12, 0x34]));
        let request = request_handle.await.expect("request captured");
        assert_eq!(request["method"], "eth_call");
        assert_eq!(request["params"][1], "latest");
        assert_eq!(
            request["params"][0]["to"],
            "0x1111111111111111111111111111111111111111"
        );
    }

    #[tokio::test]
    async fn eth_call_maps_revert_data() {
        let (url, _request_handle) = serve_rpc_once(json!({
            "jsonrpc": "2.0",
            "id": 1,
            "error": {
                "code": 3,
                "message": "execution reverted",
                "data": "0x08c379a0"
            }
        }))
        .await;
        let adapter = ExecutionRpcChainAdapter::new(url);
        let error = adapter
            .eth_call(CallRequest::default(), BlockTag::Latest, None)
            .await
            .expect_err("eth_call reverts");

        assert!(
            matches!(error, ChainError::CallReverted(data) if data == Bytes::from(vec![0x08, 0xc3, 0x79, 0xa0]))
        );
    }

    #[tokio::test]
    async fn validate_chain_id_accepts_expected_rpc_chain() {
        let (url, request_handle) =
            serve_rpc_once(json!({ "jsonrpc": "2.0", "id": 1, "result": "0xaa36a7" })).await;
        let adapter = ExecutionRpcChainAdapter::new(url);

        adapter
            .validate_chain_id(11_155_111)
            .await
            .expect("chain id should match");

        let request = request_handle.await.expect("request captured");
        assert_eq!(request["method"], "eth_chainId");
    }

    #[tokio::test]
    async fn validate_chain_id_rejects_mismatched_rpc_chain() {
        let (url, request_handle) =
            serve_rpc_once(json!({ "jsonrpc": "2.0", "id": 1, "result": "0x1" })).await;
        let adapter = ExecutionRpcChainAdapter::new(url);

        let error = adapter
            .validate_chain_id(11_155_111)
            .await
            .expect_err("chain id should mismatch");

        assert!(
            matches!(error, ChainError::RpcError(message) if message.contains("eth_chainId mismatch"))
        );
        let request = request_handle.await.expect("request captured");
        assert_eq!(request["method"], "eth_chainId");
    }
}
