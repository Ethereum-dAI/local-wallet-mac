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
        Some(receipt) => serde_json::to_value(UserOperationReceiptResponse::from_store(receipt)?)
            .map_err(|_| wallet_node_api::JsonRpcError::internal()),
        None => Ok(Value::Null),
    }
}
