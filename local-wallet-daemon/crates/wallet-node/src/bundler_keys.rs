use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use alloy_primitives::{keccak256, Address, Bytes, U256};
use secp256k1::{ecdsa::RecoveryId, Message, PublicKey, Secp256k1, SecretKey};
use thiserror::Error;
use wallet_bundler::Eip1559Signature;
use zeroize::Zeroizing;

pub(crate) const KEY_REF_PREFIX: &str = "bundler-eoa:";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct CanonicalBundlerKeyRef<'a> {
    pub(crate) owner_scope: &'a str,
    pub(crate) chain_id: u64,
    pub(crate) index: u64,
}

/// Parses the sole authority-bearing relayer key-reference representation.
/// Decimal fields must round-trip exactly, so aliases such as `01` are rejected,
/// and index zero is reserved as invalid rather than becoming a second genesis key.
pub(crate) fn parse_canonical_key_ref(
    key_ref: &str,
) -> Result<CanonicalBundlerKeyRef<'_>, BundlerKeyError> {
    let parts = key_ref.split(':').collect::<Vec<_>>();
    if parts.len() != 4 || parts[0] != "bundler-eoa" || parts[1].is_empty() {
        return Err(invalid_key_ref(key_ref));
    }
    let chain_id = parts[2]
        .parse::<u64>()
        .map_err(|_| invalid_key_ref(key_ref))?;
    let index = parts[3]
        .parse::<u64>()
        .map_err(|_| invalid_key_ref(key_ref))?;
    if chain_id == 0
        || parts[2] != chain_id.to_string()
        || index == 0
        || parts[3] != index.to_string()
    {
        return Err(invalid_key_ref(key_ref));
    }
    Ok(CanonicalBundlerKeyRef {
        owner_scope: parts[1],
        chain_id,
        index,
    })
}

fn invalid_key_ref(key_ref: &str) -> BundlerKeyError {
    BundlerKeyError::InvalidKey(format!("invalid canonical bundler key ref: {key_ref}"))
}

#[derive(Debug, Error)]
pub(crate) enum BundlerKeyError {
    #[error("bundler keychain unavailable: {0}")]
    KeychainUnavailable(String),

    #[error("bundler key not found: {0}")]
    KeyNotFound(String),

    #[error("invalid bundler key material: {0}")]
    InvalidKey(String),

    #[error("bundler signing failed: {0}")]
    Signing(String),
}

pub(crate) trait BundlerKeyStore: Send + Sync {
    fn create_key(&self, key_ref: &str) -> Result<Address, BundlerKeyError>;
    fn install_key(&self, key_ref: &str, secret: [u8; 32]) -> Result<Address, BundlerKeyError>;
    fn is_key_loaded(&self, key_ref: &str) -> Result<bool, BundlerKeyError>;
    #[cfg(test)]
    fn address_for_key(&self, key_ref: &str) -> Result<Address, BundlerKeyError>;
    fn delete_key(&self, key_ref: &str) -> Result<(), BundlerKeyError>;
    fn sign_eip1559_payload(
        &self,
        key_ref: &str,
        payload: &Bytes,
    ) -> Result<Eip1559Signature, BundlerKeyError>;
}

pub(crate) fn default_bundler_key_store() -> Arc<dyn BundlerKeyStore> {
    Arc::new(InMemoryBundlerKeyStore::new())
}

#[cfg(test)]
pub(crate) fn next_key_ref<'a>(
    existing_refs: impl Iterator<Item = &'a str>,
) -> Result<String, BundlerKeyError> {
    let mut max = 0_u64;
    for key_ref in existing_refs {
        let Some(value) = key_ref.strip_prefix(KEY_REF_PREFIX) else {
            continue;
        };
        let parsed = value.parse::<u64>().map_err(|_| {
            BundlerKeyError::InvalidKey(format!("invalid bundler key ref: {key_ref}"))
        })?;
        max = max.max(parsed);
    }
    Ok(format!("{KEY_REF_PREFIX}{}", max + 1))
}

