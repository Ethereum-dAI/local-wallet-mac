use alloy_primitives::{address, keccak256, Address, Bytes, FixedBytes, U256};

/// EntryPoint v0.7 address.
pub const ENTRY_POINT_V07: Address = address!("0000000071727De22E5E9d8BAf0edAc6f37da032");

#[derive(Clone, Debug)]
pub struct PackedUserOperation {
    pub sender: Address,
    pub nonce: U256,
    pub init_code: Bytes,
    pub call_data: Bytes,
    pub account_gas_limits: FixedBytes<32>,
    pub pre_verification_gas: U256,
    pub gas_fees: FixedBytes<32>,
    pub paymaster_and_data: Bytes,
}

pub fn compute_userop_hash(
    userop: &PackedUserOperation,
    entry_point: Address,
    chain_id: u64,
) -> [u8; 32] {
    let h_init_code = keccak256(&userop.init_code);
    let h_call_data = keccak256(&userop.call_data);
    let h_paymaster = keccak256(&userop.paymaster_and_data);

    // Inner: 8 words = 256 bytes
    let mut inner = [0u8; 256];
    inner[12..32].copy_from_slice(userop.sender.as_slice());
    inner[32..64].copy_from_slice(&userop.nonce.to_be_bytes::<32>());
    inner[64..96].copy_from_slice(h_init_code.as_slice());
    inner[96..128].copy_from_slice(h_call_data.as_slice());
    inner[128..160].copy_from_slice(userop.account_gas_limits.as_slice());
    inner[160..192].copy_from_slice(&userop.pre_verification_gas.to_be_bytes::<32>());
    inner[192..224].copy_from_slice(userop.gas_fees.as_slice());
    inner[224..256].copy_from_slice(h_paymaster.as_slice());
    let inner_hash = keccak256(inner);

    // Outer: 3 words = 96 bytes
    let mut outer = [0u8; 96];
    outer[0..32].copy_from_slice(inner_hash.as_slice());
    outer[44..64].copy_from_slice(entry_point.as_slice());
    outer[64..96].copy_from_slice(&U256::from(chain_id).to_be_bytes::<32>());
    *keccak256(outer)
}

#[cfg(test)]
mod tests {
    use super::*;
    use hex_literal::hex;

    #[test]
    fn userop_hash_matches_mainnet_vector() {
        let userop = PackedUserOperation {
            sender: address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2"),
            nonce: U256::from_str_radix(
                "0000baac0ddb0000000000000000000000000000000000000000000000000001",
                16,
            )
            .unwrap(),
            init_code: Bytes::new(),
            call_data: Bytes::from(include_bytes!("../testdata/neKodex_calldata.bin").to_vec()),
            account_gas_limits: FixedBytes::from(hex!(
                "00000000000000000000000000098a2100000000000000000000000000023dad"
            )),
            pre_verification_gas: U256::from(70952u64),
            gas_fees: FixedBytes::from(hex!(
                "00000000000000000000000001a39de00000000000000000000000000c028d49"
            )),
            paymaster_and_data: Bytes::from(
                hex!(
                    "777777777777aec03fd955926dbf81597e66834c"
                    "0000000000000000000000000000b578"
                    "000000000000000000000000000000010100006982dcf2"
                    "000000000000d8d11407392c3df4c4228006b5b955cc1d9fbb63"
                    "b7611ee6edb4fb1153b988ca276ccc833f9ce4dde4d6b4a9283b"
                    "8745db82a3b1a8fa2555bd17eee3fb9c4f1c1c"
                )
                .to_vec(),
            ),
        };

        let hash = compute_userop_hash(&userop, ENTRY_POINT_V07, 1);

        assert_eq!(
            hash,
            hex!("6d0a394861c05e39fb043ecfa6bca7ef8976ee6c8300547977c39b8a39b39dda"),
            "UserOp hash must match mainnet-verified value"
        );
    }
}
