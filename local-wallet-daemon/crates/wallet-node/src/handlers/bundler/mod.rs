pub mod estimate_user_operation_gas;
pub mod gas_price;
pub mod get_user_operation_receipt;
pub mod get_user_operation_status;
pub mod send_user_operation;
pub mod supported_entry_points;

use alloy_primitives::{Address, Bytes, U256};
use alloy_sol_types::{sol, SolCall};
use serde_json::{json, Value};
use wallet_bundler::{BundlerError, BundlerPolicy, BundlerPolicyInvariants, PolicyError};
use wallet_chain::{BlockTag, CallRequest, ChainError};
use wallet_node_api::{
    JsonRpcError, CHAIN_MISMATCH, ENTRYPOINT_NOT_ALLOWLISTED, INSUFFICIENT_SMART_ACCOUNT_BALANCE,
    INTERNAL_ERROR, WITHDRAW_AMOUNT_EXCEEDS_RECLAIMABLE,
};

use crate::state::{DaemonState, StateOverrideSmokeStatus};

sol! {
    function balanceOf(address account) view returns (uint256);
    function rootValidator() view returns (bytes21);
}

pub(crate) fn policy_from_state(state: &DaemonState) -> Result<BundlerPolicy, JsonRpcError> {
    let entry_points = state
        .config
        .bundler
        .entry_points
        .iter()
        .map(|entry| {
            entry.parse::<Address>().map_err(|_| JsonRpcError {
                code: INTERNAL_ERROR,
                message: "Invalid configured entrypoint".to_string(),
                data: Some(json!({ "entryPoint": entry })),
            })
        })
        .collect::<Result<Vec<_>, _>>()?;

    Ok(BundlerPolicy {
        chain_id: state.config.network.chain_id,
        entry_points,
        max_call_gas_limit: parse_u256_config(
            "max_call_gas_limit",
            &state.config.policy.max_call_gas_limit,
        )?,
        max_verification_gas_limit: parse_u256_config(
            "max_verification_gas_limit",
            &state.config.policy.max_verification_gas_limit,
        )?,
        max_pre_verification_gas: parse_u256_config(
            "max_pre_verification_gas",
            &state.config.policy.max_pre_verification_gas,
        )?,
        max_fee_per_gas: parse_u256_config(
            "max_fee_per_gas",
            &state.config.policy.max_fee_per_gas,
        )?,
        max_priority_fee_per_gas: parse_u256_config(
            "max_priority_fee_per_gas",
            &state.config.policy.max_priority_fee_per_gas,
        )?,
        invariants: BundlerPolicyInvariants::LOCAL_WALLET_V1,
    })
}

fn parse_entry_point(params: &[Value]) -> Result<Address, JsonRpcError> {
    params
        .get(1)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid_params("entryPoint parameter is required"))?
        .parse()
        .map_err(|_| invalid_params("entryPoint must be an address"))
}

fn parse_params_array(params: Value) -> Result<Vec<Value>, JsonRpcError> {
    params
        .as_array()
        .cloned()
        .ok_or_else(|| invalid_params("params must be an array"))
}

fn invalid_params(reason: &str) -> JsonRpcError {
    JsonRpcError {
        code: wallet_node_api::INVALID_REQUEST,
        message: "Invalid request".to_string(),
        data: Some(json!({ "reason": reason })),
    }
}

fn ensure_state_override_smoke_passed(state: &DaemonState) -> Result<(), JsonRpcError> {
    match state.state_override_smoke_status() {
        StateOverrideSmokeStatus::Passed => Ok(()),
        StateOverrideSmokeStatus::Pending => Err(not_ready("state_override_smoke_pending")),
        StateOverrideSmokeStatus::Failed(_) => Err(not_ready("helios_state_override_unsupported")),
    }
}

