use alloy_primitives::{Address, Bytes, B256, U256};
use serde::Deserialize;
use serde_json::{json, Value};
use wallet_chain::types::{Log, TransactionReceipt};

use crate::{BundlerError, Result};

// `async_trait` marks each generated method `#[must_use]` and its boxed future is already must-use,
// which clippy 1.99 flags as `double_must_use`.
#[allow(clippy::double_must_use)]
#[async_trait::async_trait]
pub trait RawTransactionSubmitter: Send + Sync {
    async fn submit_raw_transaction(
        &self,
        raw_tx: &Bytes,
        expected_tx_hash: B256,
    ) -> Result<RawTransactionSubmitOutcome>;
}

#[allow(clippy::double_must_use)]
#[async_trait::async_trait]
pub trait RawTransactionReceiptFetcher: Send + Sync {
    async fn get_transaction_receipt(&self, tx_hash: B256) -> Result<Option<TransactionReceipt>>;
}

pub trait RawTransactionTransport: RawTransactionSubmitter + RawTransactionReceiptFetcher {}

impl<T> RawTransactionTransport for T where T: RawTransactionSubmitter + RawTransactionReceiptFetcher
{}

#[derive(Clone, Debug)]
pub struct RawTransactionSubmitClient {
    client: reqwest::Client,
    endpoint: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RawTransactionSubmitOutcome {
    Accepted(B256),
    AlreadyKnown,
    NonceTooLow,
}

#[derive(Debug, Deserialize)]
struct JsonRpcErrorBody {
    code: i64,
    message: String,
}

#[derive(Debug, Deserialize)]
struct JsonRpcResponse {
    result: Option<String>,
    error: Option<JsonRpcErrorBody>,
}

#[derive(Debug, Deserialize)]
struct JsonRpcReceiptResponse {
    result: Option<RpcTransactionReceipt>,
    error: Option<JsonRpcErrorBody>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RpcTransactionReceipt {
    transaction_hash: String,
    transaction_index: Option<String>,
    block_hash: Option<String>,
    block_number: Option<String>,
    from: String,
    to: Option<String>,
    cumulative_gas_used: String,
    gas_used: Option<String>,
    contract_address: Option<String>,
    #[serde(default)]
    logs: Vec<RpcLog>,
    status: Option<String>,
    effective_gas_price: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RpcLog {
    address: String,
    #[serde(default)]
    topics: Vec<String>,
    data: String,
    block_hash: Option<String>,
    block_number: Option<String>,
    transaction_hash: Option<String>,
    transaction_index: Option<String>,
    log_index: Option<String>,
    removed: Option<bool>,
}

impl RawTransactionSubmitClient {
    pub fn new(endpoint: impl Into<String>) -> Self {
        Self {
            client: reqwest::Client::new(),
            endpoint: endpoint.into(),
        }
    }
}

#[async_trait::async_trait]
impl RawTransactionSubmitter for RawTransactionSubmitClient {
    async fn submit_raw_transaction(
        &self,
        raw_tx: &Bytes,
        expected_tx_hash: B256,
    ) -> Result<RawTransactionSubmitOutcome> {
        let response = self
            .client
            .post(&self.endpoint)
            .json(&build_send_raw_transaction_request(raw_tx))
            .send()
            .await
            .map_err(|err| BundlerError::RawTransactionSubmission {
                reason: format!("request_failed: {err}"),
            })?;

        let status = response.status();
        let body =
            response
                .bytes()
                .await
                .map_err(|err| BundlerError::RawTransactionSubmission {
                    reason: format!("response_body_failed: {err}"),
                })?;
        if !status.is_success() {
            return Err(BundlerError::RawTransactionSubmission {
                reason: format!("http_status_{status}"),
            });
        }

        interpret_send_raw_transaction_response(expected_tx_hash, &body)
    }
}

#[async_trait::async_trait]
impl RawTransactionReceiptFetcher for RawTransactionSubmitClient {
    async fn get_transaction_receipt(&self, tx_hash: B256) -> Result<Option<TransactionReceipt>> {
        let response = self
            .client
            .post(&self.endpoint)
            .json(&build_get_transaction_receipt_request(tx_hash))
            .send()
            .await
            .map_err(|err| BundlerError::RawTransactionSubmission {
                reason: format!("request_failed: {err}"),
            })?;

        let status = response.status();
        let body =
            response
                .bytes()
                .await
                .map_err(|err| BundlerError::RawTransactionSubmission {
                    reason: format!("response_body_failed: {err}"),
                })?;
        if !status.is_success() {
            return Err(BundlerError::RawTransactionSubmission {
                reason: format!("http_status_{status}"),
            });
        }

        interpret_get_transaction_receipt_response(&body)
    }
}

pub fn build_send_raw_transaction_request(raw_tx: &Bytes) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": 1_u64,
        "method": "eth_sendRawTransaction",
        "params": [format!("0x{}", hex::encode(raw_tx))],
    })
}

