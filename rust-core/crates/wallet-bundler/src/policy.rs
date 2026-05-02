use alloy_primitives::{Address, U256};

use crate::{BundlerError, Result, UserOperation};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PolicyMode {
    Estimate,
    Submit,
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
    if !policy
        .entry_points
        .iter()
        .any(|allowed| *allowed == entry_point)
    {
        return Err(PolicyError::EntrypointNotAllowlisted);
    }
    if op.paymaster.is_some()
        || op.paymaster_verification_gas_limit.is_some()
        || op.paymaster_post_op_gas_limit.is_some()
        || !op.paymaster_data.is_empty()
    {
        return Err(PolicyError::PaymasterNotSupported);
    }
    if mode == PolicyMode::Submit && op.signature.is_empty() {
        return Err(PolicyError::SignatureMissing);
    }
    if op.call_gas_limit > policy.max_call_gas_limit {
        return Err(PolicyError::CapExceeded("callGasLimit"));
    }
    if op.verification_gas_limit > policy.max_verification_gas_limit {
        return Err(PolicyError::CapExceeded("verificationGasLimit"));
    }
    if op.pre_verification_gas > policy.max_pre_verification_gas {
        return Err(PolicyError::CapExceeded("preVerificationGas"));
    }
    if op.max_fee_per_gas > policy.max_fee_per_gas {
        return Err(PolicyError::CapExceeded("maxFeePerGas"));
    }
    if op.max_priority_fee_per_gas > policy.max_priority_fee_per_gas {
        return Err(PolicyError::CapExceeded("maxPriorityFeePerGas"));
    }
    Ok(())
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

pub fn bumped_replacement_fees(
    previous: BundlerTxFees,
    op: &UserOperation,
    min_bump_pct: f64,
) -> std::result::Result<BundlerTxFees, PolicyError> {
    if !min_bump_pct.is_finite() || min_bump_pct <= 0.0 {
        return Err(PolicyError::ReplacementNotPossible("invalid_bump_pct"));
    }
    let bump_bps = (min_bump_pct * 100.0).ceil() as u64;
    let multiplier_bps = U256::from(10_000_u64 + bump_bps);
    let divisor_bps = U256::from(10_000_u64);
    let bumped = BundlerTxFees {
        max_fee_per_gas: ceil_div(previous.max_fee_per_gas * multiplier_bps, divisor_bps),
        max_priority_fee_per_gas: ceil_div(
            previous.max_priority_fee_per_gas * multiplier_bps,
            divisor_bps,
        ),
    };
    validate_bundler_tx_fee_invariant(op, bumped)?;
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
            max_pre_verification_gas: U256::from(100),
            max_fee_per_gas: U256::from(100),
            max_priority_fee_per_gas: U256::from(100),
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
}
