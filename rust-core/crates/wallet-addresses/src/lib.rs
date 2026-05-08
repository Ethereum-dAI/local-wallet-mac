//! Shared pinned Ethereum addresses and bytecode hashes.

use alloy_primitives::{address, b256, Address, B256};

pub const MAINNET_CHAIN_ID: u64 = 1;
pub const SEPOLIA_CHAIN_ID: u64 = 11_155_111;

/// EntryPoint v0.7 address.
pub const ENTRY_POINT_V07: Address = address!("0000000071727De22E5E9d8BAf0edAc6f37da032");

pub const PINNED_KERNEL_FACTORY_ADDRESS: Address =
    address!("2577507b78c2008Ff367261CB6285d44ba5eF2E9");
pub const PINNED_KERNEL_IMPLEMENTATION_ADDRESS: Address =
    address!("d6CEDDe84be40893d153Be9d467CD6aD37875b28");
pub const PINNED_WEBAUTHN_VALIDATOR_ADDRESS: Address =
    address!("7ab16Ff354AcB328452F1D445b3Ddee9a91e9e69");

/// Daimo P-256 verifier, used when the RIP-7212 precompile is unavailable.
pub const DAIMO_P256_VERIFIER_ADDRESS: Address =
    address!("c2b78104907F722DABAc4C69f826a522B2754De4");

/// Solady ERC-1967 proxy runtime code hash used by Kernel accounts.
pub const SOLADY_ERC1967_PROXY_RUNTIME_HASH: B256 =
    b256!("aaa52c8cc8a0e3fd27ce756cc6b4e70c51423e9b597b11f32d3e49f8b1fc890d");

/// ERC-1967 implementation storage slot.
pub const ERC1967_IMPLEMENTATION_SLOT: B256 =
    b256!("360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pinned_addresses_match_legacy_literals() {
        assert_eq!(
            ENTRY_POINT_V07,
            address!("0000000071727De22E5E9d8BAf0edAc6f37da032")
        );
        assert_eq!(
            DAIMO_P256_VERIFIER_ADDRESS,
            address!("c2b78104907F722DABAc4C69f826a522B2754De4")
        );
        assert_eq!(
            PINNED_KERNEL_FACTORY_ADDRESS,
            address!("2577507b78c2008Ff367261CB6285d44ba5eF2E9")
        );
    }
}
