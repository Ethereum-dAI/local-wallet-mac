use serde::Deserialize;
use serde_json::Value;

use crate::admin_challenge::{challenge_json, AdminChallengeRequest};
use crate::state::DaemonState;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BeginAdminActionParams {
    action: String,
    #[serde(default = "default_owner_scope")]
    owner_scope: String,
    #[serde(default)]
    chain_id: Option<u64>,
    #[serde(default)]
    key_ref: Option<String>,
}

pub async fn begin(
    state: &DaemonState,
    params: Value,
) -> Result<Value, wallet_node_api::JsonRpcError> {
    let params = parse_first::<BeginAdminActionParams>(params)?;
    validate_admin_action(&params.action)?;
    let chain_id = params.chain_id.unwrap_or(state.config.network.chain_id);
    if chain_id != state.config.network.chain_id {
        return Err(invalid("admin_challenge_chain_mismatch"));
    }
    let key_ref = challenge_key_ref(
        state,
        &params.action,
        &params.owner_scope,
        chain_id,
        params.key_ref,
    )
    .await?;
    let summary = admin_summary(&params.action, &params.owner_scope, chain_id);
    let challenge = state.admin_challenges.begin(AdminChallengeRequest {
        action: params.action,
        owner_scope: params.owner_scope,
        chain_id,
        key_ref,
        summary,
    });
    Ok(challenge_json(&challenge))
}

async fn challenge_key_ref(
    state: &DaemonState,
    action: &str,
    owner_scope: &str,
    chain_id: u64,
    requested_key_ref: Option<String>,
) -> Result<Option<String>, wallet_node_api::JsonRpcError> {
    if action != "rotate_bundler_eoa" {
        return Ok(requested_key_ref);
    }

    let active = state
        .store
        .bundler_account_active_for_owner(owner_scope, chain_id)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;

    match (active, requested_key_ref) {
        (Some(active), Some(requested)) if requested != active.key_ref => {
            Err(invalid("admin_challenge_key_mismatch"))
        }
        (Some(active), _) => Ok(Some(active.key_ref)),
        (None, Some(_)) => Err(invalid("admin_challenge_key_mismatch")),
        (None, None) => Ok(None),
    }
}

pub(crate) fn parse_first<T>(params: Value) -> Result<T, wallet_node_api::JsonRpcError>
where
    T: for<'de> Deserialize<'de>,
{
    let array = params
        .as_array()
        .ok_or_else(|| invalid("params_must_be_array"))?;
    let value = array
        .first()
        .cloned()
        .ok_or_else(|| invalid("params_object_required"))?;
    serde_json::from_value(value).map_err(|_| invalid("invalid_params"))
}

pub(crate) fn invalid(reason: &'static str) -> wallet_node_api::JsonRpcError {
    wallet_node_api::JsonRpcError {
        code: wallet_node_api::INVALID_REQUEST,
        message: format!("Invalid params: {reason}"),
        data: Some(serde_json::json!({ "reason": reason })),
    }
}

pub(crate) fn default_owner_scope() -> String {
    wallet_node_store::DEFAULT_OWNER_SCOPE.to_string()
}

fn validate_admin_action(action: &str) -> Result<(), wallet_node_api::JsonRpcError> {
    match action {
        "rotate_bundler_eoa" | "install_bundler_eoa" | "delete_bundler_eoa" => Ok(()),
        _ => Err(invalid("admin_challenge_unknown_action")),
    }
}

fn admin_summary(action: &str, owner_scope: &str, chain_id: u64) -> String {
    let action_label = match action {
        "rotate_bundler_eoa" => "Rotate local relayer key",
        "install_bundler_eoa" => "Install local relayer key",
        "delete_bundler_eoa" => "Delete local relayer key",
        _ => "Admin action",
    };
    format!("{action_label} for owner {owner_scope} on chain {chain_id}")
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AdminAuthorizationParams {
    pub admin_action_id: String,
    pub nonce: String,
}

pub(crate) fn parse_authorization(
    value: &Value,
) -> Result<AdminAuthorizationParams, wallet_node_api::JsonRpcError> {
    serde_json::from_value(value.clone()).map_err(|_| invalid("admin_authorization_required"))
}