pub fn build_get_transaction_receipt_request(tx_hash: B256) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": 1_u64,
        "method": "eth_getTransactionReceipt",
        "params": [format!("{tx_hash:#x}")],
    })
}

pub fn interpret_send_raw_transaction_response(
    expected_tx_hash: B256,
    body: &[u8],
) -> Result<RawTransactionSubmitOutcome> {
    let response: JsonRpcResponse =
        serde_json::from_slice(body).map_err(|err| BundlerError::RawTransactionSubmission {
            reason: format!("invalid_json: {err}"),
        })?;

    if let Some(error) = response.error {
        return classify_rpc_error(&error);
    }

    let Some(result) = response.result else {
        return Err(BundlerError::RawTransactionSubmission {
            reason: "missing_result".to_string(),
        });
    };
    let tx_hash = result
        .parse::<B256>()
        .map_err(|_| BundlerError::RawTransactionSubmission {
            reason: "invalid_tx_hash_result".to_string(),
        })?;
    if tx_hash != expected_tx_hash {
        return Err(BundlerError::RawTransactionSubmission {
            reason: "tx_hash_mismatch".to_string(),
        });
    }

    Ok(RawTransactionSubmitOutcome::Accepted(tx_hash))
}

pub fn interpret_get_transaction_receipt_response(
    body: &[u8],
) -> Result<Option<TransactionReceipt>> {
    let response: JsonRpcReceiptResponse =
        serde_json::from_slice(body).map_err(|err| BundlerError::RawTransactionSubmission {
            reason: format!("invalid_json: {err}"),
        })?;

    if let Some(error) = response.error {
        return Err(BundlerError::RawTransactionSubmission {
            reason: format!("rpc_error_{}: {}", error.code, error.message),
        });
    }

    response.result.map(TryInto::try_into).transpose()
}

fn classify_rpc_error(error: &JsonRpcErrorBody) -> Result<RawTransactionSubmitOutcome> {
    let message = error.message.to_ascii_lowercase();
    if message.contains("already known")
        || message.contains("already imported")
        || message.contains("known transaction")
        || message.contains("already in mempool")
    {
        return Ok(RawTransactionSubmitOutcome::AlreadyKnown);
    }
    if message.contains("nonce too low") {
        return Ok(RawTransactionSubmitOutcome::NonceTooLow);
    }

    Err(BundlerError::RawTransactionSubmission {
        reason: format!("rpc_error_{}: {}", error.code, error.message),
    })
}

impl TryFrom<RpcTransactionReceipt> for TransactionReceipt {
    type Error = BundlerError;

    fn try_from(value: RpcTransactionReceipt) -> Result<Self> {
        Ok(TransactionReceipt {
            transaction_hash: parse_b256(&value.transaction_hash, "transaction_hash")?,
            transaction_index: parse_optional_u64(value.transaction_index, "transaction_index")?,
            block_hash: parse_optional_b256(value.block_hash, "block_hash")?,
            block_number: parse_optional_u64(value.block_number, "block_number")?,
            from: parse_address(&value.from, "from")?,
            to: parse_optional_address(value.to, "to")?,
            cumulative_gas_used: parse_u64(&value.cumulative_gas_used, "cumulative_gas_used")?,
            gas_used: parse_optional_u64(value.gas_used, "gas_used")?,
            contract_address: parse_optional_address(value.contract_address, "contract_address")?,
            logs: value
                .logs
                .into_iter()
                .map(TryInto::try_into)
                .collect::<Result<Vec<_>>>()?,
            status: parse_optional_u64(value.status, "status")?,
            effective_gas_price: parse_optional_u256(
                value.effective_gas_price,
                "effective_gas_price",
            )?,
        })
    }
}

