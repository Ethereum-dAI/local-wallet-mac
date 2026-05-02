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
    max_fee_per_gas: U256,
    max_priority_fee_per_gas: U256,
) -> serde_json::Value {
    let slow = GasPrice::from_values(max_fee_per_gas, max_priority_fee_per_gas);
    serde_json::json!({
        "slow": slow,
        "standard": slow,
        "fast": slow,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pimlico_shape_has_three_speed_buckets() {
        let value = pimlico_gas_price(U256::from(10), U256::from(2));
        assert_eq!(value["slow"]["maxFeePerGas"], "0xa");
        assert_eq!(value["standard"]["maxPriorityFeePerGas"], "0x2");
        assert_eq!(value["fast"]["maxFeePerGas"], "0xa");
    }
}
