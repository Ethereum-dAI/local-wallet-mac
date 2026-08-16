use serde::Deserialize;
use serde_json::Value;
use wallet_node_store::{BundlerAccount, BundlerLifecycle};

use crate::admin_challenge::AdminAuthorization;
use crate::bundler_account_reconciliation::{
    self, ReconciliationError, ReconciliationMutation, SuppliedBundlerKey,
};
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
    super::bundler_account::validate_managed_key_ref(
        &params.key_ref,
        state.config.network.chain_id,
    )?;
    let _guard = state
        .relayer_lifecycle_locks
        .acquire(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await;
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
    let outcome = bundler_account_reconciliation::reconcile(
        &state.store,
        SuppliedBundlerKey {
            owner_scope: wallet_node_store::DEFAULT_OWNER_SCOPE,
            chain_id: state.config.network.chain_id,
            key_ref: &params.key_ref,
            address: &address_hex,
        },
        lifecycle,
    )
    .await
    .map_err(map_reconciliation_error)?;
    if let Err(err) = install_key(state, &params.key_ref, secret, address).await {
        match &outcome.mutation {
            ReconciliationMutation::Rebound { .. } => {
                if let Err(rollback_error) =
                    bundler_account_reconciliation::rollback_rebound(&state.store, &outcome).await
                {
                    tracing::error!(
                        error = ?rollback_error,
                        key_ref = %params.key_ref,
                        "failed to restore previous relayer metadata after RAM key install failure"
                    );
                    record_install_audit_failure(
                        state,
                        "relayer_key_repair_needed",
                        &outcome.current,
                        "metadata_rollback_failed_after_keychain_install_failure",
                        "failed to record relayer metadata rollback failure",
                    )
                    .await;
                }
            }
            ReconciliationMutation::None => {
                record_install_audit_failure(
                    state,
                    "relayer_key_installed",
                    &outcome.current,
                    "keychain_install_failed_existing_metadata_preserved",
                    "failed to record existing relayer key install failure",
                )
                .await;
            }
            ReconciliationMutation::Inserted | ReconciliationMutation::ActivatedExisting => {
                record_install_failure(
                    state,
                    &outcome.current.address,
                    &params.key_ref,
                    outcome.current.lifecycle,
                )
                .await;
            }
        }
        return Err(err);
    }
    let response_lifecycle = outcome.current.lifecycle;
    if matches!(outcome.mutation, ReconciliationMutation::Rebound { .. }) {
        if let Err(error) = super::relayer_audit::record(
            state,
            "relayer_key_rebound",
            &outcome.current,
            Some("install_bundler_eoa"),
            "success",
            None,
        )
        .await
        {
            tracing::warn!(
                error = ?error,
                key_ref = %params.key_ref,
                "failed to record successful relayer metadata rebind"
            );
        }
    }

    Ok(serde_json::json!({
        "ownerScope": wallet_node_store::DEFAULT_OWNER_SCOPE,
        "chainId": state.config.network.chain_id,
        "eoa": address_hex,
        "keyRef": params.key_ref,
        "lifecycle": response_lifecycle.as_str()
    }))
}

fn map_reconciliation_error(error: ReconciliationError) -> wallet_node_api::JsonRpcError {
    match error {
        ReconciliationError::LiveLocalWork => {
            super::admin_action::invalid("relayer_key_ref_address_mismatch_live_work")
        }
        ReconciliationError::AddressRegisteredUnderDifferentKeyRef
        | ReconciliationError::SuppliedAccountNotActive
        | ReconciliationError::ActiveAccountDiffers => {
            super::admin_action::invalid("relayer_key_ref_address_mismatch")
        }
        ReconciliationError::Store(error) => {
            tracing::error!(error = ?error, "failed to reconcile supplied relayer metadata");
            wallet_node_api::JsonRpcError::internal()
        }
    }
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
