//! Shared, checked ERC-4337 v0.7 gas authorization policy.
//!
//! This crate deliberately has no daemon or application dependency. Both sides
//! can use the same packing, pre-verification-gas schedule, and liability math
//! without making an untrusted gas estimate an authorization decision.

use alloy_primitives::{Address, Bytes, FixedBytes, U256};
use alloy_sol_types::{sol, SolCall};
use thiserror::Error;
use wallet_signature::PackedUserOperation;

pub const V1_POLICY_VERSION: u32 = 1;
pub const V1_MAX_CALL_GAS_LIMIT: u64 = 10_000_000;
pub const V1_MAX_VERIFICATION_GAS_LIMIT: u64 = 5_000_000;
pub const V1_MAX_PRE_VERIFICATION_GAS: u64 = 1_000_000;
pub const V1_MAX_FEE_PER_GAS_WEI: u64 = 50_000_000_000;
pub const V1_MAX_PRIORITY_FEE_PER_GAS_WEI: u64 = 5_000_000_000;
pub const V1_OWNER_MAX_LIABILITY_WEI: u64 = 500_000_000_000_000_000;
pub const V1_SESSION_MAX_LIABILITY_WEI: u64 = 50_000_000_000_000_000;

/// EntryPoint v0.7 rejects every gas and fee value above `uint120::MAX`
/// (`AA94 gas values overflow`). This is stricter than the 16-byte packed slots.
pub const ENTRY_POINT_V07_FIELD_MAX: U256 =
    U256::from_limbs([u64::MAX, 0x00ff_ffff_ffff_ffff, 0, 0]);

const PRE_VERIFICATION_FIXED_OVERHEAD: u64 = 35_000;
const PRE_VERIFICATION_PER_USER_OP_OVERHEAD: u64 = 18_300;
const CALLDATA_ZERO_BYTE_GAS: u64 = 4;
const CALLDATA_NONZERO_BYTE_GAS: u64 = 16;
const PRE_VERIFICATION_PER_WORD_OVERHEAD: u64 = 4;
const PECTRA_STANDARD_TOKEN_COST: u64 = 4;
const PECTRA_TOTAL_COST_FLOOR_PER_TOKEN: u64 = 10;
const TRANSACTION_BASE_GAS: u64 = 21_000;
const SAFETY_MARGIN_NUMERATOR: u64 = 12_000;
const SAFETY_MARGIN_DENOMINATOR: u64 = 10_000;

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

    function handleOps(PackedUserOperationSol[] ops, address beneficiary);
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GasSchedule {
    EthereumPectraSingleOpV07V1,
}

