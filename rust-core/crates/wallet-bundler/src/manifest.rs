use alloy_primitives::B256;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use std::fmt;
use thiserror::Error;

pub const MAX_MANIFEST_LIFETIME_SECS: u64 = 30 * 24 * 60 * 60;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AllowlistManifest {
    pub version: u64,
    pub issued_at: u64,
    pub expires_at: u64,
    #[serde(default)]
    pub additions: Vec<ManifestAddition>,
    #[serde(default)]
    pub denylist: Vec<ManifestDenylistEntry>,
    pub signatures: ManifestSignatures,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ManifestSignatures {
    pub additions: String,
    pub denylist: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ManifestTrustRoot {
    pub key_id: &'static str,
    pub public_key: [u8; 32],
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ManifestLayer {
    Proxy,
    Implementation,
    Validator,
    Policy,
    Signer,
    Hook,
    Executor,
    Factory,
}

impl fmt::Display for ManifestLayer {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Proxy => "proxy",
            Self::Implementation => "implementation",
            Self::Validator => "validator",
            Self::Policy => "policy",
            Self::Signer => "signer",
            Self::Hook => "hook",
            Self::Executor => "executor",
            Self::Factory => "factory",
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ManifestAddition {
    pub layer: ManifestLayer,
    pub module_type: String,
    pub hash: B256,
    pub label: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ManifestDenylistEntry {
    pub hash: B256,
    pub reason: String,
}

#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum ManifestPromotionError {
    #[error("manifest version {version} is not newer than persisted version {current_version}")]
    VersionNotNewer { version: u64, current_version: u64 },

    #[error("manifest issuedAt {issued_at} is after expiresAt {expires_at}")]
    InvalidTimeRange { issued_at: u64, expires_at: u64 },

    #[error("manifest lifetime {lifetime_secs}s exceeds maximum {max_secs}s")]
    LifetimeTooLong { lifetime_secs: u64, max_secs: u64 },

    #[error("manifest expired at {expires_at}, now {now}")]
    Expired { expires_at: u64, now: u64 },
}

#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum ManifestSignatureError {
    #[error("missing signature key id")]
    MissingKeyId,

    #[error("missing signature bytes")]
    MissingSignature,

    #[error("unknown key id: {0}")]
    UnknownKeyId(String),

    #[error("invalid signature hex")]
    InvalidSignatureHex,

    #[error("invalid signature length: {0}")]
    InvalidSignatureLength(usize),

    #[error("invalid public key for key id: {0}")]
    InvalidPublicKey(&'static str),

    #[error("signature verification failed for key id: {0}")]
    VerificationFailed(String),
}

pub fn validate_manifest_promotion_window(
    manifest: &AllowlistManifest,
    current_version: u64,
    now: u64,
) -> Result<(), ManifestPromotionError> {
    if manifest.version <= current_version {
        return Err(ManifestPromotionError::VersionNotNewer {
            version: manifest.version,
            current_version,
        });
    }

    let lifetime_secs = manifest.expires_at.checked_sub(manifest.issued_at).ok_or(
        ManifestPromotionError::InvalidTimeRange {
            issued_at: manifest.issued_at,
            expires_at: manifest.expires_at,
        },
    )?;

    if lifetime_secs > MAX_MANIFEST_LIFETIME_SECS {
        return Err(ManifestPromotionError::LifetimeTooLong {
            lifetime_secs,
            max_secs: MAX_MANIFEST_LIFETIME_SECS,
        });
    }

    if now >= manifest.expires_at {
        return Err(ManifestPromotionError::Expired {
            expires_at: manifest.expires_at,
            now,
        });
    }

    Ok(())
}

pub fn verify_manifest_signatures(
    manifest: &AllowlistManifest,
    addition_keys: &[ManifestTrustRoot],
    revocation_keys: &[ManifestTrustRoot],
) -> Result<(), ManifestSignatureError> {
    verify_signature_envelope(
        &manifest.signatures.additions,
        canonical_additions_payload(manifest).as_bytes(),
        addition_keys,
    )?;
    verify_signature_envelope(
        &manifest.signatures.denylist,
        canonical_denylist_payload(manifest).as_bytes(),
        revocation_keys,
    )
}

pub fn cached_additions_apply(manifest: &AllowlistManifest, now: u64) -> bool {
    now < manifest.expires_at
}

pub fn denylist_contains(manifest: &AllowlistManifest, hash: B256) -> bool {
    manifest.denylist.iter().any(|entry| entry.hash == hash)
}

pub fn manifest_allows_hash(
    manifest: &AllowlistManifest,
    now: u64,
    layer: ManifestLayer,
    module_type: &str,
    hash: B256,
) -> bool {
    if denylist_contains(manifest, hash) || !cached_additions_apply(manifest, now) {
        return false;
    }

    manifest.additions.iter().any(|addition| {
        addition.layer == layer && addition.module_type == module_type && addition.hash == hash
    })
}

pub fn canonical_additions_payload(manifest: &AllowlistManifest) -> String {
    let additions = manifest
        .additions
        .iter()
        .map(canonical_addition)
        .collect::<Vec<_>>()
        .join(",");
    format!(
        "{{\"version\":{},\"issuedAt\":{},\"expiresAt\":{},\"additions\":[{}]}}",
        manifest.version, manifest.issued_at, manifest.expires_at, additions
    )
}

pub fn canonical_denylist_payload(manifest: &AllowlistManifest) -> String {
    let denylist = manifest
        .denylist
        .iter()
        .map(canonical_denylist_entry)
        .collect::<Vec<_>>()
        .join(",");
    format!(
        "{{\"version\":{},\"issuedAt\":{},\"expiresAt\":{},\"denylist\":[{}]}}",
        manifest.version, manifest.issued_at, manifest.expires_at, denylist
    )
}

fn canonical_addition(addition: &ManifestAddition) -> String {
    format!(
        "{{\"layer\":{},\"moduleType\":{},\"hash\":{},\"label\":{}}}",
        json_string(&addition.layer.to_string()),
        json_string(&addition.module_type),
        json_string(&format!("{:#x}", addition.hash)),
        json_string(&addition.label)
    )
}

fn canonical_denylist_entry(entry: &ManifestDenylistEntry) -> String {
    format!(
        "{{\"hash\":{},\"reason\":{}}}",
        json_string(&format!("{:#x}", entry.hash)),
        json_string(&entry.reason)
    )
}

fn json_string(value: &str) -> String {
    serde_json::to_string(value).expect("serializing a string cannot fail")
}

fn verify_signature_envelope(
    envelope: &str,
    payload: &[u8],
    keys: &[ManifestTrustRoot],
) -> Result<(), ManifestSignatureError> {
    let (key_id, signature_hex) = parse_signature_envelope(envelope)?;
    let trust_root = keys
        .iter()
        .find(|key| key.key_id == key_id)
        .ok_or_else(|| ManifestSignatureError::UnknownKeyId(key_id.to_string()))?;
    let signature_bytes =
        hex::decode(signature_hex).map_err(|_| ManifestSignatureError::InvalidSignatureHex)?;
    let signature: [u8; 64] = signature_bytes
        .try_into()
        .map_err(|bytes: Vec<u8>| ManifestSignatureError::InvalidSignatureLength(bytes.len()))?;
    let verifying_key = VerifyingKey::from_bytes(&trust_root.public_key)
        .map_err(|_| ManifestSignatureError::InvalidPublicKey(trust_root.key_id))?;
    let signature = Signature::from_bytes(&signature);

    verifying_key
        .verify(payload, &signature)
        .map_err(|_| ManifestSignatureError::VerificationFailed(key_id.to_string()))
}

fn parse_signature_envelope(envelope: &str) -> Result<(&str, &str), ManifestSignatureError> {
    let (key_id, signature) = envelope
        .split_once(':')
        .ok_or(ManifestSignatureError::MissingSignature)?;
    if key_id.is_empty() {
        return Err(ManifestSignatureError::MissingKeyId);
    }
    let signature = signature
        .strip_prefix("0x")
        .ok_or(ManifestSignatureError::InvalidSignatureHex)?;
    if signature.is_empty() {
        return Err(ManifestSignatureError::MissingSignature);
    }

    Ok((key_id, signature))
}

#[cfg(test)]
mod tests {
    use alloy_primitives::b256;
    use ed25519_dalek::{Signer, SigningKey};

    use super::*;

    fn sample_manifest() -> AllowlistManifest {
        AllowlistManifest {
            version: 7,
            issued_at: 1_700_000_000,
            expires_at: 1_700_000_000 + MAX_MANIFEST_LIFETIME_SECS,
            additions: vec![ManifestAddition {
                layer: ManifestLayer::Implementation,
                module_type: "kernel_implementation".to_string(),
                hash: b256!("d748c6060679ccb34583963e5edc21299e4c6723e7c7a80561d255861ed209b7"),
                label: "kernel-v3.3.0 implementation mainnet".to_string(),
            }],
            denylist: vec![ManifestDenylistEntry {
                hash: b256!("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
                reason: "key-compromise-2026-04-15".to_string(),
            }],
            signatures: ManifestSignatures {
                additions: "add-key-1:0x01".to_string(),
                denylist: "revoke-key:0x02".to_string(),
            },
        }
    }

    #[test]
    fn manifest_schema_round_trips_camel_case() {
        let encoded = serde_json::to_string(&sample_manifest()).unwrap();
        assert!(encoded.contains("\"issuedAt\""));
        assert!(encoded.contains("\"expiresAt\""));
        assert!(encoded.contains("\"moduleType\""));

        let decoded: AllowlistManifest = serde_json::from_str(&encoded).unwrap();
        assert_eq!(decoded, sample_manifest());
    }

    #[test]
    fn canonical_payloads_match_signature_contract_field_order() {
        let manifest = sample_manifest();

        assert_eq!(
            canonical_additions_payload(&manifest),
            concat!(
                "{\"version\":7,\"issuedAt\":1700000000,\"expiresAt\":1702592000,",
                "\"additions\":[{\"layer\":\"implementation\",",
                "\"moduleType\":\"kernel_implementation\",",
                "\"hash\":\"0xd748c6060679ccb34583963e5edc21299e4c6723e7c7a80561d255861ed209b7\",",
                "\"label\":\"kernel-v3.3.0 implementation mainnet\"}]}"
            )
        );
        assert_eq!(
            canonical_denylist_payload(&manifest),
            concat!(
                "{\"version\":7,\"issuedAt\":1700000000,\"expiresAt\":1702592000,",
                "\"denylist\":[{\"hash\":\"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",",
                "\"reason\":\"key-compromise-2026-04-15\"}]}"
            )
        );
    }

    #[test]
    fn promotion_window_enforces_version_expiry_and_max_lifetime() {
        let mut manifest = sample_manifest();
        validate_manifest_promotion_window(&manifest, 6, manifest.expires_at - 1).unwrap();

        assert!(matches!(
            validate_manifest_promotion_window(&manifest, 7, manifest.expires_at - 1),
            Err(ManifestPromotionError::VersionNotNewer { .. })
        ));
        assert!(matches!(
            validate_manifest_promotion_window(&manifest, 6, manifest.expires_at),
            Err(ManifestPromotionError::Expired { .. })
        ));

        manifest.expires_at = manifest.issued_at + MAX_MANIFEST_LIFETIME_SECS + 1;
        assert!(matches!(
            validate_manifest_promotion_window(&manifest, 6, manifest.issued_at),
            Err(ManifestPromotionError::LifetimeTooLong { .. })
        ));

        manifest.expires_at = manifest.issued_at - 1;
        assert!(matches!(
            validate_manifest_promotion_window(&manifest, 6, manifest.issued_at - 2),
            Err(ManifestPromotionError::InvalidTimeRange { .. })
        ));
    }

    #[test]
    fn cached_additions_expire_but_denylist_persists() {
        let manifest = sample_manifest();
        let denied_hash = manifest.denylist[0].hash;

        assert!(cached_additions_apply(&manifest, manifest.expires_at - 1));
        assert!(!cached_additions_apply(&manifest, manifest.expires_at));
        assert!(denylist_contains(&manifest, denied_hash));
    }

    #[test]
    fn manifest_additions_apply_only_before_expiry_and_after_denylist() {
        let mut manifest = sample_manifest();
        let allowed_hash = manifest.additions[0].hash;

        assert!(manifest_allows_hash(
            &manifest,
            manifest.expires_at - 1,
            ManifestLayer::Implementation,
            "kernel_implementation",
            allowed_hash
        ));
        assert!(!manifest_allows_hash(
            &manifest,
            manifest.expires_at,
            ManifestLayer::Implementation,
            "kernel_implementation",
            allowed_hash
        ));
        assert!(!manifest_allows_hash(
            &manifest,
            manifest.expires_at - 1,
            ManifestLayer::Validator,
            "kernel_implementation",
            allowed_hash
        ));

        manifest.denylist.push(ManifestDenylistEntry {
            hash: allowed_hash,
            reason: "denylist-precedence".to_string(),
        });
        assert!(!manifest_allows_hash(
            &manifest,
            manifest.expires_at - 1,
            ManifestLayer::Implementation,
            "kernel_implementation",
            allowed_hash
        ));
    }

    #[test]
    fn verifies_addition_and_denylist_signatures_with_separate_key_sets() {
        let addition_signing_key = SigningKey::from_bytes(&[0x11; 32]);
        let revocation_signing_key = SigningKey::from_bytes(&[0x22; 32]);
        let mut manifest = sample_manifest();
        manifest.signatures.additions = format!(
            "add-key-1:0x{}",
            hex::encode(
                addition_signing_key
                    .sign(canonical_additions_payload(&manifest).as_bytes())
                    .to_bytes()
            )
        );
        manifest.signatures.denylist = format!(
            "revoke-key:0x{}",
            hex::encode(
                revocation_signing_key
                    .sign(canonical_denylist_payload(&manifest).as_bytes())
                    .to_bytes()
            )
        );

        verify_manifest_signatures(
            &manifest,
            &[ManifestTrustRoot {
                key_id: "add-key-1",
                public_key: addition_signing_key.verifying_key().to_bytes(),
            }],
            &[ManifestTrustRoot {
                key_id: "revoke-key",
                public_key: revocation_signing_key.verifying_key().to_bytes(),
            }],
        )
        .unwrap();
    }

    #[test]
    fn rejects_unknown_or_wrong_manifest_signature_keys() {
        let signing_key = SigningKey::from_bytes(&[0x33; 32]);
        let mut manifest = sample_manifest();
        manifest.signatures.additions = format!(
            "add-key-2:0x{}",
            hex::encode(
                signing_key
                    .sign(canonical_additions_payload(&manifest).as_bytes())
                    .to_bytes()
            )
        );

        assert!(matches!(
            verify_manifest_signatures(
                &manifest,
                &[ManifestTrustRoot {
                    key_id: "add-key-1",
                    public_key: signing_key.verifying_key().to_bytes(),
                }],
                &[]
            ),
            Err(ManifestSignatureError::UnknownKeyId(key)) if key == "add-key-2"
        ));

        manifest.signatures.additions = format!(
            "add-key-1:0x{}",
            hex::encode(
                signing_key
                    .sign(canonical_denylist_payload(&manifest).as_bytes())
                    .to_bytes()
            )
        );
        assert!(matches!(
            verify_manifest_signatures(
                &manifest,
                &[ManifestTrustRoot {
                    key_id: "add-key-1",
                    public_key: signing_key.verifying_key().to_bytes(),
                }],
                &[]
            ),
            Err(ManifestSignatureError::VerificationFailed(key)) if key == "add-key-1"
        ));
    }
}
