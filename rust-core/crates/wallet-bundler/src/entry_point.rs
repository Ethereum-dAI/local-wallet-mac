use alloy_primitives::{Address, Bytes};
use alloy_sol_types::{sol, SolCall};
pub use wallet_addresses::ENTRY_POINT_V07;

use crate::{Result, UserOperation};

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

pub fn encode_handle_ops(op: &UserOperation, beneficiary: Address) -> Result<Bytes> {
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
        handleOpsCall {
            ops: vec![packed],
            beneficiary,
        }
        .abi_encode(),
    ))
}

pub fn encode_empty_handle_ops(beneficiary: Address) -> Bytes {
    Bytes::from(
        handleOpsCall {
            ops: Vec::new(),
            beneficiary,
        }
        .abi_encode(),
    )
}

#[cfg(test)]
mod tests {
    use alloy_primitives::address;
    use serde_json::json;

    use super::*;

    #[test]
    fn handle_ops_calldata_has_expected_selector() {
        let op = UserOperation::parse(json!({
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
        .unwrap();
        let calldata =
            encode_handle_ops(&op, address!("1000000000000000000000000000000000000000")).unwrap();
        assert_eq!(&calldata[..4], &[0x76, 0x5e, 0x82, 0x7f]);
    }

    #[test]
    fn empty_handle_ops_calldata_has_no_ops() {
        let calldata =
            encode_empty_handle_ops(address!("1000000000000000000000000000000000000000"));

        assert_eq!(&calldata[..4], &[0x76, 0x5e, 0x82, 0x7f]);
        let decoded = handleOpsCall::abi_decode(&calldata).unwrap();
        assert!(decoded.ops.is_empty());
        assert_eq!(
            decoded.beneficiary,
            address!("1000000000000000000000000000000000000000")
        );
    }
}