impl TryFrom<RpcLog> for Log {
    type Error = BundlerError;

    fn try_from(value: RpcLog) -> Result<Self> {
        Ok(Log {
            address: parse_address(&value.address, "log.address")?,
            topics: value
                .topics
                .into_iter()
                .map(|topic| parse_b256(&topic, "log.topic"))
                .collect::<Result<Vec<_>>>()?,
            data: parse_bytes(&value.data, "log.data")?,
            block_hash: parse_optional_b256(value.block_hash, "log.block_hash")?,
            block_number: parse_optional_u64(value.block_number, "log.block_number")?,
            transaction_hash: parse_optional_b256(value.transaction_hash, "log.transaction_hash")?,
            transaction_index: parse_optional_u64(
                value.transaction_index,
                "log.transaction_index",
            )?,
            log_index: parse_optional_u64(value.log_index, "log.log_index")?,
            removed: value.removed,
        })
    }
}

fn parse_address(value: &str, field: &'static str) -> Result<Address> {
    value
        .parse()
        .map_err(|_| BundlerError::RawTransactionSubmission {
            reason: format!("invalid_{field}"),
        })
}

fn parse_optional_address(value: Option<String>, field: &'static str) -> Result<Option<Address>> {
    value.map(|value| parse_address(&value, field)).transpose()
}

fn parse_b256(value: &str, field: &'static str) -> Result<B256> {
    value
        .parse()
        .map_err(|_| BundlerError::RawTransactionSubmission {
            reason: format!("invalid_{field}"),
        })
}

fn parse_optional_b256(value: Option<String>, field: &'static str) -> Result<Option<B256>> {
    value.map(|value| parse_b256(&value, field)).transpose()
}

fn parse_bytes(value: &str, field: &'static str) -> Result<Bytes> {
    let Some(hex_value) = value.strip_prefix("0x") else {
        return Err(BundlerError::RawTransactionSubmission {
            reason: format!("invalid_{field}"),
        });
    };
    hex::decode(hex_value)
        .map(Bytes::from)
        .map_err(|_| BundlerError::RawTransactionSubmission {
            reason: format!("invalid_{field}"),
        })
}

fn parse_u64(value: &str, field: &'static str) -> Result<u64> {
    u64::from_str_radix(value.trim_start_matches("0x"), 16).map_err(|_| {
        BundlerError::RawTransactionSubmission {
            reason: format!("invalid_{field}"),
        }
    })
}

fn parse_optional_u64(value: Option<String>, field: &'static str) -> Result<Option<u64>> {
    value.map(|value| parse_u64(&value, field)).transpose()
}

