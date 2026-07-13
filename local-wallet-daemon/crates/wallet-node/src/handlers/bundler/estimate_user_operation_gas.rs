use alloy_primitives::U256;
use serde_json::Value;
use wallet_bundler::{BundlerError, DecodedValidationResult, PolicyMode, UserOperation};
use wallet_chain::{BlockTag, CallRequest, ChainError};

use crate::state::DaemonState;

const MIN_SUBMISSION_WINDOW_SECS: u64 = 60;
const MAX_BLOCK_DRIFT_SECS: u64 = 90;
const DAIMO_VERIFICATION_GAS_FLOOR: u64 = 1_000_000;
const PERMISSION_ENABLE_VERIFICATION_GAS_FLOOR: u64 = 5_000_000;
const ACCOUNT_CALL_GAS_FLOOR: u64 = 50_000;
const PRE_VERIFICATION_FIXED_OVERHEAD: u64 = 35_000;
const PRE_VERIFICATION_PER_USER_OP_OVERHEAD: u64 = 18_300;
const GAS_ESTIMATE_SAFETY_BPS: u64 = 12_000;
const GAS_ESTIMATE_BPS_DENOMINATOR: u64 = 10_000;

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
        PolicyMode::Estimate,
    )
    .map_err(super::map_policy_error)?;
    tracing::debug!(
        sender = format_args!("{:#x}", op.sender),
        entry_point = format_args!("{entry_point:#x}"),
        nonce = %op.nonce,
        factory = op
            .factory
            .map(|factory| format!("{factory:#x}"))
            .unwrap_or_else(|| "none".to_string()),
        factory_data_bytes = op.factory_data.len(),
        call_data_bytes = op.call_data.len(),
        signature_bytes = op.signature.len(),
        "estimate user operation gas started"
    );
    if !state.chain.is_synced().await {
        tracing::warn!(
            sender = format_args!("{:#x}", op.sender),
            entry_point = format_args!("{entry_point:#x}"),
            "estimate user operation gas blocked because verified reads are not synced"
        );
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
    tracing::debug!(
        sender = format_args!("{:#x}", op.sender),
        entry_point = format_args!("{entry_point:#x}"),
        block_number = head.number,
        block_hash = format_args!("{:#x}", head.hash),
        block_timestamp = head.timestamp,
        "estimate user operation gas using verified head"
    );
    let sender_code = state
        .chain
        .eth_get_code(op.sender, block)
        .await
        .map_err(wallet_bundler::BundlerError::from)
        .map_err(super::map_bundler_error)?;
    tracing::debug!(
        sender = format_args!("{:#x}", op.sender),
        sender_code_bytes = sender_code.len(),
        counterfactual = sender_code.is_empty(),
        "estimate user operation gas loaded sender code"
    );
    super::ensure_sender_account_allowlisted(state, &op, &sender_code, block).await?;
    super::ensure_smart_account_gas_funded(state, entry_point, &op, block).await?;
    let runtime = wallet_bundler::entry_point_simulations_runtime_bytecode()
        .map_err(super::map_bundler_error)?;
    let simulation = simulate_estimate_validation(
        state,
        entry_point,
        &op,
        block,
        runtime,
        state.effective_use_precompiled(),
    )
    .await?;

    match simulation {
        Some(simulation) => {
            wallet_bundler::validate_validation_result(
                &simulation.validation,
                head.timestamp,
                super::now_unix_seconds().max(0) as u64,
                MIN_SUBMISSION_WINDOW_SECS,
                MAX_BLOCK_DRIFT_SECS,
                wallet_bundler::SimulationMode::Estimate,
            )
            .map_err(super::map_bundler_error)?;
            let estimated = derive_estimated_op(state, entry_point, &simulation.op, block).await?;
            Ok(
                wallet_bundler::estimate_user_operation_gas_with_required_prefund(
                    &estimated,
                    estimated
                        .required_prefund()
                        .max(simulation.validation.prefund),
                ),
            )
        }
        None => {
            let estimated = derive_estimated_op(state, entry_point, &op, block).await?;
            Ok(wallet_bundler::estimate_user_operation_gas(&estimated))
        }
    }
}

struct EstimateSimulation {
    op: UserOperation,
    validation: DecodedValidationResult,
}

