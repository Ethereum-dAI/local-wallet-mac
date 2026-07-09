use serde_json::Value;

use crate::state::DaemonState;

pub async fn handle(
    state: &DaemonState,
    params: Value,
) -> Result<Value, wallet_node_api::JsonRpcError> {
    let params: Value = params
        .as_array()
        .and_then(|array| array.first())
        .cloned()
        .ok_or_else(|| {
            crate::handlers::wallet::admin_action::invalid("admin_authorization_required")
        })?;
    let authorization =
        crate::handlers::wallet::admin_action::parse_authorization(&params["authorization"])?;
    let active = state
        .store
        .bundler_account_active_for_owner(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    state.admin_challenges.consume(
        &crate::admin_challenge::AdminAuthorization {
            admin_action_id: authorization.admin_action_id,
            nonce: authorization.nonce,
        },
        "rotate_bundler_eoa",
        wallet_node_store::DEFAULT_OWNER_SCOPE,
        state.config.network.chain_id,
        active.as_ref().map(|account| account.key_ref.as_str()),
    )?;
    let _relayer_lifecycle_guard = state
        .relayer_lifecycle_locks
        .acquire(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await;
    let had_pending = state
        .store
        .bundler_account_pending_funding_for_owner(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?
        .is_some();
    let account = super::bundler_account::rotate_bundler_account(state).await?;
    super::relayer_audit::record(
        state,
        if had_pending {
            "relayer_key_rotation_requested"
        } else {
            "relayer_key_created_pending_funding"
        },
        &account,
        Some("rotate_bundler_eoa"),
        "success",
        None,
    )
    .await?;
    Ok(serde_json::json!({
        "eoa": account.address,
        "keyRef": account.key_ref,
        "lifecycle": account.lifecycle.as_str(),
        "ownerScope": account.owner_scope,
        "chainId": account.chain_id,
        "needsTopup": true,
        "thresholdLow": super::bundler_status::THRESHOLD_LOW
    }))
}
