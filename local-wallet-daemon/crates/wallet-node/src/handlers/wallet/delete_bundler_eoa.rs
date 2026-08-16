use std::collections::BTreeSet;

use serde::Deserialize;
use serde_json::Value;
use wallet_node_store::{AbandonedSubmission, BundlerLifecycle, SubmittedTxStatus};

use crate::admin_challenge::AdminAuthorization;
use crate::state::DaemonState;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeleteParams {
    key_ref: String,
    #[serde(default)]
    unsafe_reset: bool,
    #[serde(default)]
    acknowledged_pending: Vec<String>,
    authorization: Option<super::admin_action::AdminAuthorizationParams>,
}

pub async fn handle(
    state: &DaemonState,
    params: Value,
) -> Result<Value, wallet_node_api::JsonRpcError> {
    let params = super::admin_action::parse_first::<DeleteParams>(params)?;
    let authorization = params
        .authorization
        .ok_or_else(|| super::admin_action::invalid("admin_authorization_required"))?;
    super::bundler_account::validate_managed_key_ref(
        &params.key_ref,
        state.config.network.chain_id,
    )?;
    let _relayer_lifecycle_guard = state
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
        "delete_bundler_eoa",
        wallet_node_store::DEFAULT_OWNER_SCOPE,
        state.config.network.chain_id,
        Some(&params.key_ref),
    )?;
    let account = state
        .store
        .bundler_account_list_for_owner(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?
        .into_iter()
        .find(|account| account.key_ref == params.key_ref)
        .ok_or_else(|| super::admin_action::invalid("relayer_key_not_found"))?;
    if account.lifecycle == BundlerLifecycle::Deleted {
        return Ok(deleted_response(&account, false, false, &[]));
    }
    if !params.unsafe_reset && account.lifecycle != BundlerLifecycle::Retired {
        return Err(super::admin_action::invalid(
            "relayer_lifecycle_not_retired",
        ));
    }
    let live: Vec<_> = state
        .store
        .submitted_txs_list_for_watcher()
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?
        .into_iter()
        .filter(|tx| {
            tx.chain_id == account.chain_id
                && tx.bundler_address.eq_ignore_ascii_case(&account.address)
                && matches!(
                    tx.status,
                    SubmittedTxStatus::Submitting | SubmittedTxStatus::Submitted
                )
        })
        .collect();
    let abandoned = if live.is_empty() {
        Vec::new()
    } else {
        if !params.unsafe_reset {
            return Err(super::admin_action::invalid(
                "pending_submissions_block_delete",
            ));
        }

        let live_set: BTreeSet<String> = live
            .iter()
            .map(|tx| tx.tx_hash.to_ascii_lowercase())
            .collect();
        let acknowledged: BTreeSet<String> = params
            .acknowledged_pending
            .iter()
            .map(|hash| hash.to_ascii_lowercase())
            .collect();

        if live_set != acknowledged {
            let missing: Vec<_> = live_set.difference(&acknowledged).cloned().collect();
            let unexpected: Vec<_> = acknowledged.difference(&live_set).cloned().collect();
            return Err(wallet_node_api::JsonRpcError {
                code: wallet_node_api::INVALID_REQUEST,
                message: "Invalid admin authorization: acknowledged_pending_mismatch".to_string(),
                data: Some(serde_json::json!({
                    "reason": "acknowledged_pending_mismatch",
                    "expected": live_set,
                    "actual": acknowledged,
                    "missing": missing,
                    "unexpected": unexpected,
                })),
            });
        }

        state
            .store
            .submitted_txs_abandon_for_bundler(account.chain_id, &account.address)
            .await
            .map_err(|_| wallet_node_api::JsonRpcError::internal())?
    };
    let was_active = account.lifecycle == BundlerLifecycle::Active;

    match state.bundler_keys.delete_key(&account.key_ref) {
        Ok(()) | Err(crate::bundler_keys::BundlerKeyError::KeyNotFound(_)) => {}
        Err(err) => {
            let _ = super::relayer_audit::record(
                state,
                if params.unsafe_reset {
                    "relayer_key_reset_completed"
                } else {
                    "relayer_key_deleted"
                },
                &account,
                Some("delete_bundler_eoa"),
                "failure",
                Some("keychain_delete_failed"),
            )
            .await;
            return Err(super::bundler_account::map_key_error(err));
        }
    }
    if state
        .store
        .bundler_account_set_lifecycle_for_owner(
            &account.owner_scope,
            account.chain_id,
            &account.address,
            BundlerLifecycle::Deleted,
        )
        .await
        .is_err()
    {
        let mut repair = account.clone();
        repair.lifecycle = BundlerLifecycle::Deleted;
        let _ = super::relayer_audit::record(
            state,
            "relayer_key_repair_needed",
            &repair,
            Some("delete_bundler_eoa"),
            "failure",
            Some("sqlite_delete_mark_failed_keychain_deleted"),
        )
        .await;
        return Err(wallet_node_api::JsonRpcError::internal());
    }
    let mut deleted = account.clone();
    deleted.lifecycle = BundlerLifecycle::Deleted;
    super::relayer_audit::record(
        state,
        if params.unsafe_reset {
            "relayer_key_reset_completed"
        } else {
            "relayer_key_deleted"
        },
        &deleted,
        Some("delete_bundler_eoa"),
        "success",
        None,
    )
    .await?;

    Ok(deleted_response(
        &deleted,
        params.unsafe_reset,
        was_active,
        &abandoned,
    ))
}

fn deleted_response(
    account: &wallet_node_store::BundlerAccount,
    unsafe_reset: bool,
    submissions_blocked: bool,
    abandoned: &[AbandonedSubmission],
) -> Value {
    serde_json::json!({
        "ownerScope": account.owner_scope,
        "chainId": account.chain_id,
        "eoa": account.address,
        "keyRef": account.key_ref,
        "lifecycle": "deleted",
        "unsafeReset": unsafe_reset,
        "submissionsBlockedUntilFundedRelayerExists": submissions_blocked,
        "abandonedSubmissions": abandoned
    })
}
