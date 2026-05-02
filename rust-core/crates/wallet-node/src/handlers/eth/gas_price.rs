use crate::state::DaemonState;

pub async fn handle(
    state: &DaemonState,
) -> Result<serde_json::Value, wallet_node_api::JsonRpcError> {
    let policy = crate::handlers::bundler::policy_from_state(state)?;
    Ok(serde_json::Value::String(wallet_bundler::gas::u256_hex(
        policy.max_fee_per_gas,
    )))
}
