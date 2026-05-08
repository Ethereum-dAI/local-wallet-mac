use serde_json::Value;
use wallet_node_store::UserOperationReceipt;

use crate::state::DaemonState;

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct UserOperationReceiptResponse {
    user_op_hash: String,
    tx_hash: String,
    success: bool,
    actual_gas_cost: Option<String>,
    actual_gas_used: Option<String>,
    revert_reason: Option<String>,
    receipt: Value,
    tentative: bool,
    invalidated: bool,
    created_at: i64,
}

impl UserOperationReceiptResponse {
    fn from_store(receipt: UserOperationReceipt) -> Result<Self, wallet_node_api::JsonRpcError> {
        let receipt_json = serde_json::from_str(&receipt.receipt_json)
            .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
        Ok(Self {
            user_op_hash: receipt.user_op_hash,
            tx_hash: receipt.tx_hash,
            success: receipt.success,
            actual_gas_cost: receipt.actual_gas_cost,
            actual_gas_used: receipt.actual_gas_used,
            revert_reason: receipt.revert_reason,
            receipt: receipt_json,
            tentative: receipt.tentative,
            invalidated: receipt.invalidated,
            created_at: receipt.created_at,
        })
    }
}

pub async fn handle(
    state: &DaemonState,
    params: Value,
) -> Result<Value, wallet_node_api::JsonRpcError> {
    let params = super::parse_params_array(params)?;
    let hash = params
        .first()
        .and_then(Value::as_str)
        .ok_or_else(|| super::invalid_params("userOpHash parameter is required"))?;
    let receipt = state
        .store
        .receipt_get(hash)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    match receipt {
        Some(receipt) if receipt.invalidated => Ok(Value::Null),
        Some(receipt) => serde_json::to_value(UserOperationReceiptResponse::from_store(receipt)?)
            .map_err(|_| wallet_node_api::JsonRpcError::internal()),
        None => Ok(Value::Null),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::sync::Arc;

    use serde_json::json;
    use wallet_chain::MockChainAdapter;

    const USER_OP_HASH: &str = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const TX_HASH: &str = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    fn test_state() -> DaemonState {
        DaemonState::for_tests(Arc::new(MockChainAdapter::new()))
    }

    fn receipt(invalidated: bool) -> UserOperationReceipt {
        UserOperationReceipt {
            user_op_hash: USER_OP_HASH.to_owned(),
            tx_hash: TX_HASH.to_owned(),
            success: true,
            actual_gas_cost: Some("0x1".to_owned()),
            actual_gas_used: Some("0x2".to_owned()),
            revert_reason: None,
            receipt_json: json!({ "transactionHash": TX_HASH }).to_string(),
            tentative: false,
            invalidated,
            created_at: 1,
        }
    }

    #[tokio::test]
    async fn invalidated_receipt_returns_null() {
        let state = test_state();
        state.store.receipt_insert(receipt(true)).await.unwrap();

        let value = handle(&state, json!([USER_OP_HASH])).await.unwrap();

        assert_eq!(value, Value::Null);
    }

    #[tokio::test]
    async fn canonical_receipt_returns_populated_object() {
        let state = test_state();
        state.store.receipt_insert(receipt(false)).await.unwrap();

        let value = handle(&state, json!([USER_OP_HASH])).await.unwrap();

        assert!(value.is_object());
        assert_eq!(value["userOpHash"], USER_OP_HASH);
        assert_eq!(value["txHash"], TX_HASH);
        assert_eq!(value["success"], true);
        assert_eq!(value["receipt"]["transactionHash"], TX_HASH);
    }
}
