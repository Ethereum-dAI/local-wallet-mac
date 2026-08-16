use wallet_node_store::{BundlerAccount, BundlerLifecycle};

use crate::state::DaemonState;

pub(crate) fn validate_managed_key_ref(
    key_ref: &str,
    chain_id: u64,
) -> Result<(), wallet_node_api::JsonRpcError> {
    let parsed = crate::bundler_keys::parse_canonical_key_ref(key_ref);
    if parsed.is_ok_and(|parsed| {
        parsed.owner_scope == wallet_node_store::DEFAULT_OWNER_SCOPE && parsed.chain_id == chain_id
    }) {
        return Ok(());
    }
    Err(wallet_node_api::JsonRpcError {
        code: wallet_node_api::INVALID_REQUEST,
        message: "Invalid bundler keyRef".to_string(),
        data: Some(serde_json::json!({
            "reason": "invalid_bundler_key_ref",
            "keyRef": key_ref,
        })),
    })
}

#[cfg(test)]
pub(crate) async fn ensure_active_bundler_account(
    state: &DaemonState,
) -> Result<BundlerAccount, wallet_node_api::JsonRpcError> {
    let _relayer_lifecycle_guard = state
        .relayer_lifecycle_locks
        .acquire(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await;
    ensure_active_bundler_account_locked(state).await
}

/// Resolves the active relayer while the caller holds the owner/chain lifecycle lock.
/// Keeping this separate prevents a recursive acquisition when submission performs its
/// final authority check under that same lock.
#[cfg(test)]
pub(crate) async fn ensure_active_bundler_account_locked(
    state: &DaemonState,
) -> Result<BundlerAccount, wallet_node_api::JsonRpcError> {
    if let Some(active) = active_bundler_account_locked(state).await? {
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

/// Resolves existing relayer authority without creating a new key or database row.
/// Submission uses this fail-closed path so an unbound request cannot bootstrap
/// daemon authority as a side effect of being rejected.
pub(crate) async fn resolve_active_bundler_account(
    state: &DaemonState,
) -> Result<BundlerAccount, wallet_node_api::JsonRpcError> {
    let _relayer_lifecycle_guard = state
        .relayer_lifecycle_locks
        .acquire(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await;
    resolve_active_bundler_account_locked(state).await
}

/// Non-creating active lookup for callers that already hold the owner/chain
/// lifecycle lock. A funded pending candidate may be promoted atomically first.
pub(crate) async fn resolve_active_bundler_account_locked(
    state: &DaemonState,
) -> Result<BundlerAccount, wallet_node_api::JsonRpcError> {
    active_bundler_account_locked(state)
        .await?
        .ok_or_else(relayer_key_setup_required)
}

async fn active_bundler_account_locked(
    state: &DaemonState,
) -> Result<Option<BundlerAccount>, wallet_node_api::JsonRpcError> {
    maybe_activate_pending_funding_locked(state).await?;
    state
        .store
        .bundler_account_active_for_owner(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await
        .map_err(|_| {
            wallet_node_api::JsonRpcError::internal_with_reason("relayer_active_lookup_failed")
        })
}

fn relayer_key_setup_required() -> wallet_node_api::JsonRpcError {
    wallet_node_api::JsonRpcError {
        code: wallet_node_api::NOT_READY,
        message: "Not ready: relayer_key_setup_required".to_string(),
        data: Some(serde_json::json!({
            "reason": "relayer_key_setup_required"
        })),
    }
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
    )
    .map_err(map_key_error)?;
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
    let _relayer_lifecycle_guard = state
        .relayer_lifecycle_locks
        .acquire(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await;
    maybe_activate_pending_funding_locked(state).await
}

async fn maybe_activate_pending_funding_locked(
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
    if let Some(reason) = recorded_compromise_status(state, account).await? {
        return Ok(Some(reason));
    }

    let compromised_key = compromise_meta_key(state.config.network.chain_id, &account.address);

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

/// Returns a previously recorded compromise without requiring a live chain read.
/// Once compromise is persisted it remains the highest-priority safety signal,
/// including while the balance RPC is unavailable.
pub(crate) async fn recorded_compromise_status(
    state: &DaemonState,
    account: &BundlerAccount,
) -> Result<Option<String>, wallet_node_api::JsonRpcError> {
    let compromised_key = compromise_meta_key(state.config.network.chain_id, &account.address);
    state.store.meta_get(&compromised_key).await.map_err(|_| {
        wallet_node_api::JsonRpcError::internal_with_reason("relayer_compromise_meta_read_failed")
    })
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

#[cfg(test)]
mod tests {
    use std::{sync::Arc, time::Duration};

    use wallet_chain::{BlockTag, MockChainAdapter};

    use super::*;

    async fn state_with_funded_pending() -> (DaemonState, Arc<MockChainAdapter>, String) {
        let chain = Arc::new(MockChainAdapter::new());
        let state = DaemonState::for_tests(chain.clone());
        let active_address = "0x1111111111111111111111111111111111111111";
        let pending_address = "0x2222222222222222222222222222222222222222";
        state
            .store
            .bundler_account_insert_for_owner(
                wallet_node_store::DEFAULT_OWNER_SCOPE,
                1,
                active_address,
                "bundler-eoa:default:1:1",
                BundlerLifecycle::Active,
            )
            .await
            .unwrap();
        state
            .store
            .bundler_account_insert_for_owner(
                wallet_node_store::DEFAULT_OWNER_SCOPE,
                1,
                pending_address,
                "bundler-eoa:default:1:2",
                BundlerLifecycle::PendingFunding,
            )
            .await
            .unwrap();
        chain.set_balance(
            pending_address.parse().unwrap(),
            BlockTag::Latest,
            bundler_threshold().unwrap(),
        );
        (state, chain, pending_address.to_string())
    }

    #[tokio::test]
    async fn status_triggered_pending_activation_waits_for_lifecycle_lock() {
        let (state, _chain, pending_address) = state_with_funded_pending().await;
        let lifecycle_guard = state
            .relayer_lifecycle_locks
            .acquire(wallet_node_store::DEFAULT_OWNER_SCOPE, 1)
            .await;
        let task_state = state.clone();
        let activation =
            tokio::spawn(async move { maybe_activate_pending_funding(&task_state).await });

        tokio::task::yield_now().await;
        assert!(!activation.is_finished());
        let active_before = state
            .store
            .bundler_account_active_for_owner(wallet_node_store::DEFAULT_OWNER_SCOPE, 1)
            .await
            .unwrap()
            .unwrap();
        assert_ne!(active_before.address, pending_address);
        drop(lifecycle_guard);

        tokio::time::timeout(Duration::from_secs(1), activation)
            .await
            .expect("activation should finish after the lifecycle lock is released")
            .expect("activation task should not panic")
            .unwrap();
        let active_after = state
            .store
            .bundler_account_active_for_owner(wallet_node_store::DEFAULT_OWNER_SCOPE, 1)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(active_after.address, pending_address);
    }

    #[tokio::test]
    async fn locked_active_resolution_does_not_reacquire_lifecycle_lock() {
        let (state, _chain, pending_address) = state_with_funded_pending().await;
        let _lifecycle_guard = state
            .relayer_lifecycle_locks
            .acquire(wallet_node_store::DEFAULT_OWNER_SCOPE, 1)
            .await;

        let active = tokio::time::timeout(
            Duration::from_secs(1),
            ensure_active_bundler_account_locked(&state),
        )
        .await
        .expect("locked resolver must not recursively acquire the lifecycle lock")
        .unwrap();

        assert_eq!(active.address, pending_address);
    }

    #[tokio::test]
    async fn rotation_rejects_noncanonical_history_without_creating_candidate() {
        let state = DaemonState::for_tests(Arc::new(MockChainAdapter::new()));
        state
            .store
            .bundler_account_insert_for_owner(
                wallet_node_store::DEFAULT_OWNER_SCOPE,
                1,
                "0x1111111111111111111111111111111111111111",
                "bundler-eoa:default:1:1",
                BundlerLifecycle::Active,
            )
            .await
            .unwrap();
        state
            .store
            .bundler_account_insert_for_owner(
                wallet_node_store::DEFAULT_OWNER_SCOPE,
                1,
                "0x2222222222222222222222222222222222222222",
                "bundler-eoa:default:1:01",
                BundlerLifecycle::Retired,
            )
            .await
            .unwrap();
        let before = state
            .store
            .bundler_account_list_for_owner(wallet_node_store::DEFAULT_OWNER_SCOPE, 1)
            .await
            .unwrap()
            .into_iter()
            .map(|account| (account.key_ref, account.address, account.lifecycle))
            .collect::<Vec<_>>();
        let _lifecycle_guard = state
            .relayer_lifecycle_locks
            .acquire(wallet_node_store::DEFAULT_OWNER_SCOPE, 1)
            .await;

        let error = rotate_bundler_account(&state).await.unwrap_err();

        assert_eq!(error.data.unwrap()["reason"], "bundler_eoa_key_invalid");
        let after = state
            .store
            .bundler_account_list_for_owner(wallet_node_store::DEFAULT_OWNER_SCOPE, 1)
            .await
            .unwrap()
            .into_iter()
            .map(|account| (account.key_ref, account.address, account.lifecycle))
            .collect::<Vec<_>>();
        assert_eq!(after, before);
        assert!(state
            .bundler_keys
            .address_for_key("bundler-eoa:default:1:2")
            .is_err());
    }
}