async fn ensure_sender_account_allowlisted(
    state: &DaemonState,
    op: &wallet_bundler::UserOperation,
    code: &Bytes,
    block: BlockTag,
) -> Result<(), JsonRpcError> {
    let sender = op.sender;
    if code.is_empty() {
        wallet_bundler::validate_counterfactual_kernel_account(
            state.config.network.chain_id,
            sender,
            op.nonce,
            op.factory,
            &op.factory_data,
        )
        .map_err(map_bundler_error)?;
        if !wallet_bundler::is_permission_nonce(op.nonce) {
            ensure_daimo_verifier_allowlisted_for_signature(state, op, block).await?;
        }

        return Ok(());
    }

    if op.factory.is_some() || !op.factory_data.is_empty() {
        return Err(map_bundler_error(
            wallet_bundler::BundlerError::InvalidUserOperation(
                "factory_not_allowed_for_deployed_sender".to_string(),
            ),
        ));
    }
    wallet_bundler::validate_kernel_nonce_key(sender, op.nonce).map_err(map_bundler_error)?;

    let proxy_check = match wallet_bundler::validate_sender_proxy_code(
        state.config.network.chain_id,
        sender,
        code,
    ) {
        Ok(check) => check,
        Err(BundlerError::AccountCodeNotAllowlisted { code_hash, .. })
            if code_hash == wallet_bundler::SOLADY_ERC1967_PROXY_RUNTIME_HASH =>
        {
            None
        }
        Err(error) => return Err(map_bundler_error(error)),
    };

    let requires_erc1967_resolution = match proxy_check {
        Some(check) => check.code_hash == wallet_bundler::SOLADY_ERC1967_PROXY_RUNTIME_HASH,
        None => true,
    };
    if !requires_erc1967_resolution {
        return Ok(());
    }

    let implementation_word = state
        .chain
        .eth_get_storage_at(sender, wallet_bundler::ERC1967_IMPLEMENTATION_SLOT, block)
        .await
        .map_err(BundlerError::from)
        .map_err(map_bundler_error)?;
    let implementation = wallet_bundler::erc1967_implementation_address(implementation_word)
        .ok_or_else(|| {
            map_bundler_error(BundlerError::AccountCodeNotAllowlisted {
                layer: "implementation",
                module_type: "kernel_implementation_slot",
                address: sender,
                code_hash: implementation_word,
            })
        })?;
    let implementation_code = state
        .chain
        .eth_get_code(implementation, block)
        .await
        .map_err(BundlerError::from)
        .map_err(map_bundler_error)?;
    let implementation_check = wallet_bundler::validate_kernel_implementation_code(
        state.config.network.chain_id,
        implementation,
        &implementation_code,
    )
    .map_err(map_bundler_error)?;
    let root_validator = state
        .chain
        .eth_call(
            CallRequest {
                to: Some(sender),
                data: Some(Bytes::from(rootValidatorCall {}.abi_encode())),
                ..CallRequest::default()
            },
            block,
            None,
        )
        .await
        .map_err(BundlerError::from)
        .map_err(map_bundler_error)?;
    let root_validator = rootValidatorCall::abi_decode_returns(&root_validator).map_err(|_| {
        map_bundler_error(BundlerError::AccountCodeNotAllowlisted {
            layer: "validator",
            module_type: "kernel_root_validator_call",
            address: sender,
            code_hash: implementation_check.code_hash,
        })
    })?;
    wallet_bundler::validate_kernel_root_validator(sender, root_validator)
        .map_err(map_bundler_error)?;
    if !wallet_bundler::is_permission_nonce(op.nonce) {
        ensure_daimo_verifier_allowlisted_for_signature(state, op, block).await?;
    }

    Ok(())
}

async fn ensure_daimo_verifier_allowlisted_for_signature(
    state: &DaemonState,
    op: &wallet_bundler::UserOperation,
    block: BlockTag,
) -> Result<(), JsonRpcError> {
    match wallet_bundler::signature_uses_precompiled(&op.signature) {
        Some(false) => ensure_daimo_verifier_allowlisted(state, block).await?,
        Some(true) => {}
        None if op.signature.is_empty() || !is_webauthn_abi_shaped(&op.signature) => {}
        None => {
            return Err(map_bundler_error(
                wallet_bundler::BundlerError::InvalidUserOperation(
                    "malformed_webauthn_signature".to_string(),
                ),
            ));
        }
    }
    Ok(())
}

fn is_webauthn_abi_shaped(signature: &alloy_primitives::Bytes) -> bool {
    signature.len() >= 32 && signature.len().is_multiple_of(32)
}

async fn ensure_daimo_verifier_allowlisted(
    state: &DaemonState,
    block: BlockTag,
) -> Result<(), JsonRpcError> {
    let code = state
        .chain
        .eth_get_code(wallet_bundler::DAIMO_P256_VERIFIER_ADDRESS, block)
        .await
        .map_err(BundlerError::from)
        .map_err(map_bundler_error)?;
    wallet_bundler::validate_daimo_p256_verifier_code(state.config.network.chain_id, &code)
        .map_err(map_bundler_error)?;
    Ok(())
}

