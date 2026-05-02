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
    let balance = state
        .chain
        .eth_get_balance(address, BlockTag::Latest)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let threshold =
        alloy_primitives::U256::from_str_radix(THRESHOLD_LOW.trim_start_matches("0x"), 16)
            .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let compromise =
        super::bundler_account::compromise_status(state, &active, balance, threshold).await?;
    let replacement = replacement_status(state, &active.address).await?;
    let rotation = rotation_status(state).await?;
    Ok(serde_json::json!({
        "ready": balance >= threshold && compromise.is_none(),
        "entryPoints": state.config.bundler.entry_points,
        "eoa": active.address,
        "balance": wallet_bundler::gas::u256_hex(balance),
        "thresholdLow": THRESHOLD_LOW,
        "needsTopup": balance < threshold,
        "lifecycle": active.lifecycle.as_str(),
        "rotation": rotation,
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
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
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

async fn rotation_status(
    state: &DaemonState,
) -> Result<serde_json::Value, wallet_node_api::JsonRpcError> {
    let accounts = state
        .store
        .bundler_account_list(state.config.network.chain_id)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let retiring = accounts
        .iter()
        .filter(|account| account.lifecycle == BundlerLifecycle::Retiring)
        .map(|account| account.address.clone())
        .collect::<Vec<_>>();

    Ok(serde_json::json!({
        "rotating": !retiring.is_empty(),
        "retiring": retiring
    }))
}
