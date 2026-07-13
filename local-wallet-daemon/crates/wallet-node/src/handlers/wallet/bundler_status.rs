use wallet_chain::BlockTag;
use wallet_node_store::BundlerLifecycle;

use crate::state::DaemonState;

pub(crate) const THRESHOLD_LOW: &str = "0x11c37937e08000"; // 0.005 ETH

pub async fn handle(
    state: &DaemonState,
) -> Result<serde_json::Value, wallet_node_api::JsonRpcError> {
    let active = super::bundler_account::ensure_active_bundler_account(state).await?;
    let address = active
        .address
        .parse()
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let threshold =
        alloy_primitives::U256::from_str_radix(THRESHOLD_LOW.trim_start_matches("0x"), 16)
            .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let balance = match state.chain.eth_get_balance(address, BlockTag::Latest).await {
        Ok(balance) => Some(balance),
        Err(error) => {
            tracing::warn!(
                error = %error,
                "bundler EOA balance unavailable for wallet_bundlerStatus"
            );
            None
        }
    };
    let compromise = match balance {
        Some(balance) => {
            super::bundler_account::compromise_status(state, &active, balance, threshold).await?
        }
        None => None,
    };
    let replacement = replacement_status(state, &active.address)
        .await
        .unwrap_or_else(|error| {
            tracing::warn!(
                error = ?error,
                "replacement status unavailable for wallet_bundlerStatus"
            );
            serde_json::json!({
                "eligible": false,
                "blocked": false,
                "blockedReason": null,
                "txHash": null,
                "userOpHash": null,
                "nonce": null,
                "submittedAtBlock": null,
                "currentBlock": null,
                "minAgeBlocks": wallet_bundler::DEFAULT_REPLACEMENT_ELIGIBILITY_BLOCKS,
                "reason": "replacement_status_unavailable"
            })
        });
    let accounts = state
        .store
        .bundler_account_list_for_owner(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let rotation = rotation_status(&accounts);
    let key_history = key_history(&accounts);
    let audit_events = state
        .store
        .relayer_key_audit_list(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
            10,
        )
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    Ok(serde_json::json!({
        "ready": balance.is_some_and(|balance| balance >= threshold) && compromise.is_none(),
        "ownerScope": active.owner_scope,
        "chainId": state.config.network.chain_id,
        "networkProfile": state.config.network_profile().as_str(),
        "entryPoints": state.config.bundler.entry_points,
        "eoa": active.address,
        "keyRef": active.key_ref,
        "balance": balance
            .map(wallet_bundler::gas::u256_hex)
            .unwrap_or_else(|| "unavailable".to_string()),
        "balanceUnavailable": balance.is_none(),
        "thresholdLow": THRESHOLD_LOW,
        "needsTopup": balance.is_some_and(|balance| balance < threshold),
        "lifecycle": active.lifecycle.as_str(),
        "rotation": rotation,
        "keyHistory": key_history,
        "auditEvents": audit_events,
        "replacement": replacement,
        "compromise": {
            "suspected": compromise.is_some(),
            "reason": compromise,
            "submissionBlocked": compromise.is_some()
        }
    }))
}

async fn replacement_status(
    state: &DaemonState,
    bundler_address: &str,
) -> Result<serde_json::Value, wallet_node_api::JsonRpcError> {
    let head = state
        .chain
        .current_head()
        .await
        .map_err(wallet_bundler::BundlerError::from)
        .map_err(crate::handlers::bundler::map_bundler_error)?;
    let pending = state
        .store
        .submitted_txs_list_for_watcher()
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let candidate = wallet_bundler::eligible_replacement_candidate(
        &pending,
        state.config.network.chain_id,
        bundler_address,
        head.number,
        wallet_bundler::DEFAULT_REPLACEMENT_ELIGIBILITY_BLOCKS,
    );
    Ok(match candidate {
        Some(tx) => {
            let blocked_reason = super::replacement::blocked_reason(state, tx).await;
            serde_json::json!({
                "eligible": true,
                "blocked": blocked_reason.is_some(),
                "blockedReason": blocked_reason.unwrap_or(serde_json::Value::Null),
                "txHash": tx.tx_hash,
                "userOpHash": tx.user_op_hash,
                "nonce": tx.nonce,
                "submittedAtBlock": tx.submitted_at_block,
                "currentBlock": head.number,
                "minAgeBlocks": wallet_bundler::DEFAULT_REPLACEMENT_ELIGIBILITY_BLOCKS
            })
        }
        None => serde_json::json!({
            "eligible": false,
            "blocked": false,
            "blockedReason": null,
            "txHash": null,
            "userOpHash": null,
            "nonce": null,
            "submittedAtBlock": null,
            "currentBlock": head.number,
            "minAgeBlocks": wallet_bundler::DEFAULT_REPLACEMENT_ELIGIBILITY_BLOCKS
        }),
    })
}

fn rotation_status(accounts: &[wallet_node_store::BundlerAccount]) -> serde_json::Value {
    let retiring = accounts
        .iter()
        .filter(|account| account.lifecycle == BundlerLifecycle::Retiring)
        .map(|account| account.address.clone())
        .collect::<Vec<_>>();
    let pending_funding = accounts
        .iter()
        .filter(|account| account.lifecycle == BundlerLifecycle::PendingFunding)
        .map(|account| {
            serde_json::json!({
                "eoa": account.address,
                "keyRef": account.key_ref,
                "createdAt": account.created_at
            })
        })
        .collect::<Vec<_>>();

    serde_json::json!({
        "rotating": !retiring.is_empty() || !pending_funding.is_empty(),
        "pendingFunding": pending_funding,
        "retiring": retiring
    })
}

fn key_history(accounts: &[wallet_node_store::BundlerAccount]) -> serde_json::Value {
    serde_json::Value::Array(
        accounts
            .iter()
            .map(|account| {
                serde_json::json!({
                    "ownerScope": account.owner_scope,
                    "chainId": account.chain_id,
                    "eoa": account.address,
                    "keyRef": account.key_ref,
                    "lifecycle": account.lifecycle.as_str(),
                    "createdAt": account.created_at,
                    "activatedAt": account.activated_at,
                    "retiredAt": account.retired_at,
                    "deletedAt": account.deleted_at,
                    "lastUsedAt": account.last_used_at,
                    "lastExportedAt": account.last_exported_at,
                    "compromiseStatus": account.compromise_status
                })
            })
            .collect(),
    )
}