pub(crate) fn next_scoped_key_ref<'a>(
    owner_scope: &str,
    chain_id: u64,
    existing_refs: impl Iterator<Item = &'a str>,
) -> Result<String, BundlerKeyError> {
    let mut max = 0_u64;
    for key_ref in existing_refs {
        let parsed = parse_canonical_key_ref(key_ref)?;
        if parsed.owner_scope != owner_scope || parsed.chain_id != chain_id {
            return Err(invalid_key_ref(key_ref));
        }
        max = max.max(parsed.index);
    }
    let next = max.checked_add(1).ok_or_else(|| {
        BundlerKeyError::InvalidKey("bundler key reference index exhausted".to_string())
    })?;
    Ok(format!("{KEY_REF_PREFIX}{owner_scope}:{chain_id}:{next}"))
}

fn secret_address(secret: &SecretKey) -> Address {
    let secp = Secp256k1::signing_only();
    let public = PublicKey::from_secret_key(&secp, secret);
    let uncompressed = public.serialize_uncompressed();
    let hash = keccak256(&uncompressed[1..]);
    Address::from_slice(&hash[12..])
}

fn parse_secret(key_ref: &str, secret: &[u8; 32]) -> Result<SecretKey, BundlerKeyError> {
    SecretKey::from_slice(secret)
        .map_err(|err| BundlerKeyError::InvalidKey(format!("{key_ref}: {err}")))
}

pub(crate) fn address_for_secret(
    key_ref: &str,
    secret: &[u8; 32],
) -> Result<Address, BundlerKeyError> {
    parse_secret(key_ref, secret).map(|secret| secret_address(&secret))
}

fn sign_payload(secret: &SecretKey, payload: &Bytes) -> Result<Eip1559Signature, BundlerKeyError> {
    let secp = Secp256k1::signing_only();
    let digest = keccak256(payload);
    let msg = Message::from_digest(*digest);
    let sig = secp.sign_ecdsa_recoverable(&msg, secret);
    let (recovery_id, compact) = sig.serialize_compact();
    let y_parity = match recovery_id {
        RecoveryId::Zero | RecoveryId::Two => false,
        RecoveryId::One | RecoveryId::Three => true,
    };
    let r = U256::from_be_bytes::<32>(
        compact[..32]
            .try_into()
            .map_err(|_| BundlerKeyError::Signing("invalid r length".to_string()))?,
    );
    let s = U256::from_be_bytes::<32>(
        compact[32..]
            .try_into()
            .map_err(|_| BundlerKeyError::Signing("invalid s length".to_string()))?,
    );

    Ok(Eip1559Signature { y_parity, r, s })
}

pub(crate) struct InMemoryBundlerKeyStore {
    keys: Mutex<BTreeMap<String, Zeroizing<[u8; 32]>>>,
}

impl InMemoryBundlerKeyStore {
    pub(crate) fn new() -> Self {
        Self {
            keys: Mutex::new(BTreeMap::new()),
        }
    }
}

impl BundlerKeyStore for InMemoryBundlerKeyStore {
    fn create_key(&self, _key_ref: &str) -> Result<Address, BundlerKeyError> {
        Err(BundlerKeyError::KeychainUnavailable(
            "in-memory key store does not support create_key; install_key must be used".to_string(),
        ))
    }

    fn install_key(&self, key_ref: &str, secret: [u8; 32]) -> Result<Address, BundlerKeyError> {
        let parsed = parse_secret(key_ref, &secret)?;
        let address = secret_address(&parsed);
        self.keys
            .lock()
            .map_err(|_| BundlerKeyError::KeychainUnavailable("lock poisoned".to_string()))?
            .insert(key_ref.to_string(), Zeroizing::new(secret));
        Ok(address)
    }

    fn is_key_loaded(&self, key_ref: &str) -> Result<bool, BundlerKeyError> {
        Ok(self
            .keys
            .lock()
            .map_err(|_| BundlerKeyError::KeychainUnavailable("lock poisoned".to_string()))?
            .contains_key(key_ref))
    }

    #[cfg(test)]
    fn address_for_key(&self, key_ref: &str) -> Result<Address, BundlerKeyError> {
        let keys = self
            .keys
            .lock()
            .map_err(|_| BundlerKeyError::KeychainUnavailable("lock poisoned".to_string()))?;
        let secret = keys
            .get(key_ref)
            .ok_or_else(|| BundlerKeyError::KeyNotFound(key_ref.to_string()))?;
        Ok(secret_address(&parse_secret(key_ref, secret)?))
    }

