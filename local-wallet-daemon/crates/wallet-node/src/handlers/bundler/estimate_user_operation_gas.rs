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
    let acknowledged_call_gas_limit = parse_acknowledged_call_gas_limit(&params, &policy)?;
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
            let estimated = derive_estimated_op(
                state,
                entry_point,
                &simulation.op,
                block,
                &policy,
                acknowledged_call_gas_limit,
            )
            .await?;
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
            let estimated = derive_estimated_op(
                state,
                entry_point,
                &op,
                block,
                &policy,
                acknowledged_call_gas_limit,
            )
            .await?;
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
    policy: &wallet_bundler::BundlerPolicy,
    acknowledged_call_gas_limit: Option<U256>,
) -> Result<UserOperation, wallet_node_api::JsonRpcError> {
    let pre_verification_gas = estimate_pre_verification_gas(op)?;
    let verification_gas_limit = op.verification_gas_limit.max(verification_gas_floor(op));
    let call_gas_limit = estimate_account_call_gas(
        state,
        entry_point,
        op,
        block,
        policy,
        acknowledged_call_gas_limit,
    )
    .await?;

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
    policy: &wallet_bundler::BundlerPolicy,
    acknowledged_call_gas_limit: Option<U256>,
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

    // eth_call is the revert oracle; eth_estimate_gas is only the gas oracle.
    // Helios's estimate_gas returns Ok(result.gas_used()) for Revert and Halt
    // alike (helios core/src/client/node.rs), so in the default read mode a
    // reverting call would otherwise surface as a plausible small number. eth_call
    // maps Revert -> CallReverted in both adapters, so gate on it first.
    match state.chain.eth_call(tx.clone(), block, None).await {
        Ok(_) => {}
        Err(ChainError::CallReverted(data)) => return Err(call_reverted(&data)),
        Err(error) if is_execution_halted(&error) => return Err(execution_halted()),
        Err(error) => {
            return unavailable(op, policy, acknowledged_call_gas_limit, error);
        }
    }

    match state.chain.eth_estimate_gas(tx, Some(block), None).await {
        Ok(gas) => Ok(with_safety_margin(U256::from(gas)).max(U256::from(ACCOUNT_CALL_GAS_FLOOR))),
        Err(ChainError::CallReverted(data)) => Err(call_reverted(&data)),
        Err(error) if is_execution_halted(&error) => Err(execution_halted()),
        Err(error) => unavailable(op, policy, acknowledged_call_gas_limit, error),
    }
}

fn call_reverted(data: &[u8]) -> wallet_node_api::JsonRpcError {
    super::map_bundler_error(BundlerError::SimulationFailed {
        reason: wallet_bundler::simulation_revert_reason(data),
    })
}

/// Same shape as [`call_reverted`] (`SIMULATION_FAILED`), but with a reason
/// string of its own rather than reusing `reverted_without_data`: that string
/// already means "reverted with empty revert data", which is a different,
/// EVM-signalled outcome from a Halt (invalid opcode, precompile error,
/// call-depth exceeded) that Helios's Display text collapses onto the same
/// "no usable revert bytes" shape. Keeping the reason distinct preserves that
/// distinction for anyone reading logs or the RPC error `data.reason`.
fn execution_halted() -> wallet_node_api::JsonRpcError {
    super::map_bundler_error(BundlerError::SimulationFailed {
        reason: "execution_halted".to_string(),
    })
}

