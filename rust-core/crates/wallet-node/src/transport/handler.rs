use std::sync::Arc;
use std::time::Duration;

use bytes::{Bytes, BytesMut};
use http_body_util::{BodyExt, Full};
use hyper::body::Incoming;
use hyper::http::header::CONTENT_TYPE;
use hyper::http::{Response, StatusCode};
use tokio::task::JoinSet;
use tokio::time::{sleep_until, Instant};
use wallet_node_api::{
    parse_body_with_max, JsonRpcError, JsonRpcId, JsonRpcResponse, Method, MAX_REQUEST_BODY_BYTES,
};

#[derive(Clone, Debug)]
pub struct Handler {
    pub state: Arc<crate::state::DaemonState>,
}

impl Handler {
    pub async fn handle(&self, body: Bytes, auth_header: Option<String>) -> Response<Full<Bytes>> {
        let max_body_bytes = self.max_request_body_bytes();
        if body.len() > max_body_bytes {
            return json_response(
                StatusCode::PAYLOAD_TOO_LARGE,
                JsonRpcResponse::err(
                    JsonRpcId::Null,
                    JsonRpcError::body_too_large_with_max(body.len(), max_body_bytes),
                ),
            );
        }

        if let Err(err) = self.state.token.verify_header(auth_header.as_deref()) {
            return json_response(
                StatusCode::UNAUTHORIZED,
                JsonRpcResponse::err(
                    JsonRpcId::Null,
                    JsonRpcError {
                        code: err.json_rpc_code(),
                        message: "Unauthorized".to_string(),
                        data: None,
                    },
                ),
            );
        }

        let request = match parse_body_with_max(&body, max_body_bytes) {
            Ok(request) => request,
            Err(err) => {
                return json_response(
                    StatusCode::BAD_REQUEST,
                    JsonRpcResponse::err(JsonRpcId::Null, err),
                );
            }
        };

        let Some(method) = Method::from_str(&request.method) else {
            return json_response(
                StatusCode::OK,
                JsonRpcResponse::err(request.id, JsonRpcError::method_not_found(&request.method)),
            );
        };

        let rate_limit = self
            .state
            .rate_limiter
            .check(method.clone(), &self.state.config.rate_limits);
        if !rate_limit.allowed {
            return json_response(
                StatusCode::OK,
                JsonRpcResponse::err(
                    request.id,
                    JsonRpcError {
                        code: wallet_node_api::RATE_LIMITED,
                        message: "Rate limited".to_string(),
                        data: Some(serde_json::json!({
                            "retryAfterMs": (rate_limit.retry_after_secs * 1000.0).ceil() as u64,
                        })),
                    },
                ),
            );
        }

        match method {
            Method::WalletHealth | Method::WalletNetworkStatus => {
                let value = crate::handlers::health::handle(&self.state).await;
                json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
            }
            Method::WalletShutdown => {
                let value = crate::handlers::shutdown::handle(&self.state).await;
                json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
            }
            Method::WalletBundlerStatus => {
                match crate::handlers::wallet::bundler_status::handle(&self.state).await {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
            Method::WalletWalletStatus => {
                match crate::handlers::wallet::wallet_status::handle(&self.state, request.params)
                    .await
                {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
            Method::WalletPendingOperations => {
                match crate::handlers::wallet::pending_operations::handle(&self.state).await {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
            Method::WalletCancelPendingOperation => {
                match crate::handlers::wallet::cancel_pending_operation::handle(
                    &self.state,
                    request.params,
                )
                .await
                {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
            Method::WalletRotateBundlerEOA => {
                match crate::handlers::wallet::rotate_bundler_eoa::handle(
                    &self.state,
                    request.params,
                )
                .await
                {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
            Method::EthGetBalance => {
                match crate::handlers::eth::get_balance::handle(&self.state, request.params).await {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
            Method::EthGetCode => {
                match crate::handlers::eth::get_code::handle(&self.state, request.params).await {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
            Method::EthGetTransactionCount => {
                match crate::handlers::eth::get_transaction_count::handle(
                    &self.state,
                    request.params,
                )
                .await
                {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
            Method::EthCall => {
                match crate::handlers::eth::call::handle(&self.state, request.params).await {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
            Method::EthEstimateGas => {
                match crate::handlers::eth::estimate_gas::handle(&self.state, request.params).await
                {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
            Method::EthGetTransactionReceipt => {
                match crate::handlers::eth::get_transaction_receipt::handle(
                    &self.state,
                    request.params,
                )
                .await
                {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
            Method::EthGetBlockByNumber => {
                match crate::handlers::eth::get_block_by_number::handle(&self.state, request.params)
                    .await
                {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
            Method::EthGasPrice => {
                match crate::handlers::eth::gas_price::handle(&self.state).await {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
            Method::EthMaxPriorityFeePerGas => {
                match crate::handlers::eth::max_priority_fee_per_gas::handle(&self.state).await {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
            Method::EthSupportedEntryPoints => {
                match crate::handlers::bundler::supported_entry_points::handle(&self.state).await {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
            Method::EthEstimateUserOperationGas => {
                match crate::handlers::bundler::estimate_user_operation_gas::handle(
                    &self.state,
                    request.params,
                )
                .await
                {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
            Method::EthSendUserOperation => {
                match crate::handlers::bundler::send_user_operation::handle(
                    &self.state,
                    request.params,
                )
                .await
                {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
            Method::EthGetUserOperationReceipt => {
                match crate::handlers::bundler::get_user_operation_receipt::handle(
                    &self.state,
                    request.params,
                )
                .await
                {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
            Method::PimlicoGetUserOperationGasPrice => {
                match crate::handlers::bundler::gas_price::handle(&self.state).await {
                    Ok(value) => {
                        json_response(StatusCode::OK, JsonRpcResponse::ok(request.id, value))
                    }
                    Err(err) => {
                        json_response(StatusCode::OK, JsonRpcResponse::err(request.id, err))
                    }
                }
            }
        }
    }

    pub(crate) fn max_request_body_bytes(&self) -> usize {
        usize::try_from(self.state.config.policy.max_request_body_bytes)
            .unwrap_or(MAX_REQUEST_BODY_BYTES)
    }
}

fn json_response(status: StatusCode, response: JsonRpcResponse) -> Response<Full<Bytes>> {
    let body = serde_json::to_vec(&response).expect("JSON-RPC response serialization cannot fail");

    Response::builder()
        .status(status)
        .header(CONTENT_TYPE, "application/json")
        .body(Full::new(Bytes::from(body)))
        .expect("static response builder inputs are valid")
}

pub(crate) async fn read_body_limited(
    mut body: Incoming,
    max_body_bytes: usize,
) -> Result<Result<Bytes, usize>, hyper::Error> {
    let mut bytes = BytesMut::new();

    while let Some(frame) = body.frame().await {
        let frame = frame?;
        if let Some(data) = frame.data_ref() {
            let next_len = bytes.len().saturating_add(data.len());
            if next_len > max_body_bytes {
                return Ok(Err(next_len));
            }
            bytes.extend_from_slice(data);
        }
    }

    Ok(Ok(bytes.freeze()))
}

pub(crate) fn body_too_large_response(
    actual: usize,
    max_body_bytes: usize,
) -> Response<Full<Bytes>> {
    json_response(
        StatusCode::PAYLOAD_TOO_LARGE,
        JsonRpcResponse::err(
            JsonRpcId::Null,
            JsonRpcError::body_too_large_with_max(actual, max_body_bytes),
        ),
    )
}

#[derive(Debug, Eq, PartialEq)]
pub(crate) enum DrainResult {
    Completed,
    TimedOut(usize),
}

pub(crate) async fn drain_with_deadline(set: &mut JoinSet<()>, deadline: Duration) -> DrainResult {
    let deadline = Instant::now() + deadline;

    loop {
        if set.is_empty() {
            return DrainResult::Completed;
        }

        tokio::select! {
            joined = set.join_next() => {
                if joined.is_none() {
                    return DrainResult::Completed;
                }
            }
            _ = sleep_until(deadline) => {
                return DrainResult::TimedOut(set.len());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    use alloy_sol_types::{sol, SolCall, SolError};
    use http_body_util::BodyExt;
    use serde_json::json;
    use wallet_chain::{
        Address, BlockHeader, BlockTag, Bytes as ChainBytes, CallRequest, MockChainAdapter, B256,
        U256,
    };
    use wallet_node_store::{
        BundlerLifecycle, SubmittedTransaction, SubmittedTxStatus, UserOpStatus,
        UserOperation as StoredUserOperation, UserOperationReceipt,
    };

    use crate::auth::Token;
    use crate::bundler_keys::MemoryBundlerKeyStore;
    use crate::config::Config;
    use crate::paths::Paths;
    use crate::state::{DaemonState, TransportInfo};

    sol! {
        struct StakeInfo {
            uint256 stake;
            uint256 unstakeDelaySec;
        }

        struct ReturnInfo {
            uint256 preOpGas;
            uint256 prefund;
            uint256 accountValidationData;
            uint256 paymasterValidationData;
            bytes paymasterContext;
        }

        struct AggregatorStakeInfo {
            address aggregator;
            StakeInfo stakeInfo;
        }

        struct ValidationResult {
            ReturnInfo returnInfo;
            StakeInfo senderInfo;
            StakeInfo factoryInfo;
            StakeInfo paymasterInfo;
            AggregatorStakeInfo aggregatorInfo;
        }

        function simulateValidation() returns (ValidationResult);
        function createAccount(bytes initData, bytes32 salt);
        error FailedOp(uint256 opIndex, string reason);
    }

    #[tokio::test]
    async fn drain_completes_when_all_tasks_finish() {
        let mut set = JoinSet::new();

        for _ in 0..3 {
            set.spawn(async {
                tokio::time::sleep(Duration::from_millis(50)).await;
            });
        }

        let result = drain_with_deadline(&mut set, Duration::from_secs(1)).await;

        assert_eq!(result, DrainResult::Completed);
        assert!(set.is_empty());
    }

    #[tokio::test]
    async fn drain_times_out_when_tasks_hang() {
        let mut set = JoinSet::new();

        set.spawn(async {
            tokio::time::sleep(Duration::from_secs(5)).await;
        });

        let result = drain_with_deadline(&mut set, Duration::from_millis(100)).await;

        assert_eq!(result, DrainResult::TimedOut(1));
        set.abort_all();
        set.shutdown().await;
    }

    #[tokio::test]
    async fn routes_eth_get_balance_to_chain_adapter() {
        let address = Address::from([0x11; 20]);
        let chain = Arc::new(MockChainAdapter::new());
        chain.set_balance(address, BlockTag::Latest, U256::from(0x2a));
        let (handler, auth_header, _state) = test_handler(chain);

        let value = call_rpc(
            &handler,
            &auth_header,
            "eth_getBalance",
            json!([format!("{address:#x}"), "latest"]),
        )
        .await;

        assert_eq!(value["result"], "0x2a");
    }

    #[tokio::test]
    async fn routes_eth_estimate_gas_to_chain_adapter() {
        let address = Address::from([0x22; 20]);
        let tx = CallRequest {
            to: Some(address),
            data: Some(ChainBytes::from(vec![0xaa, 0xbb])),
            ..CallRequest::default()
        };
        let chain = Arc::new(MockChainAdapter::new());
        chain.set_gas_estimate(tx, Some(BlockTag::Latest), None, 51_000);
        let (handler, auth_header, _state) = test_handler(chain);

        let value = call_rpc(
            &handler,
            &auth_header,
            "eth_estimateGas",
            json!([{
                "to": format!("{address:#x}"),
                "data": "0xaabb"
            }, "latest"]),
        )
        .await;

        assert_eq!(value["result"], "0xc738");
    }

    #[tokio::test]
    async fn wallet_network_status_uses_health_shape() {
        let (handler, auth_header, _state) =
            test_handler(Arc::new(MockChainAdapter::with_synced(false)));

        let value = call_rpc(&handler, &auth_header, "wallet_networkStatus", json!([])).await;

        assert_eq!(value["result"]["status"], "syncing_consensus");
        assert_eq!(value["result"]["chainId"], 1);
        assert_eq!(value["result"]["helios"]["ready"], false);
    }

    #[tokio::test]
    async fn cancel_pending_operation_reports_missing_userop() {
        let (handler, auth_header, _state) = test_handler(Arc::new(MockChainAdapter::new()));

        let value = call_rpc(
            &handler,
            &auth_header,
            "wallet_cancelPendingOperation",
            json!(["0x1111111111111111111111111111111111111111111111111111111111111111"]),
        )
        .await;

        assert_eq!(
            value["error"]["code"],
            wallet_node_api::REPLACEMENT_NOT_POSSIBLE
        );
        assert_eq!(value["error"]["data"]["reason"], "user_op_not_found");
    }

    #[tokio::test]
    async fn cancel_pending_operation_rejects_terminal_userop() {
        let (handler, auth_header, state) = test_handler(Arc::new(MockChainAdapter::new()));
        let user_op_hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
        state
            .store
            .user_op_insert(stored_cancel_user_op(user_op_hash, UserOpStatus::Included))
            .await
            .unwrap();

        let value = call_rpc(
            &handler,
            &auth_header,
            "wallet_cancelPendingOperation",
            json!([user_op_hash]),
        )
        .await;

        assert_eq!(
            value["error"]["code"],
            wallet_node_api::REPLACEMENT_NOT_POSSIBLE
        );
        assert_eq!(value["error"]["data"]["reason"], "terminal_state");
        assert_eq!(value["error"]["data"]["status"], "included");
    }

    #[tokio::test]
    async fn cancel_pending_operation_submits_same_nonce_replacement() {
        let (handler, auth_header, state) = test_handler(Arc::new(MockChainAdapter::new()));
        let user_op_hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
        state.bundler_keys.create_key("bundler-eoa:1").unwrap();
        state
            .store
            .bundler_account_insert(
                1,
                "0xbeef000000000000000000000000000000000000",
                "bundler-eoa:1",
            )
            .await
            .unwrap();
        state
            .store
            .user_op_insert(stored_cancel_user_op(user_op_hash, UserOpStatus::Submitted))
            .await
            .unwrap();
        state
            .store
            .reserve_next_nonce(1, "0xbeef000000000000000000000000000000000000", 7)
            .await
            .unwrap();
        state
            .store
            .nonce_attach_tx_hash(
                1,
                "0xbeef000000000000000000000000000000000000",
                7,
                "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            )
            .await
            .unwrap();
        state
            .store
            .submitted_tx_insert(cancel_submitted_tx(user_op_hash, "0x10", "0x04"))
            .await
            .unwrap();

        let value = call_rpc(
            &handler,
            &auth_header,
            "wallet_cancelPendingOperation",
            json!([user_op_hash]),
        )
        .await;

        assert!(value.get("result").is_some(), "{value}");
        assert_eq!(value["result"]["userOpHash"], user_op_hash);
        assert_eq!(value["result"]["nonce"], 7);
        assert_eq!(
            value["result"]["replacementOf"],
            "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        );
        assert!(value["result"]["txHash"]
            .as_str()
            .unwrap()
            .starts_with("0x"));
        let old = state
            .store
            .submitted_tx_get("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(old.status, SubmittedTxStatus::Replaced);
    }

    #[tokio::test]
    async fn cancel_pending_operation_reports_cap_blocked_replacement() {
        let (handler, auth_header, state) = test_handler(Arc::new(MockChainAdapter::new()));
        let user_op_hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
        state
            .store
            .user_op_insert(stored_cancel_user_op(user_op_hash, UserOpStatus::Submitted))
            .await
            .unwrap();
        state
            .store
            .submitted_tx_insert(cancel_submitted_tx(user_op_hash, "0x40", "0x05"))
            .await
            .unwrap();

        let value = call_rpc(
            &handler,
            &auth_header,
            "wallet_cancelPendingOperation",
            json!([user_op_hash]),
        )
        .await;

        assert_eq!(
            value["error"]["code"],
            wallet_node_api::REPLACEMENT_NOT_POSSIBLE
        );
        assert_eq!(value["error"]["data"]["reason"], "gas_relay_stuck");
        assert_eq!(value["error"]["data"]["field"], "bundlerTx.maxFeePerGas");
    }

    fn stored_cancel_user_op(user_op_hash: &str, status: UserOpStatus) -> StoredUserOperation {
        StoredUserOperation {
            user_op_hash: user_op_hash.to_string(),
            chain_id: 1,
            entry_point: "0x0000000071727de22e5e9d8baf0edac6f37da032".to_string(),
            sender: "0xd73c7780b1c1da1586a8332d5499f36b7cbb33c2".to_string(),
            nonce: "0x1".to_string(),
            user_op_json: json!({
                "sender": "0xd73c7780b1c1da1586a8332d5499f36b7cbb33c2",
                "nonce": "0x01",
                "callData": "0x",
                "callGasLimit": "0x10",
                "verificationGasLimit": "0x20",
                "preVerificationGas": "0x30",
                "maxFeePerGas": "0x40",
                "maxPriorityFeePerGas": "0x05",
                "signature": "0xab"
            })
            .to_string(),
            status,
            created_at: 1,
            updated_at: 1,
        }
    }

    fn cancel_submitted_tx(
        user_op_hash: &str,
        max_fee_per_gas: &str,
        max_priority_fee_per_gas: &str,
    ) -> SubmittedTransaction {
        SubmittedTransaction {
            tx_hash: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                .to_string(),
            user_op_hash: user_op_hash.to_string(),
            chain_id: 1,
            bundler_address: "0xbeef000000000000000000000000000000000000".to_string(),
            nonce: 7,
            raw_tx: "0x02".to_string(),
            max_fee_per_gas: max_fee_per_gas.to_string(),
            max_priority_fee_per_gas: max_priority_fee_per_gas.to_string(),
            status: SubmittedTxStatus::Submitted,
            replacement_of: None,
            submitted_at_block: Some(100),
            created_at: 1,
            updated_at: 1,
        }
    }

    #[tokio::test]
    async fn rotate_bundler_eoa_creates_new_active_account() {
        let (handler, auth_header, _state) = test_handler(Arc::new(MockChainAdapter::new()));

        let value = call_rpc(&handler, &auth_header, "wallet_rotateBundlerEOA", json!([])).await;

        assert!(value["result"]["eoa"].as_str().unwrap().starts_with("0x"));
        assert_eq!(value["result"]["keyRef"], "bundler-eoa:1");
        assert_eq!(value["result"]["lifecycle"], "active");
        assert_eq!(value["result"]["needsTopup"], true);
    }

    #[tokio::test]
    async fn routes_phase4_gas_and_supported_entrypoints_methods() {
        let (handler, auth_header, _state) = test_handler(Arc::new(MockChainAdapter::new()));

        let entrypoints = call_rpc(
            &handler,
            &auth_header,
            "eth_supportedEntryPoints",
            json!([]),
        )
        .await;
        assert_eq!(
            entrypoints["result"][0],
            "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
        );

        let gas_price = call_rpc(
            &handler,
            &auth_header,
            "pimlico_getUserOperationGasPrice",
            json!([]),
        )
        .await;
        assert_eq!(
            gas_price["result"]["standard"]["maxFeePerGas"],
            "0x2540be400"
        );
        assert_eq!(
            gas_price["result"]["standard"]["maxPriorityFeePerGas"],
            "0x3b9aca00"
        );

        let eth_gas_price = call_rpc(&handler, &auth_header, "eth_gasPrice", json!([])).await;
        assert_eq!(eth_gas_price["result"], "0x2540be400");

        let priority_fee = call_rpc(
            &handler,
            &auth_header,
            "eth_maxPriorityFeePerGas",
            json!([]),
        )
        .await;
        assert_eq!(priority_fee["result"], "0x3b9aca00");
    }

    #[tokio::test]
    async fn bundler_status_surfaces_replacement_candidate() {
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let bundler_eoa = "0xbeef000000000000000000000000000000000000";
        let address: Address = bundler_eoa.parse().unwrap();
        chain.set_balance(address, BlockTag::Latest, U256::from(0x11c37937e08000_u64));
        chain.set_current_head(BlockHeader {
            number: 106,
            hash: B256::from([0x56; 32]),
            parent_hash: B256::from([0x55; 32]),
            timestamp: now_unix_seconds_for_tests(),
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        });
        let (handler, auth_header, state) = test_handler(chain);
        state
            .store
            .bundler_account_insert(1, bundler_eoa, "bundler-eoa:1")
            .await
            .unwrap();
        state
            .store
            .submitted_tx_insert(SubmittedTransaction {
                tx_hash: "0x1111111111111111111111111111111111111111111111111111111111111111"
                    .to_owned(),
                user_op_hash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                    .to_owned(),
                chain_id: 1,
                bundler_address: bundler_eoa.to_owned(),
                nonce: 7,
                raw_tx: "0x020180".to_owned(),
                max_fee_per_gas: "0x64".to_owned(),
                max_priority_fee_per_gas: "0x10".to_owned(),
                status: SubmittedTxStatus::Submitted,
                replacement_of: None,
                submitted_at_block: Some(100),
                created_at: 1,
                updated_at: 1,
            })
            .await
            .unwrap();

        let value = call_rpc(&handler, &auth_header, "wallet_bundlerStatus", json!([])).await;

        assert_eq!(value["result"]["ready"], true);
        assert_eq!(value["result"]["replacement"]["eligible"], true);
        assert_eq!(value["result"]["replacement"]["nonce"], 7);
        assert_eq!(
            value["result"]["replacement"]["txHash"],
            "0x1111111111111111111111111111111111111111111111111111111111111111"
        );
        assert_eq!(value["result"]["replacement"]["currentBlock"], 106);
        assert_eq!(value["result"]["replacement"]["minAgeBlocks"], 6);
    }

    #[tokio::test]
    async fn bundler_status_surfaces_replacement_blocked_reason() {
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let bundler_eoa = "0xbeef000000000000000000000000000000000000";
        let address: Address = bundler_eoa.parse().unwrap();
        chain.set_balance(address, BlockTag::Latest, U256::from(0x11c37937e08000_u64));
        chain.set_current_head(BlockHeader {
            number: 106,
            hash: B256::from([0x56; 32]),
            parent_hash: B256::from([0x55; 32]),
            timestamp: now_unix_seconds_for_tests(),
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        });
        let (handler, auth_header, state) = test_handler(chain);
        state
            .store
            .bundler_account_insert(1, bundler_eoa, "bundler-eoa:1")
            .await
            .unwrap();

        let user_op_hash = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let raw_op = json!({
            "sender": "0xd73c7780b1c1da1586a8332d5499f36b7cbb33c2",
            "nonce": "0x01",
            "callData": "0x",
            "callGasLimit": "0x10",
            "verificationGasLimit": "0x20",
            "preVerificationGas": "0x30",
            "maxFeePerGas": "0x40",
            "maxPriorityFeePerGas": "0x05",
            "signature": "0xab"
        });
        state
            .store
            .user_op_insert(StoredUserOperation {
                user_op_hash: user_op_hash.to_string(),
                chain_id: 1,
                entry_point: "0x0000000071727de22e5e9d8baf0edac6f37da032".to_string(),
                sender: "0xd73c7780b1c1da1586a8332d5499f36b7cbb33c2".to_string(),
                nonce: "0x1".to_string(),
                user_op_json: raw_op.to_string(),
                status: UserOpStatus::Submitted,
                created_at: 1,
                updated_at: 1,
            })
            .await
            .unwrap();
        state
            .store
            .submitted_tx_insert(SubmittedTransaction {
                tx_hash: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                    .to_string(),
                user_op_hash: user_op_hash.to_string(),
                chain_id: 1,
                bundler_address: bundler_eoa.to_string(),
                nonce: 7,
                raw_tx: "0x02".to_string(),
                max_fee_per_gas: "0x40".to_string(),
                max_priority_fee_per_gas: "0x05".to_string(),
                status: SubmittedTxStatus::Submitted,
                replacement_of: None,
                submitted_at_block: Some(100),
                created_at: 1,
                updated_at: 1,
            })
            .await
            .unwrap();

        let value = call_rpc(&handler, &auth_header, "wallet_bundlerStatus", json!([])).await;

        assert_eq!(value["result"]["replacement"]["eligible"], true);
        assert_eq!(value["result"]["replacement"]["blocked"], true);
        assert_eq!(
            value["result"]["replacement"]["blockedReason"]["reason"],
            "gas_relay_stuck"
        );
        assert_eq!(
            value["result"]["replacement"]["blockedReason"]["field"],
            "bundlerTx.maxFeePerGas"
        );
    }

    #[tokio::test]
    async fn bundler_status_surfaces_rotation_state() {
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let retiring_eoa = "0xbeef000000000000000000000000000000000000";
        let active_eoa = "0xcafe000000000000000000000000000000000000";
        let active_address: Address = active_eoa.parse().unwrap();
        chain.set_balance(
            active_address,
            BlockTag::Latest,
            U256::from(0x11c37937e08000_u64),
        );
        chain.set_current_head(BlockHeader {
            number: 106,
            hash: B256::from([0x56; 32]),
            parent_hash: B256::from([0x55; 32]),
            timestamp: now_unix_seconds_for_tests(),
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        });
        let (handler, auth_header, state) = test_handler(chain);
        state
            .store
            .bundler_account_insert(1, retiring_eoa, "bundler-eoa:1")
            .await
            .unwrap();
        state
            .store
            .bundler_account_set_lifecycle(1, retiring_eoa, BundlerLifecycle::Retiring)
            .await
            .unwrap();
        state
            .store
            .bundler_account_insert(1, active_eoa, "bundler-eoa:2")
            .await
            .unwrap();

        let value = call_rpc(&handler, &auth_header, "wallet_bundlerStatus", json!([])).await;

        assert_eq!(value["result"]["eoa"], active_eoa);
        assert_eq!(value["result"]["rotation"]["rotating"], true);
        assert_eq!(value["result"]["rotation"]["retiring"][0], retiring_eoa);
    }

    #[tokio::test]
    async fn configured_request_body_cap_is_enforced_by_handler() {
        let mut config = Config::default();
        config.policy.max_request_body_bytes = 128;
        let (handler, auth_header, _state) =
            test_handler_with_config(Arc::new(MockChainAdapter::new()), config);
        let body = Bytes::from(
            serde_json::to_vec(&json!({
                "jsonrpc": "2.0",
                "method": "wallet_health",
                "params": { "padding": "a".repeat(160) },
                "id": 1,
            }))
            .expect("serialize request"),
        );

        let response = handler.handle(body, Some(auth_header)).await;
        assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
        let bytes = response
            .into_body()
            .collect()
            .await
            .expect("collect response")
            .to_bytes();
        let value: serde_json::Value = serde_json::from_slice(&bytes).expect("response JSON");

        assert_eq!(value["error"]["code"], wallet_node_api::BODY_TOO_LARGE);
        assert_eq!(value["error"]["data"]["max"], 128);
    }

    #[tokio::test]
    async fn configured_request_body_cap_is_available_to_transports() {
        let mut config = Config::default();
        config.policy.max_request_body_bytes = 4096;
        let (handler, _auth_header, _state) =
            test_handler_with_config(Arc::new(MockChainAdapter::new()), config);

        assert_eq!(handler.max_request_body_bytes(), 4096);
    }

    #[tokio::test]
    async fn estimate_user_operation_gas_validates_policy_and_returns_prefund() {
        let entry_point: Address = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            .parse()
            .unwrap();
        let head = BlockHeader {
            number: 123,
            hash: B256::from([0x56; 32]),
            parent_hash: B256::from([0x55; 32]),
            timestamp: now_unix_seconds_for_tests(),
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        };
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let op = wallet_bundler::UserOperation::parse(sample_user_op("0x")).unwrap();
        let simulation_op = op.with_signature(wallet_bundler::dummy_webauthn_signature(false));
        chain.set_current_head(head.clone());
        chain.set_balance(op.sender, BlockTag::Hash(head.hash), U256::from(0x1800));
        set_entry_point_deposit(
            &chain,
            entry_point,
            op.sender,
            BlockTag::Hash(head.hash),
            U256::ZERO,
        );
        chain.set_call_response(
            CallRequest {
                to: Some(entry_point),
                data: Some(wallet_bundler::encode_simulate_validation(&simulation_op).unwrap()),
                ..Default::default()
            },
            BlockTag::Hash(head.hash),
            Some(wallet_bundler::simulations_state_override(
                entry_point,
                wallet_bundler::entry_point_simulations_runtime_bytecode().unwrap(),
            )),
            validation_response(U256::from(0x999), U256::from(1)),
        );
        let (handler, auth_header, state) = test_handler(chain.clone());
        state.mark_state_override_smoke_passed();

        let value = call_rpc(
            &handler,
            &auth_header,
            "eth_estimateUserOperationGas",
            json!([
                sample_user_op("0x"),
                "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            ]),
        )
        .await;

        assert_eq!(value["result"]["callGasLimit"], "0x10");
        assert_eq!(value["result"]["verificationGasLimit"], "0x20");
        assert_eq!(value["result"]["preVerificationGas"], "0x30");
        assert_eq!(value["result"]["requiredPrefund"], "0x999");
        assert_eq!(chain.balance_call_count(), 1);
        assert_eq!(chain.call_call_count(), 2);
    }

    #[tokio::test]
    async fn estimate_user_operation_gas_falls_back_when_kernel_dummy_reverts() {
        let entry_point: Address = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            .parse()
            .unwrap();
        let head = BlockHeader {
            number: 123,
            hash: B256::from([0x56; 32]),
            parent_hash: B256::from([0x55; 32]),
            timestamp: now_unix_seconds_for_tests(),
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        };
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let op = wallet_bundler::UserOperation::parse(sample_user_op("0x")).unwrap();
        let runtime = wallet_bundler::entry_point_simulations_runtime_bytecode().unwrap();
        let overrides = Some(wallet_bundler::simulations_state_override(
            entry_point,
            runtime.clone(),
        ));
        let revert_data = FailedOp {
            opIndex: U256::ZERO,
            reason: "AA23 reverted".to_string(),
        }
        .abi_encode();
        chain.set_current_head(head.clone());
        chain.set_balance(op.sender, BlockTag::Hash(head.hash), U256::from(0x1800));
        set_entry_point_deposit(
            &chain,
            entry_point,
            op.sender,
            BlockTag::Hash(head.hash),
            U256::ZERO,
        );
        for use_precompiled in [false, true] {
            for simulation_base in [
                op.clone(),
                op.with_verification_gas_limit(U256::from(1_000_000u64)),
            ] {
                let simulation_op = simulation_base
                    .with_signature(wallet_bundler::dummy_webauthn_signature(use_precompiled));
                chain.set_call_revert(
                    CallRequest {
                        to: Some(entry_point),
                        data: Some(
                            wallet_bundler::encode_simulate_validation(&simulation_op).unwrap(),
                        ),
                        ..Default::default()
                    },
                    BlockTag::Hash(head.hash),
                    overrides.clone(),
                    ChainBytes::from(revert_data.clone()),
                );
            }
        }
        let (handler, auth_header, state) = test_handler(chain.clone());
        state.mark_state_override_smoke_passed();

        let value = call_rpc(
            &handler,
            &auth_header,
            "eth_estimateUserOperationGas",
            json!([
                sample_user_op("0x"),
                "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            ]),
        )
        .await;

        assert_eq!(value["result"]["callGasLimit"], "0x10");
        assert_eq!(value["result"]["verificationGasLimit"], "0x20");
        assert_eq!(value["result"]["preVerificationGas"], "0x30");
        assert_eq!(value["result"]["requiredPrefund"], "0x1800");
        assert_eq!(chain.call_call_count(), 5);
    }

    #[tokio::test]
    async fn estimate_user_operation_gas_retries_with_higher_verification_gas() {
        let entry_point: Address = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            .parse()
            .unwrap();
        let head = BlockHeader {
            number: 123,
            hash: B256::from([0x56; 32]),
            parent_hash: B256::from([0x55; 32]),
            timestamp: now_unix_seconds_for_tests(),
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        };
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let op = wallet_bundler::UserOperation::parse(sample_user_op("0x")).unwrap();
        let runtime = wallet_bundler::entry_point_simulations_runtime_bytecode().unwrap();
        let overrides = Some(wallet_bundler::simulations_state_override(
            entry_point,
            runtime.clone(),
        ));
        let revert_data = FailedOp {
            opIndex: U256::ZERO,
            reason: "AA23 reverted".to_string(),
        }
        .abi_encode();
        let original_simulation_op =
            op.with_signature(wallet_bundler::dummy_webauthn_signature(false));
        let boosted_op = op.with_verification_gas_limit(U256::from(1_000_000u64));
        let boosted_simulation_op =
            boosted_op.with_signature(wallet_bundler::dummy_webauthn_signature(false));

        chain.set_current_head(head.clone());
        chain.set_balance(op.sender, BlockTag::Hash(head.hash), U256::from(0x1800));
        set_entry_point_deposit(
            &chain,
            entry_point,
            op.sender,
            BlockTag::Hash(head.hash),
            U256::ZERO,
        );
        chain.set_call_revert(
            CallRequest {
                to: Some(entry_point),
                data: Some(
                    wallet_bundler::encode_simulate_validation(&original_simulation_op).unwrap(),
                ),
                ..Default::default()
            },
            BlockTag::Hash(head.hash),
            overrides.clone(),
            ChainBytes::from(revert_data),
        );
        chain.set_call_response(
            CallRequest {
                to: Some(entry_point),
                data: Some(
                    wallet_bundler::encode_simulate_validation(&boosted_simulation_op).unwrap(),
                ),
                ..Default::default()
            },
            BlockTag::Hash(head.hash),
            overrides,
            validation_response(U256::from(0xabc), U256::ZERO),
        );
        let (handler, auth_header, state) = test_handler(chain.clone());
        state.mark_state_override_smoke_passed();

        let value = call_rpc(
            &handler,
            &auth_header,
            "eth_estimateUserOperationGas",
            json!([
                sample_user_op("0x"),
                "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            ]),
        )
        .await;

        assert_eq!(value["result"]["callGasLimit"], "0x10");
        assert_eq!(value["result"]["verificationGasLimit"], "0xf4240");
        assert_eq!(value["result"]["preVerificationGas"], "0x30");
        assert_eq!(value["result"]["requiredPrefund"], "0xabc");
        assert_eq!(chain.call_call_count(), 3);
    }

    #[tokio::test]
    async fn estimate_user_operation_gas_rejects_gas_underfunding_before_simulation() {
        let entry_point: Address = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            .parse()
            .unwrap();
        let head = BlockHeader {
            number: 124,
            hash: B256::from([0x57; 32]),
            parent_hash: B256::from([0x56; 32]),
            timestamp: now_unix_seconds_for_tests(),
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        };
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let op = wallet_bundler::UserOperation::parse(sample_user_op("0x")).unwrap();
        chain.set_current_head(head.clone());
        chain.set_balance(op.sender, BlockTag::Hash(head.hash), U256::from(0x17ff));
        set_entry_point_deposit(
            &chain,
            entry_point,
            op.sender,
            BlockTag::Hash(head.hash),
            U256::ZERO,
        );
        let (handler, auth_header, state) = test_handler(chain.clone());
        state.mark_state_override_smoke_passed();

        let value = call_rpc(
            &handler,
            &auth_header,
            "eth_estimateUserOperationGas",
            json!([
                sample_user_op("0x"),
                "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            ]),
        )
        .await;

        assert_eq!(
            value["error"]["code"],
            wallet_node_api::INSUFFICIENT_SMART_ACCOUNT_BALANCE
        );
        assert_eq!(value["error"]["data"]["reason"], "gas_shortfall");
        assert_eq!(value["error"]["data"]["minimumAccountBalance"], "0x1800");
        assert_eq!(value["error"]["data"]["deficit"], "0x1");
        assert_eq!(chain.code_call_count(), 1);
        assert_eq!(chain.balance_call_count(), 1);
        assert_eq!(chain.call_call_count(), 1);
    }

    #[tokio::test]
    async fn estimate_user_operation_gas_rejects_value_underfunding_before_simulation() {
        let entry_point: Address = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            .parse()
            .unwrap();
        let target: Address = "0x1111111111111111111111111111111111111111"
            .parse()
            .unwrap();
        let head = BlockHeader {
            number: 124,
            hash: B256::from([0x59; 32]),
            parent_hash: B256::from([0x58; 32]),
            timestamp: now_unix_seconds_for_tests(),
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        };
        let call_data = wallet_bundler::encode_erc7579_single_execution(
            target,
            U256::from(0x20),
            ChainBytes::from_static(&[0xab, 0xcd]),
        );
        let mut raw_op = sample_user_op("0x");
        raw_op["callData"] = json!(hex_data(&call_data));
        let op = wallet_bundler::UserOperation::parse(raw_op.clone()).unwrap();
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        chain.set_current_head(head.clone());
        chain.set_balance(op.sender, BlockTag::Hash(head.hash), U256::from(0x1f));
        set_entry_point_deposit(
            &chain,
            entry_point,
            op.sender,
            BlockTag::Hash(head.hash),
            op.required_prefund(),
        );
        let (handler, auth_header, state) = test_handler(chain.clone());
        state.mark_state_override_smoke_passed();

        let value = call_rpc(
            &handler,
            &auth_header,
            "eth_estimateUserOperationGas",
            json!([raw_op, "0x0000000071727De22E5E9d8BAf0edAc6f37da032"]),
        )
        .await;

        assert_eq!(
            value["error"]["code"],
            wallet_node_api::INSUFFICIENT_SMART_ACCOUNT_BALANCE
        );
        assert_eq!(
            value["error"]["data"]["reason"],
            "transferable_below_call_value"
        );
        assert_eq!(value["error"]["data"]["callValue"], "0x20");
        assert_eq!(value["error"]["data"]["minimumAccountBalance"], "0x20");
        assert_eq!(value["error"]["data"]["deficit"], "0x1");
        assert_eq!(chain.code_call_count(), 1);
        assert_eq!(chain.balance_call_count(), 1);
        assert_eq!(chain.call_call_count(), 1);
    }

    #[tokio::test]
    async fn estimate_user_operation_gas_rejects_entrypoint_deposit_management() {
        let entry_point: Address = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            .parse()
            .unwrap();
        let head = BlockHeader {
            number: 124,
            hash: B256::from([0x5a; 32]),
            parent_hash: B256::from([0x59; 32]),
            timestamp: now_unix_seconds_for_tests(),
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        };
        let sender = sample_sender();
        let mut raw_op = sample_user_op("0x");
        let base_op = wallet_bundler::UserOperation::parse(raw_op.clone()).unwrap();
        let withdraw_call = wallet_bundler::encode_entry_point_withdraw_to(sender, U256::from(6));
        let account_call =
            wallet_bundler::encode_erc7579_single_execution(entry_point, U256::ZERO, withdraw_call);
        raw_op["callData"] = json!(hex_data(&account_call));
        let op = wallet_bundler::UserOperation::parse(raw_op.clone()).unwrap();
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        chain.set_current_head(head.clone());
        chain.set_balance(op.sender, BlockTag::Hash(head.hash), U256::ZERO);
        set_entry_point_deposit(
            &chain,
            entry_point,
            op.sender,
            BlockTag::Hash(head.hash),
            base_op.required_prefund() + U256::from(10),
        );
        let (handler, auth_header, state) = test_handler(chain.clone());
        state.mark_state_override_smoke_passed();

        let value = call_rpc(
            &handler,
            &auth_header,
            "eth_estimateUserOperationGas",
            json!([raw_op, "0x0000000071727De22E5E9d8BAf0edAc6f37da032"]),
        )
        .await;

        assert_eq!(
            value["error"]["code"],
            wallet_node_api::WITHDRAW_AMOUNT_EXCEEDS_RECLAIMABLE
        );
        assert_eq!(
            value["error"]["data"]["reason"],
            "entrypoint_deposit_management_unsupported"
        );
        assert_eq!(chain.code_call_count(), 1);
        assert_eq!(chain.balance_call_count(), 1);
        assert_eq!(chain.call_call_count(), 1);
    }

    #[tokio::test]
    async fn estimate_user_operation_gas_rejects_non_allowlisted_sender_code_before_simulation() {
        let sender = sample_sender();
        let head = BlockHeader {
            number: 125,
            hash: B256::from([0x58; 32]),
            parent_hash: B256::from([0x57; 32]),
            timestamp: 1_700_000_024,
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        };
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        chain.set_current_head(head.clone());
        chain.set_code(
            sender,
            BlockTag::Hash(head.hash),
            ChainBytes::from_static(&[0x60, 0x00]),
        );
        let (handler, auth_header, state) = test_handler(chain.clone());
        state.mark_state_override_smoke_passed();

        let value = call_rpc(
            &handler,
            &auth_header,
            "eth_estimateUserOperationGas",
            json!([
                deployed_sample_user_op("0x"),
                "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            ]),
        )
        .await;

        assert_eq!(
            value["error"]["code"],
            wallet_node_api::ACCOUNT_CODE_NOT_ALLOWLISTED
        );
        assert_eq!(value["error"]["data"]["layer"], "proxy");
        assert_eq!(value["error"]["data"]["moduleType"], "kernel_proxy");
        assert_eq!(chain.code_call_count(), 1);
        assert_eq!(chain.call_call_count(), 0);
    }

    #[tokio::test]
    async fn estimate_user_operation_gas_reads_erc1967_slot_for_solady_proxy_before_module_gate() {
        let sender = sample_sender();
        let head = BlockHeader {
            number: 126,
            hash: B256::from([0x59; 32]),
            parent_hash: B256::from([0x58; 32]),
            timestamp: 1_700_000_025,
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        };
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        chain.set_current_head(head.clone());
        chain.set_code(
            sender,
            BlockTag::Hash(head.hash),
            ChainBytes::copy_from_slice(wallet_bundler::allowlist::SOLADY_ERC1967_PROXY_RUNTIME),
        );
        let (handler, auth_header, state) = test_handler(chain.clone());
        state.mark_state_override_smoke_passed();

        let value = call_rpc(
            &handler,
            &auth_header,
            "eth_estimateUserOperationGas",
            json!([
                deployed_sample_user_op("0x"),
                "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            ]),
        )
        .await;

        assert_eq!(
            value["error"]["code"],
            wallet_node_api::ACCOUNT_CODE_NOT_ALLOWLISTED
        );
        assert_eq!(value["error"]["data"]["layer"], "implementation");
        assert_eq!(
            value["error"]["data"]["moduleType"],
            "kernel_implementation_slot"
        );
        assert_eq!(chain.code_call_count(), 1);
        assert_eq!(chain.storage_call_count(), 1);
        assert_eq!(chain.balance_call_count(), 0);
        assert_eq!(chain.call_call_count(), 0);
    }

    #[tokio::test]
    async fn send_user_operation_returns_existing_hash_idempotently() {
        let entry_point: Address = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            .parse()
            .unwrap();
        let op = wallet_bundler::UserOperation::parse(sample_user_op("0xab")).unwrap();
        let hash = format!(
            "{:#x}",
            B256::from(op.user_op_hash(entry_point, 1).unwrap())
        );
        let chain = Arc::new(MockChainAdapter::with_synced(false));
        let (handler, auth_header, state) = test_handler(chain.clone());
        state
            .store
            .user_op_insert(StoredUserOperation {
                user_op_hash: hash.clone(),
                chain_id: 1,
                entry_point: format!("{entry_point:#x}"),
                sender: format!("{:#x}", op.sender),
                nonce: format!("0x{:x}", op.nonce),
                user_op_json: serde_json::to_string(&op.raw).unwrap(),
                status: UserOpStatus::Pending,
                created_at: 1,
                updated_at: 1,
            })
            .await
            .unwrap();

        let value = call_rpc(
            &handler,
            &auth_header,
            "eth_sendUserOperation",
            json!([
                sample_user_op("0xab"),
                "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            ]),
        )
        .await;

        assert_eq!(value["result"], hash);
        assert_eq!(chain.is_synced_call_count(), 0);
    }

    #[tokio::test]
    async fn send_user_operation_persists_and_submits_raw_transaction() {
        let entry_point: Address = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            .parse()
            .unwrap();
        let head = BlockHeader {
            number: 124,
            hash: B256::from([0x57; 32]),
            parent_hash: B256::from([0x56; 32]),
            timestamp: now_unix_seconds_for_tests(),
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        };
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        chain.set_current_head(head.clone());
        let op = wallet_bundler::UserOperation::parse(sample_user_op("0xab")).unwrap();
        chain.set_balance(op.sender, BlockTag::Hash(head.hash), U256::from(0x1800));
        set_entry_point_deposit(
            &chain,
            entry_point,
            op.sender,
            BlockTag::Hash(head.hash),
            U256::ZERO,
        );
        let (handler, auth_header, state) = test_handler(chain.clone());
        state.mark_state_override_smoke_passed();
        let bundler_address = state.bundler_keys.create_key("bundler-eoa:1").unwrap();
        let bundler_eoa = format!("{bundler_address:#x}");
        chain.set_balance(
            bundler_address,
            BlockTag::Hash(head.hash),
            U256::from(5_000_000_000_000_000_u64),
        );
        state
            .store
            .bundler_account_insert(1, &bundler_eoa, "bundler-eoa:1")
            .await
            .unwrap();

        let value = call_rpc(
            &handler,
            &auth_header,
            "eth_sendUserOperation",
            json!([
                sample_user_op("0xab"),
                "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            ]),
        )
        .await;

        assert!(value["result"].as_str().unwrap().starts_with("0x"));
        assert_eq!(chain.code_call_count(), 1);
        assert_eq!(chain.balance_call_count(), 2);
        assert_eq!(chain.call_call_count(), 1);
        assert_eq!(chain.transaction_count_call_count(), 1);

        let pending = call_rpc(
            &handler,
            &auth_header,
            "wallet_pendingOperations",
            json!([]),
        )
        .await;
        assert_eq!(pending["result"].as_array().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn send_user_operation_creates_missing_bundler_eoa_then_requires_topup() {
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let head = BlockHeader {
            number: 124,
            hash: B256::from([0x57; 32]),
            parent_hash: B256::from([0x56; 32]),
            timestamp: now_unix_seconds_for_tests(),
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        };
        chain.set_current_head(head);
        let (handler, auth_header, state) = test_handler(chain.clone());
        state.mark_state_override_smoke_passed();

        let value = call_rpc(
            &handler,
            &auth_header,
            "eth_sendUserOperation",
            json!([
                sample_user_op("0xab"),
                "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            ]),
        )
        .await;

        assert_eq!(value["error"]["code"], wallet_node_api::NOT_READY);
        assert_eq!(value["error"]["data"]["reason"], "bundler_eoa_needs_topup");
        assert_eq!(chain.call_call_count(), 0);
        assert!(state
            .store
            .bundler_account_active(1)
            .await
            .unwrap()
            .is_some());
    }

    #[tokio::test]
    async fn send_user_operation_rejects_underfunded_bundler_eoa_before_simulation() {
        let bundler_eoa = "0xbeef000000000000000000000000000000000000";
        let bundler_address: Address = bundler_eoa.parse().unwrap();
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let head = BlockHeader {
            number: 124,
            hash: B256::from([0x57; 32]),
            parent_hash: B256::from([0x56; 32]),
            timestamp: now_unix_seconds_for_tests(),
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        };
        chain.set_current_head(head.clone());
        chain.set_balance(
            bundler_address,
            BlockTag::Hash(head.hash),
            U256::from(1_u64),
        );
        let (handler, auth_header, state) = test_handler(chain.clone());
        state.mark_state_override_smoke_passed();
        state
            .store
            .bundler_account_insert(1, bundler_eoa, "bundler-eoa:1")
            .await
            .unwrap();

        let value = call_rpc(
            &handler,
            &auth_header,
            "eth_sendUserOperation",
            json!([
                sample_user_op("0xab"),
                "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            ]),
        )
        .await;

        assert_eq!(value["error"]["code"], wallet_node_api::NOT_READY);
        assert_eq!(value["error"]["data"]["reason"], "bundler_eoa_needs_topup");
        assert_eq!(chain.call_call_count(), 0);
    }

    #[tokio::test]
    async fn send_user_operation_stops_when_bundler_eoa_compromise_is_suspected() {
        let bundler_eoa = "0xbeef000000000000000000000000000000000000";
        let bundler_address: Address = bundler_eoa.parse().unwrap();
        let head = BlockHeader {
            number: 124,
            hash: B256::from([0x57; 32]),
            parent_hash: B256::from([0x56; 32]),
            timestamp: now_unix_seconds_for_tests(),
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        };
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        chain.set_current_head(head.clone());
        chain.set_balance(
            bundler_address,
            BlockTag::Latest,
            U256::from(0x11c37937e08000_u64),
        );
        chain.set_balance(bundler_address, BlockTag::Hash(head.hash), U256::ZERO);
        let (handler, auth_header, state) = test_handler(chain.clone());
        state.mark_state_override_smoke_passed();
        state
            .store
            .bundler_account_insert(1, bundler_eoa, "bundler-eoa:1")
            .await
            .unwrap();

        let status = call_rpc(&handler, &auth_header, "wallet_bundlerStatus", json!([])).await;
        assert_eq!(status["result"]["compromise"]["suspected"], false);

        let value = call_rpc(
            &handler,
            &auth_header,
            "eth_sendUserOperation",
            json!([
                sample_user_op("0xab"),
                "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            ]),
        )
        .await;

        assert_eq!(value["error"]["code"], wallet_node_api::NOT_READY);
        assert_eq!(
            value["error"]["data"]["reason"],
            "bundler_eoa_compromise_suspected"
        );
        assert_eq!(chain.code_call_count(), 0);
    }

    #[tokio::test]
    async fn send_user_operation_rejects_non_allowlisted_sender_code_before_raw_disabled() {
        let bundler_eoa = "0xbeef000000000000000000000000000000000000";
        let bundler_address: Address = bundler_eoa.parse().unwrap();
        let head = BlockHeader {
            number: 124,
            hash: B256::from([0x57; 32]),
            parent_hash: B256::from([0x56; 32]),
            timestamp: now_unix_seconds_for_tests(),
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        };
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let op = wallet_bundler::UserOperation::parse(deployed_sample_user_op("0xab")).unwrap();
        chain.set_current_head(head.clone());
        chain.set_balance(
            bundler_address,
            BlockTag::Hash(head.hash),
            U256::from(5_000_000_000_000_000_u64),
        );
        chain.set_code(
            op.sender,
            BlockTag::Hash(head.hash),
            ChainBytes::from_static(&[0x60, 0x00]),
        );
        let (handler, auth_header, state) = test_handler(chain.clone());
        state.mark_state_override_smoke_passed();
        state
            .store
            .bundler_account_insert(1, bundler_eoa, "bundler-eoa:1")
            .await
            .unwrap();

        let value = call_rpc(
            &handler,
            &auth_header,
            "eth_sendUserOperation",
            json!([
                deployed_sample_user_op("0xab"),
                "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            ]),
        )
        .await;

        assert_eq!(
            value["error"]["code"],
            wallet_node_api::ACCOUNT_CODE_NOT_ALLOWLISTED
        );
        assert_eq!(chain.code_call_count(), 1);
        assert_eq!(chain.balance_call_count(), 1);
        assert_eq!(chain.call_call_count(), 0);
    }

    #[tokio::test]
    async fn send_user_operation_rejects_gas_underfunding_before_raw_disabled() {
        let entry_point: Address = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            .parse()
            .unwrap();
        let bundler_eoa = "0xbeef000000000000000000000000000000000000";
        let bundler_address: Address = bundler_eoa.parse().unwrap();
        let head = BlockHeader {
            number: 124,
            hash: B256::from([0x57; 32]),
            parent_hash: B256::from([0x56; 32]),
            timestamp: now_unix_seconds_for_tests(),
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        };
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let op = wallet_bundler::UserOperation::parse(sample_user_op("0xab")).unwrap();
        chain.set_current_head(head.clone());
        chain.set_balance(
            bundler_address,
            BlockTag::Hash(head.hash),
            U256::from(5_000_000_000_000_000_u64),
        );
        chain.set_balance(op.sender, BlockTag::Hash(head.hash), U256::from(0x17ff));
        set_entry_point_deposit(
            &chain,
            entry_point,
            op.sender,
            BlockTag::Hash(head.hash),
            U256::ZERO,
        );
        let (handler, auth_header, state) = test_handler(chain.clone());
        state.mark_state_override_smoke_passed();
        state
            .store
            .bundler_account_insert(1, bundler_eoa, "bundler-eoa:1")
            .await
            .unwrap();

        let value = call_rpc(
            &handler,
            &auth_header,
            "eth_sendUserOperation",
            json!([
                sample_user_op("0xab"),
                "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            ]),
        )
        .await;

        assert_eq!(
            value["error"]["code"],
            wallet_node_api::INSUFFICIENT_SMART_ACCOUNT_BALANCE
        );
        assert_eq!(value["error"]["data"]["reason"], "gas_shortfall");
        assert_eq!(chain.code_call_count(), 1);
        assert_eq!(chain.balance_call_count(), 2);
        assert_eq!(chain.call_call_count(), 1);
    }

    #[tokio::test]
    async fn send_user_operation_rejects_paymaster_before_simulation() {
        let (handler, auth_header, _state) = test_handler(Arc::new(MockChainAdapter::new()));
        let mut op = sample_user_op("0xab");
        op["paymaster"] = json!("0x0000000000000000000000000000000000000001");

        let value = call_rpc(
            &handler,
            &auth_header,
            "eth_sendUserOperation",
            json!([op, "0x0000000071727De22E5E9d8BAf0edAc6f37da032"]),
        )
        .await;

        assert_eq!(value["error"]["code"], wallet_node_api::SIMULATION_FAILED);
        assert_eq!(value["error"]["data"]["reason"], "paymaster_not_supported");
    }

    #[tokio::test]
    async fn read_methods_are_rate_limited_as_a_shared_bucket() {
        let address = Address::from([0x22; 20]);
        let (handler, auth_header, _state) = test_handler(Arc::new(MockChainAdapter::new()));

        for _ in 0..20 {
            let value = call_rpc(
                &handler,
                &auth_header,
                "eth_getBalance",
                json!([format!("{address:#x}"), "latest"]),
            )
            .await;
            assert_eq!(value["result"], "0x0");
        }

        let limited = call_rpc(
            &handler,
            &auth_header,
            "eth_getCode",
            json!([format!("{address:#x}"), "latest"]),
        )
        .await;
        assert_eq!(limited["error"]["code"], wallet_node_api::RATE_LIMITED);
        assert!(limited["error"]["data"]["retryAfterMs"].as_u64().unwrap() > 0);
    }

    #[tokio::test]
    async fn get_user_operation_receipt_returns_public_shape_or_null() {
        let (handler, auth_header, state) = test_handler(Arc::new(MockChainAdapter::new()));
        state
            .store
            .receipt_insert(UserOperationReceipt {
                user_op_hash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                    .to_string(),
                tx_hash: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                    .to_string(),
                success: true,
                actual_gas_cost: Some("0x1".to_string()),
                actual_gas_used: Some("0x2".to_string()),
                revert_reason: None,
                receipt_json: r#"{"transactionHash":"0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}"#
                    .to_string(),
                tentative: false,
                created_at: 1,
            })
            .await
            .unwrap();

        let found = call_rpc(
            &handler,
            &auth_header,
            "eth_getUserOperationReceipt",
            json!(["0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]),
        )
        .await;
        assert_eq!(found["result"]["success"], true);
        assert_eq!(
            found["result"]["userOpHash"],
            "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        );
        assert_eq!(
            found["result"]["txHash"],
            "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        );
        assert_eq!(found["result"]["actualGasCost"], "0x1");
        assert_eq!(found["result"]["actualGasUsed"], "0x2");
        assert!(found["result"]["revertReason"].is_null());
        assert_eq!(
            found["result"]["receipt"]["transactionHash"],
            "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        );
        assert!(found["result"].get("actual_gas_cost").is_none());
        assert!(found["result"].get("receipt_json").is_none());

        let missing = call_rpc(
            &handler,
            &auth_header,
            "eth_getUserOperationReceipt",
            json!(["0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"]),
        )
        .await;
        assert!(missing["result"].is_null());
    }

    #[tokio::test]
    async fn wallet_status_reads_balance_and_entrypoint_deposit_at_same_head() {
        let smart_account = Address::from([0x44; 20]);
        let entry_point: Address = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
            .parse()
            .unwrap();
        let head = BlockHeader {
            number: 123,
            hash: B256::from([0x55; 32]),
            parent_hash: B256::from([0x54; 32]),
            timestamp: 1_700_000_000,
            state_root: None,
            transactions_root: None,
            receipts_root: None,
            gas_used: None,
            gas_limit: None,
            base_fee_per_gas: None,
        };
        let chain = Arc::new(MockChainAdapter::new());
        chain.set_current_head(head.clone());
        chain.set_balance(smart_account, BlockTag::Hash(head.hash), U256::from(0x2a));
        chain.set_call_response(
            CallRequest {
                to: Some(entry_point),
                data: Some(ChainBytes::from(balance_of_calldata(smart_account))),
                ..Default::default()
            },
            BlockTag::Hash(head.hash),
            None,
            ChainBytes::from(U256::from(0x09).to_be_bytes::<32>().to_vec()),
        );
        let (handler, auth_header, _state) = test_handler(chain);

        let value = call_rpc(
            &handler,
            &auth_header,
            "wallet_walletStatus",
            json!([format!("{smart_account:#x}")]),
        )
        .await;

        assert_eq!(value["result"]["accountBalance"], "0x2a");
        assert_eq!(value["result"]["entryPointDeposit"], "0x9");
        assert_eq!(value["result"]["transferableEth"], "0x2a");
        assert_eq!(value["result"]["gasReserve"], "0x9");
        assert_eq!(value["result"]["blockNumber"], 123);
        assert_eq!(value["result"]["blockHash"], format!("{:#x}", head.hash));
    }

    fn test_handler(chain: Arc<MockChainAdapter>) -> (Handler, String, Arc<DaemonState>) {
        test_handler_with_config(chain, Config::default())
    }

    fn test_handler_with_config(
        chain: Arc<MockChainAdapter>,
        config: Config,
    ) -> (Handler, String, Arc<DaemonState>) {
        let token = Arc::new(Token::generate());
        let auth_header = format!("Bearer {}", token.encoded());
        let chain_adapter: Arc<dyn wallet_chain::ChainAdapter> = chain;
        let (shutdown_tx, _shutdown_rx) = tokio::sync::watch::channel(false);
        let mut conn =
            wallet_node_store::db::open_in_memory().expect("test store should open in memory");
        wallet_node_store::migrations::apply(&mut conn)
            .expect("test store migrations should apply");
        let store = wallet_node_store::StoreActor::start(conn);
        let bundler_keys: Arc<dyn crate::bundler_keys::BundlerKeyStore> =
            Arc::new(MemoryBundlerKeyStore::new());
        let raw_submitter: Arc<dyn wallet_bundler::RawTransactionSubmitter> =
            Arc::new(MockRawTransactionSubmitter);
        let state = Arc::new(DaemonState::new(
            token,
            Arc::new(config),
            Arc::new(Paths {
                app_support_dir: PathBuf::from("/tmp/wallet-node-test"),
                socket_path: PathBuf::from("/tmp/wallet-node-test/wallet-node.sock"),
                db_path: PathBuf::from("/tmp/wallet-node-test/node.sqlite"),
                helios_dir: PathBuf::from("/tmp/wallet-node-test/helios"),
                logs_dir: PathBuf::from("/tmp/wallet-node-test/logs"),
                config_path: PathBuf::from("/tmp/wallet-node-test/config.toml"),
            }),
            shutdown_tx,
            (
                TransportInfo::http(),
                store,
                chain_adapter,
                bundler_keys,
                raw_submitter,
            ),
        ));
        (
            Handler {
                state: state.clone(),
            },
            auth_header,
            state,
        )
    }

    struct MockRawTransactionSubmitter;

    #[async_trait::async_trait]
    impl wallet_bundler::RawTransactionSubmitter for MockRawTransactionSubmitter {
        async fn submit_raw_transaction(
            &self,
            _raw_tx: &ChainBytes,
            expected_tx_hash: B256,
        ) -> wallet_bundler::Result<wallet_bundler::RawTransactionSubmitOutcome> {
            Ok(wallet_bundler::RawTransactionSubmitOutcome::Accepted(
                expected_tx_hash,
            ))
        }
    }

    async fn call_rpc(
        handler: &Handler,
        auth_header: &str,
        method: &str,
        params: serde_json::Value,
    ) -> serde_json::Value {
        let body = Bytes::from(
            serde_json::to_vec(&json!({
                "jsonrpc": "2.0",
                "method": method,
                "params": params,
                "id": 1,
            }))
            .expect("serialize request"),
        );
        let response = handler.handle(body, Some(auth_header.to_string())).await;
        assert_eq!(response.status(), StatusCode::OK);
        let bytes = response
            .into_body()
            .collect()
            .await
            .expect("collect response")
            .to_bytes();
        serde_json::from_slice(&bytes).expect("response JSON")
    }

    fn sample_user_op(signature: &str) -> serde_json::Value {
        let salt = B256::ZERO;
        let init_data = wallet_kernel::encode_initialize_call(
            wallet_bundler::PINNED_WEBAUTHN_VALIDATOR_ADDRESS,
            U256::from(1u64),
            U256::from(2u64),
            B256::ZERO,
        );
        let factory_data = createAccountCall {
            initData: ChainBytes::from(init_data),
            salt,
        }
        .abi_encode();

        json!({
            "sender": format!("{:#x}", sample_sender()),
            "nonce": "0x01",
            "factory": format!("{:#x}", wallet_bundler::PINNED_KERNEL_FACTORY_ADDRESS),
            "factoryData": hex_data(&factory_data),
            "callData": "0x1234",
            "callGasLimit": "0x10",
            "verificationGasLimit": "0x20",
            "preVerificationGas": "0x30",
            "maxFeePerGas": "0x40",
            "maxPriorityFeePerGas": "0x05",
            "signature": signature
        })
    }

    fn deployed_sample_user_op(signature: &str) -> serde_json::Value {
        let mut op = sample_user_op(signature);
        let object = op.as_object_mut().expect("sample user op is an object");
        object.remove("factory");
        object.remove("factoryData");
        op
    }

    fn sample_sender() -> Address {
        wallet_kernel::predict_kernel_account_address(
            wallet_bundler::PINNED_KERNEL_FACTORY_ADDRESS,
            wallet_bundler::PINNED_KERNEL_IMPLEMENTATION_ADDRESS,
            wallet_bundler::PINNED_WEBAUTHN_VALIDATOR_ADDRESS,
            U256::from(1u64),
            U256::from(2u64),
            B256::ZERO,
            B256::ZERO,
        )
    }

    fn hex_data(bytes: &[u8]) -> String {
        format!("0x{}", hex::encode(bytes))
    }

    fn balance_of_calldata(account: Address) -> Vec<u8> {
        let mut data = Vec::with_capacity(36);
        data.extend_from_slice(&[0x70, 0xa0, 0x82, 0x31]);
        data.extend_from_slice(&[0u8; 12]);
        data.extend_from_slice(account.as_slice());
        data
    }

    fn set_entry_point_deposit(
        chain: &MockChainAdapter,
        entry_point: Address,
        account: Address,
        block: BlockTag,
        deposit: U256,
    ) {
        chain.set_call_response(
            CallRequest {
                to: Some(entry_point),
                data: Some(ChainBytes::from(balance_of_calldata(account))),
                ..Default::default()
            },
            block,
            None,
            ChainBytes::from(deposit.to_be_bytes::<32>().to_vec()),
        );
    }

    fn now_unix_seconds_for_tests() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs()
    }

    fn validation_response(prefund: U256, account_validation_data: U256) -> ChainBytes {
        let empty_stake = StakeInfo {
            stake: U256::ZERO,
            unstakeDelaySec: U256::ZERO,
        };
        ChainBytes::from(simulateValidationCall::abi_encode_returns(
            &ValidationResult {
                returnInfo: ReturnInfo {
                    preOpGas: U256::from(0x777),
                    prefund,
                    accountValidationData: account_validation_data,
                    paymasterValidationData: U256::ZERO,
                    paymasterContext: ChainBytes::new(),
                },
                senderInfo: empty_stake.clone(),
                factoryInfo: empty_stake.clone(),
                paymasterInfo: empty_stake.clone(),
                aggregatorInfo: AggregatorStakeInfo {
                    aggregator: Address::ZERO,
                    stakeInfo: empty_stake,
                },
            },
        ))
    }
}