    fn delete_key(&self, key_ref: &str) -> Result<(), BundlerKeyError> {
        self.keys
            .lock()
            .map_err(|_| BundlerKeyError::KeychainUnavailable("lock poisoned".to_string()))?
            .remove(key_ref)
            .map(|_| ())
            .ok_or_else(|| BundlerKeyError::KeyNotFound(key_ref.to_string()))
    }

    fn sign_eip1559_payload(
        &self,
        key_ref: &str,
        payload: &Bytes,
    ) -> Result<Eip1559Signature, BundlerKeyError> {
        let keys = self
            .keys
            .lock()
            .map_err(|_| BundlerKeyError::KeychainUnavailable("lock poisoned".to_string()))?;
        let secret = keys
            .get(key_ref)
            .ok_or_else(|| BundlerKeyError::KeyNotFound(key_ref.to_string()))?;
        sign_payload(&parse_secret(key_ref, secret)?, payload)
    }
}

#[cfg(test)]
pub(crate) struct MemoryBundlerKeyStore {
    keys: Mutex<BTreeMap<String, Zeroizing<[u8; 32]>>>,
}

#[cfg(test)]
impl MemoryBundlerKeyStore {
    pub(crate) fn new() -> Self {
        Self {
            keys: Mutex::new(BTreeMap::new()),
        }
    }
}

#[cfg(test)]
impl BundlerKeyStore for MemoryBundlerKeyStore {
    fn create_key(&self, key_ref: &str) -> Result<Address, BundlerKeyError> {
        let mut keys = self
            .keys
            .lock()
            .map_err(|_| BundlerKeyError::KeychainUnavailable("lock poisoned".to_string()))?;
        if let Some(secret) = keys.get(key_ref) {
            return Ok(secret_address(&parse_secret(key_ref, secret)?));
        }
        let mut rng = secp256k1::rand::thread_rng();
        let secret = SecretKey::new(&mut rng);
        let address = secret_address(&secret);
        keys.insert(key_ref.to_string(), Zeroizing::new(secret.secret_bytes()));
        Ok(address)
    }

    fn install_key(&self, key_ref: &str, secret: [u8; 32]) -> Result<Address, BundlerKeyError> {
        let parsed = parse_secret(key_ref, &secret)?;
        let address = secret_address(&parsed);
        self.keys
            .lock()
            .map_err(|_| BundlerKeyError::KeychainUnavailable("lock poisoned".to_string()))?
            .insert(key_ref.to_string(), Zeroizing::new(secret));
        Ok(address)
    }

    fn is_key_loaded(&self, key_ref: &str) -> Result<bool, BundlerKeyError> {
        Ok(self
            .keys
            .lock()
            .map_err(|_| BundlerKeyError::KeychainUnavailable("lock poisoned".to_string()))?
            .contains_key(key_ref))
    }

    fn address_for_key(&self, key_ref: &str) -> Result<Address, BundlerKeyError> {
        let keys = self
            .keys
            .lock()
            .map_err(|_| BundlerKeyError::KeychainUnavailable("lock poisoned".to_string()))?;
        let secret = keys
            .get(key_ref)
            .ok_or_else(|| BundlerKeyError::KeyNotFound(key_ref.to_string()))?;
        Ok(secret_address(&parse_secret(key_ref, secret)?))
    }

    fn sign_eip1559_payload(
        &self,
        key_ref: &str,
        payload: &Bytes,
    ) -> Result<Eip1559Signature, BundlerKeyError> {
        let keys = self
            .keys
            .lock()
            .map_err(|_| BundlerKeyError::KeychainUnavailable("lock poisoned".to_string()))?;
        let secret = keys
            .get(key_ref)
            .ok_or_else(|| BundlerKeyError::KeyNotFound(key_ref.to_string()))?;
        sign_payload(&parse_secret(key_ref, secret)?, payload)
    }