fn not_ready(reason: &str) -> JsonRpcError {
    JsonRpcError {
        code: wallet_node_api::NOT_READY,
        message: format!("Not ready: {reason}"),
        data: Some(json!({ "reason": reason })),
    }
}

fn map_policy_error(error: PolicyError) -> JsonRpcError {
    match error {
        PolicyError::EntrypointNotAllowlisted => JsonRpcError {
            code: ENTRYPOINT_NOT_ALLOWLISTED,
            message: "EntryPoint not allowlisted".to_string(),
            data: None,
        },
        PolicyError::ChainMismatch => JsonRpcError {
            code: CHAIN_MISMATCH,
            message: "Chain mismatch".to_string(),
            data: None,
        },
        PolicyError::PaymasterNotSupported => {
            JsonRpcError::simulation_failed("paymaster_not_supported", None)
        }
        PolicyError::SignatureMissing => JsonRpcError::simulation_failed("signature_missing", None),
        PolicyError::CapExceeded(field) => JsonRpcError::policy_cap_exceeded(field),
        PolicyError::ReplacementNotPossible(reason) => {
            JsonRpcError::replacement_not_possible(reason)
        }
    }
}

pub(crate) fn map_bundler_error(error: BundlerError) -> JsonRpcError {
    match error {
        BundlerError::EntrypointNotAllowlisted(_) => JsonRpcError {
            code: ENTRYPOINT_NOT_ALLOWLISTED,
            message: "EntryPoint not allowlisted".to_string(),
            data: None,
        },
        BundlerError::ChainMismatch { expected, actual } => JsonRpcError {
            code: CHAIN_MISMATCH,
            message: "Chain mismatch".to_string(),
            data: Some(json!({ "expected": expected, "actual": actual })),
        },
        BundlerError::PolicyCapExceeded { field } => JsonRpcError::policy_cap_exceeded(field),
        BundlerError::PaymasterNotSupported => {
            JsonRpcError::simulation_failed("paymaster_not_supported", None)
        }
        BundlerError::SignatureMissing => {
            JsonRpcError::simulation_failed("signature_missing", None)
        }
        BundlerError::InvalidUserOperation(reason) => JsonRpcError {
            code: wallet_node_api::INVALID_REQUEST,
            message: "Invalid UserOperation".to_string(),
            data: Some(json!({ "reason": reason })),
        },
        BundlerError::InvalidTransaction(reason) => JsonRpcError {
            code: wallet_node_api::INVALID_REQUEST,
            message: "Invalid transaction".to_string(),
            data: Some(json!({ "reason": reason })),
        },
        BundlerError::ReplacementNotPossible { reason } => {
            JsonRpcError::replacement_not_possible(reason)
        }
        BundlerError::SimulationFailed { reason } => JsonRpcError::simulation_failed(&reason, None),
        BundlerError::RawTransactionSubmission { reason } => {
            JsonRpcError::internal_with_detail("raw_transaction_submission_failed", reason)
        }
        BundlerError::InvalidPinnedArtifact { reason } => {
            JsonRpcError::internal_with_detail("invalid_pinned_artifact", reason)
        }
        BundlerError::AccountCodeNotAllowlisted {
            layer,
            module_type,
            address,
            code_hash,
        } => JsonRpcError::account_code_not_allowlisted(
            layer,
            module_type,
            &format!("{address:#x}"),
            &format!("{code_hash:#x}"),
        ),
        BundlerError::Chain(error) => map_chain_error(error),
        BundlerError::Store(error) => {
            JsonRpcError::internal_with_detail("bundler_store_error", error)
        }
    }
}

fn map_chain_error(error: ChainError) -> JsonRpcError {
    match error {
        ChainError::Stale {
            helios_head,
            exec_head,
        } => JsonRpcError {
            code: wallet_node_api::HELIOS_STALE,
            message: "Verified reads are stale".to_string(),
            data: Some(json!({
                "reason": "verified_reads_stale",
                "heliosHead": helios_head,
                "executionHead": exec_head,
            })),
        },
        ChainError::StateOverrideUnsupported => JsonRpcError {
            code: wallet_node_api::HELIOS_STATE_OVERRIDE_UNSUPPORTED,
            message: "State override unsupported".to_string(),
            data: Some(json!({ "reason": "state_override_unsupported" })),
        },
        ChainError::CallReverted(bytes) => {
            JsonRpcError::simulation_failed("chain_call_reverted", Some(bytes.as_ref()))
        }
        ChainError::BlockNotFound => JsonRpcError {
            code: wallet_node_api::NOT_READY,
            message: "Not ready: block_not_found".to_string(),
            data: Some(json!({ "reason": "block_not_found" })),
        },
        ChainError::RpcError(error) => chain_read_unavailable("rpc_error", &error),
        ChainError::Helios(error) => chain_read_unavailable("helios_error", &error),
        ChainError::CheckpointTooOld { reason } => {
            chain_read_unavailable("checkpoint_too_old", &reason)
        }
        ChainError::Internal(error) => {
            chain_read_unavailable("chain_internal_error", &error.to_string())
        }
    }
}

