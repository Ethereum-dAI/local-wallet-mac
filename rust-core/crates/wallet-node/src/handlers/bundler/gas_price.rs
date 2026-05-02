use crate::state::DaemonState;

pub async fn handle(
    state: &DaemonState,
) -> Result<serde_json::Value, wallet_node_api::JsonRpcError> {
    let policy = super::policy_from_state(state)?;
    Ok(wallet_bundler::pimlico_gas_price(
        policy.max_fee_per_gas,
        policy.max_priority_fee_per_gas,
    ))
}