    fn delete_key(&self, key_ref: &str) -> Result<(), BundlerKeyError> {
        self.keys
            .lock()
            .map_err(|_| BundlerKeyError::KeychainUnavailable("lock poisoned".to_string()))?
            .remove(key_ref)
            .map(|_| ())
            .ok_or_else(|| BundlerKeyError::KeyNotFound(key_ref.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn next_key_ref_advances_numeric_suffix() {
        let refs = ["bundler-eoa:1", "other", "bundler-eoa:4"];
        assert_eq!(next_key_ref(refs.into_iter()).unwrap(), "bundler-eoa:5");
    }

    #[test]
    fn next_scoped_key_ref_advances_owner_chain_suffix() {
        let refs = ["bundler-eoa:default:1:1", "bundler-eoa:default:1:4"];
        assert_eq!(
            next_scoped_key_ref("default", 1, refs.into_iter()).unwrap(),
            "bundler-eoa:default:1:5"
        );
    }

    #[test]
    fn next_scoped_key_ref_fails_closed_on_corrupt_or_exhausted_history() {
        for invalid in [
            "bundler-eoa:default:1:01".to_string(),
            "bundler-eoa:default:1:0".to_string(),
            "bundler-eoa:other:1:1".to_string(),
            "bundler-eoa:default:2:1".to_string(),
            "bundler-eoa:default:1:garbage".to_string(),
            format!("bundler-eoa:default:1:{}", u64::MAX),
        ] {
            assert!(
                next_scoped_key_ref("default", 1, std::iter::once(invalid.as_str())).is_err(),
                "{invalid}"
            );
        }
    }

    #[test]
    fn canonical_key_ref_parser_rejects_aliases_and_zero_values() {
        assert_eq!(
            parse_canonical_key_ref("bundler-eoa:default:1:7").unwrap(),
            CanonicalBundlerKeyRef {
                owner_scope: "default",
                chain_id: 1,
                index: 7,
            }
        );

        for invalid in [
            "bundler-eoa:1",
            "bundler-eoa::1:1",
            "bundler-eoa:default:0:1",
            "bundler-eoa:default:01:1",
            "bundler-eoa:default:1:0",
            "bundler-eoa:default:1:01",
            "bundler-eoa:default:1:1:extra",
        ] {
            assert!(parse_canonical_key_ref(invalid).is_err(), "{invalid}");
        }
    }

    #[test]
    fn memory_key_store_creates_address_and_signs_payload() {
        let store = MemoryBundlerKeyStore::new();
        assert!(!store.is_key_loaded("bundler-eoa:1").unwrap());
        let address = store.create_key("bundler-eoa:1").unwrap();
        assert!(store.is_key_loaded("bundler-eoa:1").unwrap());
        assert_eq!(store.address_for_key("bundler-eoa:1").unwrap(), address);
        let sig = store
            .sign_eip1559_payload("bundler-eoa:1", &Bytes::from_static(&[0x02, 0xc0]))
            .unwrap();
        assert!(!sig.r.is_zero());
        assert!(!sig.s.is_zero());
        store.delete_key("bundler-eoa:1").unwrap();
        assert!(!store.is_key_loaded("bundler-eoa:1").unwrap());
        assert!(matches!(
            store.address_for_key("bundler-eoa:1"),
            Err(BundlerKeyError::KeyNotFound(_))
        ));
    }

    #[test]
    fn in_memory_store_signs_with_supplied_secret_and_rejects_create() {
        let store = InMemoryBundlerKeyStore::new();
        assert!(!store.is_key_loaded("bundler-eoa:default:1:1").unwrap());
        let address = store
            .install_key("bundler-eoa:default:1:1", [1u8; 32])
            .unwrap();
        assert!(store.is_key_loaded("bundler-eoa:default:1:1").unwrap());
        assert_ne!(address, Address::ZERO);

        let sig = store
            .sign_eip1559_payload(
                "bundler-eoa:default:1:1",
                &Bytes::from_static(&[0x02, 0xc0]),
            )
            .unwrap();
        assert!(!sig.r.is_zero());

        let err = store.create_key("any").unwrap_err();
        assert!(matches!(err, BundlerKeyError::KeychainUnavailable(_)));
    }

    #[test]
    fn in_memory_store_zeroizes_on_delete() {
        let store = InMemoryBundlerKeyStore::new();
        store.install_key("k", [7u8; 32]).unwrap();
        store.delete_key("k").unwrap();
        assert!(matches!(
            store.address_for_key("k"),
            Err(BundlerKeyError::KeyNotFound(_))
        ));
    }
}
