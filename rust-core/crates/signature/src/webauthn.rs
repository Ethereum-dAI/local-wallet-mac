//! WebAuthn ceremony fields and signing message construction.
//!
//! The Kernel WebAuthn validator hardcodes `challengeLocation = 23`, meaning
//! the `"challenge":` key must start at byte 23 of clientDataJSON.
//!
//! Our fixed format:
//! `{"type":"webauthn.get","challenge":"<base64url>","origin":"https://wallet.local","crossOrigin":false}`
//!
//! Signing message: sha256(authenticatorData || sha256(clientDataJSON))

use sha2::{Digest, Sha256};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const DEFAULT_RP_ID: &str = "wallet";
pub const RP_ID: &str = DEFAULT_RP_ID;

/// sha256(b"wallet")
pub const RP_ID_HASH: [u8; 32] = [
    0xe8, 0xd4, 0x40, 0x50, 0x87, 0x3d, 0xba, 0x86, 0x5a, 0xa7, 0xc1, 0x70, 0xab, 0x4c, 0xce, 0x64,
    0xd9, 0x08, 0x39, 0xa3, 0x4d, 0xcf, 0xd6, 0xcf, 0x71, 0xd1, 0x4e, 0x02, 0x05, 0x44, 0x3b, 0x1b,
];

pub const DEFAULT_ORIGIN: &str = "https://wallet.local";
pub const ORIGIN: &str = DEFAULT_ORIGIN;

/// `"type":` starts at byte 1 (after the opening `{`).
pub const RESPONSE_TYPE_LOCATION: u32 = 1;

/// `"challenge":` starts at byte 23 of clientDataJSON.
pub const CHALLENGE_LOCATION: u32 = 23;

