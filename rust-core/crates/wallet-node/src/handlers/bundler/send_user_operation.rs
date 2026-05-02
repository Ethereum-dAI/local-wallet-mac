use alloy_primitives::{Address, U256};
use serde_json::Value;
use wallet_bundler::{PolicyMode, UserOperation};
use wallet_chain::BlockTag;
use wallet_node_store::{
    NonceStatus, SubmittedTransaction, SubmittedTxStatus, UserOpInsertOutcome, UserOpStatus,
    UserOperation as StoredUserOperation,
};

use crate::state::DaemonState;

pub async fn handle(
    state: &DaemonState,
    params: Value,
) -> Result<Value, wallet_node_api::JsonRpcError> {
    let params = super::parse_params_array(params)?;
    let op = UserOperation::parse(
        params
            .first()
            .cloned()
            .ok_or_else(|| super::invalid_params("UserOperation parameter is required"))?,
    )
    .map_err(super::map_bundler_error)?;
    let entry_point = super::parse_entry_point(&params)?;
    let policy = super::policy_from_state(state)?;
    wallet_bundler::validate_user_operation(
        &policy,
        &op,
        entry_point,
        state.config.network.chain_id,
        PolicyMode::Submit,
    )
    .map_err(super::map_policy_error)?;

    let hash = super::hex_hash(
        op.user_op_hash(entry_point, state.config.network.chain_id)
            .map_err(super::map_bundler_error)?,
    );
    if state
        .store
        .user_op_get(&hash)
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?
        .is_some()
    {
        return Ok(Value::String(hash));
    }

    let active_bundler =
        crate::handlers::wallet::bundler_account::ensure_active_bundler_account(state).await?;
    let active_bundler_address = active_bundler
        .address
        .parse()
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;

    if !state.chain.is_synced().await {
        return Err(super::map_bundler_error(
            wallet_bundler::BundlerError::SimulationFailed {
                reason: "verified_reads_not_ready".to_string(),
            },
        ));
    }
    super::ensure_state_override_smoke_passed(state)?;
    let head = state
        .chain
        .current_head()
        .await
        .map_err(wallet_bundler::BundlerError::from)
        .map_err(super::map_bundler_error)?;
    let block = BlockTag::Hash(head.hash);
    let bundler_balance = state
        .chain
        .eth_get_balance(active_bundler_address, block)
        .await
        .map_err(wallet_bundler::BundlerError::from)
        .map_err(super::map_bundler_error)?;
    let threshold = alloy_primitives::U256::from_str_radix(
        crate::handlers::wallet::bundler_status::THRESHOLD_LOW.trim_start_matches("0x"),
        16,
    )
    .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    if crate::handlers::wallet::bundler_account::compromise_status(
        state,
        &active_bundler,
        bundler_balance,
        threshold,
    )
    .await?
    .is_some()
    {
        return Err(super::not_ready("bundler_eoa_compromise_suspected"));
    }
    if bundler_balance < threshold {
        return Err(super::not_ready("bundler_eoa_needs_topup"));
    }
    let sender_code = state
        .chain
        .eth_get_code(op.sender, block)
        .await
        .map_err(wallet_bundler::BundlerError::from)
        .map_err(super::map_bundler_error)?;
    super::ensure_sender_account_allowlisted(state, &op, &sender_code, block).await?;
    super::ensure_smart_account_gas_funded(state, entry_point, &op, block).await?;
    persist_sign_and_submit(
        state,
        &active_bundler,
        active_bundler_address,
        entry_point,
        &op,
        &hash,
        head.number,
    )
    .await?;

    Ok(Value::String(hash))
}