fn parse_optional_u256(value: Option<String>, field: &'static str) -> Result<Option<U256>> {
    value
        .map(|value| {
            U256::from_str_radix(value.trim_start_matches("0x"), 16).map_err(|_| {
                BundlerError::RawTransactionSubmission {
                    reason: format!("invalid_{field}"),
                }
            })
        })
        .transpose()
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::b256;

    fn expected_hash() -> B256 {
        b256!("1111111111111111111111111111111111111111111111111111111111111111")
    }

    fn receipt_body() -> &'static [u8] {
        br#"{
            "jsonrpc": "2.0",
            "id": 1,
            "result": {
                "transactionHash": "0x1111111111111111111111111111111111111111111111111111111111111111",
                "transactionIndex": "0x2",
                "blockHash": "0x2222222222222222222222222222222222222222222222222222222222222222",
                "blockNumber": "0x10",
                "from": "0x1000000000000000000000000000000000000000",
                "to": "0x0000000071727de22e5e9d8baf0edac6f37da032",
                "cumulativeGasUsed": "0x5208",
                "gasUsed": "0x5208",
                "contractAddress": null,
                "logs": [{
                    "address": "0x0000000071727de22e5e9d8baf0edac6f37da032",
                    "topics": ["0x3333333333333333333333333333333333333333333333333333333333333333"],
                    "data": "0xabcd",
                    "blockHash": "0x2222222222222222222222222222222222222222222222222222222222222222",
                    "blockNumber": "0x10",
                    "transactionHash": "0x1111111111111111111111111111111111111111111111111111111111111111",
                    "transactionIndex": "0x2",
                    "logIndex": "0x1",
                    "removed": false
                }],
                "status": "0x1",
                "effectiveGasPrice": "0x3b9aca00"
            }
        }"#
    }

    #[test]
    fn raw_transaction_request_uses_first_class_json_rpc_shape() {
        let request =
            build_send_raw_transaction_request(&Bytes::from(vec![0x02, 0x01, 0x80, 0xff]));

        assert_eq!(request["jsonrpc"], "2.0");
        assert_eq!(request["method"], "eth_sendRawTransaction");
        assert_eq!(request["params"][0], "0x020180ff");
    }

    #[test]
    fn receipt_request_uses_transaction_hash_param() {
        let request = build_get_transaction_receipt_request(expected_hash());

        assert_eq!(request["jsonrpc"], "2.0");
        assert_eq!(request["method"], "eth_getTransactionReceipt");
        assert_eq!(
            request["params"][0],
            "0x1111111111111111111111111111111111111111111111111111111111111111"
        );
    }

    #[test]
    fn accepted_response_requires_expected_transaction_hash() {
        let body = br#"{
            "jsonrpc": "2.0",
            "id": 1,
            "result": "0x1111111111111111111111111111111111111111111111111111111111111111"
        }"#;

        assert_eq!(
            interpret_send_raw_transaction_response(expected_hash(), body).unwrap(),
            RawTransactionSubmitOutcome::Accepted(expected_hash())
        );
    }

    #[test]
    fn mismatched_transaction_hash_is_rejected() {
        let body = br#"{
            "jsonrpc": "2.0",
            "id": 1,
            "result": "0x2222222222222222222222222222222222222222222222222222222222222222"
        }"#;

        match interpret_send_raw_transaction_response(expected_hash(), body).unwrap_err() {
            BundlerError::RawTransactionSubmission { reason } => {
                assert_eq!(reason, "tx_hash_mismatch");
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn retry_idempotent_provider_errors_are_non_fatal() {
        for (message, expected) in [
            ("already known", RawTransactionSubmitOutcome::AlreadyKnown),
            (
                "ALREADY IN MEMPOOL",
                RawTransactionSubmitOutcome::AlreadyKnown,
            ),
            ("nonce too low", RawTransactionSubmitOutcome::NonceTooLow),
        ] {
            let body = format!(
                r#"{{
                    "jsonrpc": "2.0",
                    "id": 1,
                    "error": {{"code": -32000, "message": "{message}"}}
                }}"#
            );

            assert_eq!(
                interpret_send_raw_transaction_response(expected_hash(), body.as_bytes()).unwrap(),
                expected
            );
        }
    }

    #[test]
    fn unknown_provider_error_is_fatal() {
        let body = br#"{
            "jsonrpc": "2.0",
            "id": 1,
            "error": {"code": -32000, "message": "intrinsic gas too low"}
        }"#;

        match interpret_send_raw_transaction_response(expected_hash(), body).unwrap_err() {
            BundlerError::RawTransactionSubmission { reason } => {
                assert!(reason.contains("rpc_error_-32000"));
                assert!(reason.contains("intrinsic gas too low"));
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn receipt_response_decodes_hex_quantities() {
        let receipt = interpret_get_transaction_receipt_response(receipt_body())
            .unwrap()
            .unwrap();

        assert_eq!(receipt.transaction_hash, expected_hash());
        assert_eq!(receipt.transaction_index, Some(2));
        assert_eq!(receipt.block_number, Some(16));
        assert_eq!(receipt.cumulative_gas_used, 21_000);
        assert_eq!(receipt.gas_used, Some(21_000));
        assert_eq!(receipt.status, Some(1));
        assert_eq!(
            receipt.effective_gas_price,
            Some(U256::from(1_000_000_000_u64))
        );
        assert_eq!(receipt.logs.len(), 1);
        assert_eq!(receipt.logs[0].data.as_ref(), &[0xab, 0xcd]);
    }

    #[test]
    fn missing_receipt_result_decodes_as_none() {
        let body = br#"{"jsonrpc":"2.0","id":1,"result":null}"#;

        assert!(interpret_get_transaction_receipt_response(body)
            .unwrap()
            .is_none());
    }
}
