use serde_json::Value;

use crate::state::DaemonState;

pub async fn handle(
    state: &DaemonState,
    _params: Value,
) -> Result<Value, wallet_node_api::JsonRpcError> {
    let account = super::bundler_account::rotate_bundler_account(state).await?;
    Ok(serde_json::json!({
        "eoa": account.address,
        "keyRef": account.key_ref,
        "lifecycle": account.lifecycle.as_str(),
        "needsTopup": true,
        "thresholdLow": super::bundler_status::THRESHOLD_LOW
    }))
}
