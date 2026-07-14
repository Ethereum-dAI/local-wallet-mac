//! Deterministic RAILGUN account-key derivation from the shielded entropy.
//!
//! The RAILGUN account is a spending key + viewing key pair (BabyJubJub). We derive
//! both deterministically from the 32-byte fd-5 entropy by seeding a ChaCha20 CSPRNG
//! and drawing the keys from it — the same `rng.random()` path the crate's own tests
//! use, so the keys are valid curve scalars. Deterministic ⇒ the same entropy always
//! recovers the same shielded account.
//!
//! Note: this is a self-consistent derivation, NOT (yet) byte-compatible with the
//! RAILGUN-Community `wallet-node.ts` BIP-32 scheme; cross-tool recovery is future work.
//! Keys never leave this process, are never logged, and are never returned over RPC.

use std::sync::Arc;

use railgun::account::signer::PrivateKeySigner;
use rand::{Rng, SeedableRng};
use rand_chacha::ChaCha20Rng;

use crate::secret::{parse_entropy_32, SecretError};

/// Derive the RAILGUN account signer for `chain_id` from hex entropy.
///
/// The `SpendingKey`/`ViewingKey` types are inferred from `new_evm`'s signature via the
/// `StandardUniform` distribution, so we never need to name those (crate-private-bounded)
/// types directly.
pub fn derive_railgun_signer(
    entropy_hex: &str,
    chain_id: u64,
) -> Result<Arc<PrivateKeySigner>, SecretError> {
    let seed = parse_entropy_32(entropy_hex)?;
    let mut rng = ChaCha20Rng::from_seed(seed);
    // Order matters: spending key first, then viewing key.
    Ok(PrivateKeySigner::new_evm(
        rng.random(),
        rng.random(),
        chain_id,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    const E1: &str = "0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";
    const E2: &str = "0xff02030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";

    fn addr_str(entropy: &str) -> String {
        let s = derive_railgun_signer(entropy, 11155111).unwrap();
        // RailgunSigner is in scope via the trait; address() is on the trait.
        use railgun::account::signer::RailgunSigner;
        format!("{:?}", s.address())
    }

    #[test]
    fn derivation_is_deterministic() {
        assert_eq!(
            addr_str(E1),
            addr_str(E1),
            "same entropy → same shielded address"
        );
    }

    #[test]
    fn different_entropy_yields_different_address() {
        assert_ne!(
            addr_str(E1),
            addr_str(E2),
            "different entropy → different address"
        );
    }

    #[test]
    fn rejects_bad_entropy() {
        assert!(derive_railgun_signer("0x00", 11155111).is_err());
    }
}
