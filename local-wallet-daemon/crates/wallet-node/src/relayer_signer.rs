use alloy_primitives::{Address, U256};
use wallet_bundler::{Eip1559Signature, Eip1559TxRequest, UserOperation};

use crate::bundler_keys::{BundlerKeyError, BundlerKeyStore};

pub(crate) fn sign_validated_handle_ops_transaction(
    key_store: &dyn BundlerKeyStore,
    key_ref: &str,
    tx: &Eip1559TxRequest,
    expected_chain_id: u64,
    beneficiary: Address,
    op: &UserOperation,
) -> Result<Eip1559Signature, BundlerKeyError> {
    sign_validated_single_op_handle_ops_transaction(
        key_store,
        key_ref,
        tx,
        expected_chain_id,
        beneficiary,
        op,
        true,
    )
}

pub(crate) fn sign_validated_replacement_handle_ops_transaction(
    key_store: &dyn BundlerKeyStore,
    key_ref: &str,
    tx: &Eip1559TxRequest,
    expected_chain_id: u64,
    beneficiary: Address,
    op: &UserOperation,
) -> Result<Eip1559Signature, BundlerKeyError> {
    sign_validated_single_op_handle_ops_transaction(
        key_store,
        key_ref,
        tx,
        expected_chain_id,
        beneficiary,
        op,
        false,
    )
}

#[allow(clippy::too_many_arguments)]
fn sign_validated_single_op_handle_ops_transaction(
    key_store: &dyn BundlerKeyStore,
    key_ref: &str,
    tx: &Eip1559TxRequest,
    expected_chain_id: u64,
    beneficiary: Address,
    op: &UserOperation,
    enforce_user_op_fee_caps: bool,
) -> Result<Eip1559Signature, BundlerKeyError> {
    validate_common(tx, expected_chain_id)?;
    if tx.input != wallet_bundler::encode_handle_ops(op, beneficiary).map_err(map_bundler_err)? {
        return Err(BundlerKeyError::Signing(
            "relayer transaction calldata is not the validated single-op handleOps shape"
                .to_string(),
        ));
    }
    if enforce_user_op_fee_caps
        && (tx.max_fee_per_gas > op.max_fee_per_gas
            || tx.max_priority_fee_per_gas > op.max_priority_fee_per_gas)
    {
        return Err(BundlerKeyError::Signing(
            "relayer transaction fee caps exceed UserOperation fee caps".to_string(),
        ));
    }
    sign_tx(key_store, key_ref, tx)
}

pub(crate) fn sign_validated_empty_handle_ops_transaction(
    key_store: &dyn BundlerKeyStore,
    key_ref: &str,
    tx: &Eip1559TxRequest,
    expected_chain_id: u64,
    beneficiary: Address,
) -> Result<Eip1559Signature, BundlerKeyError> {
    validate_common(tx, expected_chain_id)?;
    if tx.input != wallet_bundler::encode_empty_handle_ops(beneficiary) {
        return Err(BundlerKeyError::Signing(
            "relayer transaction calldata is not empty handleOps cancel shape".to_string(),
        ));
    }
    sign_tx(key_store, key_ref, tx)
}

fn validate_common(tx: &Eip1559TxRequest, expected_chain_id: u64) -> Result<(), BundlerKeyError> {
    if tx.max_priority_fee_per_gas > tx.max_fee_per_gas {
        return Err(BundlerKeyError::Signing(
            "relayer transaction priority fee cap exceeds max fee cap".to_string(),
        ));
    }
    if tx.chain_id != expected_chain_id {
        return Err(BundlerKeyError::Signing(
            "relayer transaction chain id mismatch".to_string(),
        ));
    }
    if tx.to != wallet_bundler::ENTRY_POINT_V07 {
        return Err(BundlerKeyError::Signing(
            "relayer transaction target is not the pinned EntryPoint".to_string(),
        ));
    }
    if tx.value != U256::ZERO {
        return Err(BundlerKeyError::Signing(
            "relayer transaction value must be zero".to_string(),
        ));
    }
    Ok(())
}

fn sign_tx(
    key_store: &dyn BundlerKeyStore,
    key_ref: &str,
    tx: &Eip1559TxRequest,
) -> Result<Eip1559Signature, BundlerKeyError> {
    let signing_payload =
        wallet_bundler::encode_eip1559_payload_for_signing(tx).map_err(map_bundler_err)?;
    key_store.sign_eip1559_payload(key_ref, &signing_payload)
}

