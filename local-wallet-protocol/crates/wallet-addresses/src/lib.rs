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

/// ZeroDev modular-permission modules for Kernel v3.3 / EntryPoint v0.7.
/// Same address on Mainnet and Sepolia.
pub const ECDSA_SIGNER_MODULE: Address = address!("6A6F069E2a08c2468e7724Ab3250CdBFBA14D4FF");
pub const GAS_POLICY: Address = address!("aeFC5AbC67FfD258abD0A3E54f65E70326F84b23");
pub const RATE_LIMIT_POLICY: Address = address!("f63d4139B25c836334edD76641356c6b74C86873");
pub const TIMESTAMP_POLICY: Address = address!("B9f8f524bE6EcD8C945b1b87f9ae5C192FdCE20F");
pub const SUDO_POLICY: Address = address!("67b436caD8a6D025DF6C82C5BB43fbF11fC5B9B7");
pub const CALL_POLICY_V0_0_5: Address = address!("85770b902D1e503D5f5141d9eaC16d0d08eEaDd2");

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

    #[test]
    fn permission_module_addresses_are_pinned() {
        assert_eq!(
            ECDSA_SIGNER_MODULE,
            address!("6A6F069E2a08c2468e7724Ab3250CdBFBA14D4FF")
        );
        assert_eq!(
            GAS_POLICY,
            address!("aeFC5AbC67FfD258abD0A3E54f65E70326F84b23")
        );
        assert_eq!(
            RATE_LIMIT_POLICY,
            address!("f63d4139B25c836334edD76641356c6b74C86873")
        );
        assert_eq!(
            TIMESTAMP_POLICY,
            address!("B9f8f524bE6EcD8C945b1b87f9ae5C192FdCE20F")
        );
        assert_eq!(
            SUDO_POLICY,
            address!("67b436caD8a6D025DF6C82C5BB43fbF11fC5B9B7")
        );
        assert_eq!(
            CALL_POLICY_V0_0_5,
            address!("85770b902D1e503D5f5141d9eaC16d0d08eEaDd2")
        );
    }
}
