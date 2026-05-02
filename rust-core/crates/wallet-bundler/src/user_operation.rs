use alloy_primitives::{Address, Bytes, FixedBytes, U256};
use serde::Deserialize;
use serde_json::Value;
use wallet_signature::PackedUserOperation;

use crate::error::{BundlerError, Result};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UserOperation {
    pub sender: Address,
    pub nonce: U256,
    pub factory: Option<Address>,
    pub factory_data: Bytes,
    pub call_data: Bytes,
    pub call_gas_limit: U256,
    pub verification_gas_limit: U256,
    pub pre_verification_gas: U256,
    pub max_fee_per_gas: U256,
    pub max_priority_fee_per_gas: U256,
    pub paymaster: Option<Address>,
    pub paymaster_verification_gas_limit: Option<U256>,
    pub paymaster_post_op_gas_limit: Option<U256>,
    pub paymaster_data: Bytes,
    pub signature: Bytes,
    pub raw: Value,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawUserOperation {
    sender: String,
    nonce: String,
    #[serde(default)]
    factory: Option<String>,
    #[serde(default)]
    factory_data: Option<String>,
    call_data: Option<String>,
    call_gas_limit: Option<String>,
    verification_gas_limit: Option<String>,
    pre_verification_gas: Option<String>,
    max_fee_per_gas: Option<String>,
    max_priority_fee_per_gas: Option<String>,
    #[serde(default)]
    paymaster: Option<String>,
    #[serde(default)]
    paymaster_verification_gas_limit: Option<String>,
    #[serde(default)]
    paymaster_post_op_gas_limit: Option<String>,
    #[serde(default)]
    paymaster_data: Option<String>,
    signature: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PackedUserOperationFields {
    pub account_gas_limits: FixedBytes<32>,
    pub gas_fees: FixedBytes<32>,
    pub init_code: Bytes,
    pub paymaster_and_data: Bytes,
}

impl UserOperation {
    pub fn parse(value: Value) -> Result<Self> {
        let raw: RawUserOperation = serde_json::from_value(value.clone())
            .map_err(|err| BundlerError::InvalidUserOperation(err.to_string()))?;
        let factory_data = raw.factory_data.unwrap_or_default();
        let paymaster_data = raw.paymaster_data.unwrap_or_default();

        Ok(Self {
            sender: parse_address("sender", &raw.sender)?,
            nonce: parse_u256("nonce", &raw.nonce)?,
            factory: raw
                .factory
                .as_deref()
                .map(|value| parse_address("factory", value))
                .transpose()?,
            factory_data: parse_bytes("factoryData", &factory_data)?,
            call_data: parse_bytes("callData", &required("callData", raw.call_data)?)?,
            call_gas_limit: parse_u256(
                "callGasLimit",
                &required("callGasLimit", raw.call_gas_limit)?,
            )?,
            verification_gas_limit: parse_u256(
                "verificationGasLimit",
                &required("verificationGasLimit", raw.verification_gas_limit)?,
            )?,
            pre_verification_gas: parse_u256(
                "preVerificationGas",
                &required("preVerificationGas", raw.pre_verification_gas)?,
            )?,
            max_fee_per_gas: parse_u256(
                "maxFeePerGas",
                &required("maxFeePerGas", raw.max_fee_per_gas)?,
            )?,
            max_priority_fee_per_gas: parse_u256(
                "maxPriorityFeePerGas",
                &required("maxPriorityFeePerGas", raw.max_priority_fee_per_gas)?,
            )?,
            paymaster: raw
                .paymaster
                .as_deref()
                .map(|value| parse_address("paymaster", value))
                .transpose()?,
            paymaster_verification_gas_limit: raw
                .paymaster_verification_gas_limit
                .as_deref()
                .map(|value| parse_u256("paymasterVerificationGasLimit", value))
                .transpose()?,
            paymaster_post_op_gas_limit: raw
                .paymaster_post_op_gas_limit
                .as_deref()
                .map(|value| parse_u256("paymasterPostOpGasLimit", value))
                .transpose()?,
            paymaster_data: parse_bytes("paymasterData", &paymaster_data)?,
            signature: parse_bytes("signature", &raw.signature.unwrap_or_default())?,
            raw: value,
        })
    }

    pub fn pack_fields(&self) -> Result<PackedUserOperationFields> {
        let mut account_gas_limits = [0u8; 32];
        account_gas_limits[..16].copy_from_slice(&u256_to_u128_be(
            self.verification_gas_limit,
            "verificationGasLimit",
        )?);
        account_gas_limits[16..]
            .copy_from_slice(&u256_to_u128_be(self.call_gas_limit, "callGasLimit")?);

        let mut gas_fees = [0u8; 32];
        gas_fees[..16].copy_from_slice(&u256_to_u128_be(
            self.max_priority_fee_per_gas,
            "maxPriorityFeePerGas",
        )?);
        gas_fees[16..].copy_from_slice(&u256_to_u128_be(self.max_fee_per_gas, "maxFeePerGas")?);

        let mut init_code = Vec::new();
        if let Some(factory) = self.factory {
            init_code.extend_from_slice(factory.as_slice());
            init_code.extend_from_slice(&self.factory_data);
        }

        let mut paymaster_and_data = Vec::new();
        if let Some(paymaster) = self.paymaster {
            paymaster_and_data.extend_from_slice(paymaster.as_slice());
            paymaster_and_data.extend_from_slice(&u256_to_u128_be(
                self.paymaster_verification_gas_limit.unwrap_or(U256::ZERO),
                "paymasterVerificationGasLimit",
            )?);
            paymaster_and_data.extend_from_slice(&u256_to_u128_be(
                self.paymaster_post_op_gas_limit.unwrap_or(U256::ZERO),
                "paymasterPostOpGasLimit",
            )?);
            paymaster_and_data.extend_from_slice(&self.paymaster_data);
        }

        Ok(PackedUserOperationFields {
            account_gas_limits: FixedBytes::from(account_gas_limits),
            gas_fees: FixedBytes::from(gas_fees),
            init_code: Bytes::from(init_code),
            paymaster_and_data: Bytes::from(paymaster_and_data),
        })
    }

    pub fn packed_for_hash(&self) -> Result<PackedUserOperation> {
        let fields = self.pack_fields()?;
        Ok(PackedUserOperation {
            sender: self.sender,
            nonce: self.nonce,
            init_code: fields.init_code,
            call_data: self.call_data.clone(),
            account_gas_limits: fields.account_gas_limits,
            pre_verification_gas: self.pre_verification_gas,
            gas_fees: fields.gas_fees,
            paymaster_and_data: fields.paymaster_and_data,
        })
    }

    pub fn required_prefund(&self) -> U256 {
        // EntryPoint v0.7 adds paymaster gas terms here, but Phase 4 rejects paymasters.
        (self.call_gas_limit + self.verification_gas_limit + self.pre_verification_gas)
            * self.max_fee_per_gas
    }

    pub fn user_op_hash(&self, entry_point: Address, chain_id: u64) -> Result<[u8; 32]> {
        Ok(wallet_signature::compute_userop_hash(
            &self.packed_for_hash()?,
            entry_point,
            chain_id,
        ))
    }

    pub fn with_signature(&self, signature: Bytes) -> Self {
        let mut op = self.clone();
        op.signature = signature;
        op
    }

    pub fn with_verification_gas_limit(&self, verification_gas_limit: U256) -> Self {
        let mut op = self.clone();
        op.verification_gas_limit = verification_gas_limit;
        op
    }
}

pub fn dummy_webauthn_signature(use_precompiled: bool) -> Bytes {
    Bytes::from(wallet_signature::abi_encode_dummy_signature(
        use_precompiled,
    ))
}

fn required(field: &'static str, value: Option<String>) -> Result<String> {
    value.ok_or_else(|| BundlerError::InvalidUserOperation(format!("{field} is required")))
}

fn parse_address(field: &'static str, value: &str) -> Result<Address> {
    value
        .parse()
        .map_err(|err| BundlerError::InvalidUserOperation(format!("{field}: {err}")))
}

fn parse_bytes(field: &'static str, value: &str) -> Result<Bytes> {
    value
        .parse()
        .map_err(|err| BundlerError::InvalidUserOperation(format!("{field}: {err}")))
}

fn parse_u256(field: &'static str, value: &str) -> Result<U256> {
    U256::from_str_radix(value.strip_prefix("0x").unwrap_or(value), 16)
        .map_err(|err| BundlerError::InvalidUserOperation(format!("{field}: {err}")))
}

fn u256_to_u128_be(value: U256, field: &'static str) -> Result<[u8; 16]> {
    if value > U256::from(u128::MAX) {
        return Err(BundlerError::PolicyCapExceeded { field });
    }
    Ok((value.to::<u128>()).to_be_bytes())
}

#[cfg(test)]
mod tests {
    use alloy_primitives::{address, U256};
    use serde_json::json;

    use super::*;

    fn sample() -> Value {
        json!({
            "sender": "0xd73c7780b1c1da1586a8332d5499f36b7cbb33c2",
            "nonce": "0x01",
            "callData": "0x1234",
            "callGasLimit": "0x10",
            "verificationGasLimit": "0x20",
            "preVerificationGas": "0x30",
            "maxFeePerGas": "0x40",
            "maxPriorityFeePerGas": "0x05",
            "signature": "0xab"
        })
    }

    #[test]
    fn parses_camel_case_user_operation() {
        let op = UserOperation::parse(sample()).unwrap();
        assert_eq!(
            op.sender,
            address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2")
        );
        assert_eq!(op.nonce, U256::from(1));
        assert_eq!(op.required_prefund(), U256::from(0x1800u64));
    }

    #[test]
    fn required_prefund_matches_entrypoint_v07_no_paymaster_formula() {
        let op = UserOperation::parse(sample()).unwrap();

        assert!(op.paymaster_data.is_empty());
        assert_eq!(
            op.required_prefund(),
            (op.call_gas_limit + op.verification_gas_limit + op.pre_verification_gas)
                * op.max_fee_per_gas
        );
    }

    #[test]
    fn packed_fields_match_entrypoint_v07_order() {
        let op = UserOperation::parse(sample()).unwrap();
        let fields = op.pack_fields().unwrap();
        assert_eq!(&fields.account_gas_limits[..15], &[0u8; 15]);
        assert_eq!(fields.account_gas_limits[15], 0x20);
        assert_eq!(fields.account_gas_limits[31], 0x10);
        assert_eq!(fields.gas_fees[15], 0x05);
        assert_eq!(fields.gas_fees[31], 0x40);
    }

    #[test]
    fn dummy_signature_replaces_signature_without_changing_userop_hash() {
        let op = UserOperation::parse(sample()).unwrap();
        let entry_point = address!("0000000071727de22e5e9d8baf0edac6f37da032");
        let original_hash = op.user_op_hash(entry_point, 1).unwrap();

        let dummy = dummy_webauthn_signature(false);
        let estimate_op = op.with_signature(dummy.clone());

        assert_eq!(estimate_op.signature, dummy);
        assert_eq!(
            estimate_op.user_op_hash(entry_point, 1).unwrap(),
            original_hash
        );
    }
}