fn chain_read_unavailable(reason: &'static str, detail: &str) -> JsonRpcError {
    JsonRpcError {
        code: wallet_node_api::NOT_READY,
        message: format!("Not ready: {reason}"),
        data: Some(json!({
            "reason": reason,
            "detail": detail,
        })),
    }
}

async fn ensure_smart_account_gas_funded(
    state: &DaemonState,
    entry_point: Address,
    op: &wallet_bundler::UserOperation,
    block: BlockTag,
) -> Result<(), JsonRpcError> {
    let account_balance = state
        .chain
        .eth_get_balance(op.sender, block)
        .await
        .map_err(BundlerError::from)
        .map_err(map_bundler_error)?;
    let entry_point_deposit = entry_point_deposit(state, entry_point, op.sender, block).await?;
    ensure_entry_point_deposit_management_unsupported(entry_point, op)?;
    let call_value = wallet_bundler::decode_erc7579_single_execution(&op.call_data)
        .map(|execution| execution.value)
        .unwrap_or(U256::ZERO);
    let minimum_account_balance = wallet_bundler::minimum_account_balance(
        call_value,
        op.required_prefund(),
        entry_point_deposit,
    );
    if account_balance >= minimum_account_balance {
        return Ok(());
    }
    let deficit = minimum_account_balance - account_balance;
    let reason = if call_value > account_balance {
        "transferable_below_call_value"
    } else {
        "gas_shortfall"
    };
    Err(JsonRpcError {
        code: INSUFFICIENT_SMART_ACCOUNT_BALANCE,
        message: "Insufficient smart account balance".to_string(),
        data: Some(json!({
            "reason": reason,
            "accountBalance": wallet_bundler::gas::u256_hex(account_balance),
            "entryPointDeposit": wallet_bundler::gas::u256_hex(entry_point_deposit),
            "callValue": wallet_bundler::gas::u256_hex(call_value),
            "requiredPrefund": wallet_bundler::gas::u256_hex(op.required_prefund()),
            "minimumAccountBalance": wallet_bundler::gas::u256_hex(minimum_account_balance),
            "deficit": wallet_bundler::gas::u256_hex(deficit),
            "displayedTopup": wallet_bundler::gas::u256_hex(
                wallet_bundler::displayed_topup_minimum(deficit)
            ),
        })),
    })
}

fn ensure_entry_point_deposit_management_unsupported(
    entry_point: Address,
    op: &wallet_bundler::UserOperation,
) -> Result<(), JsonRpcError> {
    if let Some(execution) = wallet_bundler::decode_erc7579_single_execution(&op.call_data) {
        if execution.target == entry_point
            && wallet_bundler::decode_entry_point_withdraw_to(&execution.call_data).is_some()
        {
            return Err(JsonRpcError {
                code: WITHDRAW_AMOUNT_EXCEEDS_RECLAIMABLE,
                message: "EntryPoint deposit management is not supported".to_string(),
                data: Some(json!({ "reason": "entrypoint_deposit_management_unsupported" })),
            });
        }
    }

    Ok(())
}

async fn entry_point_deposit(
    state: &DaemonState,
    entry_point: Address,
    smart_account: Address,
    block: BlockTag,
) -> Result<U256, JsonRpcError> {
    let call = balanceOfCall {
        account: smart_account,
    };
    let bytes = state
        .chain
        .eth_call(
            CallRequest {
                to: Some(entry_point),
                data: Some(Bytes::from(call.abi_encode())),
                ..Default::default()
            },
            block,
            None,
        )
        .await
        .map_err(BundlerError::from)
        .map_err(map_bundler_error)?;
    Ok(if bytes.len() >= 32 {
        U256::from_be_slice(&bytes[bytes.len() - 32..])
    } else {
        U256::ZERO
    })
}