async fn simulate_estimate_validation(
    state: &DaemonState,
    entry_point: alloy_primitives::Address,
    op: &UserOperation,
    block: BlockTag,
    runtime: alloy_primitives::Bytes,
    configured_use_precompiled: bool,
) -> Result<Option<EstimateSimulation>, wallet_node_api::JsonRpcError> {
    let mut unsupported_dummy = false;
    let mut attempt = 0_u64;
    for use_precompiled in [configured_use_precompiled, !configured_use_precompiled] {
        for simulation_base in simulation_attempts(op) {
            attempt += 1;
            tracing::debug!(
                sender = format_args!("{:#x}", op.sender),
                entry_point = format_args!("{entry_point:#x}"),
                attempt,
                use_precompiled,
                verification_gas_limit = %simulation_base.verification_gas_limit,
                call_gas_limit = %simulation_base.call_gas_limit,
                pre_verification_gas = %simulation_base.pre_verification_gas,
                factory_data_bytes = simulation_base.factory_data.len(),
                "simulateValidation attempt for gas estimate"
            );
            let simulation_op = simulation_base.with_signature(
                wallet_bundler::estimation_signature(op.nonce, &op.signature, use_precompiled),
            );
            match wallet_bundler::simulate_validation(
                state.chain.as_ref(),
                entry_point,
                &simulation_op,
                block,
                runtime.clone(),
            )
            .await
            {
                Ok(validation) => {
                    tracing::debug!(
                        sender = format_args!("{:#x}", op.sender),
                        entry_point = format_args!("{entry_point:#x}"),
                        attempt,
                        use_precompiled,
                        pre_op_gas = %validation.pre_op_gas,
                        prefund = %validation.prefund,
                        sig_failed = validation.sig_failed,
                        valid_after = validation.valid_after,
                        valid_until = validation.valid_until,
                        "simulateValidation succeeded for gas estimate"
                    );
                    return Ok(Some(EstimateSimulation {
                        op: simulation_base,
                        validation,
                    }));
                }
                Err(BundlerError::SimulationFailed { reason }) => {
                    tracing::warn!(
                        sender = format_args!("{:#x}", op.sender),
                        entry_point = format_args!("{entry_point:#x}"),
                        attempt,
                        use_precompiled,
                        reason = %reason,
                        "simulateValidation failed for gas estimate"
                    );
                    if reason == "AA23 reverted" {
                        unsupported_dummy = true;
                    } else {
                        return Err(super::map_bundler_error(BundlerError::SimulationFailed {
                            reason,
                        }));
                    }
                }
                Err(error) => {
                    tracing::warn!(
                        sender = format_args!("{:#x}", op.sender),
                        entry_point = format_args!("{entry_point:#x}"),
                        attempt,
                        use_precompiled,
                        error = %error,
                        "simulateValidation chain error for gas estimate"
                    );
                    return Err(super::map_bundler_error(error));
                }
            }
        }
    }

    if unsupported_dummy {
        tracing::debug!(
            sender = format_args!("{:#x}", op.sender),
            "Kernel dummy-signature simulation reverted; using local gas estimate fallback"
        );
        return Ok(None);
    }

    Err(super::map_bundler_error(BundlerError::SimulationFailed {
        reason: "dummy_signature_unsupported".to_string(),
    }))
}

fn simulation_attempts(op: &UserOperation) -> Vec<UserOperation> {
    let gas_floor = verification_gas_floor(op);
    if op.verification_gas_limit >= gas_floor {
        return vec![op.clone()];
    }
    // Below the floor the EntryPoint forwards too little gas to account
    // deployment and validation, so the simulation can only fail (createSender
    // reverts without data on an undeployed sender). The final estimate is
    // floored by derive_estimated_op either way, so simulate at the floor only.
    vec![op.with_verification_gas_limit(gas_floor)]
}

fn verification_gas_floor(op: &UserOperation) -> U256 {
    if wallet_bundler::is_permission_enable_nonce(op.nonce) {
        U256::from(PERMISSION_ENABLE_VERIFICATION_GAS_FLOOR)
    } else {
        U256::from(DAIMO_VERIFICATION_GAS_FLOOR)
    }
}

