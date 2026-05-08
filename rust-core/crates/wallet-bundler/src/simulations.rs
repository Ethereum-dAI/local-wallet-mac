use std::collections::BTreeMap;

use alloy_primitives::{Address, Bytes, U256};
use alloy_sol_types::{sol, Revert, SolCall, SolError};
use sha2::{Digest, Sha256};
use wallet_chain::{
    AccountOverride, BlockTag, CallRequest, ChainAdapter, ChainError, StateOverride,
};

use crate::{BundlerError, Result, UserOperation};

pub const ENTRY_POINT_SIMULATIONS_RUNTIME_SHA256: &str =
    "1344b913c91c8390385f5a17d2b1cc1643e4d457932a6911d9bf45f6ef9a2fa8";

// Sourced from @account-abstraction/contracts@0.7.0, artifact
// artifacts/EntryPointSimulations.json, contract EntryPointSimulations.
// Source tag: eth-infinitism/account-abstraction v0.7.0
// Source commit checked locally: 7af70c8993a6f42973f520ae0752386a5032abe7
// Solidity compiler: 0.8.23; optimizer enabled, runs = 1_000_000.
pub const ENTRY_POINT_SIMULATIONS_SOURCE: &str =
    "npm:@account-abstraction/contracts@0.7.0/artifacts/EntryPointSimulations.json";
const ENTRY_POINT_SIMULATIONS_RUNTIME_HEX: &str =
    include_str!("entry_point_simulations_runtime.hex");