impl GasSchedule {
    pub const fn policy_version(self) -> u32 {
        match self {
            Self::EthereumPectraSingleOpV07V1 => V1_POLICY_VERSION,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GasAuthorizationCaps {
    pub max_call_gas_limit: U256,
    pub max_verification_gas_limit: U256,
    pub max_pre_verification_gas: U256,
    pub max_fee_per_gas: U256,
    pub max_priority_fee_per_gas: U256,
    pub max_liability: U256,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GasAuthorizationInput {
    pub sender: Address,
    pub nonce: U256,
    pub init_code: Bytes,
    pub call_data: Bytes,
    pub call_gas_limit: U256,
    pub verification_gas_limit: U256,
    pub max_fee_per_gas: U256,
    pub max_priority_fee_per_gas: U256,
    pub paymaster_and_data: Bytes,
    pub signature_len: usize,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthorizedGasPlan {
    pub account_gas_limits: FixedBytes<32>,
    pub pre_verification_gas: U256,
    pub gas_fees: FixedBytes<32>,
    pub max_liability: U256,
    pub signature_len: usize,
    pub policy_version: u32,
}

#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum GasPolicyError {
    #[error("{field} exceeds EntryPoint v0.7 uint120")]
    EntryPointFieldWidth { field: &'static str },
    #[error("{field} exceeds the configured gas policy cap")]
    CapExceeded { field: &'static str },
    #[error("maxPriorityFeePerGas exceeds maxFeePerGas")]
    PriorityFeeAboveMaxFee,
    #[error("paymasters are not supported by this gas policy")]
    PaymasterNotSupported,
    #[error("arithmetic overflow while computing {operation}")]
    ArithmeticOverflow { operation: &'static str },
    #[error("signature length cannot be represented safely")]
    SignatureLengthTooLarge,
}

pub fn v1_owner_caps() -> GasAuthorizationCaps {
    GasAuthorizationCaps {
        max_call_gas_limit: U256::from(V1_MAX_CALL_GAS_LIMIT),
        max_verification_gas_limit: U256::from(V1_MAX_VERIFICATION_GAS_LIMIT),
        max_pre_verification_gas: U256::from(V1_MAX_PRE_VERIFICATION_GAS),
        max_fee_per_gas: U256::from(V1_MAX_FEE_PER_GAS_WEI),
        max_priority_fee_per_gas: U256::from(V1_MAX_PRIORITY_FEE_PER_GAS_WEI),
        max_liability: U256::from(V1_OWNER_MAX_LIABILITY_WEI),
    }
}

pub fn v1_session_caps(configured_session_gas_budget: U256) -> GasAuthorizationCaps {
    GasAuthorizationCaps {
        max_liability: configured_session_gas_budget.min(U256::from(V1_SESSION_MAX_LIABILITY_WEI)),
        ..v1_owner_caps()
    }
}

/// Authorize and pack every signed gas field for an operation without a
/// paymaster. The returned values, rather than daemon-provided equivalents, are
/// the values that must cross the signing boundary.
pub fn authorize_no_paymaster(
    input: &GasAuthorizationInput,
    caps: &GasAuthorizationCaps,
    schedule: GasSchedule,
) -> Result<AuthorizedGasPlan, GasPolicyError> {
    validate_input_before_estimation(input)?;
    check_cap(
        input.call_gas_limit,
        caps.max_call_gas_limit,
        "callGasLimit",
    )?;
    check_cap(
        input.verification_gas_limit,
        caps.max_verification_gas_limit,
        "verificationGasLimit",
    )?;
    check_cap(input.max_fee_per_gas, caps.max_fee_per_gas, "maxFeePerGas")?;
    check_cap(
        input.max_priority_fee_per_gas,
        caps.max_priority_fee_per_gas,
        "maxPriorityFeePerGas",
    )?;

    let pre_verification_gas = conservative_pre_verification_gas(input, schedule)?;
    validate_entrypoint_v07_width(
        input.call_gas_limit,
        input.verification_gas_limit,
        pre_verification_gas,
        input.max_fee_per_gas,
        input.max_priority_fee_per_gas,
    )?;
    check_cap(
        pre_verification_gas,
        caps.max_pre_verification_gas,
        "preVerificationGas",
    )?;

    let max_liability = checked_max_liability_no_paymaster(
        input.call_gas_limit,
        input.verification_gas_limit,
        pre_verification_gas,
        input.max_fee_per_gas,
    )?;
    check_cap(max_liability, caps.max_liability, "maxLiability")?;

    Ok(AuthorizedGasPlan {
        account_gas_limits: pack_u128_pair(input.verification_gas_limit, input.call_gas_limit),
        pre_verification_gas,
        gas_fees: pack_u128_pair(input.max_priority_fee_per_gas, input.max_fee_per_gas),
        max_liability,
        signature_len: input.signature_len,
        policy_version: schedule.policy_version(),
    })
}

/// Conservative, versioned pre-verification-gas calculation for a single
/// EntryPoint v0.7 operation on an Ethereum network with EIP-7623 active.
pub fn conservative_pre_verification_gas(
    input: &GasAuthorizationInput,
    schedule: GasSchedule,
) -> Result<U256, GasPolicyError> {
    validate_input_before_estimation(input)?;

    match schedule {
        GasSchedule::EthereumPectraSingleOpV07V1 => conservative_pectra_single_op_v07_v1(input),
    }
}

pub fn checked_max_liability_no_paymaster(
    call_gas_limit: U256,
    verification_gas_limit: U256,
    pre_verification_gas: U256,
    max_fee_per_gas: U256,
) -> Result<U256, GasPolicyError> {
    let gas_limit_sum = call_gas_limit
        .checked_add(verification_gas_limit)
        .and_then(|sum| sum.checked_add(pre_verification_gas))
        .ok_or(GasPolicyError::ArithmeticOverflow {
            operation: "gas limit sum",
        })?;
    gas_limit_sum
        .checked_mul(max_fee_per_gas)
        .ok_or(GasPolicyError::ArithmeticOverflow {
            operation: "maximum liability",
        })
}

pub fn validate_entrypoint_v07_width(
    call_gas_limit: U256,
    verification_gas_limit: U256,
    pre_verification_gas: U256,
    max_fee_per_gas: U256,
    max_priority_fee_per_gas: U256,
) -> Result<(), GasPolicyError> {
    for (field, value) in [
        ("callGasLimit", call_gas_limit),
        ("verificationGasLimit", verification_gas_limit),
        ("preVerificationGas", pre_verification_gas),
        ("maxFeePerGas", max_fee_per_gas),
        ("maxPriorityFeePerGas", max_priority_fee_per_gas),
    ] {
        if value > ENTRY_POINT_V07_FIELD_MAX {
            return Err(GasPolicyError::EntryPointFieldWidth { field });
        }
    }
    Ok(())
}

/// Exact ABI encoding shared by gas accounting and the bundler transaction
/// builder. Keeping one encoder prevents their packed layouts from drifting.
pub fn encode_single_handle_ops(
    op: &PackedUserOperation,
    signature: &[u8],
    beneficiary: Address,
) -> Bytes {
    let packed = PackedUserOperationSol {
        sender: op.sender,
        nonce: op.nonce,
        initCode: op.init_code.clone(),
        callData: op.call_data.clone(),
        accountGasLimits: op.account_gas_limits,
        preVerificationGas: op.pre_verification_gas,
        gasFees: op.gas_fees,
        paymasterAndData: op.paymaster_and_data.clone(),
        signature: Bytes::copy_from_slice(signature),
    };
    Bytes::from(
        handleOpsCall {
            ops: vec![packed],
            beneficiary,
        }
        .abi_encode(),
    )
}

fn validate_input_before_estimation(input: &GasAuthorizationInput) -> Result<(), GasPolicyError> {
    if !input.paymaster_and_data.is_empty() {
        return Err(GasPolicyError::PaymasterNotSupported);
    }
    if input.max_priority_fee_per_gas > input.max_fee_per_gas {
        return Err(GasPolicyError::PriorityFeeAboveMaxFee);
    }
    validate_entrypoint_v07_width(
        input.call_gas_limit,
        input.verification_gas_limit,
        U256::ZERO,
        input.max_fee_per_gas,
        input.max_priority_fee_per_gas,
    )
}

fn conservative_pectra_single_op_v07_v1(
    input: &GasAuthorizationInput,
) -> Result<U256, GasPolicyError> {
    let packed = PackedUserOperation {
        sender: input.sender,
        nonce: input.nonce,
        init_code: input.init_code.clone(),
        call_data: input.call_data.clone(),
        account_gas_limits: pack_u128_pair(input.verification_gas_limit, input.call_gas_limit),
        // This word is part of the calldata whose cost we are calculating. An
        // all-nonzero placeholder makes the circular dependency conservative.
        pre_verification_gas: U256::MAX,
        gas_fees: pack_u128_pair(input.max_priority_fee_per_gas, input.max_fee_per_gas),
        paymaster_and_data: input.paymaster_and_data.clone(),
    };
    let mut signature = Vec::new();
    signature
        .try_reserve_exact(input.signature_len)
        .map_err(|_| GasPolicyError::SignatureLengthTooLarge)?;
    signature.resize(input.signature_len, 0xff);
    let calldata = encode_single_handle_ops(&packed, &signature, Address::from([0xff; 20]));

    let calldata_len =
        u64::try_from(calldata.len()).map_err(|_| GasPolicyError::ArithmeticOverflow {
            operation: "calldata length",
        })?;
    let zero_bytes =
        u64::try_from(calldata.iter().filter(|byte| **byte == 0).count()).map_err(|_| {
            GasPolicyError::ArithmeticOverflow {
                operation: "calldata length",
            }
        })?;
    let nonzero_bytes = calldata_len - zero_bytes;

    let calldata_gas = checked_mul_u64(zero_bytes, CALLDATA_ZERO_BYTE_GAS, "calldata gas")?
        .checked_add(checked_mul_u64(
            nonzero_bytes,
            CALLDATA_NONZERO_BYTE_GAS,
            "calldata gas",
        )?)
        .ok_or(GasPolicyError::ArithmeticOverflow {
            operation: "calldata gas",
        })?;
    let word_overhead = U256::from(calldata_len.div_ceil(32))
        .checked_mul(U256::from(PRE_VERIFICATION_PER_WORD_OVERHEAD))
        .ok_or(GasPolicyError::ArithmeticOverflow {
            operation: "word overhead",
        })?;
    let legacy = checked_sum(
        [
            U256::from(PRE_VERIFICATION_FIXED_OVERHEAD),
            U256::from(PRE_VERIFICATION_PER_USER_OP_OVERHEAD),
            word_overhead,
            calldata_gas,
        ],
        "legacy pre-verification gas",
    )?;

    let calldata_tokens = U256::from(zero_bytes)
        .checked_add(checked_mul_u64(
            nonzero_bytes,
            PECTRA_STANDARD_TOKEN_COST,
            "calldata tokens",
        )?)
        .ok_or(GasPolicyError::ArithmeticOverflow {
            operation: "calldata tokens",
        })?;
    let floor_variable = calldata_tokens
        .checked_mul(U256::from(PECTRA_TOTAL_COST_FLOOR_PER_TOKEN))
        .ok_or(GasPolicyError::ArithmeticOverflow {
            operation: "Pectra calldata floor",
        })?;
    let pectra_floor = U256::from(TRANSACTION_BASE_GAS)
        .checked_add(floor_variable)
        .ok_or(GasPolicyError::ArithmeticOverflow {
            operation: "Pectra calldata floor",
        })?;

    let selected = legacy.max(pectra_floor);
    let with_margin = selected
        .checked_mul(U256::from(SAFETY_MARGIN_NUMERATOR))
        .ok_or(GasPolicyError::ArithmeticOverflow {
            operation: "pre-verification safety margin",
        })?;
    checked_ceil_div(
        with_margin,
        U256::from(SAFETY_MARGIN_DENOMINATOR),
        "pre-verification safety margin",
    )
}

fn checked_mul_u64(left: u64, right: u64, operation: &'static str) -> Result<U256, GasPolicyError> {
    U256::from(left)
        .checked_mul(U256::from(right))
        .ok_or(GasPolicyError::ArithmeticOverflow { operation })
}

fn checked_sum<const N: usize>(
    values: [U256; N],
    operation: &'static str,
) -> Result<U256, GasPolicyError> {
    values.into_iter().try_fold(U256::ZERO, |sum, value| {
        sum.checked_add(value)
            .ok_or(GasPolicyError::ArithmeticOverflow { operation })
    })
}

fn checked_ceil_div(
    numerator: U256,
    denominator: U256,
    operation: &'static str,
) -> Result<U256, GasPolicyError> {
    let quotient = numerator / denominator;
    if numerator % denominator == U256::ZERO {
        return Ok(quotient);
    }
    quotient
        .checked_add(U256::from(1))
        .ok_or(GasPolicyError::ArithmeticOverflow { operation })
}

fn pack_u128_pair(high: U256, low: U256) -> FixedBytes<32> {
    // Callers validate the stricter uint120 EntryPoint bound first, so taking
    // the low 16 bytes is a representation conversion rather than truncation.
    let high = high.to_be_bytes::<32>();
    let low = low.to_be_bytes::<32>();
    let mut packed = [0_u8; 32];
    packed[..16].copy_from_slice(&high[16..]);
    packed[16..].copy_from_slice(&low[16..]);
    FixedBytes::from(packed)
}

fn check_cap(value: U256, cap: U256, field: &'static str) -> Result<(), GasPolicyError> {
    if value > cap {
        return Err(GasPolicyError::CapExceeded { field });
    }
    Ok(())
}
