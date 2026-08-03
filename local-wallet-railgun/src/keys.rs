//! Standard RAILGUN account-key derivation from the shielded entropy.
//!
//! One 32-byte entropy → a BIP-39 mnemonic → the RAILGUN spending + viewing keys via the
//! custom RAILGUN HD walk (see `derivation`). Byte-compatible with RAILGUN-Community
//! `engine`, so the shielded account is recoverable/importable by other RAILGUN wallets.
//! Keys never leave this process, are never logged, and are never returned over RPC.

use std::sync::Arc;

use railgun::account::signer::PrivateKeySigner;
use railgun::crypto::keys::{HexKey, SpendingKey, ViewingKey};

use crate::derivation::{self, RAILGUN_SPENDING_PATH, RAILGUN_VIEWING_PATH};
use crate::secret::{parse_entropy_32, SecretError};

/// Derive the RAILGUN account signer for `chain_id` from the 32-byte hex entropy.
pub fn derive_railgun_signer(
    entropy_hex: &str,
    chain_id: u64,
) -> Result<Arc<PrivateKeySigner>, SecretError> {
    let entropy = parse_entropy_32(entropy_hex)?;
    let mnemonic = derivation::entropy_to_mnemonic(&entropy)
        .map_err(|e| SecretError::Derivation(e.to_string()))?;
    let seed = derivation::mnemonic_to_seed(&mnemonic)
        .map_err(|e| SecretError::Derivation(e.to_string()))?;

    let spend = derivation::railgun_node_key(&seed, &RAILGUN_SPENDING_PATH);
    let view = derivation::railgun_node_key(&seed, &RAILGUN_VIEWING_PATH);
    let spending = SpendingKey::from_hex(&hex::encode(spend))
        .map_err(|e| SecretError::Derivation(format!("{e:?}")))?;
    let viewing = ViewingKey::from_hex(&hex::encode(view))
        .map_err(|e| SecretError::Derivation(format!("{e:?}")))?;

    Ok(PrivateKeySigner::new_evm(spending, viewing, chain_id))
}

/// entropy hex → BIP-39 mnemonic → 64-byte BIP-39 seed. The shared prefix of every
/// secp256k1 derivation below.
fn seed_from_entropy(entropy_hex: &str) -> Result<[u8; 64], SecretError> {
    let entropy = parse_entropy_32(entropy_hex)?;
    let mnemonic = derivation::entropy_to_mnemonic(&entropy)
        .map_err(|e| SecretError::Derivation(e.to_string()))?;
    derivation::mnemonic_to_seed(&mnemonic).map_err(|e| SecretError::Derivation(e.to_string()))
}

/// Derive the ephemeral EIP-7702 exit-sender private key (0x-hex) for exit `index`, from the
/// same 32-byte entropy as the RAILGUN account, at `m/44'/60'/0'/1/{index}`.
///
/// **`change = 1`, the BIP-44 internal branch, is deliberate**: it keeps exit senders in a
/// keyspace disjoint from the broadcaster EOA at `m/44'/60'/0'/0/0`, which is funded and has
/// already transacted publicly. See `derivation::exit_secp256k1_from_seed_at_index`.
///
/// This key signs the UserOperation and its 7702 authorization. It is never funded, never
/// logged, and never returned over RPC. A seed leak gains an attacker nothing here: that
/// same seed already controls the shielded funds.
pub fn derive_exit_key(entropy_hex: &str, index: u32) -> Result<String, SecretError> {
    let seed = seed_from_entropy(entropy_hex)?;
    let key = derivation::exit_secp256k1_from_seed_at_index(&seed, index)
        .map_err(|e| SecretError::Derivation(e.to_string()))?;
    Ok(format!("0x{}", hex::encode(key)))
}

