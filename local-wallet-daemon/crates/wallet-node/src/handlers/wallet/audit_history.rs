use serde::Deserialize;
use serde_json::Value;

use crate::state::DaemonState;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AuditHistoryRequest {
    #[serde(default = "default_limit")]
    limit: u64,
}

pub async fn handle(
    state: &DaemonState,
    params: Value,
) -> Result<Value, wallet_node_api::JsonRpcError> {
    let request = parse_request(params)?;
    let history = state
        .store
        .audit_history_list(request.limit)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;

    serde_json::to_value(history).map_err(|_| wallet_node_api::JsonRpcError::internal())
}

fn parse_request(params: Value) -> Result<AuditHistoryRequest, wallet_node_api::JsonRpcError> {
    let value = params
        .as_array()
        .and_then(|values| values.first())
        .cloned()
        .unwrap_or(params);
    if value.is_null() {
        return Ok(AuditHistoryRequest {
            limit: default_limit(),
        });
    }
    serde_json::from_value(value).map_err(|err| wallet_node_api::JsonRpcError {
        code: wallet_node_api::INVALID_REQUEST,
        message: "Invalid request".to_string(),
        data: Some(serde_json::json!({ "reason": err.to_string() })),
    })
}

fn default_limit() -> u64 {
    20
}
