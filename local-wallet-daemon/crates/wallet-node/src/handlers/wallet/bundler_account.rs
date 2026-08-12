use wallet_node_store::{BundlerAccount, BundlerLifecycle};

use crate::state::DaemonState;

pub(crate) async fn ensure_active_bundler_account(
    state: &DaemonState,
) -> Result<BundlerAccount, wallet_node_api::JsonRpcError> {
    maybe_activate_pending_funding(state).await?;
    if let Some(active) = state
        .store
        .bundler_account_active_for_owner(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await
        .map_err(|_| {
            wallet_node_api::JsonRpcError::internal_with_reason("relayer_active_lookup_failed")
        })?
    {
        return Ok(active);
    }

    let existing_accounts = state
        .store
        .bundler_account_list_for_owner(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await
        .map_err(|_| {
            wallet_node_api::JsonRpcError::internal_with_reason("relayer_account_list_failed")
        })?;
    if !existing_accounts.is_empty() {
        return Err(wallet_node_api::JsonRpcError {
            code: wallet_node_api::NOT_READY,
            message: "Not ready: relayer_key_setup_required".to_string(),
            data: Some(serde_json::json!({
                "reason": "relayer_key_setup_required"
            })),
        });
    }

    create_bundler_account(state, BundlerLifecycle::Active).await
}

pub(crate) async fn rotate_bundler_account(
    state: &DaemonState,
) -> Result<BundlerAccount, wallet_node_api::JsonRpcError> {
    if let Some(pending) = state
        .store
        .bundler_account_pending_funding_for_owner(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await
        .map_err(|_| {
            wallet_node_api::JsonRpcError::internal_with_reason(
                "relayer_pending_funding_lookup_failed",
            )
        })?
    {
        return Ok(pending);
    }

    create_bundler_account(state, BundlerLifecycle::PendingFunding).await
}

async fn create_bundler_account(
    state: &DaemonState,
    lifecycle: BundlerLifecycle,
) -> Result<BundlerAccount, wallet_node_api::JsonRpcError> {
    let accounts = state
        .store
        .bundler_account_list_for_owner(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await
        .map_err(|_| {
            wallet_node_api::JsonRpcError::internal_with_reason("relayer_account_list_failed")
        })?;
    let key_ref = crate::bundler_keys::next_scoped_key_ref(
        wallet_node_store::DEFAULT_OWNER_SCOPE,
        state.config.network.chain_id,
        accounts.iter().map(|account| account.key_ref.as_str()),
    );
    let address = state
        .bundler_keys
        .create_key(&key_ref)
        .map_err(|err| match err {
            crate::bundler_keys::BundlerKeyError::KeychainUnavailable(_) => {
                wallet_node_api::JsonRpcError {
                    code: wallet_node_api::NOT_READY,
                    message: "Not ready: relayer_key_setup_required".to_string(),
                    data: Some(serde_json::json!({
                        "reason": "relayer_key_setup_required",
                        "keyRef": key_ref.clone(),
                    })),
                }
            }
            other => map_key_error(other),
        })?;
    let address_hex = format!("{address:#x}");
    let now = now_unix_seconds();
    let account = BundlerAccount {
        owner_scope: wallet_node_store::DEFAULT_OWNER_SCOPE.to_string(),
        chain_id: state.config.network.chain_id,
        address: address_hex.clone(),
        key_ref: key_ref.clone(),
        lifecycle,
        created_at: now,
        activated_at: if lifecycle == BundlerLifecycle::Active {
            Some(now)
        } else {
            None
        },
        retired_at: None,
        deleted_at: None,
        last_used_at: None,
        last_exported_at: None,
        compromise_status: None,
    };

    if state
        .store
        .bundler_account_insert_for_owner(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
            &address_hex,
            &key_ref,
            lifecycle,
        )
        .await
        .is_err()
    {
        let cleanup_result = state.bundler_keys.delete_key(&key_ref);
        let (event_type, failure_reason) = if cleanup_result.is_ok() {
            (
                "relayer_key_created",
                "sqlite_insert_failed_keychain_cleanup_completed",
            )
        } else {
            (
                "relayer_key_repair_needed",
                "sqlite_insert_failed_keychain_cleanup_failed",
            )
        };
        let _ = super::relayer_audit::record(
            state,
            event_type,
            &account,
            None,
            "failure",
            Some(failure_reason),
        )
        .await;
        return Err(wallet_node_api::JsonRpcError::internal_with_reason(
            "relayer_account_store_insert_failed",
        ));
    }

    Ok(account)
}

pub(crate) async fn maybe_activate_pending_funding(
    state: &DaemonState,
) -> Result<(), wallet_node_api::JsonRpcError> {
    let Some(pending) = state
        .store
        .bundler_account_pending_funding_for_owner(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await
        .map_err(|_| {
            wallet_node_api::JsonRpcError::internal_with_reason(
                "relayer_pending_funding_lookup_failed",
            )
        })?
    else {
        return Ok(());
    };

    let address = pending.address.parse().map_err(|_| {
        wallet_node_api::JsonRpcError::internal_with_reason("relayer_address_invalid")
    })?;
    let balance = state
        .chain
        .eth_get_balance(address, wallet_chain::BlockTag::Latest)
        .await
        .map_err(wallet_bundler::BundlerError::from)
        .map_err(crate::handlers::bundler::map_bundler_error)?;
    let threshold = bundler_threshold()?;
    if balance < threshold {
        return Ok(());
    }

    if state
        .store
        .bundler_account_activate_pending_for_owner(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
            &pending.address,
        )
        .await
        .is_err()
    {
        let active = state
            .store
            .bundler_account_active_for_owner(
                wallet_node_store::DEFAULT_OWNER_SCOPE,
                state.config.network.chain_id,
            )
            .await
            .map_err(|_| {
                wallet_node_api::JsonRpcError::internal_with_reason("relayer_active_lookup_failed")
            })?;
        if !active
            .as_ref()
            .is_some_and(|active| active.address.eq_ignore_ascii_case(&pending.address))
        {
            return Err(wallet_node_api::JsonRpcError::internal_with_reason(
                "relayer_pending_activation_failed",
            ));
        }
    }
    Ok(())
}

pub(crate) fn bundler_threshold() -> Result<alloy_primitives::U256, wallet_node_api::JsonRpcError> {
    alloy_primitives::U256::from_str_radix(
        crate::handlers::wallet::bundler_status::THRESHOLD_LOW.trim_start_matches("0x"),
        16,
    )
    .map_err(|_| wallet_node_api::JsonRpcError::internal_with_reason("relayer_threshold_invalid"))
}

pub(crate) fn map_key_error(
    err: crate::bundler_keys::BundlerKeyError,
) -> wallet_node_api::JsonRpcError {
    let reason = match err {
        crate::bundler_keys::BundlerKeyError::KeychainUnavailable(_) => {
            "bundler_keychain_unavailable"
        }
        crate::bundler_keys::BundlerKeyError::KeyNotFound(_) => "bundler_eoa_key_missing",
        crate::bundler_keys::BundlerKeyError::InvalidKey(_) => "bundler_eoa_key_invalid",
        crate::bundler_keys::BundlerKeyError::Signing(_) => "bundler_eoa_signing_failed",
    };

    wallet_node_api::JsonRpcError {
        code: wallet_node_api::NOT_READY,
        message: format!("Not ready: {reason}"),
        data: Some(serde_json::json!({ "reason": reason })),
    }
}

pub(crate) async fn compromise_status(
    state: &DaemonState,
    account: &BundlerAccount,
    balance: alloy_primitives::U256,
    threshold: alloy_primitives::U256,
) -> Result<Option<String>, wallet_node_api::JsonRpcError> {
    let compromised_key = compromise_meta_key(state.config.network.chain_id, &account.address);
    if let Some(reason) = state.store.meta_get(&compromised_key).await.map_err(|_| {
        wallet_node_api::JsonRpcError::internal_with_reason("relayer_compromise_meta_read_failed")
    })? {
        return Ok(Some(reason));
    }

    let last_key = last_balance_meta_key(state.config.network.chain_id, &account.address);
    let previous = state
        .store
        .meta_get(&last_key)
        .await
        .map_err(|_| {
            wallet_node_api::JsonRpcError::internal_with_reason("relayer_balance_meta_read_failed")
        })?
        .and_then(|value| {
            alloy_primitives::U256::from_str_radix(value.trim_start_matches("0x"), 16).ok()
        });

    let has_pending_for_account = state
        .store
        .submitted_txs_list_for_watcher()
        .await
        .map_err(|_| {
            wallet_node_api::JsonRpcError::internal_with_reason("relayer_submitted_tx_list_failed")
        })?
        .into_iter()
        .any(|tx| tx.bundler_address.eq_ignore_ascii_case(&account.address));

    if previous.is_some_and(|previous| previous >= threshold)
        && balance.is_zero()
        && !has_pending_for_account
    {
        let reason = "unexpected_full_drain".to_string();
        state
            .store
            .meta_set(&compromised_key, &reason)
            .await
            .map_err(|_| {
                wallet_node_api::JsonRpcError::internal_with_reason(
                    "relayer_compromise_meta_write_failed",
                )
            })?;
        return Ok(Some(reason));
    }

    state
        .store
        .meta_set(&last_key, &wallet_bundler::gas::u256_hex(balance))
        .await
        .map_err(|_| {
            wallet_node_api::JsonRpcError::internal_with_reason("relayer_balance_meta_write_failed")
        })?;
    Ok(None)
}

fn last_balance_meta_key(chain_id: u64, address: &str) -> String {
    format!(
        "bundler_eoa_last_balance:{chain_id}:{}",
        address.to_ascii_lowercase()
    )
}

fn compromise_meta_key(chain_id: u64, address: &str) -> String {
    format!(
        "bundler_eoa_compromised:{chain_id}:{}",
        address.to_ascii_lowercase()
    )
}

fn now_unix_seconds() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}
