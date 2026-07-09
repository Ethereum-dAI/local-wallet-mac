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

    if let Some(existing) = state
        .store
        .user_op_get(&hash)
        .await
        .map_err(|_| internal("user_operation_lookup_failed"))?
    {
        if existing.status != UserOpStatus::Failed {
            return Ok(Value::String(hash));
        }
    }

    enforce_per_sender_quota(state, &op)?;
    let active_bundler =
        crate::handlers::wallet::bundler_account::ensure_active_bundler_account(state).await?;
    let active_bundler_address = active_bundler
        .address
        .parse()
        .map_err(|_| internal("relayer_address_invalid"))?;

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
    .map_err(|_| internal("relayer_threshold_invalid"))?;
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
    ensure_bundler_eoa_gas_funded(&op, bundler_balance)?;
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
    let relayer_lifecycle_guard = state
        .relayer_lifecycle_locks
        .acquire(
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            state.config.network.chain_id,
        )
        .await;
    if let Some(existing) = state
        .store
        .user_op_get(user_op_hash)
        .await
        .map_err(|_| internal("user_operation_lookup_failed"))?
    {
        if existing.status != UserOpStatus::Failed {
            drop(relayer_lifecycle_guard);
            return Ok(());
        }
    }
    let current_active =
        crate::handlers::wallet::bundler_account::ensure_active_bundler_account(state).await?;
    if current_active.address != active_bundler.address
        || current_active.key_ref != active_bundler.key_ref
    {
        drop(relayer_lifecycle_guard);
        return Err(super::not_ready("relayer_rotated_during_send"));
    }
    let bundler_nonce = state
        .store
        .reserve_next_nonce(
            state.config.network.chain_id,
            &active_bundler.address,
            confirmed_nonce,
        )
        .await
        .map_err(|error| internal_detail("nonce_reservation_failed", error))?;
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
    let signature = crate::relayer_signer::sign_validated_handle_ops_transaction(
        state.bundler_keys.as_ref(),
        &active_bundler.key_ref,
        &tx,
        state.config.network.chain_id,
        active_bundler_address,
        op,
    )
    .map_err(crate::handlers::wallet::bundler_account::map_key_error)?;
    let raw_tx = wallet_bundler::encode_signed_eip1559_tx(&tx, &signature)
        .map_err(super::map_bundler_error)?;
    let tx_hash = wallet_bundler::signed_eip1559_tx_hash(&tx, &signature)
        .map_err(super::map_bundler_error)?;
    let now = now_unix_seconds();

    match state
        .store
        .user_op_insert_abandon_nonce_on_exists(
            StoredUserOperation {
                user_op_hash: user_op_hash.to_string(),
                chain_id: state.config.network.chain_id,
                entry_point: format!("{entry_point:#x}"),
                sender: format!("{:#x}", op.sender),
                nonce: wallet_bundler::gas::u256_hex(op.nonce),
                user_op_json: op.raw.to_string(),
                status: UserOpStatus::Submitted,
                created_at: now,
                updated_at: now,
            },
            state.config.network.chain_id,
            &active_bundler.address,
            bundler_nonce,
        )
        .await
        .map_err(|_| internal("user_operation_insert_failed"))?
    {
        UserOpInsertOutcome::Inserted => {}
        UserOpInsertOutcome::AlreadyExists(_) => return Ok(()),
    }
    state
        .store
        .bundler_account_mark_used_for_owner(
            &active_bundler.owner_scope,
            state.config.network.chain_id,
            &active_bundler.address,
        )
        .await
        .map_err(|_| internal("relayer_mark_used_failed"))?;

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
            recovery_attempts: 0,
            created_at: now,
            updated_at: now,
        })
        .await
        .map_err(|_| internal("submitted_transaction_insert_failed"))?;
    state
        .store
        .nonce_attach_tx_hash(
            state.config.network.chain_id,
            &active_bundler.address,
            bundler_nonce,
            &tx_hash_hex,
        )
        .await
        .map_err(|_| internal("nonce_tx_hash_attach_failed"))?;
    state
        .store
        .nonce_set_status(
            state.config.network.chain_id,
            &active_bundler.address,
            bundler_nonce,
            NonceStatus::Submitted,
        )
        .await
        .map_err(|_| internal("nonce_status_update_failed"))?;

    drop(relayer_lifecycle_guard);

    let submit_outcome = state
        .raw_submitter
        .submit_raw_transaction(&raw_tx, tx_hash)
        .await;
    record_submit_outcome(&state.store, submit_outcome, &tx_hash_hex, user_op_hash).await?;

    Ok(())
}

