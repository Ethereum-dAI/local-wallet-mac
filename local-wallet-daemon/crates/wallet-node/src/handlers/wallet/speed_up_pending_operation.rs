use serde_json::Value;
use wallet_chain::BlockTag;
use wallet_node_store::{
    BundlerLifecycle, NonceStatus, SubmittedTransaction, SubmittedTxStatus, UserOpStatus,
};

use crate::state::DaemonState;

pub async fn handle(
    state: &DaemonState,
    params: Value,
) -> Result<Value, wallet_node_api::JsonRpcError> {
    let params = params
        .as_array()
        .ok_or_else(|| wallet_node_api::JsonRpcError {
            code: wallet_node_api::INVALID_REQUEST,
            message: "Invalid request".to_string(),
            data: Some(serde_json::json!({ "reason": "params must be an array" })),
        })?;
    let requested_hash =
        params
            .first()
            .and_then(Value::as_str)
            .ok_or_else(|| wallet_node_api::JsonRpcError {
                code: wallet_node_api::INVALID_REQUEST,
                message: "Invalid request".to_string(),
                data: Some(serde_json::json!({ "reason": "userOpHash parameter is required" })),
            })?;
    let Some(op) = state
        .store
        .user_op_get(requested_hash)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?
    else {
        return Err(replacement_not_possible(
            requested_hash,
            serde_json::json!({
                "reason": "user_op_not_found",
            }),
        ));
    };

    match op.status {
        UserOpStatus::Included | UserOpStatus::Reverted => {
            return Err(replacement_not_possible(
                requested_hash,
                serde_json::json!({
                    "reason": "terminal_state",
                    "status": op.status.as_str(),
                }),
            ));
        }
        UserOpStatus::Received | UserOpStatus::Simulated | UserOpStatus::Pending => {
            return Err(replacement_not_possible(
                requested_hash,
                serde_json::json!({
                    "reason": "no_submitted_transaction",
                    "status": op.status.as_str(),
                }),
            ));
        }
        UserOpStatus::Submitted | UserOpStatus::Failed => {}
    }

    let candidates = state
        .store
        .submitted_txs_list_all()
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let Some(own_candidate) = pending_replacement_candidate(&candidates, requested_hash) else {
        return Err(replacement_not_possible(
            requested_hash,
            serde_json::json!({
                "reason": "no_pending_bundler_transaction",
                "status": op.status.as_str(),
            }),
        ));
    };
    if local_terminal_candidate(own_candidate)
        && !terminal_candidate_can_be_rescued(state, own_candidate).await?
    {
        return Err(replacement_not_possible(
            requested_hash,
            serde_json::json!({
                "reason": "terminal_state",
                "status": op.status.as_str(),
            }),
        ));
    }
    let Some(candidate) = lowest_replaceable_candidate(
        state,
        &candidates,
        own_candidate.chain_id,
        &own_candidate.bundler_address,
    )
    .await?
    else {
        return Err(replacement_not_possible(
            requested_hash,
            serde_json::json!({
                "reason": "no_pending_bundler_transaction",
                "status": op.status.as_str(),
            }),
        ));
    };
    let Some(candidate_op) = state
        .store
        .user_op_get(&candidate.user_op_hash)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?
    else {
        return Err(replacement_not_possible(
            &candidate.user_op_hash,
            serde_json::json!({
                "reason": "user_op_not_found",
            }),
        ));
    };
    if let Some(blocked_reason) = super::replacement::blocked_reason(state, candidate).await {
        return Err(replacement_not_possible(
            &candidate.user_op_hash,
            blocked_reason,
        ));
    }

    let replacement =
        sign_submit_speed_up_replacement(state, candidate, &candidate_op.user_op_json).await?;
    Ok(serde_json::json!({
        "userOpHash": candidate.user_op_hash,
        "txHash": replacement.tx_hash,
        "replacementOf": candidate.tx_hash,
        "nonce": candidate.nonce
    }))
}

fn pending_replacement_candidate<'a>(
    pending: &'a [SubmittedTransaction],
    user_op_hash: &str,
) -> Option<&'a SubmittedTransaction> {
    pending
        .iter()
        .filter(|tx| {
            tx.user_op_hash == user_op_hash
                && matches!(
                    tx.status,
                    SubmittedTxStatus::Submitting
                        | SubmittedTxStatus::Submitted
                        | SubmittedTxStatus::Dropped
                        | SubmittedTxStatus::Failed
                )
        })
        .min_by_key(|tx| (tx.nonce, tx.created_at, tx.updated_at))
}

