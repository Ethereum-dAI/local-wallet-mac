use serde_json::Value;
use wallet_node_store::UserOperation;

use crate::state::DaemonState;

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct UserOperationStatusResponse {
    user_op_hash: String,
    status: String,
    last_error: Option<String>,
    created_at: i64,
    updated_at: i64,
}

impl UserOperationStatusResponse {
    async fn from_store(
        state: &DaemonState,
        op: UserOperation,
    ) -> Result<Self, wallet_node_api::JsonRpcError> {
        let last_error = state
            .store
            .diagnostic_get("user_operation", &op.user_op_hash)
            .await
            .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
        Ok(Self {
            user_op_hash: op.user_op_hash,
            status: op.status.as_str().to_owned(),
            last_error,
            created_at: op.created_at,
            updated_at: op.updated_at,
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
    let op = state
        .store
        .user_op_get(hash)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    match op {
        Some(op) => serde_json::to_value(UserOperationStatusResponse::from_store(state, op).await?)
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
    use wallet_node_store::{UserOpStatus, UserOperation};

    const USER_OP_HASH: &str = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    fn test_state() -> DaemonState {
        DaemonState::for_tests(Arc::new(MockChainAdapter::new()))
    }

    fn stored_op(status: UserOpStatus) -> UserOperation {
        UserOperation {
            user_op_hash: USER_OP_HASH.to_owned(),
            chain_id: 1,
            entry_point: "0x0000000071727de22e5e9d8baf0edac6f37da032".to_owned(),
            sender: "0x1111111111111111111111111111111111111111".to_owned(),
            nonce: "0x1".to_owned(),
            user_op_json: "{}".to_owned(),
            status,
            created_at: 10,
            updated_at: 20,
        }
    }

    #[tokio::test]
    async fn missing_status_returns_null() {
        let state = test_state();

        let value = handle(&state, json!([USER_OP_HASH])).await.unwrap();

        assert!(value.is_null());
    }

    #[tokio::test]
    async fn status_returns_terminal_failure_and_last_error() {
        let state = test_state();
        state
            .store
            .user_op_insert(stored_op(UserOpStatus::Failed))
            .await
            .unwrap();
        state
            .store
            .diagnostic_set(
                "user_operation",
                USER_OP_HASH,
                "auto_dropped_aged_no_receipt",
            )
            .await
            .unwrap();

        let value = handle(&state, json!([USER_OP_HASH])).await.unwrap();

        assert_eq!(value["userOpHash"], USER_OP_HASH);
        assert_eq!(value["status"], "failed");
        assert_eq!(value["lastError"], "auto_dropped_aged_no_receipt");
        assert_eq!(value["createdAt"], 10);
        assert_eq!(value["updatedAt"], 20);
    }
}