async fn derive_estimated_op(
    state: &DaemonState,
    entry_point: alloy_primitives::Address,
    op: &UserOperation,
    block: BlockTag,
) -> Result<UserOperation, wallet_node_api::JsonRpcError> {
    let pre_verification_gas = estimate_pre_verification_gas(op)?;
    let verification_gas_limit = op.verification_gas_limit.max(verification_gas_floor(op));
    let call_gas_limit = estimate_account_call_gas(state, entry_point, op, block).await?;

    Ok(op.with_gas_limits(
        op.call_gas_limit.max(call_gas_limit),
        verification_gas_limit,
        op.pre_verification_gas.max(pre_verification_gas),
    ))
}

fn estimate_pre_verification_gas(
    op: &UserOperation,
) -> Result<U256, wallet_node_api::JsonRpcError> {
    let calldata = wallet_bundler::encode_handle_ops(op, alloy_primitives::Address::ZERO)
        .map_err(super::map_bundler_error)?;
    let calldata_gas: u64 = calldata
        .iter()
        .map(|byte| if *byte == 0 { 4_u64 } else { 16_u64 })
        .sum();
    let word_overhead = calldata.len().div_ceil(32) as u64 * 4;
    let raw = U256::from(PRE_VERIFICATION_FIXED_OVERHEAD)
        + U256::from(PRE_VERIFICATION_PER_USER_OP_OVERHEAD)
        + U256::from(word_overhead)
        + U256::from(calldata_gas);
    Ok(with_safety_margin(raw))
}

async fn estimate_account_call_gas(
    state: &DaemonState,
    entry_point: alloy_primitives::Address,
    op: &UserOperation,
    block: BlockTag,
) -> Result<U256, wallet_node_api::JsonRpcError> {
    if op.call_data.is_empty() {
        return Ok(U256::ZERO);
    }

    let tx = CallRequest {
        from: Some(entry_point),
        to: Some(op.sender),
        data: Some(op.call_data.clone()),
        ..CallRequest::default()
    };
    match state.chain.eth_estimate_gas(tx, Some(block), None).await {
        Ok(gas) => Ok(with_safety_margin(U256::from(gas)).max(U256::from(ACCOUNT_CALL_GAS_FLOOR))),
        Err(ChainError::CallReverted(data)) => {
            Err(super::map_bundler_error(BundlerError::SimulationFailed {
                reason: wallet_bundler::simulation_revert_reason(&data),
            }))
        }
        Err(error) => {
            tracing::warn!(
                error = %error,
                sender = format_args!("{:#x}", op.sender),
                "account call gas estimate unavailable; using conservative floor"
            );
            Ok(U256::from(ACCOUNT_CALL_GAS_FLOOR))
        }
    }
}