pub(crate) async fn record_submit_outcome(
    store: &wallet_node_store::StoreHandle,
    outcome: wallet_bundler::Result<wallet_bundler::RawTransactionSubmitOutcome>,
    tx_hash_hex: &str,
    user_op_hash: &str,
) -> Result<(), wallet_node_api::JsonRpcError> {
    match outcome {
        Ok(
            wallet_bundler::RawTransactionSubmitOutcome::Accepted(_)
            | wallet_bundler::RawTransactionSubmitOutcome::AlreadyKnown,
        ) => {
            store
                .submitted_tx_set_status(tx_hash_hex, SubmittedTxStatus::Submitted)
                .await
                .map_err(|_| internal("submitted_transaction_status_update_failed"))?;
        }
        Ok(wallet_bundler::RawTransactionSubmitOutcome::NonceTooLow) => {
            store
                .submitted_tx_set_status(tx_hash_hex, SubmittedTxStatus::Submitted)
                .await
                .map_err(|_| internal("submitted_transaction_status_update_failed"))?;
            store
                .diagnostic_set(
                    "submitted_transaction",
                    tx_hash_hex,
                    "nonce_too_low_reconcile",
                )
                .await
                .map_err(|_| internal("submitted_transaction_diagnostic_write_failed"))?;
            store
                .diagnostic_set("user_operation", user_op_hash, "nonce_too_low_reconcile")
                .await
                .map_err(|_| internal("user_operation_diagnostic_write_failed"))?;
        }
        Err(_) => {
            store
                .diagnostic_set(
                    "user_operation",
                    user_op_hash,
                    "raw_transaction_first_submit_failed",
                )
                .await
                .map_err(|_| internal("user_operation_diagnostic_write_failed"))?;
            store
                .diagnostic_set(
                    "submitted_transaction",
                    tx_hash_hex,
                    "raw_transaction_first_submit_failed",
                )
                .await
                .map_err(|_| internal("submitted_transaction_diagnostic_write_failed"))?;
            tracing::warn!(
                error.kind = "raw_transaction_first_submit_failed",
                tx_hash = tx_hash_hex,
                user_op_hash,
                "raw transaction first-submit failed; watcher will retry persisted transaction without storing provider error text"
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

fn ensure_bundler_eoa_gas_funded(
    op: &UserOperation,
    bundler_balance: U256,
) -> Result<(), wallet_node_api::JsonRpcError> {
    let gas_limit = handle_ops_gas_limit(op)?;
    let required_max_cost = U256::from(gas_limit) * op.max_fee_per_gas;
    if bundler_balance >= required_max_cost {
        return Ok(());
    }
    let deficit = required_max_cost - bundler_balance;
    Err(wallet_node_api::JsonRpcError {
        code: wallet_node_api::NOT_READY,
        message: "Not ready: bundler_eoa_needs_topup".to_string(),
        data: Some(serde_json::json!({
            "reason": "bundler_eoa_needs_topup",
            "bundlerBalance": wallet_bundler::gas::u256_hex(bundler_balance),
            "requiredMaxCost": wallet_bundler::gas::u256_hex(required_max_cost),
            "deficit": wallet_bundler::gas::u256_hex(deficit),
            "gasLimit": wallet_bundler::gas::u256_hex(U256::from(gas_limit)),
            "maxFeePerGas": wallet_bundler::gas::u256_hex(op.max_fee_per_gas),
            "displayedTopup": wallet_bundler::gas::u256_hex(
                wallet_bundler::displayed_topup_minimum(deficit)
            ),
        })),
    })
}

fn enforce_per_sender_quota(
    state: &DaemonState,
    op: &UserOperation,
) -> Result<(), wallet_node_api::JsonRpcError> {
    let max_gas_wei_per_hour = U256::from_str_radix(
        state
            .config
            .policy
            .max_gas_wei_per_sender_per_hour
            .trim_start_matches("0x"),
        16,
    )
    .map_err(|_| internal("sender_quota_config_invalid"))?;
    let decision = state.per_sender_rate_limiter.check(
        state.config.network.chain_id,
        op.sender,
        op.required_prefund(),
        crate::rate_limit::SenderQuotaConfig {
            max_user_ops_per_minute: state.config.policy.max_user_ops_per_sender_per_minute,
            max_gas_wei_per_hour,
        },
    );

    if decision.allowed {
        Ok(())
    } else {
        Err(wallet_node_api::JsonRpcError {
            code: wallet_node_api::RATE_LIMITED,
            message: "Rate limited".to_string(),
            data: Some(serde_json::json!({
                "reason": decision.reason.unwrap_or("sender_quota_exceeded"),
                "retryAfterMs": (decision.retry_after_secs * 1000.0).ceil() as u64,
            })),
        })
    }
}

fn now_unix_seconds() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

fn internal(reason: &'static str) -> wallet_node_api::JsonRpcError {
    wallet_node_api::JsonRpcError::internal_with_reason(reason)
}

fn internal_detail(reason: &'static str, detail: impl ToString) -> wallet_node_api::JsonRpcError {
    wallet_node_api::JsonRpcError::internal_with_detail(reason, detail)
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use serde_json::json;
    use wallet_chain::MockChainAdapter;
    use wallet_node_store::BundlerLifecycle;

    use super::*;

    fn sample_user_op() -> UserOperation {
        UserOperation::parse(json!({
            "sender": "0x1111111111111111111111111111111111111111",
            "nonce": "0x01",
            "callData": "0x1234",
            "callGasLimit": "0x10",
            "verificationGasLimit": "0x20",
            "preVerificationGas": "0x30",
            "maxFeePerGas": "0x40",
            "maxPriorityFeePerGas": "0x05",
            "signature": "0xab"
        }))
        .unwrap()
    }

    #[test]
    fn bundler_eoa_gas_guard_rejects_balance_below_tx_max_cost() {
        let op = sample_user_op();
        let gas_limit = handle_ops_gas_limit(&op).unwrap();
        let required = U256::from(gas_limit) * op.max_fee_per_gas;

        let err = ensure_bundler_eoa_gas_funded(&op, required - U256::from(1_u64)).unwrap_err();

        assert_eq!(err.code, wallet_node_api::NOT_READY);
        assert_eq!(
            err.data.as_ref().unwrap()["reason"],
            "bundler_eoa_needs_topup"
        );
        assert_eq!(
            err.data.as_ref().unwrap()["requiredMaxCost"],
            wallet_bundler::gas::u256_hex(required)
        );
    }

    #[test]
    fn bundler_eoa_gas_guard_accepts_exact_tx_max_cost() {
        let op = sample_user_op();
        let gas_limit = handle_ops_gas_limit(&op).unwrap();
        let required = U256::from(gas_limit) * op.max_fee_per_gas;

        ensure_bundler_eoa_gas_funded(&op, required).unwrap();
    }

    #[tokio::test]
    async fn record_submit_outcome_marks_nonce_too_low_for_reconciliation() {
        let chain = Arc::new(MockChainAdapter::new());
        let state = DaemonState::for_tests(chain);
        let user_op_hash = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let tx_hash = "0x1111111111111111111111111111111111111111111111111111111111111111";
        state
            .store
            .submitted_tx_insert(SubmittedTransaction {
                tx_hash: tx_hash.to_owned(),
                user_op_hash: user_op_hash.to_owned(),
                chain_id: 1,
                bundler_address: "0xbeef000000000000000000000000000000000000".to_owned(),
                nonce: 0,
                raw_tx: "0x020180".to_owned(),
                max_fee_per_gas: "0x3b9aca00".to_owned(),
                max_priority_fee_per_gas: "0x3b9aca0".to_owned(),
                status: SubmittedTxStatus::Submitting,
                replacement_of: None,
                submitted_at_block: Some(100),
                recovery_attempts: 0,
                created_at: 1,
                updated_at: 1,
            })
            .await
            .unwrap();

        record_submit_outcome(
            &state.store,
            Ok(wallet_bundler::RawTransactionSubmitOutcome::NonceTooLow),
            tx_hash,
            user_op_hash,
        )
        .await
        .unwrap();

        assert_eq!(
            state
                .store
                .submitted_tx_get(tx_hash)
                .await
                .unwrap()
                .unwrap()
                .status,
            SubmittedTxStatus::Submitted
        );
        assert_eq!(
            state
                .store
                .diagnostic_get("submitted_transaction", tx_hash)
                .await
                .unwrap(),
            Some("nonce_too_low_reconcile".to_owned())
        );
        assert_eq!(
            state
                .store
                .diagnostic_get("user_operation", user_op_hash)
                .await
                .unwrap(),
            Some("nonce_too_low_reconcile".to_owned())
        );

        state.store.shutdown_and_wait().await.unwrap();
    }

    #[tokio::test]
    async fn persist_sign_and_submit_rejects_stale_active_bundler_after_rotation() {
        let chain = Arc::new(MockChainAdapter::new());
        let state = DaemonState::for_tests(chain.clone());
        let stale_address = "0x1111111111111111111111111111111111111112";
        let current_address = "0x2222222222222222222222222222222222222222";
        state
            .store
            .bundler_account_insert(1, stale_address, "bundler-eoa:1")
            .await
            .unwrap();
        let stale_active =
            crate::handlers::wallet::bundler_account::ensure_active_bundler_account(&state)
                .await
                .unwrap();
        state
            .store
            .bundler_account_insert_for_owner(
                wallet_node_store::DEFAULT_OWNER_SCOPE,
                1,
                current_address,
                "bundler-eoa:2",
                BundlerLifecycle::PendingFunding,
            )
            .await
            .unwrap();
        state
            .store
            .bundler_account_activate_pending_for_owner(
                wallet_node_store::DEFAULT_OWNER_SCOPE,
                1,
                current_address,
            )
            .await
            .unwrap();

        let op = sample_user_op();
        let err = persist_sign_and_submit(
            &state,
            &stale_active,
            stale_active.address.parse().unwrap(),
            wallet_bundler::ENTRY_POINT_V07,
            &op,
            "0x1234",
            1,
        )
        .await
        .unwrap_err();

        assert_eq!(err.code, wallet_node_api::NOT_READY);
        assert_eq!(err.data.unwrap()["reason"], "relayer_rotated_during_send");
        assert_eq!(chain.transaction_count_call_count(), 1);
        assert!(state
            .store
            .nonces_list_pending(1, stale_address)
            .await
            .unwrap()
            .is_empty());
        assert!(state.store.user_op_get("0x1234").await.unwrap().is_none());
        assert!(state
            .store
            .submitted_txs_list_all()
            .await
            .unwrap()
            .is_empty());
    }
}