fn map_bundler_err(error: wallet_bundler::BundlerError) -> BundlerKeyError {
    BundlerKeyError::Signing(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::{address, Bytes};
    use serde_json::json;

    fn op() -> wallet_bundler::UserOperation {
        wallet_bundler::UserOperation::parse(json!({
            "sender": "0xd73c7780b1c1da1586a8332d5499f36b7cbb33c2",
            "nonce": "0x0",
            "factory": null,
            "factoryData": "0x",
            "callData": "0x",
            "callGasLimit": "0x5208",
            "verificationGasLimit": "0x5208",
            "preVerificationGas": "0x5208",
            "maxFeePerGas": "0x64",
            "maxPriorityFeePerGas": "0x01",
            "paymaster": null,
            "paymasterVerificationGasLimit": "0x0",
            "paymasterPostOpGasLimit": "0x0",
            "paymasterData": "0x",
            "signature": "0x01"
        }))
        .unwrap()
    }

    fn tx(op: &wallet_bundler::UserOperation) -> Eip1559TxRequest {
        let beneficiary = address!("1000000000000000000000000000000000000000");
        wallet_bundler::build_handle_ops_tx_request(
            1,
            0,
            wallet_bundler::ENTRY_POINT_V07,
            beneficiary,
            op,
            100_000,
            op.max_fee_per_gas,
            op.max_priority_fee_per_gas,
        )
        .unwrap()
    }

    fn key_store() -> crate::bundler_keys::MemoryBundlerKeyStore {
        let key_store = crate::bundler_keys::MemoryBundlerKeyStore::new();
        key_store.create_key("key").unwrap();
        key_store
    }

    #[test]
    fn rejects_wrong_chain_entrypoint_value_calldata_and_beneficiary_before_signing() {
        let key_store = key_store();
        let beneficiary = address!("1000000000000000000000000000000000000000");
        let other = address!("2000000000000000000000000000000000000000");
        let op = op();

        let mut wrong_chain = tx(&op);
        wrong_chain.chain_id = 11155111;
        let err = sign_validated_handle_ops_transaction(
            &key_store,
            "key",
            &wrong_chain,
            1,
            beneficiary,
            &op,
        )
        .unwrap_err();
        assert!(err.to_string().contains("chain id mismatch"));

        let mut wrong_entrypoint = tx(&op);
        wrong_entrypoint.to = other;
        let err = sign_validated_handle_ops_transaction(
            &key_store,
            "key",
            &wrong_entrypoint,
            1,
            beneficiary,
            &op,
        )
        .unwrap_err();
        assert!(err.to_string().contains("not the pinned EntryPoint"));

        let mut nonzero_value = tx(&op);
        nonzero_value.value = U256::from(1);
        let err = sign_validated_handle_ops_transaction(
            &key_store,
            "key",
            &nonzero_value,
            1,
            beneficiary,
            &op,
        )
        .unwrap_err();
        assert!(err.to_string().contains("value must be zero"));

        let mut wrong_calldata = tx(&op);
        wrong_calldata.input = Bytes::from_static(&[0xde, 0xad, 0xbe, 0xef]);
        let err = sign_validated_handle_ops_transaction(
            &key_store,
            "key",
            &wrong_calldata,
            1,
            beneficiary,
            &op,
        )
        .unwrap_err();
        assert!(err.to_string().contains("single-op handleOps shape"));

        let err = sign_validated_handle_ops_transaction(&key_store, "key", &tx(&op), 1, other, &op)
            .unwrap_err();

        assert!(err.to_string().contains("single-op handleOps shape"));
    }

    #[test]
    fn rejects_fee_caps_above_user_operation_before_signing() {
        let key_store = key_store();
        let beneficiary = address!("1000000000000000000000000000000000000000");
        let op = op();
        let mut tx = tx(&op);
        tx.max_fee_per_gas = op.max_fee_per_gas + U256::from(1);

        let err =
            sign_validated_handle_ops_transaction(&key_store, "key", &tx, 1, beneficiary, &op)
                .unwrap_err();

        assert!(err.to_string().contains("fee caps exceed"));
    }

    #[test]
    fn allows_replacement_handle_ops_fee_caps_above_user_operation() {
        let key_store = key_store();
        let beneficiary = address!("1000000000000000000000000000000000000000");
        let op = op();
        let mut tx = tx(&op);
        tx.max_fee_per_gas = op.max_fee_per_gas * U256::from(2);
        tx.max_priority_fee_per_gas = op.max_priority_fee_per_gas;

        assert!(sign_validated_replacement_handle_ops_transaction(
            &key_store,
            "key",
            &tx,
            1,
            beneficiary,
            &op
        )
        .is_ok());
    }

    #[test]
    fn allows_empty_handle_ops_cancel_fee_caps_above_original_operation() {
        let key_store = key_store();
        let beneficiary = address!("1000000000000000000000000000000000000000");
        let op = op();
        let tx = wallet_bundler::build_cancel_handle_ops_tx_request_with_fees(
            1,
            0,
            wallet_bundler::ENTRY_POINT_V07,
            beneficiary,
            100_000,
            wallet_bundler::BundlerTxFees {
                max_fee_per_gas: op.max_fee_per_gas * U256::from(2),
                max_priority_fee_per_gas: op.max_priority_fee_per_gas,
            },
        )
        .unwrap();

        assert!(sign_validated_empty_handle_ops_transaction(
            &key_store,
            "key",
            &tx,
            1,
            beneficiary
        )
        .is_ok());
    }

    #[test]
    fn rejects_priority_fee_above_max_fee_before_signing() {
        let key_store = key_store();
        let beneficiary = address!("1000000000000000000000000000000000000000");
        let op = op();
        let mut tx = tx(&op);
        tx.max_fee_per_gas = U256::from(1);
        tx.max_priority_fee_per_gas = U256::from(2);

        let err =
            sign_validated_handle_ops_transaction(&key_store, "key", &tx, 1, beneficiary, &op)
                .unwrap_err();

        assert!(err.to_string().contains("priority fee cap exceeds"));
    }

    #[test]
    fn allows_empty_handle_ops_cancel_shape() {
        let key_store = key_store();
        let beneficiary = address!("1000000000000000000000000000000000000000");
        let op = op();
        let tx = wallet_bundler::build_cancel_handle_ops_tx_request(
            1,
            0,
            wallet_bundler::ENTRY_POINT_V07,
            beneficiary,
            &op,
            100_000,
            wallet_bundler::BundlerTxFees {
                max_fee_per_gas: op.max_fee_per_gas,
                max_priority_fee_per_gas: op.max_priority_fee_per_gas,
            },
            12.5,
            50.0,
        )
        .unwrap();

        assert!(sign_validated_empty_handle_ops_transaction(
            &key_store,
            "key",
            &tx,
            1,
            beneficiary
        )
        .is_ok());
    }
}
