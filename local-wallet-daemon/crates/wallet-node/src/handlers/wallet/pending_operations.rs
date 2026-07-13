use crate::state::DaemonState;

pub async fn handle(
    state: &DaemonState,
) -> Result<serde_json::Value, wallet_node_api::JsonRpcError> {
    let pending = state
        .store
        .user_ops_list_pending()
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    serde_json::to_value(pending).map_err(|_| wallet_node_api::JsonRpcError::internal())
}