/// Helios reports an EVM Halt as `EvmError::Revert(None)`, whose Display text is
/// "execution reverted: execution halted" — not hex, so the adapter's revert
/// parser rejects it and it arrives here as `ChainError::Helios` rather than
/// `CallReverted`. A halt is a deterministic execution failure, not an
/// unavailable estimate: retrying it and then buying gas headroom cannot help,
/// so classify it as a revert and fail with a reason instead.
/// Phrases that mean "the account call itself could not complete" rather than
/// "we could not reach the chain". Deliberately narrow: a false positive here
/// converts a transient transport failure into a permanent verdict and blocks a
/// send the user could have retried, which is worse than the offer-headroom
/// failure it prevents.
/// The call request carries no `gas` field, so the node applies its own cap:
/// "gas required exceeds" therefore means the call needs more than that cap, far
/// above `policy.max_call_gas_limit`, and headroom cannot reach it either.
const EXECUTION_HALT_MARKERS: [&str; 3] = [
    // helios-core's `display_revert` for a `Halt` outcome.
    "execution halted",
    // Execution-RPC providers report a halt as a plain error with no revert data.
    "out of gas",
    "gas required exceeds",
];

/// True when the error says the call halted deterministically, in either read
/// mode. Helios surfaces a halt as `Helios(..)`; `execution_rpc` mode surfaces
/// the same condition as `RpcError(..)` because the provider returns an error
/// body with no revert data (`wallet-chain/src/execution_rpc.rs`, `rpc_error_body`).
/// Both must fail closed — a halt is not something more gas headroom can fix.
fn is_execution_halted(error: &ChainError) -> bool {
    let message = match error {
        ChainError::Helios(message) | ChainError::RpcError(message) => message,
        _ => return false,
    };
    let message = message.to_ascii_lowercase();
    EXECUTION_HALT_MARKERS
        .iter()
        .any(|marker| message.contains(marker))
}

/// Estimation could not run. Fails closed unless the client explicitly
/// acknowledged a call-gas limit for exactly this case.
///
/// This is the *only* place `acknowledged_call_gas_limit` is consulted, which is
/// what makes the override invariant structural: it can never override a
/// successful estimate, and never suppress a revert. The suggestion is
/// re-derived from the op actually being estimated on every call (not cached
/// from an earlier attempt), so a client-supplied acknowledgement can raise the
/// call-gas limit but never lower it below what this op's own calldata implies.
fn unavailable(
    op: &UserOperation,
    policy: &wallet_bundler::BundlerPolicy,
    acknowledged_call_gas_limit: Option<U256>,
    error: ChainError,
) -> Result<U256, wallet_node_api::JsonRpcError> {
    let suggested = wallet_bundler::suggested_unestimated_call_gas_limit(
        &op.call_data,
        policy.max_call_gas_limit,
    );

    if let Some(limit) = acknowledged_call_gas_limit {
        let floored = limit.max(suggested);
        tracing::warn!(
            error = %error,
            sender = format_args!("{:#x}", op.sender),
            acknowledged_call_gas_limit = %limit,
            suggested_call_gas_limit = %suggested,
            floored_call_gas_limit = %floored,
            "account call gas estimate unavailable; client acknowledged submitting with headroom"
        );
        return Ok(floored);
    }

    tracing::warn!(
        error = %error,
        sender = format_args!("{:#x}", op.sender),
        suggested_call_gas_limit = %suggested,
        "account call gas estimate unavailable; failing closed"
    );
    Err(wallet_node_api::JsonRpcError::gas_estimation_unavailable(
        error,
        &format!("{suggested:#x}"),
    ))
}

fn with_safety_margin(value: U256) -> U256 {
    value * U256::from(GAS_ESTIMATE_SAFETY_BPS) / U256::from(GAS_ESTIMATE_BPS_DENOMINATOR)
}

