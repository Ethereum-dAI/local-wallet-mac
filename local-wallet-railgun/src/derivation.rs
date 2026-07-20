//! Standard RAILGUN key derivation, byte-compatible with RAILGUN-Community `engine`
//! (`src/key-derivation`, commit e2913b3). One BIP-39 mnemonic → the RAILGUN account
//! (custom HMAC-SHA512 HD walk, curve seed "babyjubjub seed", hardened-only) and the
//! local broadcaster EOA (standard secp256k1 BIP-32). Pure bytes in/out; no I/O.

use hmac::{Hmac, Mac};
use sha2::Sha512;
use thiserror::Error;

type HmacSha512 = Hmac<Sha512>;

#[derive(Debug, Error, PartialEq)]
pub enum DerivationError {
    #[error("bip39: {0}")]
    Bip39(String),
    #[error("bip32: {0}")]
    Bip32(String),
}

/// RAILGUN spending-key path m/44'/1984'/0'/0'/0' (indices are hardened internally).
pub const RAILGUN_SPENDING_PATH: [u32; 5] = [44, 1984, 0, 0, 0];
/// RAILGUN viewing-key path m/420'/1984'/0'/0'/0'.
pub const RAILGUN_VIEWING_PATH: [u32; 5] = [420, 1984, 0, 0, 0];

/// BIP-39: mnemonic phrase → 64-byte seed (empty passphrase, matching the engine).
pub fn mnemonic_to_seed(mnemonic: &str) -> Result<[u8; 64], DerivationError> {
    let m = bip39::Mnemonic::parse_normalized(mnemonic)
        .map_err(|e| DerivationError::Bip39(e.to_string()))?;
    Ok(m.to_seed(""))
}

/// BIP-39: entropy (16/20/24/28/32 bytes) → mnemonic phrase.
pub fn entropy_to_mnemonic(entropy: &[u8]) -> Result<String, DerivationError> {
    let m = bip39::Mnemonic::from_entropy(entropy)
        .map_err(|e| DerivationError::Bip39(e.to_string()))?;
    Ok(m.to_string())
}

/// One HD node: 32-byte key + 32-byte chain code.
struct Node {
    key: [u8; 32],
    chain_code: [u8; 32],
}

fn split_i(i: &[u8]) -> Node {
    let mut key = [0u8; 32];
    let mut chain_code = [0u8; 32];
    key.copy_from_slice(&i[0..32]);
    chain_code.copy_from_slice(&i[32..64]);
    Node { key, chain_code }
}

/// Master node: I = HMAC-SHA512(key="babyjubjub seed", msg=seed).
fn master(seed: &[u8]) -> Node {
    let mut mac = HmacSha512::new_from_slice(b"babyjubjub seed").expect("hmac any key len");
    mac.update(seed);
    split_i(&mac.finalize().into_bytes())
}

/// Hardened child: preImage = 0x00 || parent.key(32) || (index + 0x8000_0000) as BE u32;
/// I = HMAC-SHA512(key=parent.chain_code, msg=preImage). Hardened-only (matches engine).
fn ckd_hardened(parent: &Node, index: u32) -> Node {
    let hardened = index.wrapping_add(0x8000_0000);
    let mut pre = Vec::with_capacity(37);
    pre.push(0x00);
    pre.extend_from_slice(&parent.key);
    pre.extend_from_slice(&hardened.to_be_bytes());
    let mut mac = HmacSha512::new_from_slice(&parent.chain_code).expect("hmac any key len");
    mac.update(&pre);
    split_i(&mac.finalize().into_bytes())
}

/// Walk the RAILGUN custom HD tree from `seed` along `path` (all hardened); return the
/// final node's 32-byte key — used directly as the babyjubjub private key.
pub fn railgun_node_key(seed: &[u8], path: &[u32]) -> [u8; 32] {
    let mut node = master(seed);
    for &index in path {
        node = ckd_hardened(&node, index);
    }
    node.key
}

/// Standard secp256k1 BIP-32: seed → private key at m/44'/60'/0'/0/0 (the broadcaster EOA).
pub fn broadcaster_secp256k1_from_seed(seed: &[u8]) -> Result<[u8; 32], DerivationError> {
    let path: bip32::DerivationPath = "m/44'/60'/0'/0/0"
        .parse()
        .map_err(|e: bip32::Error| DerivationError::Bip32(e.to_string()))?;
    let xprv = bip32::XPrv::derive_from_path(seed, &path)
        .map_err(|e| DerivationError::Bip32(e.to_string()))?;
    let mut out = [0u8; 32];
    out.copy_from_slice(xprv.private_key().to_bytes().as_slice());
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const HARDHAT: &str = "test test test test test test test test test test test junk";
    const SPENDING: &str = "b0958f8bc286ae0832fa83b01b719a225a07ce7b861ff311323f221667b3bd50";
    const VIEWING: &str = "9da4b4f0b5493a6ba3f7df0611c3e0842f7e2bb3d640f313b235f1b75c1d80b9";

    #[test]
    fn railgun_walk_matches_engine_vector() {
        let seed = mnemonic_to_seed(HARDHAT).unwrap();
        let spend = railgun_node_key(&seed, &RAILGUN_SPENDING_PATH);
        let view = railgun_node_key(&seed, &RAILGUN_VIEWING_PATH);
        assert_eq!(hex::encode(spend), SPENDING, "spending key parity");
        assert_eq!(hex::encode(view), VIEWING, "viewing key parity");
    }

    #[test]
    fn entropy_round_trips_through_mnemonic() {
        // 16-byte entropy → 12 words; 32-byte → 24 words. Both must produce a valid seed.
        let m12 = entropy_to_mnemonic(&[0x11; 16]).unwrap();
        assert_eq!(m12.split_whitespace().count(), 12);
        let m24 = entropy_to_mnemonic(&[0x22; 32]).unwrap();
        assert_eq!(m24.split_whitespace().count(), 24);
        assert!(mnemonic_to_seed(&m24).is_ok());
    }

    #[test]
    fn broadcaster_key_matches_hardhat_account_zero() {
        let seed = mnemonic_to_seed(HARDHAT).unwrap();
        let key = broadcaster_secp256k1_from_seed(&seed).unwrap();
        // Feed the derived key to alloy's signer and check the address (hardhat account #0).
        let hex_key = format!("0x{}", hex::encode(key));
        let signer: alloy::signers::local::PrivateKeySigner = hex_key.parse().unwrap();
        // `{:?}` on alloy's `Address` renders plain lowercase hex; `{}` (Display) renders
        // the EIP-55 checksummed form, which is what the expected vector uses.
        assert_eq!(
            format!("{}", signer.address()),
            "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
        );
    }
}
