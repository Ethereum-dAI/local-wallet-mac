use serde::Deserialize;
use serde_json::Value;
use wallet_node_store::{BundlerAccount, BundlerLifecycle};

use crate::admin_challenge::AdminAuthorization;
use crate::state::DaemonState;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InstallParams {
    key_ref: String,
    secret: String,
    authorization: Option<super::admin_action::AdminAuthorizationParams>,
}

pub async fn handle(
    state: &DaemonState,
    params: Value,
) -> Result<Value, wallet_node_api::JsonRpcError> {
    let params = super::admin_action::parse_first::<InstallParams>(params)?;
    let authorization = params
        .authorization
        .ok_or_else(|| super::admin_action::invalid("admin_authorization_required"))?;
    state.admin_challenges.consume(
        &AdminAuthorization {
            admin_action_id: authorization.admin_action_id,
            nonce: authorization.nonce,
        },
        "install_bundler_eoa",
        wallet_node_store::DEFAULT_OWNER_SCOPE,
        state.config.network.chain_id,
        Some(&params.key_ref),
    )?;
    validate_key_ref(&params.key_ref, state.config.network.chain_id)?;
    let _guard = state
        .relayer_lifecycle_locks
        .acquire(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await;

    let secret = decode_secret(&params.key_ref, &params.secret)?;
    let address = crate::bundler_keys::address_for_secret(&params.key_ref, &secret)
        .map_err(super::bundler_account::map_key_error)?;
    let address_hex = format!("{address:#x}");
    let accounts = state
        .store
        .bundler_account_list_for_owner(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let lifecycle = if accounts
        .iter()
        .any(|account| account.lifecycle == BundlerLifecycle::Active)
    {
        BundlerLifecycle::PendingFunding
    } else {
        BundlerLifecycle::Active
    };
    let response_lifecycle = if let Some(existing) = accounts
        .iter()
        .find(|account| account.key_ref == params.key_ref)
    {
        if !existing.address.eq_ignore_ascii_case(&address_hex) {
            return Err(super::admin_action::invalid(
                "relayer_key_ref_address_mismatch",
            ));
        }
        if let Err(err) = install_key(state, &params.key_ref, secret, address).await {
            record_install_failure(
                state,
                &existing.address,
                &params.key_ref,
                existing.lifecycle,
            )
            .await;
            return Err(err);
        }
        existing.lifecycle
    } else {
        state
            .store
            .bundler_account_insert_for_owner(
                wallet_node_store::DEFAULT_OWNER_SCOPE,
                state.config.network.chain_id,
                &address_hex,
                &params.key_ref,
                lifecycle,
            )
            .await
            .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
        if let Err(err) = install_key(state, &params.key_ref, secret, address).await {
            record_install_failure(state, &address_hex, &params.key_ref, lifecycle).await;
            return Err(err);
        }
        lifecycle
    };

    Ok(serde_json::json!({
        "ownerScope": wallet_node_store::DEFAULT_OWNER_SCOPE,
        "chainId": state.config.network.chain_id,
        "eoa": address_hex,
        "keyRef": params.key_ref,
        "lifecycle": response_lifecycle.as_str()
    }))
}

async fn install_key(
    state: &DaemonState,
    key_ref: &str,
    secret: [u8; 32],
    expected_address: alloy_primitives::Address,
) -> Result<(), wallet_node_api::JsonRpcError> {
    let installed_address = state
        .bundler_keys
        .install_key(key_ref, secret)
        .map_err(super::bundler_account::map_key_error)?;
    if installed_address != expected_address {
        if let Err(err) = state.bundler_keys.delete_key(key_ref) {
            tracing::warn!(
                error = ?err,
                key_ref,
                "failed to clean up RAM relayer key after address mismatch"
            );
            record_cleanup_failure(state, &format!("{expected_address:#x}"), key_ref).await;
        }
        return Err(wallet_node_api::JsonRpcError::internal());
    }
    Ok(())
}

async fn record_cleanup_failure(state: &DaemonState, address: &str, key_ref: &str) {
    let owner_scope = wallet_node_store::DEFAULT_OWNER_SCOPE;
    let chain_id = state.config.network.chain_id;
    let account = BundlerAccount {
        owner_scope: owner_scope.to_string(),
        chain_id,
        address: address.to_string(),
        key_ref: key_ref.to_string(),
        lifecycle: BundlerLifecycle::Deleted,
        created_at: 0,
        activated_at: None,
        retired_at: None,
        deleted_at: Some(0),
        last_used_at: None,
        last_exported_at: None,
        compromise_status: None,
    };
    record_install_audit_failure(
        state,
        "relayer_key_repair_needed",
        &account,
        "ram_key_cleanup_failed_after_address_mismatch",
        "failed to record relayer install cleanup failure audit event",
    )
    .await;
}

async fn record_install_failure(
    state: &DaemonState,
    address: &str,
    key_ref: &str,
    lifecycle: BundlerLifecycle,
) {
    let owner_scope = wallet_node_store::DEFAULT_OWNER_SCOPE;
    let chain_id = state.config.network.chain_id;
    let mut account = BundlerAccount {
        owner_scope: owner_scope.to_string(),
        chain_id,
        address: address.to_string(),
        key_ref: key_ref.to_string(),
        lifecycle,
        created_at: 0,
        activated_at: if lifecycle == BundlerLifecycle::Active {
            Some(0)
        } else {
            None
        },
        retired_at: None,
        deleted_at: None,
        last_used_at: None,
        last_exported_at: None,
        compromise_status: None,
    };
    let (event_type, failure_reason) = match state
        .store
        .bundler_account_set_lifecycle_for_owner(
            owner_scope,
            chain_id,
            address,
            BundlerLifecycle::Deleted,
        )
        .await
    {
        Ok(()) => {
            account.lifecycle = BundlerLifecycle::Deleted;
            (
                "relayer_key_installed",
                "keychain_install_failed_metadata_deleted",
            )
        }
        Err(_) => (
            "relayer_key_repair_needed",
            "keychain_install_failed_metadata_delete_failed",
        ),
    };
    record_install_audit_failure(
        state,
        event_type,
        &account,
        failure_reason,
        "failed to record relayer install failure audit event",
    )
    .await;
}

async fn record_install_audit_failure(
    state: &DaemonState,
    event_type: &str,
    account: &BundlerAccount,
    failure_reason: &str,
    log_message: &'static str,
) {
    if let Err(err) = super::relayer_audit::record(
        state,
        event_type,
        account,
        Some("install_bundler_eoa"),
        "failure",
        Some(failure_reason),
    )
    .await
    {
        tracing::warn!(
            error = ?err,
            relayer = %account.address,
            "{log_message}"
        );
    }
}

fn validate_key_ref(key_ref: &str, chain_id: u64) -> Result<(), wallet_node_api::JsonRpcError> {
    let parts = key_ref.split(':').collect::<Vec<_>>();
    if parts.len() != 4
        || parts[0] != "bundler-eoa"
        || parts[1] != wallet_node_store::DEFAULT_OWNER_SCOPE
        || parts[2].parse::<u64>().ok() != Some(chain_id)
        || parts[3].parse::<u64>().is_err()
    {
        return Err(wallet_node_api::JsonRpcError {
            code: wallet_node_api::INVALID_REQUEST,
            message: "Invalid bundler keyRef".to_string(),
            data: Some(serde_json::json!({
                "reason": "invalid_bundler_key_ref",
                "keyRef": key_ref,
            })),
        });
    }
    Ok(())
}

fn decode_secret(key_ref: &str, value: &str) -> Result<[u8; 32], wallet_node_api::JsonRpcError> {
    let bytes =
        hex::decode(value.trim_start_matches("0x")).map_err(|_| wallet_node_api::JsonRpcError {
            code: wallet_node_api::INVALID_REQUEST,
            message: "Invalid bundler secret".to_string(),
            data: Some(serde_json::json!({
                "reason": "invalid_bundler_secret_hex",
                "keyRef": key_ref,
            })),
        })?;
    if bytes.len() != 32 {
        return Err(wallet_node_api::JsonRpcError {
            code: wallet_node_api::INVALID_REQUEST,
            message: "Invalid bundler secret".to_string(),
            data: Some(serde_json::json!({
                "reason": "invalid_bundler_secret_length",
                "keyRef": key_ref,
                "actualLength": bytes.len(),
            })),
        });
    }
    let mut secret = [0u8; 32];
    secret.copy_from_slice(&bytes);
    Ok(secret)
}