/// Derive the local broadcaster EOA private key (0x-hex) from the same 32-byte entropy,
/// at standard Ethereum path m/44'/60'/0'/0/0. Distinct from the RAILGUN account, and — since
/// exit senders live on `change = 1` — distinct from every exit sender.
// Removed in Task 6 with the broadcaster itself; kept so every commit builds.
pub fn derive_broadcaster_key(entropy_hex: &str) -> Result<String, SecretError> {
    let seed = seed_from_entropy(entropy_hex)?;
    let key = derivation::broadcaster_secp256k1_from_seed(&seed)
        .map_err(|e| SecretError::Derivation(e.to_string()))?;
    Ok(format!("0x{}", hex::encode(key)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use railgun::account::chain::ChainId;
    use railgun::account::signer::{PrivateKeySigner, RailgunSigner};
    use railgun::crypto::keys::{HexKey, SpendingKey, ViewingKey};

    const HARDHAT: &str = "test test test test test test test test test test test junk";
    const RAILGUN_0ZK: &str = "0zk1qyk9nn28x0u3rwn5pknglda68wrn7gw6anjw8gg94mcj6eq5u48tlrv7j6fe3z53lama02nutwtcqc979wnce0qwly4y7w4rls5cq040g7z8eagshxrw5ajy990";

    // Full pipeline parity: hardhat mnemonic → RAILGUN account → 0zk address (ChainId::All,
    // the engine's "default chain" vector). Cross-validates our walk + Kohaku's encoding.
    #[test]
    fn hardhat_mnemonic_yields_engine_railgun_address() {
        let seed = crate::derivation::mnemonic_to_seed(HARDHAT).unwrap();
        let spend =
            crate::derivation::railgun_node_key(&seed, &crate::derivation::RAILGUN_SPENDING_PATH);
        let view =
            crate::derivation::railgun_node_key(&seed, &crate::derivation::RAILGUN_VIEWING_PATH);
        let spending = SpendingKey::from_hex(&hex::encode(spend)).unwrap();
        let viewing = ViewingKey::from_hex(&hex::encode(view)).unwrap();
        let signer = PrivateKeySigner::new(spending, viewing, ChainId::All);
        assert_eq!(signer.address().to_string(), RAILGUN_0ZK);
    }

    const E1: &str = "0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";
    const E2: &str = "0xff02030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";

    fn addr(entropy: &str) -> String {
        format!(
            "{:?}",
            derive_railgun_signer(entropy, 11155111).unwrap().address()
        )
    }

    #[test]
    fn derivation_is_deterministic() {
        assert_eq!(addr(E1), addr(E1));
    }

    #[test]
    fn different_entropy_yields_different_address() {
        assert_ne!(addr(E1), addr(E2));
    }

    /// Frozen regression vector for `derive_railgun_signer`'s address for `E1` @ chain 11155111.
    /// If `derive_railgun_signer`'s body is ever reverted to the old ChaCha20-CSPRNG scheme
    /// (which never calls `entropy_to_mnemonic`), this address will change and the test below
    /// will fail.
    const E1_SEPOLIA_ADDRESS: &str = "0zk1qyhp25ulukkge548f770q889vygfxvhrce3ve02f9ffnpg2n4cr7zunpd9kx0h6c5ulxljytkqzlx66e69axgr5gj4dl8h29fwwyvhw4fte6mpd0cj3vugswtef";

    // Exercises `derive_railgun_signer` itself (not just the `derivation` primitives): computes
    // the expected address by independently walking the same entropy -> mnemonic -> seed ->
    // spend/view node -> signer pipeline that `derive_railgun_signer` uses internally, then
    // asserts the two agree. Also pins the result as a hardcoded constant so a silent revert to
    // the old ChaCha20 body (which would produce a different address) fails this test outright.
    #[test]
    fn derive_railgun_signer_matches_independently_derived_address() {
        let chain_id = 11155111u64;
        let entropy = crate::secret::parse_entropy_32(E1).unwrap();

        let mnemonic = crate::derivation::entropy_to_mnemonic(&entropy).unwrap();
        let seed = crate::derivation::mnemonic_to_seed(&mnemonic).unwrap();
        let spend =
            crate::derivation::railgun_node_key(&seed, &crate::derivation::RAILGUN_SPENDING_PATH);
        let view =
            crate::derivation::railgun_node_key(&seed, &crate::derivation::RAILGUN_VIEWING_PATH);
        let spending = SpendingKey::from_hex(&hex::encode(spend)).unwrap();
        let viewing = ViewingKey::from_hex(&hex::encode(view)).unwrap();
        let expected = PrivateKeySigner::new_evm(spending, viewing, chain_id)
            .address()
            .to_string();

        let actual = derive_railgun_signer(E1, chain_id)
            .unwrap()
            .address()
            .to_string();

        assert_eq!(actual, expected);
        assert_eq!(actual, E1_SEPOLIA_ADDRESS);
    }

    #[test]
    fn broadcaster_key_matches_hardhat_when_derived_from_matching_entropy() {
        // 12-word hardhat = 16-byte entropy; derive_broadcaster_key takes 32-byte entropy,
        // so test the shared seed-based core directly for the published address, and assert
        // derive_broadcaster_key returns a well-formed 0x-key for the 32-byte runtime path.
        use crate::derivation::{broadcaster_secp256k1_from_seed, mnemonic_to_seed};
        let seed = mnemonic_to_seed(HARDHAT).unwrap();
        let key = broadcaster_secp256k1_from_seed(&seed).unwrap();
        let signer: alloy::signers::local::PrivateKeySigner =
            format!("0x{}", hex::encode(key)).parse().unwrap();
        // `{:?}` on alloy's `Address` renders plain lowercase hex; `{}` (Display) renders
        // the EIP-55 checksummed form, which is what the published hardhat vector uses.
        assert_eq!(
            format!("{}", signer.address()),
            "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
        );

        // Runtime path (32-byte entropy) returns a valid, parseable key.
        let k = derive_broadcaster_key(E1).unwrap();
        assert!(k.starts_with("0x") && k.len() == 66);
        let _: alloy::signers::local::PrivateKeySigner = k.parse().unwrap();
    }

    /// Address of an EOA key, so assertions never print key material on failure.
    fn eoa_address(key_hex: &str) -> String {
        let signer: alloy::signers::local::PrivateKeySigner = key_hex.parse().unwrap();
        format!("{}", signer.address())
    }

    #[test]
    fn exit_index_zero_is_not_the_broadcaster_address() {
        // Before this was fixed, `derive_exit_key(e, 0)` was byte-identical to
        // `derive_broadcaster_key(e)`: both `m/44'/60'/0'/0/0`. The broadcaster gets FUNDED and
        // submits public relay transactions, so for any wallet that ever used the old unshield
        // path, the first "single-use, never-funded" exit sender would have been their
        // already-published broadcaster address — voiding the unlinkability the derived sender
        // exists to provide. Deleting the broadcaster cannot un-publish it.
        let broadcaster = eoa_address(&derive_broadcaster_key(E1).unwrap());
        assert_ne!(
            eoa_address(&derive_exit_key(E1, 0).unwrap()),
            broadcaster,
            "exit index 0 must not reuse the broadcaster address"
        );
        // No exit index may collide with it either.
        for i in 0..8u32 {
            assert_ne!(
                eoa_address(&derive_exit_key(E1, i).unwrap()),
                broadcaster,
                "exit index {i} must not be the broadcaster address"
            );
        }
    }

    #[test]
    fn exit_keys_are_deterministic_and_index_unique() {
        // Determinism is what makes a stranded exit recoverable from the seed alone.
        assert_eq!(
            derive_exit_key(E1, 5).unwrap(),
            derive_exit_key(E1, 5).unwrap()
        );
        assert_ne!(
            eoa_address(&derive_exit_key(E1, 5).unwrap()),
            eoa_address(&derive_exit_key(E1, 6).unwrap())
        );
        assert_ne!(
            eoa_address(&derive_exit_key(E1, 5).unwrap()),
            eoa_address(&derive_exit_key(E2, 5).unwrap()),
            "different wallets must not share an exit sender"
        );
    }
}
