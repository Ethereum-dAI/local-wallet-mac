use alloy_primitives::U256;
use serde::Serialize;

use crate::{DecodedValidationResult, UserOperation};

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GasPrice {
    pub max_fee_per_gas: String,
    pub max_priority_fee_per_gas: String,
}

pub fn pimlico_gas_price(
    slow: (U256, U256),
    standard: (U256, U256),
    fast: (U256, U256),
) -> serde_json::Value {
    serde_json::json!({
        "slow": GasPrice::from_values(slow.0, slow.1),
        "standard": GasPrice::from_values(standard.0, standard.1),
        "fast": GasPrice::from_values(fast.0, fast.1),
    })
}

pub fn estimate_user_operation_gas(op: &UserOperation) -> serde_json::Value {
    estimate_user_operation_gas_with_prefund(op, op.required_prefund())
}

pub fn estimate_user_operation_gas_from_validation(
    op: &UserOperation,
    validation: &DecodedValidationResult,
) -> serde_json::Value {
    estimate_user_operation_gas_with_prefund(op, validation.prefund)
}

fn estimate_user_operation_gas_with_prefund(
    op: &UserOperation,
    required_prefund: U256,
) -> serde_json::Value {
    serde_json::json!({
        "preVerificationGas": u256_hex(op.pre_verification_gas),
        "verificationGasLimit": u256_hex(op.verification_gas_limit),
        "callGasLimit": u256_hex(op.call_gas_limit),
        "paymasterVerificationGasLimit": "0x0",
        "paymasterPostOpGasLimit": "0x0",
        "requiredPrefund": u256_hex(required_prefund),
    })
}

impl GasPrice {
    pub fn from_values(max_fee_per_gas: U256, max_priority_fee_per_gas: U256) -> Self {
        Self {
            max_fee_per_gas: u256_hex(max_fee_per_gas),
            max_priority_fee_per_gas: u256_hex(max_priority_fee_per_gas),
        }
    }
}

pub fn u256_hex(value: U256) -> String {
    format!("0x{value:x}")
}

pub fn derive_fee_tiers(base: U256) -> (U256, U256, U256) {
    let hundred = U256::from(100u64);
    let slow = base * U256::from(85u64) / hundred;
    let standard = base;
    let fast = base * U256::from(125u64) / hundred;
    (slow, standard, fast)
}

pub fn clamp_to_cap(value: U256, cap: U256) -> U256 {
    if value > cap {
        cap
    } else {
        value
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pimlico_gas_price_returns_three_distinct_tiers() {
        let value = pimlico_gas_price(
            (U256::from(7), U256::from(1)),
            (U256::from(8), U256::from(2)),
            (U256::from(10), U256::from(3)),
        );

        assert_eq!(value["slow"]["maxFeePerGas"], "0x7");
        assert_eq!(value["slow"]["maxPriorityFeePerGas"], "0x1");
        assert_eq!(value["standard"]["maxFeePerGas"], "0x8");
        assert_eq!(value["standard"]["maxPriorityFeePerGas"], "0x2");
        assert_eq!(value["fast"]["maxFeePerGas"], "0xa");
        assert_eq!(value["fast"]["maxPriorityFeePerGas"], "0x3");
    }

    #[test]
    fn pimlico_gas_price_returns_three_identical_tiers_when_given_uniform_input() {
        let cap_pair = (U256::from(10), U256::from(2));
        let value = pimlico_gas_price(cap_pair, cap_pair, cap_pair);

        assert_eq!(value["slow"], value["standard"]);
        assert_eq!(value["standard"], value["fast"]);
        assert_eq!(value["fast"]["maxFeePerGas"], "0xa");
        assert_eq!(value["fast"]["maxPriorityFeePerGas"], "0x2");
    }

    #[test]
    fn tier_multipliers_apply_to_fee() {
        let (slow, standard, fast) = derive_fee_tiers(U256::from(100));

        assert_eq!(slow, U256::from(85));
        assert_eq!(standard, U256::from(100));
        assert_eq!(fast, U256::from(125));
    }

    #[test]
    fn tier_multipliers_round_down() {
        let (slow, _standard, fast) = derive_fee_tiers(U256::from(7));

        assert_eq!(slow, U256::from(5));
        assert_eq!(fast, U256::from(8));
    }

    #[test]
    fn tier_multipliers_zero_input_stays_zero() {
        let (slow, standard, fast) = derive_fee_tiers(U256::ZERO);

        assert_eq!(slow, U256::ZERO);
        assert_eq!(standard, U256::ZERO);
        assert_eq!(fast, U256::ZERO);
    }

    #[test]
    fn clamp_returns_value_when_below_cap() {
        assert_eq!(
            clamp_to_cap(U256::from(50), U256::from(100)),
            U256::from(50)
        );
    }

    #[test]
    fn clamp_returns_cap_when_value_exceeds_or_equals_cap() {
        assert_eq!(
            clamp_to_cap(U256::from(150), U256::from(100)),
            U256::from(100)
        );
        assert_eq!(
            clamp_to_cap(U256::from(100), U256::from(100)),
            U256::from(100)
        );
    }
}
