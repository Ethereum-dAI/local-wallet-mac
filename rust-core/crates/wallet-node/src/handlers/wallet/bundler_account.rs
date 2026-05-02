use wallet_node_store::{BundlerAccount, BundlerLifecycle};

use crate::state::DaemonState;

pub(crate) async fn ensure_active_bundler_account(
    state: &DaemonState,
) -> Result<BundlerAccount, wallet_node_api::JsonRpcError> {
    if let Some(active) = state
        .store
        .bundler_account_active(state.config.network.chain_id)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?
    {
        return Ok(active);
    }

    create_bundler_account(state).await
}

pub(crate) async fn rotate_bundler_account(
    state: &DaemonState,
) -> Result<BundlerAccount, wallet_node_api::JsonRpcError> {
    let existing_active = state
        .store
        .bundler_account_active(state.config.network.chain_id)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;

    if let Some(active) = existing_active.as_ref() {
        state
            .store
            .bundler_account_set_lifecycle(
                state.config.network.chain_id,
                &active.address,
                BundlerLifecycle::Retiring,
            )
            .await
            .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    }

    match create_bundler_account(state).await {
        Ok(new_account) => Ok(new_account),
        Err(err) => {
            if let Some(active) = existing_active {
                let _ = state
                    .store
                    .bundler_account_set_lifecycle(
                        state.config.network.chain_id,
                        &active.address,
                        BundlerLifecycle::Active,
                    )
                    .await;
            }
            Err(err)
        }
    }
}

async fn create_bundler_account(
    state: &DaemonState,
) -> Result<BundlerAccount, wallet_node_api::JsonRpcError> {
    let accounts = state
        .store
        .bundler_account_list(state.config.network.chain_id)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let key_ref =
        crate::bundler_keys::next_key_ref(accounts.iter().map(|account| account.key_ref.as_str()))
            .map_err(map_key_error)?;
    let address = state
        .bundler_keys
        .create_key(&key_ref)
        .map_err(map_key_error)?;
    let address_hex = format!("{address:#x}");

    state
        .store
        .bundler_account_insert(state.config.network.chain_id, &address_hex, &key_ref)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;

    Ok(BundlerAccount {
        chain_id: state.config.network.chain_id,
        address: address_hex,
        key_ref,
        lifecycle: BundlerLifecycle::Active,
        created_at: now_unix_seconds(),
    })
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
    if let Some(reason) = state
        .store
        .meta_get(&compromised_key)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?
    {
        return Ok(Some(reason));
    }

    let last_key = last_balance_meta_key(state.config.network.chain_id, &account.address);
    let previous = state
        .store
        .meta_get(&last_key)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?
        .and_then(|value| {
            alloy_primitives::U256::from_str_radix(value.trim_start_matches("0x"), 16).ok()
        });

    let has_pending_for_account = state
        .store
        .submitted_txs_list_for_watcher()
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?
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
            .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
        return Ok(Some(reason));
    }

    state
        .store
        .meta_set(&last_key, &wallet_bundler::gas::u256_hex(balance))
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
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