async fn persist_sign_and_submit(
    state: &DaemonState,
    active_bundler: &wallet_node_store::BundlerAccount,
    active_bundler_address: Address,
    entry_point: Address,
    op: &UserOperation,
    user_op_hash: &str,
    submitted_at_block: u64,
) -> Result<(), wallet_node_api::JsonRpcError> {
    let confirmed_nonce = state
        .chain
        .eth_get_transaction_count(active_bundler_address, BlockTag::Latest)
        .await
        .map_err(wallet_bundler::BundlerError::from)
        .map_err(super::map_bundler_error)?;
    let bundler_nonce = state
        .store
        .reserve_next_nonce(
            state.config.network.chain_id,
            &active_bundler.address,
            confirmed_nonce,
        )
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    let gas_limit = handle_ops_gas_limit(op)?;
    let tx = wallet_bundler::build_handle_ops_tx_request(
        state.config.network.chain_id,
        bundler_nonce,
        entry_point,
        active_bundler_address,
        op,
        gas_limit,
        op.max_fee_per_gas,
        op.max_priority_fee_per_gas,
    )
    .map_err(super::map_bundler_error)?;
    let signing_payload = wallet_bundler::encode_eip1559_payload_for_signing(&tx)
        .map_err(super::map_bundler_error)?;
    let signature = state
        .bundler_keys
        .sign_eip1559_payload(&active_bundler.key_ref, &signing_payload)
        .map_err(crate::handlers::wallet::bundler_account::map_key_error)?;
    let raw_tx = wallet_bundler::encode_signed_eip1559_tx(&tx, &signature)
        .map_err(super::map_bundler_error)?;
    let tx_hash = wallet_bundler::signed_eip1559_tx_hash(&tx, &signature)
        .map_err(super::map_bundler_error)?;
    let now = now_unix_seconds();

    match state
        .store
        .user_op_insert(StoredUserOperation {
            user_op_hash: user_op_hash.to_string(),
            chain_id: state.config.network.chain_id,
            entry_point: format!("{entry_point:#x}"),
            sender: format!("{:#x}", op.sender),
            nonce: wallet_bundler::gas::u256_hex(op.nonce),
            user_op_json: op.raw.to_string(),
            status: UserOpStatus::Submitted,
            created_at: now,
            updated_at: now,
        })
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?
    {
        UserOpInsertOutcome::Inserted => {}
        UserOpInsertOutcome::AlreadyExists(_) => return Ok(()),
    }

    let tx_hash_hex = format!("{tx_hash:#x}");
    state
        .store
        .submitted_tx_insert(SubmittedTransaction {
            tx_hash: tx_hash_hex.clone(),
            user_op_hash: user_op_hash.to_string(),
            chain_id: state.config.network.chain_id,
            bundler_address: active_bundler.address.clone(),
            nonce: bundler_nonce,
            raw_tx: format!("{raw_tx:#x}"),
            max_fee_per_gas: wallet_bundler::gas::u256_hex(op.max_fee_per_gas),
            max_priority_fee_per_gas: wallet_bundler::gas::u256_hex(op.max_priority_fee_per_gas),
            status: SubmittedTxStatus::Submitting,
            replacement_of: None,
            submitted_at_block: Some(submitted_at_block),
            created_at: now,
            updated_at: now,
        })
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    state
        .store
        .nonce_attach_tx_hash(
            state.config.network.chain_id,
            &active_bundler.address,
            bundler_nonce,
            &tx_hash_hex,
        )
        .await
        .map_err(|_| wallet_node_api::JsonRpcError::internal())?;
    state
        .store
        .nonce_set_status(
            state.config.network.chain_id,
            &active_bundler.address,
            bundler_nonce,
            NonceStatus::Submitted,
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
                user_op_hash,
                "raw transaction first-submit failed; watcher will retry persisted transaction"
            );
        }
    }

    Ok(())
}

fn handle_ops_gas_limit(op: &UserOperation) -> Result<u64, wallet_node_api::JsonRpcError> {
    let limit = op.call_gas_limit + op.verification_gas_limit + op.pre_verification_gas;
    let overhead = U256::from(150_000_u64);
    let total = limit + overhead;
    if total > U256::from(u64::MAX) {
        return Err(super::map_bundler_error(
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
