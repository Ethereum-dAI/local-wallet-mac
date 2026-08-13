use alloy_primitives::{Address, U256};
use wallet_userop_policy::{
    AuthorizedGasPlan, GasAuthorizationCaps, GasAuthorizationInput, GasPolicyError, GasSchedule,
};

use crate::{BundlerError, Result, UserOperation};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PolicyMode {
    Estimate,
    Submit,
}

/// Hard invariants the daemon enforces on every accepted UserOp, surfaced
/// as data so a reader can see them in one place.
///
/// `LOCAL_WALLET_V1` matches what the daemon shipped before this struct
/// existed. A fork that wants different invariants replaces the constant.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BundlerPolicyInvariants {
    /// Reject UserOps with non-empty paymaster fields.
    pub reject_paymaster: bool,
    /// Maximum number of UserOps per `handleOps` bundle the daemon will pack.
    /// Informational at the policy layer; the daemon enforces it at submit time.
    pub max_user_ops_per_bundle: u32,
    /// Required nonce key for accepted UserOps. `None` = any. Currently the
    /// nonce-key check lives in the allowlist layer (`validate_kernel_nonce_key`);
    /// surfacing it here documents the invariant for forks.
    pub required_nonce_key: Option<U256>,
}

impl BundlerPolicyInvariants {
    pub const LOCAL_WALLET_V1: Self = Self {
        reject_paymaster: true,
        max_user_ops_per_bundle: 1,
        required_nonce_key: Some(U256::ZERO),
    };
}