fn with_safety_margin(value: U256) -> U256 {
    value * U256::from(GAS_ESTIMATE_SAFETY_BPS) / U256::from(GAS_ESTIMATE_BPS_DENOMINATOR)
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use alloy_primitives::{Address, Bytes, B256, U256};
    use alloy_sol_types::{Revert, SolError};
    use serde_json::json;
    use wallet_bundler::UserOperation;
    use wallet_chain::{BlockTag, CallRequest, MockChainAdapter};

    use crate::state::DaemonState;

    fn sub_floor_user_operation() -> UserOperation {
        UserOperation {
            sender: Address::from([0x11; 20]),
            nonce: U256::ZERO,
            factory: Some(Address::from([0x22; 20])),
            factory_data: Bytes::from(vec![0xaa; 4]),
            call_data: Bytes::new(),
            call_gas_limit: U256::from(100_000),
            verification_gas_limit: U256::ZERO,
            pre_verification_gas: U256::from(50_000),
            max_fee_per_gas: U256::from(1),
            max_priority_fee_per_gas: U256::from(1),
            paymaster: None,
            paymaster_verification_gas_limit: None,
            paymaster_post_op_gas_limit: None,
            paymaster_data: Bytes::new(),
            signature: Bytes::new(),
            raw: json!({}),
        }
    }

    fn permission_user_operation(mode: u8) -> UserOperation {
        let mut nonce = [0u8; 32];
        nonce[0] = mode;
        nonce[1] = wallet_kernel::VALIDATION_TYPE_PERMISSION;
        nonce[2..6].copy_from_slice(&[0xaa, 0xbb, 0xcc, 0xdd]);

        let mut op = sub_floor_user_operation();
        op.nonce = U256::from_be_bytes(nonce);
        op
    }

    fn simulation_request(op: &UserOperation, use_precompiled: bool) -> CallRequest {
        let sim_op = op.with_signature(wallet_bundler::dummy_webauthn_signature(use_precompiled));
        CallRequest {
            to: Some(wallet_bundler::ENTRY_POINT_V07),
            data: Some(wallet_bundler::encode_simulate_validation(&sim_op).unwrap()),
            ..CallRequest::default()
        }
    }

    #[test]
    fn simulation_attempts_stay_at_or_above_verification_gas_floor() {
        let floor = U256::from(super::DAIMO_VERIFICATION_GAS_FLOOR);

        let attempts = super::simulation_attempts(&sub_floor_user_operation());
        assert!(!attempts.is_empty());
        assert!(attempts
            .iter()
            .all(|attempt| attempt.verification_gas_limit >= floor));

        let above_floor =
            sub_floor_user_operation().with_verification_gas_limit(U256::from(2_000_000_u64));
        let attempts = super::simulation_attempts(&above_floor);
        assert_eq!(attempts.len(), 1);
        assert_eq!(
            attempts[0].verification_gas_limit,
            U256::from(2_000_000_u64)
        );
    }

    #[test]
    fn permission_enable_nonce_uses_higher_verification_gas_floor() {
        let enable_op = permission_user_operation(wallet_kernel::VALIDATION_MODE_ENABLE);
        let default_op = permission_user_operation(wallet_kernel::VALIDATION_MODE_DEFAULT);
        let root_op = sub_floor_user_operation();

        assert_eq!(
            super::verification_gas_floor(&enable_op),
            U256::from(super::PERMISSION_ENABLE_VERIFICATION_GAS_FLOOR)
        );
        assert_eq!(
            super::verification_gas_floor(&default_op),
            U256::from(super::DAIMO_VERIFICATION_GAS_FLOOR)
        );
        assert_eq!(
            super::verification_gas_floor(&root_op),
            U256::from(super::DAIMO_VERIFICATION_GAS_FLOOR)
        );

        let attempts = super::simulation_attempts(&enable_op);
        assert_eq!(attempts.len(), 1);
        assert_eq!(
            attempts[0].verification_gas_limit,
            U256::from(super::PERMISSION_ENABLE_VERIFICATION_GAS_FLOOR)
        );
    }

    #[tokio::test]
    async fn estimate_simulation_never_runs_below_verification_gas_floor() {
        let chain = Arc::new(MockChainAdapter::new());
        let state = DaemonState::for_tests(chain.clone());
        let op = sub_floor_user_operation();
        let floored =
            op.with_verification_gas_limit(U256::from(super::DAIMO_VERIFICATION_GAS_FLOOR));
        let block = BlockTag::Hash(B256::from([7; 32]));
        let runtime = Bytes::from_static(&[0x60, 0x00]);
        let overrides = wallet_bundler::simulations_state_override(
            wallet_bundler::ENTRY_POINT_V07,
            runtime.clone(),
        );
        let aa23 = Bytes::from(
            Revert {
                reason: "AA23 reverted".to_string(),
            }
            .abi_encode(),
        );
        for use_precompiled in [true, false] {
            // A sub-floor simulation forwards ~zero gas to createSender, which
            // dies with an empty revert instead of a structured FailedOp.
            chain.set_call_revert(
                simulation_request(&op, use_precompiled),
                block,
                Some(overrides.clone()),
                Bytes::new(),
            );
            chain.set_call_revert(
                simulation_request(&floored, use_precompiled),
                block,
                Some(overrides.clone()),
                aa23.clone(),
            );
        }

        let simulation = super::simulate_estimate_validation(
            &state,
            wallet_bundler::ENTRY_POINT_V07,
            &op,
            block,
            runtime,
            true,
        )
        .await
        .expect("estimate must not fail on a sub-floor simulation attempt");

        assert!(simulation.is_none());
    }
}
