//! Profile types that bundle the app-pinned Kernel choices and supported-chain
//! enumeration into named, legible structs.
//!
//! These exist so a reader can see the seams of the daemon's opinions in one
//! place. Today only `KERNEL_V3_3_0_PROFILE` exists; a fork retargeting Local
//! Wallet for a different account shape replaces this constant.

use alloy_primitives::{address, Address, B256};
use wallet_addresses::{
    DAIMO_P256_VERIFIER_ADDRESS, ERC1967_IMPLEMENTATION_SLOT, PINNED_KERNEL_FACTORY_ADDRESS,
    PINNED_KERNEL_IMPLEMENTATION_ADDRESS, PINNED_WEBAUTHN_VALIDATOR_ADDRESS,
    SOLADY_ERC1967_PROXY_RUNTIME_HASH,
};
pub use wallet_addresses::{MAINNET_CHAIN_ID, SEPOLIA_CHAIN_ID};

use crate::allowlist::{
    AllowlistedCodeHash, STATIC_DAIMO_P256_VERIFIER_CODE_HASHES, STATIC_KERNEL_FACTORY_CODE_HASHES,
    STATIC_KERNEL_IMPLEMENTATION_CODE_HASHES, STATIC_KERNEL_PROXY_CODE_HASHES,
    STATIC_WEBAUTHN_VALIDATOR_CODE_HASHES,
};

/// All of the pinned data points that define one Kernel-flavored account profile.
///
/// A fork retargeting Local Wallet for a different account shape replaces the
/// `KERNEL_V3_3_0_PROFILE` constant below with one of its own. The runtime
/// allowlist consults this profile rather than reading the underlying
/// constants directly.
#[derive(Clone, Debug)]
pub struct KernelProfile {
    pub label: &'static str,
    pub factory: Address,
    pub implementation: Address,
    pub webauthn_validator: Address,
    pub p256_fallback_verifier: Address,
    pub erc1967_implementation_slot: B256,
    pub solady_proxy_runtime_hash: B256,
    pub factory_code_hashes: &'static [AllowlistedCodeHash],
    pub implementation_code_hashes: &'static [AllowlistedCodeHash],
    pub webauthn_validator_code_hashes: &'static [AllowlistedCodeHash],
    pub solady_proxy_code_hashes: &'static [AllowlistedCodeHash],
    pub p256_fallback_verifier_code_hashes: &'static [AllowlistedCodeHash],
}

/// The single profile currently shipped by the daemon. Pins Kernel v3.3.0
/// (factory + implementation + WebAuthn validator) on mainnet and Sepolia,
/// with the Daimo P-256 fallback verifier as the non-precompile signature
/// path.
pub const KERNEL_V3_3_0_PROFILE: KernelProfile = KernelProfile {
    label: "kernel-v3.3.0",
    factory: PINNED_KERNEL_FACTORY_ADDRESS,
    implementation: PINNED_KERNEL_IMPLEMENTATION_ADDRESS,
    webauthn_validator: PINNED_WEBAUTHN_VALIDATOR_ADDRESS,
    p256_fallback_verifier: DAIMO_P256_VERIFIER_ADDRESS,
    erc1967_implementation_slot: ERC1967_IMPLEMENTATION_SLOT,
    solady_proxy_runtime_hash: SOLADY_ERC1967_PROXY_RUNTIME_HASH,
    factory_code_hashes: STATIC_KERNEL_FACTORY_CODE_HASHES,
    implementation_code_hashes: STATIC_KERNEL_IMPLEMENTATION_CODE_HASHES,
    webauthn_validator_code_hashes: STATIC_WEBAUTHN_VALIDATOR_CODE_HASHES,
    solady_proxy_code_hashes: STATIC_KERNEL_PROXY_CODE_HASHES,
    p256_fallback_verifier_code_hashes: STATIC_DAIMO_P256_VERIFIER_CODE_HASHES,
};

/// The chains the daemon currently supports. Picked at startup; changing the
/// supported set is a deliberate edit to this enum.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SupportedChain {
    Mainnet,
    Sepolia,
}

impl SupportedChain {
    pub const fn chain_id(&self) -> u64 {
        match self {
            Self::Mainnet => MAINNET_CHAIN_ID,
            Self::Sepolia => SEPOLIA_CHAIN_ID,
        }
    }

    pub fn from_chain_id(chain_id: u64) -> Option<Self> {
        if chain_id == MAINNET_CHAIN_ID {
            Some(Self::Mainnet)
        } else if chain_id == SEPOLIA_CHAIN_ID {
            Some(Self::Sepolia)
        } else {
            None
        }
    }
}

/// EntryPoint protocol version. Today only v0.7 is supported; v0.8 is
/// reserved for a future protocol bump (see Direction: open-source readiness
/// brief).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EntryPointVersion {
    V07,
}

impl EntryPointVersion {
    pub const fn pinned_address(&self) -> Address {
        match self {
            Self::V07 => address!("0000000071727De22E5E9d8BAf0edAc6f37da032"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kernel_v3_3_0_profile_matches_legacy_constants() {
        let p = &KERNEL_V3_3_0_PROFILE;
        assert_eq!(p.factory, PINNED_KERNEL_FACTORY_ADDRESS);
        assert_eq!(p.implementation, PINNED_KERNEL_IMPLEMENTATION_ADDRESS);
        assert_eq!(p.webauthn_validator, PINNED_WEBAUTHN_VALIDATOR_ADDRESS);
        assert_eq!(p.p256_fallback_verifier, DAIMO_P256_VERIFIER_ADDRESS);
        assert_eq!(p.erc1967_implementation_slot, ERC1967_IMPLEMENTATION_SLOT);
        assert_eq!(
            p.solady_proxy_runtime_hash,
            SOLADY_ERC1967_PROXY_RUNTIME_HASH
        );
    }

    #[test]
    fn kernel_v3_3_0_profile_pins_two_chains_per_layer() {
        let p = &KERNEL_V3_3_0_PROFILE;
        assert_eq!(p.factory_code_hashes.len(), 2);
        assert_eq!(p.implementation_code_hashes.len(), 2);
        assert_eq!(p.webauthn_validator_code_hashes.len(), 2);
        assert_eq!(p.solady_proxy_code_hashes.len(), 2);
        assert_eq!(p.p256_fallback_verifier_code_hashes.len(), 2);
    }

    #[test]
    fn supported_chain_round_trips_through_chain_id() {
        for chain in [SupportedChain::Mainnet, SupportedChain::Sepolia] {
            assert_eq!(SupportedChain::from_chain_id(chain.chain_id()), Some(chain));
        }
    }

    #[test]
    fn unknown_chain_id_returns_none() {
        assert_eq!(SupportedChain::from_chain_id(99_999), None);
    }

    #[test]
    fn entry_point_v07_address_is_pinned() {
        assert_eq!(
            EntryPointVersion::V07.pinned_address(),
            address!("0000000071727De22E5E9d8BAf0edAc6f37da032")
        );
    }
}