async fn lowest_replaceable_candidate<'a>(
    state: &DaemonState,
    candidates: &'a [SubmittedTransaction],
    chain_id: u64,
    bundler_address: &str,
) -> Result<Option<&'a SubmittedTransaction>, wallet_node_api::JsonRpcError> {
    let mut ordered: Vec<&SubmittedTransaction> = candidates
        .iter()
        .filter(|tx| {
            tx.chain_id == chain_id
                && tx.bundler_address.eq_ignore_ascii_case(bundler_address)
                && matches!(
                    tx.status,
                    SubmittedTxStatus::Submitting
                        | SubmittedTxStatus::Submitted
                        | SubmittedTxStatus::Dropped
                        | SubmittedTxStatus::Failed
                )
        })
        .collect();
    ordered.sort_by_key(|tx| (tx.nonce, tx.created_at, tx.updated_at));

    for candidate in ordered {
        if !candidate_user_op_is_replaceable(state, candidate).await? {
            continue;
        }
        if !local_terminal_candidate(candidate)
            || terminal_candidate_can_be_rescued(state, candidate).await?
        {
            return Ok(Some(candidate));
        }
    }
    Ok(None)
}

async fn candidate_user_op_is_replaceable(
    state: &DaemonState,
    candidate: &SubmittedTransaction,
) -> Result<bool, wallet_node_api::JsonRpcError> {
    let Some(op) = state
        .store
        .user_op_get(&candidate.user_op_hash)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?
    else {
        return Ok(false);
    };
    Ok(matches!(
        op.status,
        UserOpStatus::Submitted | UserOpStatus::Failed
    ))
}

fn local_terminal_candidate(candidate: &SubmittedTransaction) -> bool {
    matches!(
        candidate.status,
        SubmittedTxStatus::Dropped | SubmittedTxStatus::Failed
    )
}

async fn terminal_candidate_can_be_rescued(
    state: &DaemonState,
    candidate: &SubmittedTransaction,
) -> Result<bool, wallet_node_api::JsonRpcError> {
    let tx_hash = candidate
        .tx_hash
        .parse()
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    match state.chain.eth_get_transaction_receipt(tx_hash).await {
        Ok(Some(_)) => return Ok(false),
        Ok(None) => {}
        Err(err) => {
            tracing::warn!(
                error = %err,
                tx_hash = candidate.tx_hash,
                user_op_hash = candidate.user_op_hash,
                "speed-up rescue could not verify terminal candidate receipt; proceeding best-effort"
            );
            return Ok(true);
        }
    }

    let bundler_address = candidate
        .bundler_address
        .parse()
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let latest_nonce = match state
        .chain
        .eth_get_transaction_count(bundler_address, BlockTag::Latest)
        .await
    {
        Ok(nonce) => nonce,
        Err(err) => {
            tracing::warn!(
                error = %err,
                bundler_address = candidate.bundler_address,
                nonce = candidate.nonce,
                user_op_hash = candidate.user_op_hash,
                "speed-up rescue could not verify relayer nonce; proceeding best-effort"
            );
            return Ok(true);
        }
    };

    Ok(latest_nonce <= candidate.nonce)
}

fn replacement_not_possible(
    user_op_hash: &str,
    mut data: serde_json::Value,
) -> wallet_node_api::JsonRpcError {
    data["userOpHash"] = serde_json::Value::String(user_op_hash.to_string());
    wallet_node_api::JsonRpcError {
        code: wallet_node_api::REPLACEMENT_NOT_POSSIBLE,
        message: "Replacement not possible".to_string(),
        data: Some(data),
    }
}

