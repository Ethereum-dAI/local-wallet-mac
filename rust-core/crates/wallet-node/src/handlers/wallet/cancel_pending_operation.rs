use serde_json::Value;
use wallet_node_store::{SubmittedTransaction, SubmittedTxStatus, UserOpStatus};

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
    let hash =
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
        .user_op_get(hash)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?
    else {
        return Err(replacement_not_possible(
            hash,
            serde_json::json!({
                "reason": "user_op_not_found",
            }),
        ));
    };

    match op.status {
        UserOpStatus::Included | UserOpStatus::Reverted | UserOpStatus::Failed => {
            return Err(replacement_not_possible(
                hash,
                serde_json::json!({
                    "reason": "terminal_state",
                    "status": op.status.as_str(),
                }),
            ));
        }
        UserOpStatus::Received | UserOpStatus::Simulated | UserOpStatus::Pending => {
            return Err(replacement_not_possible(
                hash,
                serde_json::json!({
                    "reason": "no_submitted_transaction",
                    "status": op.status.as_str(),
                }),
            ));
        }
        UserOpStatus::Submitted => {}
    }

    let pending = state
        .store
        .submitted_txs_list_for_watcher()
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let Some(candidate) = pending_replacement_candidate(&pending, hash) else {
        return Err(replacement_not_possible(
            hash,
            serde_json::json!({
                "reason": "no_pending_bundler_transaction",
                "status": op.status.as_str(),
            }),
        ));
    };
    if let Some(blocked_reason) = super::replacement::blocked_reason(state, candidate).await {
        return Err(replacement_not_possible(hash, blocked_reason));
    }

    let replacement = sign_submit_cancel_replacement(state, candidate, &op.user_op_json).await?;
    Ok(serde_json::json!({
        "userOpHash": hash,
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
                    SubmittedTxStatus::Submitting | SubmittedTxStatus::Submitted
                )
        })
        .min_by_key(|tx| (tx.nonce, tx.created_at, tx.updated_at))
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

async fn sign_submit_cancel_replacement(
    state: &DaemonState,
    candidate: &SubmittedTransaction,
    user_op_json: &str,
) -> Result<SubmittedTransaction, wallet_node_api::JsonRpcError> {
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
            .ok_or_else(|| wallet_node_api::JsonRpcError::internal())?,
        max_priority_fee_per_gas: super::replacement::parse_stored_u256(
            &candidate.max_priority_fee_per_gas,
        )
        .ok_or_else(|| wallet_node_api::JsonRpcError::internal())?,
    };
    let gas_limit = handle_ops_gas_limit(&op)?;
    let tx = wallet_bundler::build_cancel_handle_ops_tx_request(
        state.config.network.chain_id,
        candidate.nonce,
        entry_point,
        bundler_address,
        &op,
        gas_limit,
        previous_fees,
        state.config.policy.min_replacement_bump_pct,
    )
    .map_err(crate::handlers::bundler::map_bundler_error)?;
    let signing_payload = wallet_bundler::encode_eip1559_payload_for_signing(&tx)
        .map_err(crate::handlers::bundler::map_bundler_error)?;
    let signature = state
        .bundler_keys
        .sign_eip1559_payload(&account.key_ref, &signing_payload)
        .map_err(super::bundler_account::map_key_error)?;
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
        created_at: now,
        updated_at: now,
    };

    state
        .store
        .submitted_txs_replace(&candidate.tx_hash, replacement.clone())
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
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

    match state
        .raw_submitter
        .submit_raw_transaction(&raw_tx, tx_hash)
        .await
    {
        Ok(
            wallet_bundler::RawTransactionSubmitOutcome::Accepted(_)
            | wallet_bundler::RawTransactionSubmitOutcome::AlreadyKnown
            | wallet_bundler::RawTransactionSubmitOutcome::NonceTooLow,
        ) => {
            state
                .store
                .submitted_tx_set_status(&tx_hash_hex, SubmittedTxStatus::Submitted)
                .await
                .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
        }
        Err(err) => {
            tracing::warn!(
                error = %err,
                tx_hash = tx_hash_hex,
                user_op_hash = candidate.user_op_hash,
                "same-nonce cancel first-submit failed; watcher will retry persisted transaction"
            );
        }
    }

    Ok(replacement)
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
