use serde_json::Value;

use crate::state::DaemonState;

pub async fn handle(state: &DaemonState) -> Result<Value, wallet_node_api::JsonRpcError> {
    Ok(serde_json::json!(state.config.bundler.entry_points))
}