pub(crate) async fn sign_submit_speed_up_replacement(
    state: &DaemonState,
    candidate: &SubmittedTransaction,
    user_op_json: &str,
) -> Result<SubmittedTransaction, wallet_node_api::JsonRpcError> {
    let relayer_lifecycle_guard = state
        .relayer_lifecycle_locks
        .acquire(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await;
    let entry_point = state
        .config
        .bundler
        .entry_points
        .first()
        .ok_or_else(|| {
            replacement_not_possible(
                &candidate.user_op_hash,
                serde_json::json!({
                    "reason": "entrypoint_not_configured"
                }),
            )
        })?
        .parse()
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let account = state
        .store
        .bundler_account_list(state.config.network.chain_id)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?
        .into_iter()
        .find(|account| {
            account
                .address
                .eq_ignore_ascii_case(&candidate.bundler_address)
        })
        .ok_or_else(|| {
            replacement_not_possible(
                &candidate.user_op_hash,
                serde_json::json!({
                    "reason": "bundler_account_not_found"
                }),
            )
        })?;
    if matches!(
        account.lifecycle,
        BundlerLifecycle::PendingFunding | BundlerLifecycle::Retired | BundlerLifecycle::Deleted
    ) {
        return Err(replacement_not_possible(
            &candidate.user_op_hash,
            serde_json::json!({
                "reason": "bundler_account_lifecycle_not_signable",
                "lifecycle": account.lifecycle.as_str()
            }),
        ));
    }
    let bundler_address = account
        .address
        .parse()
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let op_value: serde_json::Value = serde_json::from_str(user_op_json)
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let op = wallet_bundler::UserOperation::parse(op_value)
        .map_err(crate::handlers::bundler::map_bundler_error)?;
    let previous_fees = wallet_bundler::BundlerTxFees {
        max_fee_per_gas: super::replacement::parse_stored_u256(&candidate.max_fee_per_gas)
            .ok_or_else(wallet_node_api::JsonRpcError::internal)?,
        max_priority_fee_per_gas: super::replacement::parse_stored_u256(
            &candidate.max_priority_fee_per_gas,
        )
        .ok_or_else(wallet_node_api::JsonRpcError::internal)?,
    };
    let replacement_fees = super::replacement::live_speed_up_replacement_fees(state, previous_fees)
        .await
        .map_err(|error| replacement_error_for_user_op(&candidate.user_op_hash, error))?;
    let gas_limit = handle_ops_gas_limit(&op)?;
    let tx = wallet_bundler::build_handle_ops_tx_request(
        state.config.network.chain_id,
        candidate.nonce,
        entry_point,
        bundler_address,
        &op,
        gas_limit,
        replacement_fees.max_fee_per_gas,
        replacement_fees.max_priority_fee_per_gas,
    )
    .map_err(crate::handlers::bundler::map_bundler_error)?;
    let signature = crate::relayer_signer::sign_validated_replacement_handle_ops_transaction(
        state.bundler_keys.as_ref(),
        &account.key_ref,
        &tx,
        state.config.network.chain_id,
        bundler_address,
        &op,
    )
    .map_err(super::bundler_account::map_key_error)?;
    state
        .store
        .bundler_account_mark_used_for_owner(
            &account.owner_scope,
            state.config.network.chain_id,
            &account.address,
        )
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let raw_tx = wallet_bundler::encode_signed_eip1559_tx(&tx, &signature)
        .map_err(crate::handlers::bundler::map_bundler_error)?;
    let tx_hash = wallet_bundler::signed_eip1559_tx_hash(&tx, &signature)
        .map_err(crate::handlers::bundler::map_bundler_error)?;
    let tx_hash_hex = format!("{tx_hash:#x}");
    let now = now_unix_seconds();
    let replacement = SubmittedTransaction {
        tx_hash: tx_hash_hex.clone(),
        user_op_hash: candidate.user_op_hash.clone(),
        chain_id: candidate.chain_id,
        bundler_address: candidate.bundler_address.clone(),
        nonce: candidate.nonce,
        raw_tx: format!("{raw_tx:#x}"),
        max_fee_per_gas: wallet_bundler::gas::u256_hex(tx.max_fee_per_gas),
        max_priority_fee_per_gas: wallet_bundler::gas::u256_hex(tx.max_priority_fee_per_gas),
        status: SubmittedTxStatus::Submitting,
        replacement_of: Some(candidate.tx_hash.clone()),
        submitted_at_block: candidate.submitted_at_block,
        recovery_attempts: candidate.recovery_attempts,
        created_at: now,
        updated_at: now,
    };

    if local_terminal_candidate(candidate) {
        state
            .store
            .submitted_txs_rescue_replace(&candidate.tx_hash, replacement.clone())
            .await
            .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    } else {
        state
            .store
            .submitted_txs_replace(&candidate.tx_hash, replacement.clone())
            .await
            .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    }
    state
        .store
        .nonce_attach_tx_hash(
            candidate.chain_id,
            &candidate.bundler_address,
            candidate.nonce,
            &tx_hash_hex,
        )
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    state
        .store
        .nonce_set_status(
            candidate.chain_id,
            &candidate.bundler_address,
            candidate.nonce,
            NonceStatus::Submitted,
        )
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    drop(relayer_lifecycle_guard);

    let outcome = state
        .raw_submitter
        .submit_raw_transaction(&raw_tx, tx_hash)
        .await;
    crate::handlers::bundler::send_user_operation::record_submit_outcome(
        &state.store,
        outcome,
        &tx_hash_hex,
        &candidate.user_op_hash,
    )
    .await?;

    Ok(replacement)
}

fn replacement_error_for_user_op(
    user_op_hash: &str,
    mut error: wallet_node_api::JsonRpcError,
) -> wallet_node_api::JsonRpcError {
    if error.code == wallet_node_api::REPLACEMENT_NOT_POSSIBLE {
        if let Some(serde_json::Value::Object(data)) = error.data.as_mut() {
            data.insert(
                "userOpHash".to_string(),
                serde_json::Value::String(user_op_hash.to_string()),
            );
        }
    }
    error
}

fn handle_ops_gas_limit(
    op: &wallet_bundler::UserOperation,
) -> Result<u64, wallet_node_api::JsonRpcError> {
    let total = op.call_gas_limit
        + op.verification_gas_limit
        + op.pre_verification_gas
        + alloy_primitives::U256::from(150_000_u64);
    if total > alloy_primitives::U256::from(u64::MAX) {
        return Err(crate::handlers::bundler::map_bundler_error(
            wallet_bundler::BundlerError::PolicyCapExceeded {
                field: "bundlerTx.gasLimit",
            },
        ));
    }
    Ok(total.to::<u64>())
}

fn now_unix_seconds() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}