fn parse_u256_config(field: &'static str, value: &str) -> Result<U256, JsonRpcError> {
    U256::from_str_radix(value.trim_start_matches("0x"), 16).map_err(|_| JsonRpcError {
        code: INTERNAL_ERROR,
        message: "Invalid bundler policy config".to_string(),
        data: Some(json!({ "field": field })),
    })
}

fn hex_hash(hash: [u8; 32]) -> String {
    format!("0x{}", hex::encode(hash))
}

fn now_unix_seconds() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use alloy_primitives::{Address, Bytes, U256};
    use serde_json::json;
    use wallet_chain::{BlockTag, ChainError, MockChainAdapter};

    use crate::state::DaemonState;

    fn user_operation_with_signature(signature: Bytes) -> wallet_bundler::UserOperation {
        wallet_bundler::UserOperation {
            sender: Address::from([0x11; 20]),
            nonce: U256::ZERO,
            factory: None,
            factory_data: Bytes::new(),
            call_data: Bytes::new(),
            call_gas_limit: U256::from(1),
            verification_gas_limit: U256::from(1),
            pre_verification_gas: U256::from(1),
            max_fee_per_gas: U256::from(1),
            max_priority_fee_per_gas: U256::from(1),
            paymaster: None,
            paymaster_verification_gas_limit: None,
            paymaster_post_op_gas_limit: None,
            paymaster_data: Bytes::new(),
            signature,
            raw: json!({}),
        }
    }

    #[tokio::test]
    async fn daimo_verifier_gate_runs_only_for_non_precompiled_webauthn_signature() {
        let chain = Arc::new(MockChainAdapter::new());
        let state = DaemonState::for_tests(chain.clone());
        let precompiled =
            user_operation_with_signature(wallet_bundler::dummy_webauthn_signature(true));

        super::ensure_daimo_verifier_allowlisted_for_signature(
            &state,
            &precompiled,
            BlockTag::Latest,
        )
        .await
        .unwrap();

        assert_eq!(chain.code_call_count(), 0);

        let non_precompiled =
            user_operation_with_signature(wallet_bundler::dummy_webauthn_signature(false));
        let error = super::ensure_daimo_verifier_allowlisted_for_signature(
            &state,
            &non_precompiled,
            BlockTag::Latest,
        )
        .await
        .unwrap_err();

        assert_eq!(chain.code_call_count(), 1);
        assert_eq!(error.code, wallet_node_api::ACCOUNT_CODE_NOT_ALLOWLISTED);
        assert_eq!(error.data.unwrap()["moduleType"], "daimo_p256_verifier");
    }

    #[test]
    fn chain_rpc_errors_map_to_not_ready_with_reason() {
        let error = super::map_bundler_error(wallet_bundler::BundlerError::Chain(
            ChainError::RpcError("request failed".to_string()),
        ));

        assert_eq!(error.code, wallet_node_api::NOT_READY);
        let data = error.data.unwrap();
        assert_eq!(data["reason"], "rpc_error");
        assert_eq!(data["detail"], "request failed");
    }

    #[test]
    fn bundler_internal_errors_keep_reason_detail() {
        let raw =
            super::map_bundler_error(wallet_bundler::BundlerError::RawTransactionSubmission {
                reason: "provider rejected request".to_string(),
            });
        assert_eq!(raw.code, wallet_node_api::INTERNAL_ERROR);
        let raw_data = raw.data.unwrap();
        assert_eq!(raw_data["reason"], "raw_transaction_submission_failed");
        assert_eq!(raw_data["detail"], "provider rejected request");

        let artifact =
            super::map_bundler_error(wallet_bundler::BundlerError::InvalidPinnedArtifact {
                reason: "hash mismatch".to_string(),
            });
        assert_eq!(artifact.code, wallet_node_api::INTERNAL_ERROR);
        let artifact_data = artifact.data.unwrap();
        assert_eq!(artifact_data["reason"], "invalid_pinned_artifact");
        assert_eq!(artifact_data["detail"], "hash mismatch");
    }

    #[test]
    fn stale_chain_errors_do_not_collapse_to_internal() {
        let error =
            super::map_bundler_error(wallet_bundler::BundlerError::Chain(ChainError::Stale {
                helios_head: 10,
                exec_head: 12,
            }));

        assert_eq!(error.code, wallet_node_api::HELIOS_STALE);
        let data = error.data.unwrap();
        assert_eq!(data["reason"], "verified_reads_stale");
        assert_eq!(data["heliosHead"], 10);
        assert_eq!(data["executionHead"], 12);
    }
}
