use alloy_primitives::U256;
use serde_json::Value;
use wallet_bundler::{BundlerError, DecodedValidationResult, PolicyMode, UserOperation};
use wallet_chain::BlockTag;

use crate::state::DaemonState;

const MIN_SUBMISSION_WINDOW_SECS: u64 = 60;
const MAX_BLOCK_DRIFT_SECS: u64 = 90;
const DAIMO_VERIFICATION_GAS_FLOOR: u64 = 1_000_000;

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
    let sender_code = state
        .chain
        .eth_get_code(op.sender, block)
        .await
        .map_err(wallet_bundler::BundlerError::from)
        .map_err(super::map_bundler_error)?;
    super::ensure_sender_account_allowlisted(state, &op, &sender_code, block).await?;
    super::ensure_smart_account_gas_funded(state, entry_point, &op, block).await?;
    let runtime = wallet_bundler::entry_point_simulations_runtime_bytecode()
        .map_err(super::map_bundler_error)?;
    match simulate_estimate_validation(
        state,
        entry_point,
        &op,
        block,
        runtime,
        state.config.bundler.use_precompiled,
    )
    .await?
    {
        Some(simulation) => {
            wallet_bundler::validate_validation_result(
                &simulation.validation,
                head.timestamp,
                super::now_unix_seconds().max(0) as u64,
                MIN_SUBMISSION_WINDOW_SECS,
                MAX_BLOCK_DRIFT_SECS,
                true,
            )
            .map_err(super::map_bundler_error)?;
            Ok(wallet_bundler::estimate_user_operation_gas_from_validation(
                &simulation.op,
                &simulation.validation,
            ))
        }
        None => Ok(wallet_bundler::estimate_user_operation_gas(&op)),
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
    for use_precompiled in [configured_use_precompiled, !configured_use_precompiled] {
        for simulation_base in simulation_attempts(op) {
            let simulation_op = simulation_base
                .with_signature(wallet_bundler::dummy_webauthn_signature(use_precompiled));
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
                    return Ok(Some(EstimateSimulation {
                        op: simulation_base,
                        validation,
                    }));
                }
                Err(BundlerError::SimulationFailed { reason }) if reason == "AA23 reverted" => {
                    unsupported_dummy = true;
                }
                Err(error) => return Err(super::map_bundler_error(error)),
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
    let gas_floor = U256::from(DAIMO_VERIFICATION_GAS_FLOOR);
    if op.verification_gas_limit >= gas_floor {
        return vec![op.clone()];
    }
    vec![op.clone(), op.with_verification_gas_limit(gas_floor)]
}
