use alloy_primitives::{keccak256, Address, Bytes, B256, U256};

use crate::{
    bumped_replacement_fees_with_budget, encode_empty_handle_ops, encode_handle_ops, BundlerError,
    BundlerTxFees, PolicyError, Result, UserOperation,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Eip1559TxRequest {
    pub chain_id: u64,
    pub nonce: u64,
    pub max_priority_fee_per_gas: U256,
    pub max_fee_per_gas: U256,
    pub gas_limit: u64,
    pub to: Address,
    pub value: U256,
    pub input: Bytes,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Eip1559Signature {
    pub y_parity: bool,
    pub r: U256,
    pub s: U256,
}

#[allow(clippy::too_many_arguments)]
pub fn build_handle_ops_tx_request(
    chain_id: u64,
    bundler_nonce: u64,
    entry_point: Address,
    beneficiary: Address,
    op: &UserOperation,
    gas_limit: u64,
    max_fee_per_gas: U256,
    max_priority_fee_per_gas: U256,
) -> Result<Eip1559TxRequest> {
    Ok(Eip1559TxRequest {
        chain_id,
        nonce: bundler_nonce,
        max_priority_fee_per_gas,
        max_fee_per_gas,
        gas_limit,
        to: entry_point,
        value: U256::ZERO,
        input: encode_handle_ops(op, beneficiary)?,
    })
}

#[allow(clippy::too_many_arguments)]
pub fn build_replacement_handle_ops_tx_request(
    chain_id: u64,
    bundler_nonce: u64,
    entry_point: Address,
    beneficiary: Address,
    op: &UserOperation,
    gas_limit: u64,
    previous_fees: BundlerTxFees,
    min_bump_pct: f64,
    max_relayer_bump_pct: f64,
) -> Result<Eip1559TxRequest> {
    let bumped =
        bumped_replacement_fees_with_budget(previous_fees, op, min_bump_pct, max_relayer_bump_pct)
            .map_err(replacement_policy_error)?;
    build_handle_ops_tx_request(
        chain_id,
        bundler_nonce,
        entry_point,
        beneficiary,
        op,
        gas_limit,
        bumped.max_fee_per_gas,
        bumped.max_priority_fee_per_gas,
    )
}

#[allow(clippy::too_many_arguments)]
pub fn build_cancel_handle_ops_tx_request(
    chain_id: u64,
    bundler_nonce: u64,
    entry_point: Address,
    beneficiary: Address,
    original_op: &UserOperation,
    gas_limit: u64,
    previous_fees: BundlerTxFees,
    min_bump_pct: f64,
    max_relayer_bump_pct: f64,
) -> Result<Eip1559TxRequest> {
    let bumped = bumped_replacement_fees_with_budget(
        previous_fees,
        original_op,
        min_bump_pct,
        max_relayer_bump_pct,
    )
    .map_err(replacement_policy_error)?;
    build_cancel_handle_ops_tx_request_with_fees(
        chain_id,
        bundler_nonce,
        entry_point,
        beneficiary,
        gas_limit,
        bumped,
    )
}

pub fn build_cancel_handle_ops_tx_request_with_fees(
    chain_id: u64,
    bundler_nonce: u64,
    entry_point: Address,
    beneficiary: Address,
    gas_limit: u64,
    fees: BundlerTxFees,
) -> Result<Eip1559TxRequest> {
    if fees.max_priority_fee_per_gas > fees.max_fee_per_gas {
        return Err(BundlerError::InvalidTransaction(
            "max_priority_fee_per_gas_exceeds_max_fee_per_gas".to_string(),
        ));
    }
    Ok(Eip1559TxRequest {
        chain_id,
        nonce: bundler_nonce,
        max_priority_fee_per_gas: fees.max_priority_fee_per_gas,
        max_fee_per_gas: fees.max_fee_per_gas,
        gas_limit,
        to: entry_point,
        value: U256::ZERO,
        input: encode_empty_handle_ops(beneficiary),
    })
}

pub fn encode_eip1559_payload_for_signing(tx: &Eip1559TxRequest) -> Result<Bytes> {
    let mut out = vec![0x02];
    out.extend(rlp_list(&eip1559_unsigned_fields(tx)?)?);
    Ok(Bytes::from(out))
}

fn replacement_policy_error(error: PolicyError) -> BundlerError {
    match error {
        PolicyError::CapExceeded(field) => BundlerError::PolicyCapExceeded { field },
        PolicyError::ReplacementNotPossible(reason) => {
            BundlerError::ReplacementNotPossible { reason }
        }
        PolicyError::EntrypointNotAllowlisted => BundlerError::ReplacementNotPossible {
            reason: "entrypoint_not_allowlisted",
        },
        PolicyError::ChainMismatch => BundlerError::ReplacementNotPossible {
            reason: "chain_mismatch",
        },
        PolicyError::PaymasterNotSupported => BundlerError::PaymasterNotSupported,
        PolicyError::SignatureMissing => BundlerError::SignatureMissing,
    }
}

pub fn encode_signed_eip1559_tx(
    tx: &Eip1559TxRequest,
    signature: &Eip1559Signature,
) -> Result<Bytes> {
    let mut fields = eip1559_unsigned_fields(tx)?;
    fields.push(rlp_bool(signature.y_parity));
    fields.push(rlp_u256(&signature.r)?);
    fields.push(rlp_u256(&signature.s)?);

    let mut out = vec![0x02];
    out.extend(rlp_list(&fields)?);
    Ok(Bytes::from(out))
}

pub fn signed_eip1559_tx_hash(tx: &Eip1559TxRequest, signature: &Eip1559Signature) -> Result<B256> {
    Ok(keccak256(encode_signed_eip1559_tx(tx, signature)?))
}

fn eip1559_unsigned_fields(tx: &Eip1559TxRequest) -> Result<Vec<Vec<u8>>> {
    Ok(vec![
        rlp_u64(tx.chain_id),
        rlp_u64(tx.nonce),
        rlp_u256(&tx.max_priority_fee_per_gas)?,
        rlp_u256(&tx.max_fee_per_gas)?,
        rlp_u64(tx.gas_limit),
        rlp_bytes(tx.to.as_slice())?,
        rlp_u256(&tx.value)?,
        rlp_bytes(&tx.input)?,
        rlp_list(&[])?,
    ])
}

fn rlp_bool(value: bool) -> Vec<u8> {
    rlp_u64(u64::from(value))
}

fn rlp_u64(value: u64) -> Vec<u8> {
    if value == 0 {
        return vec![0x80];
    }
    let bytes = value.to_be_bytes();
    let start = bytes
        .iter()
        .position(|byte| *byte != 0)
        .expect("non-zero integer has at least one non-zero byte");
    rlp_bytes(&bytes[start..]).expect("u64 bytes are shorter than RLP limits")
}

fn rlp_u256(value: &U256) -> Result<Vec<u8>> {
    if value.is_zero() {
        return Ok(vec![0x80]);
    }
    let bytes = value.to_be_bytes::<32>();
    let start = bytes
        .iter()
        .position(|byte| *byte != 0)
        .expect("non-zero integer has at least one non-zero byte");
    rlp_bytes(&bytes[start..])
}

fn rlp_bytes(bytes: &[u8]) -> Result<Vec<u8>> {
    if bytes.len() == 1 && bytes[0] < 0x80 {
        return Ok(vec![bytes[0]]);
    }

    let mut out = rlp_length_prefix(0x80, bytes.len())?;
    out.extend_from_slice(bytes);
    Ok(out)
}

fn rlp_list(items: &[Vec<u8>]) -> Result<Vec<u8>> {
    let payload_len = items.iter().map(Vec::len).sum();
    let mut out = rlp_length_prefix(0xc0, payload_len)?;
    for item in items {
        out.extend_from_slice(item);
    }
    Ok(out)
}

fn rlp_length_prefix(offset: u8, len: usize) -> Result<Vec<u8>> {
    if len <= 55 {
        return Ok(vec![offset + len as u8]);
    }

    let len_u64 = u64::try_from(len)
        .map_err(|_| BundlerError::InvalidTransaction("rlp_payload_too_large".to_string()))?;
    let len_bytes = len_u64.to_be_bytes();
    let start = len_bytes
        .iter()
        .position(|byte| *byte != 0)
        .expect("long RLP payload length is non-zero");
    let len_bytes = &len_bytes[start..];
    let len_of_len = u8::try_from(len_bytes.len())
        .map_err(|_| BundlerError::InvalidTransaction("rlp_payload_too_large".to_string()))?;
    let mut out = vec![offset + 55 + len_of_len];
    out.extend_from_slice(len_bytes);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::address;

    fn sample_tx(input: Bytes) -> Eip1559TxRequest {
        Eip1559TxRequest {
            chain_id: 1,
            nonce: 0,
            max_priority_fee_per_gas: U256::from(2),
            max_fee_per_gas: U256::from(3),
            gas_limit: 21_000,
            to: address!("1111111111111111111111111111111111111111"),
            value: U256::ZERO,
            input,
        }
    }

    #[test]
    fn encodes_eip1559_signing_payload() {
        let encoded = encode_eip1559_payload_for_signing(&sample_tx(Bytes::new())).unwrap();

        assert_eq!(
            hex::encode(encoded),
            concat!(
                "02df",
                "01",
                "80",
                "02",
                "03",
                "825208",
                "941111111111111111111111111111111111111111",
                "80",
                "80",
                "c0"
            )
        );
    }

    #[test]
    fn encodes_signed_eip1559_tx_and_hashes_raw_bytes() {
        let tx = sample_tx(Bytes::new());
        let signature = Eip1559Signature {
            y_parity: false,
            r: U256::from(1),
            s: U256::from(2),
        };

        let raw = encode_signed_eip1559_tx(&tx, &signature).unwrap();

        assert_eq!(
            hex::encode(raw.clone()),
            concat!(
                "02e2",
                "01",
                "80",
                "02",
                "03",
                "825208",
                "941111111111111111111111111111111111111111",
                "80",
                "80",
                "c0",
                "80",
                "01",
                "02"
            )
        );
        assert_eq!(
            signed_eip1559_tx_hash(&tx, &signature).unwrap(),
            keccak256(raw)
        );
    }

    #[test]
    fn uses_long_rlp_prefixes_for_realistic_calldata() {
        let encoded =
            encode_eip1559_payload_for_signing(&sample_tx(Bytes::from(vec![0xaa; 56]))).unwrap();

        assert_eq!(encoded[0], 0x02);
        assert_eq!(encoded[1], 0xf8);
        assert_eq!(encoded[2], 0x58);
        assert!(encoded.windows(2).any(|window| window == [0xb8, 0x38]));
    }

    #[test]
    fn handle_ops_tx_request_targets_entrypoint_with_zero_value() {
        let op = UserOperation::parse(serde_json::json!({
            "sender": "0x1000000000000000000000000000000000000000",
            "nonce": "0x1",
            "callData": "0x",
            "callGasLimit": "0x10000",
            "verificationGasLimit": "0x20000",
            "preVerificationGas": "0x1000",
            "maxFeePerGas": "0x3",
            "maxPriorityFeePerGas": "0x2",
            "signature": "0xab"
        }))
        .unwrap();
        let entry_point = wallet_addresses::ENTRY_POINT_V07;
        let beneficiary = address!("2000000000000000000000000000000000000000");

        let tx = build_handle_ops_tx_request(
            1,
            7,
            entry_point,
            beneficiary,
            &op,
            500_000,
            U256::from(3),
            U256::from(2),
        )
        .unwrap();

        assert_eq!(tx.chain_id, 1);
        assert_eq!(tx.nonce, 7);
        assert_eq!(tx.to, entry_point);
        assert_eq!(tx.value, U256::ZERO);
        assert_eq!(&tx.input[..4], &[0x76, 0x5e, 0x82, 0x7f]);
    }

    #[test]
    fn replacement_tx_request_bumps_previous_fees_for_same_userop() {
        let op = UserOperation::parse(serde_json::json!({
            "sender": "0x1000000000000000000000000000000000000000",
            "nonce": "0x1",
            "callData": "0x",
            "callGasLimit": "0x10000",
            "verificationGasLimit": "0x20000",
            "preVerificationGas": "0x1000",
            "maxFeePerGas": "0x64",
            "maxPriorityFeePerGas": "0x20",
            "signature": "0xab"
        }))
        .unwrap();
        let entry_point = wallet_addresses::ENTRY_POINT_V07;
        let beneficiary = address!("2000000000000000000000000000000000000000");

        let tx = build_replacement_handle_ops_tx_request(
            1,
            7,
            entry_point,
            beneficiary,
            &op,
            500_000,
            BundlerTxFees {
                max_fee_per_gas: U256::from(80),
                max_priority_fee_per_gas: U256::from(16),
            },
            12.5,
            50.0,
        )
        .unwrap();

        assert_eq!(tx.nonce, 7);
        assert_eq!(tx.max_fee_per_gas, U256::from(90));
        assert_eq!(tx.max_priority_fee_per_gas, U256::from(18));
        assert_eq!(&tx.input[..4], &[0x76, 0x5e, 0x82, 0x7f]);
    }

    #[test]
    fn cancel_tx_request_uses_empty_handle_ops_and_original_fee_caps() {
        let op = UserOperation::parse(serde_json::json!({
            "sender": "0x1000000000000000000000000000000000000000",
            "nonce": "0x1",
            "callData": "0x",
            "callGasLimit": "0x10000",
            "verificationGasLimit": "0x20000",
            "preVerificationGas": "0x1000",
            "maxFeePerGas": "0x64",
            "maxPriorityFeePerGas": "0x20",
            "signature": "0xab"
        }))
        .unwrap();
        let entry_point = wallet_addresses::ENTRY_POINT_V07;
        let beneficiary = address!("2000000000000000000000000000000000000000");

        let tx = build_cancel_handle_ops_tx_request(
            1,
            7,
            entry_point,
            beneficiary,
            &op,
            50_000,
            BundlerTxFees {
                max_fee_per_gas: U256::from(80),
                max_priority_fee_per_gas: U256::from(16),
            },
            12.5,
            50.0,
        )
        .unwrap();

        assert_eq!(tx.to, entry_point);
        assert_eq!(tx.value, U256::ZERO);
        assert_eq!(tx.max_fee_per_gas, U256::from(90));
        assert_eq!(tx.max_priority_fee_per_gas, U256::from(18));
        assert_eq!(tx.input, crate::encode_empty_handle_ops(beneficiary));
    }

    #[test]
    fn cancel_tx_request_with_explicit_fees_uses_empty_handle_ops() {
        let entry_point = wallet_addresses::ENTRY_POINT_V07;
        let beneficiary = address!("2000000000000000000000000000000000000000");

        let tx = build_cancel_handle_ops_tx_request_with_fees(
            1,
            7,
            entry_point,
            beneficiary,
            50_000,
            BundlerTxFees {
                max_fee_per_gas: U256::from(250),
                max_priority_fee_per_gas: U256::from(25),
            },
        )
        .unwrap();

        assert_eq!(tx.chain_id, 1);
        assert_eq!(tx.nonce, 7);
        assert_eq!(tx.to, entry_point);
        assert_eq!(tx.value, U256::ZERO);
        assert_eq!(tx.max_fee_per_gas, U256::from(250));
        assert_eq!(tx.max_priority_fee_per_gas, U256::from(25));
        assert_eq!(tx.input, crate::encode_empty_handle_ops(beneficiary));
    }

    #[test]
    fn cancel_tx_request_allows_bump_within_relayer_budget_and_rejects_above() {
        let op = UserOperation::parse(serde_json::json!({
            "sender": "0x1000000000000000000000000000000000000000",
            "nonce": "0x1",
            "callData": "0x",
            "callGasLimit": "0x10000",
            "verificationGasLimit": "0x20000",
            "preVerificationGas": "0x1000",
            "maxFeePerGas": "0x64",
            "maxPriorityFeePerGas": "0x20",
            "signature": "0xab"
        }))
        .unwrap();

        let tx = build_cancel_handle_ops_tx_request(
            1,
            7,
            wallet_addresses::ENTRY_POINT_V07,
            address!("2000000000000000000000000000000000000000"),
            &op,
            50_000,
            BundlerTxFees {
                max_fee_per_gas: U256::from(100),
                max_priority_fee_per_gas: U256::from(16),
            },
            12.5,
            50.0,
        )
        .unwrap();
        assert_eq!(tx.max_fee_per_gas, U256::from(113));

        let err = build_cancel_handle_ops_tx_request(
            1,
            7,
            wallet_addresses::ENTRY_POINT_V07,
            address!("2000000000000000000000000000000000000000"),
            &op,
            50_000,
            BundlerTxFees {
                max_fee_per_gas: U256::from(100),
                max_priority_fee_per_gas: U256::from(16),
            },
            12.5,
            10.0,
        )
        .unwrap_err();

        assert!(matches!(
            err,
            BundlerError::PolicyCapExceeded {
                field: "bundlerTx.maxFeePerGas"
            }
        ));
    }
}