#[derive(Clone, Debug)]
pub struct BundlerPolicy {
    pub chain_id: u64,
    pub entry_points: Vec<Address>,
    pub max_call_gas_limit: U256,
    pub max_verification_gas_limit: U256,
    pub max_pre_verification_gas: U256,
    pub max_fee_per_gas: U256,
    pub max_priority_fee_per_gas: U256,
    pub invariants: BundlerPolicyInvariants,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BundlerTxFees {
    pub max_fee_per_gas: U256,
    pub max_priority_fee_per_gas: U256,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PolicyError {
    EntrypointNotAllowlisted,
    ChainMismatch,
    PaymasterNotSupported,
    SignatureMissing,
    CapExceeded(&'static str),
    PriorityFeeAboveMaxFee,
    ArithmeticOverflow(&'static str),
    FinalizedGasMismatch(&'static str),
    SignatureLengthTooLarge,
    ReplacementNotPossible(&'static str),
}

pub fn validate_user_operation(
    policy: &BundlerPolicy,
    op: &UserOperation,
    entry_point: Address,
    chain_id: u64,
    mode: PolicyMode,
) -> std::result::Result<(), PolicyError> {
    if chain_id != policy.chain_id {
        return Err(PolicyError::ChainMismatch);
    }
    if !policy.entry_points.contains(&entry_point) {
        return Err(PolicyError::EntrypointNotAllowlisted);
    }
    if policy.invariants.reject_paymaster
        && (op.paymaster.is_some()
            || op.paymaster_verification_gas_limit.is_some()
            || op.paymaster_post_op_gas_limit.is_some()
            || !op.paymaster_data.is_empty())
    {
        return Err(PolicyError::PaymasterNotSupported);
    }
    if mode == PolicyMode::Submit && op.signature.is_empty() {
        return Err(PolicyError::SignatureMissing);
    }
    authorize_user_operation_gas(policy, op)?;
    wallet_userop_policy::validate_entrypoint_v07_width(
        op.call_gas_limit,
        op.verification_gas_limit,
        op.pre_verification_gas,
        op.max_fee_per_gas,
        op.max_priority_fee_per_gas,
    )
    .map_err(map_gas_policy_error)?;
    if op.pre_verification_gas > policy.max_pre_verification_gas {
        return Err(PolicyError::CapExceeded("preVerificationGas"));
    }
    Ok(())
}

/// Derive the only gas plan the daemon is willing to estimate, sign, or submit.
/// Configured daemon caps may tighten the shared v1 policy, but cannot widen it.
pub fn authorize_user_operation_gas(
    policy: &BundlerPolicy,
    op: &UserOperation,
) -> std::result::Result<AuthorizedGasPlan, PolicyError> {
    let shared_caps = wallet_userop_policy::v1_owner_caps();
    let caps = GasAuthorizationCaps {
        max_call_gas_limit: policy
            .max_call_gas_limit
            .min(shared_caps.max_call_gas_limit),
        max_verification_gas_limit: policy
            .max_verification_gas_limit
            .min(shared_caps.max_verification_gas_limit),
        max_pre_verification_gas: policy
            .max_pre_verification_gas
            .min(shared_caps.max_pre_verification_gas),
        max_fee_per_gas: policy.max_fee_per_gas.min(shared_caps.max_fee_per_gas),
        max_priority_fee_per_gas: policy
            .max_priority_fee_per_gas
            .min(shared_caps.max_priority_fee_per_gas),
        max_liability: shared_caps.max_liability,
    };
    wallet_userop_policy::authorize_no_paymaster(
        &gas_authorization_input(op),
        &caps,
        GasSchedule::EthereumPectraSingleOpV07V1,
    )
    .map_err(map_gas_policy_error)
}

/// Recompute the shared plan after estimation and again before submission.
/// A caller-supplied preVerificationGas is never an authorization decision.
pub fn validate_finalized_user_operation_gas(
    policy: &BundlerPolicy,
    op: &UserOperation,
) -> std::result::Result<AuthorizedGasPlan, PolicyError> {
    let plan = authorize_user_operation_gas(policy, op)?;
    if op.pre_verification_gas != plan.pre_verification_gas {
        return Err(PolicyError::FinalizedGasMismatch("preVerificationGas"));
    }
    let fields = op.pack_fields().map_err(|error| match error {
        BundlerError::PolicyCapExceeded { field } => PolicyError::CapExceeded(field),
        _ => PolicyError::FinalizedGasMismatch("packedGasFields"),
    })?;
    if fields.account_gas_limits != plan.account_gas_limits {
        return Err(PolicyError::FinalizedGasMismatch("accountGasLimits"));
    }
    if fields.gas_fees != plan.gas_fees {
        return Err(PolicyError::FinalizedGasMismatch("gasFees"));
    }
    Ok(plan)
}

fn gas_authorization_input(op: &UserOperation) -> GasAuthorizationInput {
    let mut init_code = Vec::new();
    if let Some(factory) = op.factory {
        init_code.extend_from_slice(factory.as_slice());
        init_code.extend_from_slice(&op.factory_data);
    }

    let mut paymaster_and_data = Vec::new();
    if let Some(paymaster) = op.paymaster {
        paymaster_and_data.extend_from_slice(paymaster.as_slice());
    }
    if op.paymaster_verification_gas_limit.is_some()
        || op.paymaster_post_op_gas_limit.is_some()
        || !op.paymaster_data.is_empty()
    {
        // The shared policy only needs to know this input is non-empty because
        // v1 rejects every paymaster shape before packing it.
        paymaster_and_data.push(1);
    }

    GasAuthorizationInput {
        sender: op.sender,
        nonce: op.nonce,
        init_code: init_code.into(),
        call_data: op.call_data.clone(),
        call_gas_limit: op.call_gas_limit,
        verification_gas_limit: op.verification_gas_limit,
        max_fee_per_gas: op.max_fee_per_gas,
        max_priority_fee_per_gas: op.max_priority_fee_per_gas,
        paymaster_and_data: paymaster_and_data.into(),
        signature_len: op.signature.len(),
    }
}

fn map_gas_policy_error(error: GasPolicyError) -> PolicyError {
    match error {
        GasPolicyError::EntryPointFieldWidth { field } | GasPolicyError::CapExceeded { field } => {
            PolicyError::CapExceeded(field)
        }
        GasPolicyError::PriorityFeeAboveMaxFee => PolicyError::PriorityFeeAboveMaxFee,
        GasPolicyError::PaymasterNotSupported => PolicyError::PaymasterNotSupported,
        GasPolicyError::ArithmeticOverflow { operation } => {
            PolicyError::ArithmeticOverflow(operation)
        }
        GasPolicyError::SignatureLengthTooLarge => PolicyError::SignatureLengthTooLarge,
    }
}

pub fn validate_bundler_tx_fee_invariant(
    op: &UserOperation,
    tx_fees: BundlerTxFees,
) -> std::result::Result<(), PolicyError> {
    if tx_fees.max_fee_per_gas > op.max_fee_per_gas {
        return Err(PolicyError::CapExceeded("bundlerTx.maxFeePerGas"));
    }
    if tx_fees.max_priority_fee_per_gas > op.max_priority_fee_per_gas {
        return Err(PolicyError::CapExceeded("bundlerTx.maxPriorityFeePerGas"));
    }
    Ok(())
}

pub fn validate_relayer_replacement_fee_budget(
    op: &UserOperation,
    tx_fees: BundlerTxFees,
    max_relayer_bump_pct: f64,
) -> std::result::Result<(), PolicyError> {
    if !max_relayer_bump_pct.is_finite() || max_relayer_bump_pct < 0.0 {
        return Err(PolicyError::ReplacementNotPossible(
            "invalid_relayer_bump_budget",
        ));
    }
    let bump_bps = (max_relayer_bump_pct * 100.0).ceil() as u64;
    let multiplier_bps = U256::from(10_000_u64 + bump_bps);
    let divisor_bps = U256::from(10_000_u64);
    let fee_ceiling = ceil_div(op.max_fee_per_gas * multiplier_bps, divisor_bps);
    let priority_ceiling = ceil_div(op.max_priority_fee_per_gas * multiplier_bps, divisor_bps);
    if tx_fees.max_fee_per_gas > fee_ceiling {
        return Err(PolicyError::CapExceeded("bundlerTx.maxFeePerGas"));
    }
    if tx_fees.max_priority_fee_per_gas > priority_ceiling {
        return Err(PolicyError::CapExceeded("bundlerTx.maxPriorityFeePerGas"));
    }
    Ok(())
}

pub fn bumped_replacement_fees(
    previous: BundlerTxFees,
    op: &UserOperation,
    min_bump_pct: f64,
) -> std::result::Result<BundlerTxFees, PolicyError> {
    let bumped = bumped_transaction_fees(previous, min_bump_pct)?;
    validate_bundler_tx_fee_invariant(op, bumped)?;
    Ok(bumped)
}

pub fn bumped_transaction_fees(
    previous: BundlerTxFees,
    min_bump_pct: f64,
) -> std::result::Result<BundlerTxFees, PolicyError> {
    if !min_bump_pct.is_finite() || min_bump_pct <= 0.0 {
        return Err(PolicyError::ReplacementNotPossible("invalid_bump_pct"));
    }
    let bump_bps = (min_bump_pct * 100.0).ceil() as u64;
    let multiplier_bps = U256::from(10_000_u64 + bump_bps);
    let divisor_bps = U256::from(10_000_u64);
    Ok(BundlerTxFees {
        max_fee_per_gas: ceil_div(previous.max_fee_per_gas * multiplier_bps, divisor_bps),
        max_priority_fee_per_gas: ceil_div(
            previous.max_priority_fee_per_gas * multiplier_bps,
            divisor_bps,
        ),
    })
}

pub fn bumped_replacement_fees_with_budget(
    previous: BundlerTxFees,
    op: &UserOperation,
    min_bump_pct: f64,
    max_relayer_bump_pct: f64,
) -> std::result::Result<BundlerTxFees, PolicyError> {
    let bumped = bumped_transaction_fees(previous, min_bump_pct)?;
    validate_relayer_replacement_fee_budget(op, bumped, max_relayer_bump_pct)?;
    Ok(bumped)
}

fn ceil_div(numerator: U256, denominator: U256) -> U256 {
    if numerator.is_zero() {
        return U256::ZERO;
    }
    ((numerator - U256::from(1)) / denominator) + U256::from(1)
}

impl PolicyError {
    pub fn into_bundler_error(
        self,
        policy: &BundlerPolicy,
        entry_point: Address,
        chain_id: u64,
    ) -> BundlerError {
        match self {
            PolicyError::EntrypointNotAllowlisted => {
                BundlerError::EntrypointNotAllowlisted(format!("{entry_point:#x}"))
            }
            PolicyError::ChainMismatch => BundlerError::ChainMismatch {
                expected: policy.chain_id,
                actual: chain_id,
            },
            PolicyError::PaymasterNotSupported => BundlerError::PaymasterNotSupported,
            PolicyError::SignatureMissing => BundlerError::SignatureMissing,
            PolicyError::CapExceeded(field) => BundlerError::PolicyCapExceeded { field },
            PolicyError::PriorityFeeAboveMaxFee => BundlerError::InvalidUserOperation(
                "maxPriorityFeePerGas exceeds maxFeePerGas".to_string(),
            ),
            PolicyError::ArithmeticOverflow(operation) => BundlerError::InvalidUserOperation(
                format!("arithmetic overflow while computing {operation}"),
            ),
            PolicyError::FinalizedGasMismatch(field) => BundlerError::InvalidUserOperation(
                format!("{field} does not match the authorized gas plan"),
            ),
            PolicyError::SignatureLengthTooLarge => BundlerError::InvalidUserOperation(
                "signature length cannot be represented safely".to_string(),
            ),
            PolicyError::ReplacementNotPossible(reason) => {
                BundlerError::ReplacementNotPossible { reason }
            }
        }
    }
}

pub fn parse_u256_config(field: &'static str, value: &str) -> Result<U256> {
    U256::from_str_radix(value.strip_prefix("0x").unwrap_or(value), 16)
        .map_err(|_| BundlerError::PolicyCapExceeded { field })
}

#[cfg(test)]
mod tests {
    use alloy_primitives::{address, U256};
    use serde_json::json;

    use super::*;

    fn policy() -> BundlerPolicy {
        BundlerPolicy {
            chain_id: 1,
            entry_points: vec![crate::ENTRY_POINT_V07],
            max_call_gas_limit: U256::from(100),
            max_verification_gas_limit: U256::from(100),
            max_pre_verification_gas: U256::from(1_000_000),
            max_fee_per_gas: U256::from(100),
            max_priority_fee_per_gas: U256::from(100),
            invariants: BundlerPolicyInvariants::LOCAL_WALLET_V1,
        }
    }

    fn op() -> UserOperation {
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

    #[test]
    fn rejects_non_allowlisted_entrypoint() {
        let err = validate_user_operation(
            &policy(),
            &op(),
            address!("0000000000000000000000000000000000000001"),
            1,
            PolicyMode::Submit,
        )
        .unwrap_err();
        assert_eq!(err, PolicyError::EntrypointNotAllowlisted);
    }

    #[test]
    fn estimate_allows_empty_signature_but_submit_rejects_it() {
        let mut op = op();
        op.signature = Default::default();
        assert!(validate_user_operation(
            &policy(),
            &op,
            crate::ENTRY_POINT_V07,
            1,
            PolicyMode::Estimate,
        )
        .is_ok());
        assert_eq!(
            validate_user_operation(
                &policy(),
                &op,
                crate::ENTRY_POINT_V07,
                1,
                PolicyMode::Submit
            )
            .unwrap_err(),
            PolicyError::SignatureMissing
        );
    }

    #[test]
    fn rejects_paymaster_fields_before_simulation() {
        let mut op = op();
        op.paymaster = Some(address!("0000000000000000000000000000000000000001"));
        assert_eq!(
            validate_user_operation(
                &policy(),
                &op,
                crate::ENTRY_POINT_V07,
                1,
                PolicyMode::Submit
            )
            .unwrap_err(),
            PolicyError::PaymasterNotSupported
        );
    }

    #[test]
    fn rejects_priority_fee_above_max_fee_before_simulation() {
        let mut op = op();
        op.max_priority_fee_per_gas = op.max_fee_per_gas + U256::from(1);

        assert_eq!(
            validate_user_operation(
                &policy(),
                &op,
                crate::ENTRY_POINT_V07,
                1,
                PolicyMode::Estimate
            )
            .unwrap_err(),
            PolicyError::PriorityFeeAboveMaxFee
        );
    }

    #[test]
    fn finalized_gas_must_exactly_match_shared_authorization() {
        let mut op = op();
        let plan = authorize_user_operation_gas(&policy(), &op).unwrap();
        op.pre_verification_gas = plan.pre_verification_gas;

        assert_eq!(
            validate_finalized_user_operation_gas(&policy(), &op)
                .unwrap()
                .max_liability,
            op.required_prefund().unwrap()
        );

        op.pre_verification_gas += U256::from(1);
        assert_eq!(
            validate_finalized_user_operation_gas(&policy(), &op).unwrap_err(),
            PolicyError::FinalizedGasMismatch("preVerificationGas")
        );
    }

    #[test]
    fn entrypoint_uint120_boundary_is_enforced_even_if_config_is_wider() {
        let mut policy = policy();
        policy.max_call_gas_limit = U256::MAX;
        let mut op = op();
        op.call_gas_limit = wallet_userop_policy::ENTRY_POINT_V07_FIELD_MAX + U256::from(1);

        assert_eq!(
            validate_user_operation(
                &policy,
                &op,
                crate::ENTRY_POINT_V07,
                1,
                PolicyMode::Estimate
            )
            .unwrap_err(),
            PolicyError::CapExceeded("callGasLimit")
        );
    }

    #[test]
    fn total_liability_cap_rejects_individually_bounded_fields() {
        let mut policy = policy();
        policy.max_call_gas_limit = U256::from(10_000_000_u64);
        policy.max_verification_gas_limit = U256::from(5_000_000_u64);
        policy.max_fee_per_gas = U256::from(50_000_000_000_u64);
        policy.max_priority_fee_per_gas = U256::from(5_000_000_000_u64);
        let mut op = op();
        op.call_gas_limit = policy.max_call_gas_limit;
        op.verification_gas_limit = policy.max_verification_gas_limit;
        op.max_fee_per_gas = policy.max_fee_per_gas;
        op.max_priority_fee_per_gas = policy.max_priority_fee_per_gas;

        assert_eq!(
            authorize_user_operation_gas(&policy, &op).unwrap_err(),
            PolicyError::CapExceeded("maxLiability")
        );
    }

    #[test]
    fn bundler_tx_fee_invariant_allows_equal_or_lower_tx_fees() {
        let op = op();

        assert!(validate_bundler_tx_fee_invariant(
            &op,
            BundlerTxFees {
                max_fee_per_gas: op.max_fee_per_gas,
                max_priority_fee_per_gas: op.max_priority_fee_per_gas,
            }
        )
        .is_ok());
        assert!(validate_bundler_tx_fee_invariant(
            &op,
            BundlerTxFees {
                max_fee_per_gas: op.max_fee_per_gas - U256::from(1),
                max_priority_fee_per_gas: op.max_priority_fee_per_gas - U256::from(1),
            }
        )
        .is_ok());
    }

    #[test]
    fn bundler_tx_fee_invariant_rejects_subsidizing_fees() {
        let op = op();

        assert_eq!(
            validate_bundler_tx_fee_invariant(
                &op,
                BundlerTxFees {
                    max_fee_per_gas: op.max_fee_per_gas + U256::from(1),
                    max_priority_fee_per_gas: op.max_priority_fee_per_gas,
                }
            )
            .unwrap_err(),
            PolicyError::CapExceeded("bundlerTx.maxFeePerGas")
        );
        assert_eq!(
            validate_bundler_tx_fee_invariant(
                &op,
                BundlerTxFees {
                    max_fee_per_gas: op.max_fee_per_gas,
                    max_priority_fee_per_gas: op.max_priority_fee_per_gas + U256::from(1),
                }
            )
            .unwrap_err(),
            PolicyError::CapExceeded("bundlerTx.maxPriorityFeePerGas")
        );
    }

    #[test]
    fn bumped_replacement_fees_round_up_and_respect_userop_caps() {
        let op = op();
        let bumped = bumped_replacement_fees(
            BundlerTxFees {
                max_fee_per_gas: U256::from(10),
                max_priority_fee_per_gas: U256::from(2),
            },
            &op,
            12.5,
        )
        .unwrap();

        assert_eq!(
            bumped,
            BundlerTxFees {
                max_fee_per_gas: U256::from(12),
                max_priority_fee_per_gas: U256::from(3),
            }
        );

        assert_eq!(
            bumped_replacement_fees(
                BundlerTxFees {
                    max_fee_per_gas: op.max_fee_per_gas,
                    max_priority_fee_per_gas: op.max_priority_fee_per_gas,
                },
                &op,
                12.5,
            )
            .unwrap_err(),
            PolicyError::CapExceeded("bundlerTx.maxFeePerGas")
        );
    }

    #[test]
    fn bumped_transaction_fees_round_up_without_userop_caps() {
        let bumped = bumped_transaction_fees(
            BundlerTxFees {
                max_fee_per_gas: U256::from(64),
                max_priority_fee_per_gas: U256::from(5),
            },
            12.5,
        )
        .unwrap();

        assert_eq!(
            bumped,
            BundlerTxFees {
                max_fee_per_gas: U256::from(72),
                max_priority_fee_per_gas: U256::from(6),
            }
        );
    }

    #[test]
    fn relayer_replacement_fee_budget_allows_up_to_ceiling_and_rejects_above() {
        let op = op();
        assert!(validate_relayer_replacement_fee_budget(
            &op,
            BundlerTxFees {
                max_fee_per_gas: U256::from(72),
                max_priority_fee_per_gas: U256::from(5),
            },
            50.0,
        )
        .is_ok());
        assert!(validate_relayer_replacement_fee_budget(
            &op,
            BundlerTxFees {
                max_fee_per_gas: U256::from(96),
                max_priority_fee_per_gas: U256::from(8),
            },
            50.0,
        )
        .is_ok());
        assert_eq!(
            validate_relayer_replacement_fee_budget(
                &op,
                BundlerTxFees {
                    max_fee_per_gas: U256::from(97),
                    max_priority_fee_per_gas: U256::from(5),
                },
                50.0,
            )
            .unwrap_err(),
            PolicyError::CapExceeded("bundlerTx.maxFeePerGas")
        );
        assert_eq!(
            validate_relayer_replacement_fee_budget(
                &op,
                BundlerTxFees {
                    max_fee_per_gas: U256::from(64),
                    max_priority_fee_per_gas: U256::from(9),
                },
                50.0,
            )
            .unwrap_err(),
            PolicyError::CapExceeded("bundlerTx.maxPriorityFeePerGas")
        );
    }

    #[test]
    fn bumped_replacement_relayer_fee_allows_12_5pct_above_op_cap() {
        let op = op();
        let bumped = bumped_replacement_fees_with_budget(
            BundlerTxFees {
                max_fee_per_gas: U256::from(64),
                max_priority_fee_per_gas: U256::from(5),
            },
            &op,
            12.5,
            50.0,
        )
        .unwrap();

        assert_eq!(
            bumped,
            BundlerTxFees {
                max_fee_per_gas: U256::from(72),
                max_priority_fee_per_gas: U256::from(6),
            }
        );
        assert_eq!(
            bumped_replacement_fees_with_budget(
                BundlerTxFees {
                    max_fee_per_gas: U256::from(90),
                    max_priority_fee_per_gas: U256::from(5),
                },
                &op,
                12.5,
                10.0,
            )
            .unwrap_err(),
            PolicyError::CapExceeded("bundlerTx.maxFeePerGas")
        );
    }
}
