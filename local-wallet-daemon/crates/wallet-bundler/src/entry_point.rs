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
    Ok(wallet_userop_policy::encode_single_handle_ops(
        &op.packed_for_hash()?,
        &op.signature,
        beneficiary,
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
    fn handle_ops_calldata_matches_golden_vector() {
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
        let expected: Bytes = "0x765e827f0000000000000000000000000000000000000000000000000000000000000040000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000d73c7780b1c1da1586a8332d5499f36b7cbb33c2000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000200000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000500000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001ab00000000000000000000000000000000000000000000000000000000000000"
            .parse()
            .unwrap();
        assert_eq!(calldata, expected);
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