// ---------------------------------------------------------------------------
// WebAuthnSignature struct
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct WebAuthnSignature {
    pub authenticator_data: Vec<u8>,
    pub client_data_json: String,
    /// Always 1 — `"type":` starts at byte 1.
    pub response_type_location: u32,
    pub r: [u8; 32],
    pub s: [u8; 32],
    pub use_precompiled: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WebAuthnContext {
    pub rp_id: String,
    pub origin: String,
    pub sign_count: u32,
    pub user_presence: bool,
    pub user_verification: bool,
}

impl Default for WebAuthnContext {
    fn default() -> Self {
        Self {
            rp_id: DEFAULT_RP_ID.to_string(),
            origin: DEFAULT_ORIGIN.to_string(),
            sign_count: 0,
            user_presence: true,
            user_verification: true,
        }
    }
}

// ---------------------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------------------

/// RFC 4648 §5 base64url encoding without padding characters.
pub fn base64url_encode_nopad(input: &[u8]) -> String {
    // Standard base64 alphabet replaced: '+' -> '-', '/' -> '_', no '='
    let encoded = base64_encode(input);
    encoded
        .replace('+', "-")
        .replace('/', "_")
        .trim_end_matches('=')
        .to_string()
}

pub fn build_rp_id_hash(rp_id: &str) -> [u8; 32] {
    Sha256::digest(rp_id.as_bytes()).into()
}

/// Minimal base64 encoder (standard alphabet, with padding).
fn base64_encode(input: &[u8]) -> String {
    const CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    let mut i = 0;
    while i < input.len() {
        let b0 = input[i] as u32;
        let b1 = if i + 1 < input.len() {
            input[i + 1] as u32
        } else {
            0
        };
        let b2 = if i + 2 < input.len() {
            input[i + 2] as u32
        } else {
            0
        };

        let n = (b0 << 16) | (b1 << 8) | b2;

        out.push(CHARS[((n >> 18) & 0x3f) as usize] as char);
        out.push(CHARS[((n >> 12) & 0x3f) as usize] as char);
        if i + 1 < input.len() {
            out.push(CHARS[((n >> 6) & 0x3f) as usize] as char);
        } else {
            out.push('=');
        }
        if i + 2 < input.len() {
            out.push(CHARS[(n & 0x3f) as usize] as char);
        } else {
            out.push('=');
        }

        i += 3;
    }
    out
}

// ---------------------------------------------------------------------------
// Public functions
// ---------------------------------------------------------------------------

/// Build the 37-byte authenticatorData:
///   bytes  0-31: RP_ID_HASH
///   byte  32:    flags = 0x05 (UP | UV)
///   bytes 33-36: signCount = 0 (big-endian u32)
pub fn build_authenticator_data() -> [u8; 37] {
    build_authenticator_data_with_context(&WebAuthnContext::default())
}

/// Build the 37-byte authenticatorData with configurable rpId, flags, and signCount.
pub fn build_authenticator_data_with_context(context: &WebAuthnContext) -> [u8; 37] {
    let mut data = [0u8; 37];
    data[..32].copy_from_slice(&build_rp_id_hash(&context.rp_id));
    let mut flags = 0u8;
    if context.user_presence {
        flags |= 0x01;
    }
    if context.user_verification {
        flags |= 0x04;
    }
    data[32] = flags;
    data[33..37].copy_from_slice(&context.sign_count.to_be_bytes());
    data
}

/// Build the clientDataJSON string for a given userOp hash.
///
/// The resulting string has `"challenge":` starting at byte 23:
/// `{"type":"webauthn.get","challenge":"<base64url>","origin":"https://wallet.local","crossOrigin":false}`
pub fn build_client_data_json(userop_hash: &[u8; 32]) -> String {
    build_client_data_json_with_context(userop_hash, &WebAuthnContext::default())
}

/// Build the clientDataJSON string for a given userOp hash and origin.
pub fn build_client_data_json_with_context(
    userop_hash: &[u8; 32],
    context: &WebAuthnContext,
) -> String {
    let challenge = base64url_encode_nopad(userop_hash);
    format!(
        r#"{{"type":"webauthn.get","challenge":"{}","origin":"{}","crossOrigin":false}}"#,
        challenge, context.origin
    )
}

/// Compute the signing message:
///   1. Build authenticatorData (37 bytes)
///   2. Build clientDataJSON
///   3. hash_cdj = sha256(clientDataJSON)
///   4. message  = sha256(authenticatorData || hash_cdj)
///
/// Returns `(message: [u8; 32], client_data_json: String)`.
pub fn compute_signing_message(userop_hash: &[u8; 32]) -> ([u8; 32], String) {
    compute_signing_message_with_context(userop_hash, &WebAuthnContext::default())
}

/// Compute the signing message using a custom WebAuthn context.
pub fn compute_signing_message_with_context(
    userop_hash: &[u8; 32],
    context: &WebAuthnContext,
) -> ([u8; 32], String) {
    let auth_data = build_authenticator_data_with_context(context);
    let cdj = build_client_data_json_with_context(userop_hash, context);

    let hash_cdj: [u8; 32] = Sha256::digest(cdj.as_bytes()).into();

    let mut hasher = Sha256::new();
    hasher.update(auth_data);
    hasher.update(hash_cdj);
    let message: [u8; 32] = hasher.finalize().into();

    (message, cdj)
}

/// Build a `WebAuthnSignature` for a given userOp hash and ECDSA (r, s) pair.
pub fn build_signature(
    userop_hash: &[u8; 32],
    r: [u8; 32],
    s: [u8; 32],
    use_precompiled: bool,
) -> WebAuthnSignature {
    build_signature_with_context(
        userop_hash,
        r,
        s,
        use_precompiled,
        &WebAuthnContext::default(),
    )
}

/// Build a `WebAuthnSignature` using a custom WebAuthn context.
pub fn build_signature_with_context(
    userop_hash: &[u8; 32],
    r: [u8; 32],
    s: [u8; 32],
    use_precompiled: bool,
    context: &WebAuthnContext,
) -> WebAuthnSignature {
    let auth_data = build_authenticator_data_with_context(context);
    let cdj = build_client_data_json_with_context(userop_hash, context);
    WebAuthnSignature {
        authenticator_data: auth_data.to_vec(),
        client_data_json: cdj,
        response_type_location: RESPONSE_TYPE_LOCATION,
        r,
        s,
        use_precompiled,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use hex_literal::hex;

    /// 1. `"challenge":` must start at byte 23.
    #[test]
    fn challenge_starts_at_byte_23() {
        let hash = [0u8; 32];
        let cdj = build_client_data_json(&hash);
        let bytes = cdj.as_bytes();
        // byte 23 should be the start of `"challenge":`
        assert_eq!(
            &bytes[23..34],
            b"\"challenge\"",
            "\"challenge\" should start at byte 23; got: {:?}",
            std::str::from_utf8(&bytes[20..36]).unwrap()
        );
    }

    /// 2. `"type":"webauthn.get"` starts at byte 1 (after opening `{`).
    #[test]
    fn response_type_at_byte_1() {
        let hash = [0u8; 32];
        let cdj = build_client_data_json(&hash);
        let bytes = cdj.as_bytes();
        assert_eq!(bytes[0], b'{');
        assert_eq!(&bytes[1..7], b"\"type\"");
    }

    /// 3. base64url of 32 bytes → 43 chars, no +, /, or =.
    #[test]
    fn base64url_encode_32_bytes() {
        let input = [0xabu8; 32];
        let encoded = base64url_encode_nopad(&input);
        assert_eq!(encoded.len(), 43);
        assert!(!encoded.contains('+'), "must not contain '+'");
        assert!(!encoded.contains('/'), "must not contain '/'");
        assert!(!encoded.contains('='), "must not contain '='");
    }

    /// 4. Known-vector test.
    #[test]
    fn base64url_encodes_correctly() {
        let input = hex!("6d0a394861c05e39fb043ecfa6bca7ef8976ee6c8300547977c39b8a39b39dda");
        let encoded = base64url_encode_nopad(&input);
        assert_eq!(encoded, "bQo5SGHAXjn7BD7Ppryn74l27myDAFR5d8Obijmzndo");
    }

    /// 5. Signing message construction sanity checks.
    #[test]
    fn signing_message_construction() {
        let hash = [0x42u8; 32];
        let (msg, cdj) = compute_signing_message(&hash);

        // Message must be non-zero
        assert_ne!(msg, [0u8; 32]);

        // JSON must contain base64url of hash (no padding/special chars)
        let challenge = base64url_encode_nopad(&hash);
        assert!(cdj.contains(&challenge));

        // JSON structure integrity
        assert!(cdj.starts_with('{'));
        assert!(cdj.ends_with('}'));
        assert!(cdj.contains("webauthn.get"));
        assert!(cdj.contains(ORIGIN));
    }

    #[test]
    fn custom_context_changes_authenticator_data_and_origin() {
        let context = WebAuthnContext {
            rp_id: "example.com".to_string(),
            origin: "https://example.com".to_string(),
            sign_count: 7,
            user_presence: true,
            user_verification: false,
        };

        let auth_data = build_authenticator_data_with_context(&context);
        let cdj = build_client_data_json_with_context(&[0x11; 32], &context);

        assert_eq!(&auth_data[..32], &build_rp_id_hash("example.com"));
        assert_eq!(auth_data[32], 0x01);
        assert_eq!(&auth_data[33..37], &7u32.to_be_bytes());
        assert!(cdj.contains("https://example.com"));
    }

    #[test]
    fn default_context_matches_legacy_helpers() {
        let hash = [0x22u8; 32];
        let context = WebAuthnContext::default();

        assert_eq!(
            build_authenticator_data(),
            build_authenticator_data_with_context(&context)
        );
        assert_eq!(
            build_client_data_json(&hash),
            build_client_data_json_with_context(&hash, &context)
        );
        assert_eq!(
            compute_signing_message(&hash),
            compute_signing_message_with_context(&hash, &context)
        );
    }

    /// 6. Sign with P-256 using `sign_prehash` (matches Secure Enclave behaviour).
    #[test]
    fn signing_message_verifies_with_p256() {
        use p256::ecdsa::Signature;
        use p256::ecdsa::{
            signature::hazmat::PrehashSigner, signature::hazmat::PrehashVerifier, SigningKey,
            VerifyingKey,
        };

        let hash = [0x01u8; 32];
        let (msg, _cdj) = compute_signing_message(&hash);

        // Generate a random key for testing
        let signing_key = SigningKey::random(&mut rand_core_getrandom());

        let sig: Signature = signing_key.sign_prehash(&msg).expect("sign_prehash failed");

        let verifying_key = VerifyingKey::from(&signing_key);
        verifying_key
            .verify_prehash(&msg, &sig)
            .expect("verify_prehash failed");
    }

    /// 7. clientDataJSON must be valid JSON with the expected fields.
    #[test]
    fn client_data_json_is_valid_json() {
        let hash = [0x99u8; 32];
        let cdj = build_client_data_json(&hash);

        let v: serde_json::Value =
            serde_json::from_str(&cdj).expect("clientDataJSON must be valid JSON");

        assert_eq!(v["type"], "webauthn.get");
        assert_eq!(v["origin"], ORIGIN);
        assert_eq!(v["crossOrigin"], false);

        // challenge field must be present and non-empty
        let challenge = v["challenge"].as_str().expect("challenge must be a string");
        assert!(!challenge.is_empty());
        assert_eq!(challenge, base64url_encode_nopad(&hash));
    }

    // Tiny shim so we don't need to add a new dependency just for the test.
    fn rand_core_getrandom(
    ) -> impl p256::elliptic_curve::rand_core::CryptoRng + p256::elliptic_curve::rand_core::RngCore
    {
        use p256::elliptic_curve::rand_core::OsRng;
        OsRng
    }
}