sol! {
    struct PackedUserOperationSol {
        address sender;
        uint256 nonce;
        bytes initCode;
        bytes callData;
        bytes32 accountGasLimits;
        uint256 preVerificationGas;
        bytes32 gasFees;
        bytes paymasterAndData;
        bytes signature;
    }

    struct StakeInfo {
        uint256 stake;
        uint256 unstakeDelaySec;
    }

    struct ReturnInfo {
        uint256 preOpGas;
        uint256 prefund;
        uint256 accountValidationData;
        uint256 paymasterValidationData;
        bytes paymasterContext;
    }

    struct AggregatorStakeInfo {
        address aggregator;
        StakeInfo stakeInfo;
    }

    struct ValidationResult {
        ReturnInfo returnInfo;
        StakeInfo senderInfo;
        StakeInfo factoryInfo;
        StakeInfo paymasterInfo;
        AggregatorStakeInfo aggregatorInfo;
    }

    function simulateValidation(PackedUserOperationSol userOp) returns (ValidationResult);

    error FailedOp(uint256 opIndex, string reason);
    error FailedOpWithRevert(uint256 opIndex, string reason, bytes inner);
    error SignatureValidationFailed(address aggregator);
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DecodedValidationResult {
    pub pre_op_gas: U256,
    pub prefund: U256,
    pub account_validation_data: U256,
    pub paymaster_validation_data: U256,
    pub sig_failed: bool,
    pub aggregator: Address,
    pub valid_after: u64,
    pub valid_until: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SimulationRevert {
    FailedOp {
        op_index: U256,
        reason: String,
    },
    FailedOpWithRevert {
        op_index: U256,
        reason: String,
        inner: Bytes,
    },
    SignatureValidationFailed {
        aggregator: Address,
    },
    ErrorString(String),
    Unknown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SimulationMode {
    Estimate,
    Submit,
}

pub fn encode_simulate_validation(op: &UserOperation) -> Result<Bytes> {
    let fields = op.pack_fields()?;
    let packed = PackedUserOperationSol {
        sender: op.sender,
        nonce: op.nonce,
        initCode: fields.init_code,
        callData: op.call_data.clone(),
        accountGasLimits: fields.account_gas_limits,
        preVerificationGas: op.pre_verification_gas,
        gasFees: fields.gas_fees,
        paymasterAndData: fields.paymaster_and_data,
        signature: op.signature.clone(),
    };
    Ok(Bytes::from(
        simulateValidationCall { userOp: packed }.abi_encode(),
    ))
}

pub fn simulations_state_override(entry_point: Address, runtime_bytecode: Bytes) -> StateOverride {
    let mut overrides = BTreeMap::new();
    overrides.insert(
        entry_point,
        AccountOverride {
            code: Some(runtime_bytecode),
            ..AccountOverride::default()
        },
    );
    overrides
}

pub fn entry_point_simulations_runtime_bytecode() -> Result<Bytes> {
    let hex = ENTRY_POINT_SIMULATIONS_RUNTIME_HEX
        .trim()
        .strip_prefix("0x")
        .ok_or_else(|| BundlerError::InvalidPinnedArtifact {
            reason: "runtime bytecode must be 0x-prefixed".to_string(),
        })?;
    let bytes = hex::decode(hex).map_err(|error| BundlerError::InvalidPinnedArtifact {
        reason: format!("runtime bytecode is not hex: {error}"),
    })?;
    let digest = Sha256::digest(&bytes);
    let actual = hex::encode(digest);
    if actual != ENTRY_POINT_SIMULATIONS_RUNTIME_SHA256 {
        return Err(BundlerError::InvalidPinnedArtifact {
            reason: format!(
                "runtime sha256 mismatch: expected {}, actual {}",
                ENTRY_POINT_SIMULATIONS_RUNTIME_SHA256, actual
            ),
        });
    }
    Ok(Bytes::from(bytes))
}

pub async fn simulate_validation(
    chain: &dyn ChainAdapter,
    entry_point: Address,
    op: &UserOperation,
    block: BlockTag,
    runtime_bytecode: Bytes,
) -> Result<DecodedValidationResult> {
    let tx = CallRequest {
        to: Some(entry_point),
        data: Some(encode_simulate_validation(op)?),
        ..CallRequest::default()
    };
    let raw = match chain
        .eth_call(
            tx,
            block,
            Some(simulations_state_override(entry_point, runtime_bytecode)),
        )
        .await
    {
        Ok(raw) => raw,
        Err(ChainError::CallReverted(data)) => {
            return Err(BundlerError::SimulationFailed {
                reason: simulation_revert_reason(&data),
            });
        }
        Err(error) => return Err(error.into()),
    };
    decode_validation_result(&raw)
}

pub fn validate_validation_result(
    result: &DecodedValidationResult,
    simulated_block_timestamp: u64,
    wall_now_timestamp: u64,
    min_submission_window_secs: u64,
    max_block_drift_secs: u64,
    mode: SimulationMode,
) -> Result<()> {
    if result.aggregator != Address::ZERO {
        return Err(BundlerError::SimulationFailed {
            reason: "aggregator_not_supported".to_string(),
        });
    }
    if result.paymaster_validation_data != U256::ZERO {
        return Err(BundlerError::SimulationFailed {
            reason: "paymaster_validation_not_supported".to_string(),
        });
    }
    if result.sig_failed && mode == SimulationMode::Submit {
        return Err(BundlerError::SimulationFailed {
            reason: "signature_validation_failed".to_string(),
        });
    }
    if result.valid_after > simulated_block_timestamp {
        return Err(BundlerError::SimulationFailed {
            reason: "valid_after_in_future".to_string(),
        });
    }
    let min_valid_until = simulated_block_timestamp.saturating_add(min_submission_window_secs);
    if result.valid_until != 0 && result.valid_until < min_valid_until {
        return Err(BundlerError::SimulationFailed {
            reason: "valid_until_too_soon".to_string(),
        });
    }
    if simulated_block_timestamp.saturating_add(max_block_drift_secs) < wall_now_timestamp {
        return Err(BundlerError::SimulationFailed {
            reason: "simulated_block_too_old".to_string(),
        });
    }
    Ok(())
}

pub fn decode_validation_result(raw: &[u8]) -> Result<DecodedValidationResult> {
    let decoded = simulateValidationCall::abi_decode_returns(raw).map_err(|error| {
        BundlerError::SimulationFailed {
            reason: format!("invalid_validation_result: {error}"),
        }
    })?;
    let return_info = decoded.returnInfo;
    let (authorizer, valid_after, valid_until) =
        unpack_validation_data(return_info.accountValidationData);
    let aggregator = if authorizer == Address::ZERO || authorizer == address_one() {
        Address::ZERO
    } else {
        authorizer
    };

    Ok(DecodedValidationResult {
        pre_op_gas: return_info.preOpGas,
        prefund: return_info.prefund,
        account_validation_data: return_info.accountValidationData,
        paymaster_validation_data: return_info.paymasterValidationData,
        sig_failed: authorizer == address_one(),
        aggregator,
        valid_after,
        valid_until,
    })
}

pub fn decode_simulation_revert(raw: &[u8]) -> SimulationRevert {
    if let Ok(error) = FailedOp::abi_decode(raw) {
        return SimulationRevert::FailedOp {
            op_index: error.opIndex,
            reason: error.reason,
        };
    }
    if let Ok(error) = FailedOpWithRevert::abi_decode(raw) {
        return SimulationRevert::FailedOpWithRevert {
            op_index: error.opIndex,
            reason: error.reason,
            inner: error.inner,
        };
    }
    if let Ok(error) = SignatureValidationFailed::abi_decode(raw) {
        return SimulationRevert::SignatureValidationFailed {
            aggregator: error.aggregator,
        };
    }
    if let Ok(error) = Revert::abi_decode(raw) {
        return SimulationRevert::ErrorString(error.reason);
    }
    SimulationRevert::Unknown
}

pub fn simulation_revert_reason(raw: &[u8]) -> String {
    match decode_simulation_revert(raw) {
        SimulationRevert::FailedOp { reason, .. } => reason,
        SimulationRevert::FailedOpWithRevert { reason, .. } => reason,
        SimulationRevert::SignatureValidationFailed { aggregator } => {
            format!("signature_validation_failed:{aggregator:#x}")
        }
        SimulationRevert::ErrorString(reason) => reason,
        SimulationRevert::Unknown => "unknown".to_string(),
    }
}

fn unpack_validation_data(data: U256) -> (Address, u64, u64) {
    let bytes = data.to_be_bytes::<32>();
    let authorizer = Address::from_slice(&bytes[12..32]);
    let valid_until = u64::from_be_bytes([
        0, 0, bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
    ]);
    let valid_after = u64::from_be_bytes([
        0, 0, bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
    ]);
    (authorizer, valid_after, valid_until)
}

fn address_one() -> Address {
    Address::from_slice(&[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
}

#[cfg(test)]
mod tests {
    use alloy_primitives::{address, Bytes, B256};
    use alloy_sol_types::SolCall;
    use serde_json::json;
    use wallet_chain::{BlockTag, MockChainAdapter};

    use super::*;

    fn sample_user_op() -> UserOperation {
        UserOperation::parse(json!({
            "sender": "0xd73c7780b1c1da1586a8332d5499f36b7cbb33c2",
            "nonce": "0x01",
            "callData": "0x",
            "callGasLimit": "0x10",
            "verificationGasLimit": "0x20",
            "preVerificationGas": "0x30",
            "maxFeePerGas": "0x40",
            "maxPriorityFeePerGas": "0x05",
            "signature": "0xab"
        }))
        .unwrap()
    }

    fn validation_result(account_validation_data: U256) -> ValidationResult {
        ValidationResult {
            returnInfo: ReturnInfo {
                preOpGas: U256::from(11),
                prefund: U256::from(22),
                accountValidationData: account_validation_data,
                paymasterValidationData: U256::ZERO,
                paymasterContext: Bytes::new(),
            },
            senderInfo: StakeInfo {
                stake: U256::ZERO,
                unstakeDelaySec: U256::ZERO,
            },
            factoryInfo: StakeInfo {
                stake: U256::ZERO,
                unstakeDelaySec: U256::ZERO,
            },
            paymasterInfo: StakeInfo {
                stake: U256::ZERO,
                unstakeDelaySec: U256::ZERO,
            },
            aggregatorInfo: AggregatorStakeInfo {
                aggregator: Address::ZERO,
                stakeInfo: StakeInfo {
                    stake: U256::ZERO,
                    unstakeDelaySec: U256::ZERO,
                },
            },
        }
    }

    #[test]
    fn simulate_validation_calldata_has_expected_selector() {
        let calldata = encode_simulate_validation(&sample_user_op()).unwrap();
        assert_eq!(&calldata[..4], &[0xc3, 0xbc, 0xe0, 0x09]);
    }

    #[test]
    fn pinned_entrypoint_simulations_runtime_hash_matches_artifact() {
        let bytecode = entry_point_simulations_runtime_bytecode().unwrap();
        assert_eq!(bytecode.len(), 21210);
    }

    #[test]
    fn decodes_validation_result_and_sig_failed_authorizer() {
        let data = U256::from(1);
        let encoded = simulateValidationCall::abi_encode_returns(&validation_result(data));

        let decoded = decode_validation_result(&encoded).unwrap();

        assert_eq!(decoded.pre_op_gas, U256::from(11));
        assert_eq!(decoded.prefund, U256::from(22));
        assert!(decoded.sig_failed);
        assert_eq!(decoded.aggregator, Address::ZERO);
    }

    #[test]
    fn decodes_aggregator_authorizer_without_confusing_sig_failed() {
        let aggregator = address!("1111111111111111111111111111111111111111");
        let data = U256::from_be_slice(aggregator.as_slice());
        let encoded = simulateValidationCall::abi_encode_returns(&validation_result(data));

        let decoded = decode_validation_result(&encoded).unwrap();

        assert!(!decoded.sig_failed);
        assert_eq!(decoded.aggregator, aggregator);
    }

    #[test]
    fn decodes_validation_time_bounds() {
        let valid_after = 1000u64;
        let valid_until = 2000u64;
        let data = (U256::from(valid_after) << 208) | (U256::from(valid_until) << 160);
        let encoded = simulateValidationCall::abi_encode_returns(&validation_result(data));

        let decoded = decode_validation_result(&encoded).unwrap();

        assert_eq!(decoded.valid_after, valid_after);
        assert_eq!(decoded.valid_until, valid_until);
    }

    #[test]
    fn decodes_entrypoint_simulation_reverts() {
        let failed = FailedOp {
            opIndex: U256::ZERO,
            reason: "AA21 didn't pay prefund".to_string(),
        }
        .abi_encode();
        assert_eq!(
            decode_simulation_revert(&failed),
            SimulationRevert::FailedOp {
                op_index: U256::ZERO,
                reason: "AA21 didn't pay prefund".to_string()
            }
        );

        let plain = Revert {
            reason: "factory panic".to_string(),
        }
        .abi_encode();
        assert_eq!(
            decode_simulation_revert(&plain),
            SimulationRevert::ErrorString("factory panic".to_string())
        );
    }

    #[tokio::test]
    async fn simulate_validation_uses_entrypoint_code_override() {
        let op = sample_user_op();
        let entry_point = crate::ENTRY_POINT_V07;
        let runtime_bytecode = Bytes::from_static(&[0x60, 0x00]);
        let block = BlockTag::Hash(B256::from([7; 32]));
        let tx = CallRequest {
            to: Some(entry_point),
            data: Some(encode_simulate_validation(&op).unwrap()),
            ..CallRequest::default()
        };
        let response = simulateValidationCall::abi_encode_returns(&validation_result(U256::ZERO));
        let chain = MockChainAdapter::new();
        chain.set_call_response(
            tx,
            block,
            Some(simulations_state_override(
                entry_point,
                runtime_bytecode.clone(),
            )),
            Bytes::from(response),
        );

        let decoded = simulate_validation(&chain, entry_point, &op, block, runtime_bytecode)
            .await
            .unwrap();

        assert_eq!(decoded.prefund, U256::from(22));
        assert_eq!(chain.call_call_count(), 1);
    }

    #[tokio::test]
    async fn simulate_validation_decodes_revert_bytes_from_chain_adapter() {
        let op = sample_user_op();
        let entry_point = crate::ENTRY_POINT_V07;
        let runtime_bytecode = Bytes::from_static(&[0x60, 0x00]);
        let block = BlockTag::Hash(B256::from([8; 32]));
        let tx = CallRequest {
            to: Some(entry_point),
            data: Some(encode_simulate_validation(&op).unwrap()),
            ..CallRequest::default()
        };
        let revert_data = FailedOp {
            opIndex: U256::ZERO,
            reason: "AA21 didn't pay prefund".to_string(),
        }
        .abi_encode();
        let chain = MockChainAdapter::new();
        chain.set_call_revert(
            tx,
            block,
            Some(simulations_state_override(
                entry_point,
                runtime_bytecode.clone(),
            )),
            Bytes::from(revert_data),
        );

        let err = simulate_validation(&chain, entry_point, &op, block, runtime_bytecode)
            .await
            .unwrap_err();

        assert!(matches!(
            err,
            BundlerError::SimulationFailed { reason } if reason == "AA21 didn't pay prefund"
        ));
    }

    #[test]
    fn estimate_mode_allows_sig_failed_but_still_rejects_expiring_userops() {
        let result = DecodedValidationResult {
            pre_op_gas: U256::ZERO,
            prefund: U256::ZERO,
            account_validation_data: U256::ZERO,
            paymaster_validation_data: U256::ZERO,
            sig_failed: true,
            aggregator: Address::ZERO,
            valid_after: 999,
            valid_until: 1059,
        };

        assert!(
            validate_validation_result(&result, 1000, 1000, 60, 90, SimulationMode::Estimate)
                .is_err()
        );

        let mut valid = result;
        valid.valid_until = 1060;
        validate_validation_result(&valid, 1000, 1000, 60, 90, SimulationMode::Estimate).unwrap();
    }

    #[test]
    fn submit_mode_rejects_sig_failed() {
        let result = DecodedValidationResult {
            pre_op_gas: U256::ZERO,
            prefund: U256::ZERO,
            account_validation_data: U256::ZERO,
            paymaster_validation_data: U256::ZERO,
            sig_failed: true,
            aggregator: Address::ZERO,
            valid_after: 0,
            valid_until: 0,
        };

        assert!(matches!(
            validate_validation_result(&result, 1000, 1000, 60, 90, SimulationMode::Submit),
            Err(BundlerError::SimulationFailed { reason }) if reason == "signature_validation_failed"
        ));
    }

    #[test]
    fn validation_result_rejects_stale_simulated_block_timestamp() {
        let result = DecodedValidationResult {
            pre_op_gas: U256::ZERO,
            prefund: U256::ZERO,
            account_validation_data: U256::ZERO,
            paymaster_validation_data: U256::ZERO,
            sig_failed: false,
            aggregator: Address::ZERO,
            valid_after: 0,
            valid_until: 0,
        };

        validate_validation_result(&result, 1000, 1090, 60, 90, SimulationMode::Submit).unwrap();
        assert!(matches!(
            validate_validation_result(&result, 1000, 1091, 60, 90, SimulationMode::Submit),
            Err(BundlerError::SimulationFailed { reason }) if reason == "simulated_block_too_old"
        ));
    }
}