/// Parses the optional third parameter,
/// `{ "acknowledgedCallGasLimit": "0x…" }`.
///
/// Present-and-valid means the client has explicitly consented to submitting at
/// that call-gas limit *if and only if* estimation turns out to be unavailable.
/// Malformed input is rejected rather than silently ignored: a client that meant
/// to consent must not be told the estimate simply failed.
fn parse_acknowledged_call_gas_limit(
    params: &[Value],
    policy: &wallet_bundler::BundlerPolicy,
) -> Result<Option<U256>, wallet_node_api::JsonRpcError> {
    let Some(value) = params.get(2) else {
        return Ok(None);
    };
    if value.is_null() {
        return Ok(None);
    }
    let object = value
        .as_object()
        .ok_or_else(|| super::invalid_params("third parameter must be an object"))?;
    // ERC-4337 gives slot 3 of `eth_estimateUserOperationGas` to `stateOverride`,
    // and `method.rs` accepts that name as an alias for this method. We do not
    // implement state overrides, so an unrecognised key must be rejected loudly:
    // silently ignoring one would answer a spec-conforming client with an estimate
    // computed against state it did not ask for.
    if let Some(unexpected) = object
        .keys()
        .find(|key| key.as_str() != "acknowledgedCallGasLimit")
    {
        return Err(super::invalid_params(&format!(
            "third parameter does not support {unexpected:?} (state overrides are not implemented)"
        )));
    }
    let Some(raw) = object.get("acknowledgedCallGasLimit") else {
        return Ok(None);
    };
    if raw.is_null() {
        return Ok(None);
    }

    let text = raw
        .as_str()
        .ok_or_else(|| super::invalid_params("acknowledgedCallGasLimit must be a hex quantity"))?;
    let digits = text
        .strip_prefix("0x")
        .ok_or_else(|| super::invalid_params("acknowledgedCallGasLimit must be a hex quantity"))?;
    let limit = U256::from_str_radix(digits, 16)
        .map_err(|_| super::invalid_params("acknowledgedCallGasLimit must be a hex quantity"))?;

    if limit > policy.max_call_gas_limit {
        return Err(wallet_node_api::JsonRpcError::policy_cap_exceeded(
            "callGasLimit",
        ));
    }
    Ok(Some(limit))
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use alloy_primitives::{Address, Bytes, B256, U256};
    use alloy_sol_types::{sol, Revert, SolCall, SolError, SolValue};
    use serde_json::json;
    use wallet_bundler::UserOperation;
    use wallet_chain::{BlockTag, CallRequest, ChainError, MockChainAdapter};

    use crate::state::DaemonState;

    // Local re-declaration of the ERC-7579 `execute(bytes32,bytes)` selector and
    // `Execution` tuple shape, scoped to this test module, so batch calldata can
    // be built without reaching into `wallet_bundler::execution`'s private items.
    // ABI encoding is structural, not name-based, so this round-trips through
    // `wallet_bundler::decode_erc7579_executions` identically to the real type.
    sol! {
        struct BatchExecution {
            address target;
            uint256 value;
            bytes callData;
        }
        function execute(bytes32 mode, bytes executionCalldata);
    }

    fn encode_batch_call_data(executions: &[(Address, U256, Bytes)]) -> Bytes {
        let mut mode = [0u8; 32];
        mode[0] = 0x01;
        let items: Vec<BatchExecution> = executions
            .iter()
            .map(|(target, value, call_data)| BatchExecution {
                target: *target,
                value: *value,
                callData: call_data.clone(),
            })
            .collect();

        Bytes::from(
            executeCall {
                mode: mode.into(),
                executionCalldata: Bytes::from(items.abi_encode()),
            }
            .abi_encode(),
        )
    }

    fn account_call_request(op: &UserOperation, entry_point: Address) -> CallRequest {
        CallRequest {
            from: Some(entry_point),
            to: Some(op.sender),
            data: Some(op.call_data.clone()),
            ..CallRequest::default()
        }
    }

    fn op_with_call_data() -> UserOperation {
        let mut op = sub_floor_user_operation();
        op.call_data = wallet_bundler::encode_erc7579_single_execution(
            Address::from([0x33; 20]),
            U256::from(10_000_000_000_000_000u64),
            Bytes::from(vec![0xab; 8]),
        );
        op
    }

    // 2 sub-executions -> suggested_unestimated_call_gas_limit = 200_000 base +
    // 400_000 per execution * 2 = 1_000_000.
    fn op_with_batch_call_data() -> UserOperation {
        let mut op = sub_floor_user_operation();
        let target = Address::from([0x33; 20]);
        let inner = Bytes::from(vec![0xab; 8]);
        op.call_data = encode_batch_call_data(&[
            (target, U256::from(10_000_000_000_000_000u64), inner.clone()),
            (target, U256::from(10_000_000_000_000_000u64), inner),
        ]);
        op
    }

    // Only `max_call_gas_limit` is read by the code under test; the rest just
    // has to be well-formed. Mirrors the shape built by
    // `handlers/bundler/mod.rs::policy_from_state`.
    fn test_policy() -> wallet_bundler::BundlerPolicy {
        wallet_bundler::BundlerPolicy {
            chain_id: 11_155_111,
            entry_points: vec![wallet_bundler::ENTRY_POINT_V07],
            max_call_gas_limit: U256::from(10_000_000u64),
            max_verification_gas_limit: U256::from(5_000_000u64),
            max_pre_verification_gas: U256::from(1_000_000u64),
            max_fee_per_gas: U256::from(50_000_000_000u64),
            max_priority_fee_per_gas: U256::from(5_000_000_000u64),
            invariants: wallet_bundler::BundlerPolicyInvariants::LOCAL_WALLET_V1,
        }
    }

    #[tokio::test]
    async fn reverting_call_is_reported_even_when_estimate_gas_returns_ok() {
        // Regression guard for the Helios blindness: helios estimate_gas returns
        // Ok(gas_used) for Revert and Halt, so eth_call is the only revert oracle.
        let chain = Arc::new(MockChainAdapter::new());
        let state = DaemonState::for_tests(chain.clone());
        let entry_point = wallet_bundler::ENTRY_POINT_V07;
        let op = op_with_call_data();
        let block = BlockTag::Hash(B256::from([9; 32]));
        let revert = Bytes::from(
            Revert {
                reason: "CallFailed".to_string(),
            }
            .abi_encode(),
        );

        chain.set_call_revert(account_call_request(&op, entry_point), block, None, revert);
        chain.set_gas_estimate(
            account_call_request(&op, entry_point),
            Some(block),
            None,
            21_000,
        );

        let error =
            super::estimate_account_call_gas(&state, entry_point, &op, block, &test_policy(), None)
                .await
                .expect_err("a reverting call must not produce a gas estimate");

        assert_eq!(error.code, wallet_node_api::SIMULATION_FAILED);
        let data = error.data.expect("data is present");
        assert!(
            data["reason"].as_str().unwrap().contains("CallFailed"),
            "revert reason must be surfaced, got {data}"
        );
    }

    #[tokio::test]
    async fn estimation_transport_failure_fails_closed_with_suggestion() {
        let chain = Arc::new(MockChainAdapter::new());
        let state = DaemonState::for_tests(chain.clone());
        let entry_point = wallet_bundler::ENTRY_POINT_V07;
        let op = op_with_call_data();
        let block = BlockTag::Hash(B256::from([9; 32]));

        // No mock entries: eth_call resolves to a chain error, not a revert.
        let error =
            super::estimate_account_call_gas(&state, entry_point, &op, block, &test_policy(), None)
                .await
                .expect_err("an unavailable estimate must fail closed, not floor to 50k");

        assert_eq!(error.code, wallet_node_api::NOT_READY);
        let data = error.data.expect("data is present");
        assert_eq!(data["reason"], "gas_estimation_unavailable");
        assert!(data["detail"].is_string());
        // Single execution -> 200k base + 400k per execution.
        assert_eq!(data["suggestedCallGasLimit"], "0x927c0");
    }

    #[tokio::test]
    async fn successful_estimate_still_applies_margin_and_floor() {
        // The 50k floor survives on a *successful* estimate; only its use as a
        // fallback is removed. 40_554 * 1.2 = 48_664, floored to 50_000.
        let chain = Arc::new(MockChainAdapter::new());
        let state = DaemonState::for_tests(chain.clone());
        let entry_point = wallet_bundler::ENTRY_POINT_V07;
        let op = op_with_call_data();
        let block = BlockTag::Hash(B256::from([9; 32]));

        chain.set_call_response(
            account_call_request(&op, entry_point),
            block,
            None,
            Bytes::new(),
        );
        chain.set_gas_estimate(
            account_call_request(&op, entry_point),
            Some(block),
            None,
            40_554,
        );

        let gas =
            super::estimate_account_call_gas(&state, entry_point, &op, block, &test_policy(), None)
                .await
                .expect("a successful estimate must succeed");

        assert_eq!(gas, U256::from(50_000u64));
    }

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

    #[tokio::test]
    async fn acknowledged_headroom_never_suppresses_a_revert() {
        // Headroom buys gas, not silence.
        let chain = Arc::new(MockChainAdapter::new());
        let state = DaemonState::for_tests(chain.clone());
        let entry_point = wallet_bundler::ENTRY_POINT_V07;
        let op = op_with_call_data();
        let block = BlockTag::Hash(B256::from([9; 32]));

        chain.set_call_revert(
            account_call_request(&op, entry_point),
            block,
            None,
            Bytes::from(
                Revert {
                    reason: "CallFailed".to_string(),
                }
                .abi_encode(),
            ),
        );

        let error = super::estimate_account_call_gas(
            &state,
            entry_point,
            &op,
            block,
            &test_policy(),
            Some(U256::from(2_000_000u64)),
        )
        .await
        .expect_err("an acknowledged limit must not mask a revert");

        assert_eq!(error.code, wallet_node_api::SIMULATION_FAILED);
    }

    #[tokio::test]
    async fn acknowledged_headroom_never_overrides_a_successful_estimate() {
        let chain = Arc::new(MockChainAdapter::new());
        let state = DaemonState::for_tests(chain.clone());
        let entry_point = wallet_bundler::ENTRY_POINT_V07;
        let op = op_with_call_data();
        let block = BlockTag::Hash(B256::from([9; 32]));

        chain.set_call_response(
            account_call_request(&op, entry_point),
            block,
            None,
            Bytes::new(),
        );
        chain.set_gas_estimate(
            account_call_request(&op, entry_point),
            Some(block),
            None,
            300_000,
        );

        let gas = super::estimate_account_call_gas(
            &state,
            entry_point,
            &op,
            block,
            &test_policy(),
            Some(U256::from(2_000_000u64)),
        )
        .await
        .expect("a successful estimate must win");

        // 300_000 * 1.2, not the acknowledged 2_000_000.
        assert_eq!(gas, U256::from(360_000u64));
    }

    #[tokio::test]
    async fn acknowledged_headroom_is_honored_when_estimation_unavailable() {
        let chain = Arc::new(MockChainAdapter::new());
        let state = DaemonState::for_tests(chain.clone());
        let entry_point = wallet_bundler::ENTRY_POINT_V07;
        let op = op_with_call_data();
        let block = BlockTag::Hash(B256::from([9; 32]));

        // No mocks: eth_call resolves to a chain error.
        let gas = super::estimate_account_call_gas(
            &state,
            entry_point,
            &op,
            block,
            &test_policy(),
            Some(U256::from(2_000_000u64)),
        )
        .await
        .expect("an acknowledged limit must be honored when estimation is unavailable");

        assert_eq!(gas, U256::from(2_000_000u64));
    }

    #[tokio::test]
    async fn acknowledged_headroom_below_the_freshly_derived_suggestion_is_floored_to_it() {
        // Regression guard for Finding 1: the suggestion must be re-derived from
        // the op actually being estimated on every call, not trusted from an
        // earlier attempt. A batch op suggests 1_000_000 (200_000 base +
        // 400_000 * 2 executions); an acknowledgement of 600_000 -- correct for
        // a *single*-execution op -- must be raised to the batch op's own floor,
        // not submitted as-is.
        let chain = Arc::new(MockChainAdapter::new());
        let state = DaemonState::for_tests(chain.clone());
        let entry_point = wallet_bundler::ENTRY_POINT_V07;
        let op = op_with_batch_call_data();
        let block = BlockTag::Hash(B256::from([9; 32]));

        // No mocks: eth_call resolves to a chain error, so estimation is
        // unavailable and the acknowledged limit is consulted.
        let gas = super::estimate_account_call_gas(
            &state,
            entry_point,
            &op,
            block,
            &test_policy(),
            Some(U256::from(600_000u64)),
        )
        .await
        .expect("a below-suggestion acknowledgement must still be honored, floored up");

        assert_eq!(gas, U256::from(1_000_000u64));
    }

    #[tokio::test]
    async fn acknowledged_headroom_above_the_suggestion_is_returned_unchanged() {
        // Companion to the floor test above: an acknowledgement that already
        // covers the freshly-derived suggestion must not be clamped down to it.
        let chain = Arc::new(MockChainAdapter::new());
        let state = DaemonState::for_tests(chain.clone());
        let entry_point = wallet_bundler::ENTRY_POINT_V07;
        let op = op_with_batch_call_data();
        let block = BlockTag::Hash(B256::from([9; 32]));

        let gas = super::estimate_account_call_gas(
            &state,
            entry_point,
            &op,
            block,
            &test_policy(),
            Some(U256::from(3_000_000u64)),
        )
        .await
        .expect("an above-suggestion acknowledgement must be returned unchanged");

        assert_eq!(gas, U256::from(3_000_000u64));
    }

    #[tokio::test]
    async fn eth_call_evm_halt_is_reported_as_simulation_failed_not_unavailable() {
        // Regression guard for Finding 2: Helios reports an EVM Halt as
        // `EvmError::Revert(None)`, whose Display text ("execution reverted:
        // execution halted") is not hex, so the adapter's revert parser can't
        // turn it into `ChainError::CallReverted` and it arrives here as a
        // plain `ChainError::Helios`. That must not be classified alongside a
        // transient transport failure (`gas_estimation_unavailable`): a halt is
        // deterministic, so retrying and buying gas headroom cannot help.
        let chain = Arc::new(MockChainAdapter::new());
        let state = DaemonState::for_tests(chain.clone());
        let entry_point = wallet_bundler::ENTRY_POINT_V07;
        let op = op_with_call_data();
        let block = BlockTag::Hash(B256::from([9; 32]));

        chain.inject_error(Box::new(|| {
            ChainError::Helios("execution reverted: execution halted".to_string())
        }));

        let error =
            super::estimate_account_call_gas(&state, entry_point, &op, block, &test_policy(), None)
                .await
                .expect_err("an EVM halt must be reported as a simulation failure");

        assert_eq!(error.code, wallet_node_api::SIMULATION_FAILED);
        let data = error.data.expect("data is present");
        assert_eq!(data["reason"], "execution_halted");
    }

    #[tokio::test]
    async fn eth_estimate_gas_evm_halt_is_reported_as_simulation_failed_not_unavailable() {
        // Same check applied to the eth_estimate_gas gate, for consistency:
        // eth_call must succeed (so the flow reaches eth_estimate_gas) and only
        // eth_estimate_gas sees the halt.
        let chain = Arc::new(MockChainAdapter::new());
        let state = DaemonState::for_tests(chain.clone());
        let entry_point = wallet_bundler::ENTRY_POINT_V07;
        let op = op_with_call_data();
        let block = BlockTag::Hash(B256::from([9; 32]));

        chain.set_call_response(
            account_call_request(&op, entry_point),
            block,
            None,
            Bytes::new(),
        );
        chain.inject_gas_estimate_error(Box::new(|| {
            ChainError::Helios("execution reverted: execution halted".to_string())
        }));

        let error =
            super::estimate_account_call_gas(&state, entry_point, &op, block, &test_policy(), None)
                .await
                .expect_err("an EVM halt from eth_estimate_gas must also be a simulation failure");

        assert_eq!(error.code, wallet_node_api::SIMULATION_FAILED);
        let data = error.data.expect("data is present");
        assert_eq!(data["reason"], "execution_halted");
    }

    #[tokio::test]
    async fn execution_rpc_mode_halt_is_reported_as_simulation_failed_not_unavailable() {
        // `read_verification = "execution_rpc"` reports a halt through a
        // different ChainError variant: the provider returns an error body with
        // no revert data, so `rpc_error_body` (wallet-chain/src/execution_rpc.rs)
        // produces `ChainError::RpcError`, not `Helios`. Without this the app
        // burns its warm-up backoff and then offers gas headroom that cannot
        // help, and consenting submits an op that reverts on-chain — the exact
        // failure #49 is about, on the non-default read path.
        for message in [
            "eth_call error -32000: out of gas",
            "eth_call error -32000: gas required exceeds allowance (50000000)",
            "eth_call error -32000: Out Of Gas",
        ] {
            let chain = Arc::new(MockChainAdapter::new());
            let state = DaemonState::for_tests(chain.clone());
            let entry_point = wallet_bundler::ENTRY_POINT_V07;
            let op = op_with_call_data();
            let block = BlockTag::Hash(B256::from([9; 32]));

            let owned = message.to_string();
            chain.inject_error(Box::new(move || ChainError::RpcError(owned.clone())));

            let error = super::estimate_account_call_gas(
                &state,
                entry_point,
                &op,
                block,
                &test_policy(),
                None,
            )
            .await
            .unwrap_err();

            assert_eq!(
                error.code,
                wallet_node_api::SIMULATION_FAILED,
                "{message:?} must fail closed"
            );
            assert_eq!(
                error.data.expect("data is present")["reason"],
                "execution_halted"
            );
        }
    }

    #[tokio::test]
    async fn transient_rpc_failure_is_still_unavailable_not_halted() {
        // The other half of the previous test: the halt markers must stay narrow
        // enough that an ordinary transport failure remains retryable. A false
        // positive here would turn a transient error into a permanent verdict
        // and block a send the user could have retried.
        for message in [
            "eth_call error -32603: request timed out",
            "eth_call error 429: too many requests",
        ] {
            let chain = Arc::new(MockChainAdapter::new());
            let state = DaemonState::for_tests(chain.clone());
            let entry_point = wallet_bundler::ENTRY_POINT_V07;
            let op = op_with_call_data();
            let block = BlockTag::Hash(B256::from([9; 32]));

            let owned = message.to_string();
            chain.inject_error(Box::new(move || ChainError::RpcError(owned.clone())));

            let error = super::estimate_account_call_gas(
                &state,
                entry_point,
                &op,
                block,
                &test_policy(),
                None,
            )
            .await
            .unwrap_err();

            assert_eq!(
                error.code,
                wallet_node_api::NOT_READY,
                "{message:?} must stay retryable"
            );
            assert_eq!(
                error.data.expect("data is present")["reason"],
                "gas_estimation_unavailable"
            );
        }
    }

    #[test]
    fn third_param_state_override_is_rejected_not_silently_dropped() {
        use serde_json::json;

        // ERC-4337 gives slot 3 of `eth_estimateUserOperationGas` to
        // `stateOverride`, and method.rs accepts that alias. Returning Ok(None)
        // for an object we don't understand would answer a spec-conforming
        // client with an estimate computed against state it never asked for.
        let policy = test_policy();
        for bad in [
            json!({ "0x1111111111111111111111111111111111111111": { "balance": "0x1" } }),
            json!({ "acknowledgedCallGasLimit": "0x1e8480", "stateOverride": {} }),
        ] {
            let params = vec![json!({}), json!("0x0"), bad];
            let error = super::parse_acknowledged_call_gas_limit(&params, &policy)
                .expect_err("an unrecognised third-param key must be rejected");
            assert_eq!(error.code, wallet_node_api::INVALID_REQUEST);
        }
    }

    #[test]
    fn parses_acknowledged_call_gas_limit_from_optional_third_param() {
        use serde_json::json;

        let policy = test_policy();
        let base = vec![json!({}), json!("0x0")];

        // Absent, explicit null, and an object without the key are all None.
        assert_eq!(
            super::parse_acknowledged_call_gas_limit(&base, &policy).unwrap(),
            None
        );
        let mut with_null = base.clone();
        with_null.push(json!(null));
        assert_eq!(
            super::parse_acknowledged_call_gas_limit(&with_null, &policy).unwrap(),
            None
        );
        let mut without_key = base.clone();
        without_key.push(json!({}));
        assert_eq!(
            super::parse_acknowledged_call_gas_limit(&without_key, &policy).unwrap(),
            None
        );

        let mut valid = base.clone();
        valid.push(json!({ "acknowledgedCallGasLimit": "0x1e8480" }));
        assert_eq!(
            super::parse_acknowledged_call_gas_limit(&valid, &policy).unwrap(),
            Some(U256::from(2_000_000u64))
        );

        // Wrong types and non-hex values are invalid params, not silent Nones.
        // Covers: a non-object third param, a non-string value under the key,
        // a string missing the `0x` prefix, and a `0x`-prefixed string with
        // non-hex digits.
        for bad in [
            json!(7),
            json!("nope"),
            json!({ "acknowledgedCallGasLimit": 7 }),
            json!({ "acknowledgedCallGasLimit": "12345" }),
            json!({ "acknowledgedCallGasLimit": "0xzz" }),
        ] {
            let mut params = base.clone();
            params.push(bad);
            let error = super::parse_acknowledged_call_gas_limit(&params, &policy)
                .expect_err("malformed override must be rejected");
            assert_eq!(error.code, wallet_node_api::INVALID_REQUEST);
        }
    }

    #[test]
    fn acknowledged_headroom_above_policy_cap_is_rejected() {
        use serde_json::json;

        let policy = test_policy();
        let params = vec![
            json!({}),
            json!("0x0"),
            // 10_000_001 > max_call_gas_limit of 10_000_000.
            json!({ "acknowledgedCallGasLimit": "0x989681" }),
        ];

        let error = super::parse_acknowledged_call_gas_limit(&params, &policy)
            .expect_err("an override above the policy cap must be rejected");

        assert_eq!(error.code, wallet_node_api::POLICY_CAP_EXCEEDED);
        assert_eq!(error.data.unwrap()["field"], "callGasLimit");
    }

    #[test]
    fn acknowledged_headroom_exactly_at_the_policy_cap_is_accepted() {
        use serde_json::json;

        // `parse_acknowledged_call_gas_limit` rejects with `>`, so `limit ==
        // max_call_gas_limit` must be accepted, not rejected -- a `>=` typo here
        // would reject every override once the cap binds, which is exactly the
        // common case: `suggested_unestimated_call_gas_limit` returns the cap
        // itself once its raw suggestion exceeds it, and the app echoes that
        // suggestion straight back as the acknowledgement.
        let policy = test_policy();
        let params = vec![
            json!({}),
            json!("0x0"),
            // Exactly max_call_gas_limit of 10_000_000.
            json!({ "acknowledgedCallGasLimit": "0x989680" }),
        ];

        assert_eq!(
            super::parse_acknowledged_call_gas_limit(&params, &policy).unwrap(),
            Some(policy.max_call_gas_limit)
        );
    }
}
