//! fd-5 / config secret payload: the entropy that seeds the RAILGUN account, the
//! sidecar's own socket path, and how to reach the Ethereum provider (a direct RPC
//! URL for the fork/standalone path, or a daemon unix socket for the app path).
//!
//! The entropy never touches argv/env-on-disk in the app path; it arrives on fd-5.
//! In the e2e/standalone path it comes from an env var for convenience (testnet only).

use std::fmt;

use serde::Deserialize;
use thiserror::Error;

#[derive(Debug, Error, PartialEq)]
pub enum SecretError {
    #[error("invalid JSON: {0}")]
    Json(String),
    #[error("entropyHex must be 32 bytes (64 hex chars, optional 0x); got {0} hex chars")]
    EntropyLength(usize),
    #[error("entropyHex is not valid hex")]
    EntropyHex,
    #[error("key derivation failed: {0}")]
    Derivation(String),
}

/// How the sidecar reaches the Ethereum provider.
#[derive(Deserialize, Clone, PartialEq)]
pub struct ProviderConn {
    /// Direct HTTP(S) RPC URL (fork / standalone path).
    #[serde(default)]
    pub url: Option<String>,
    /// Daemon unix-socket path (app path).
    #[serde(default, rename = "socketPath")]
    pub socket_path: Option<String>,
    /// Bearer token for the daemon socket (unused for a plain fork RPC).
    #[serde(default)]
    pub token: Option<String>,
}

// Manual Debug: NEVER print the daemon token. A derived Debug would leak it via any
// stray `{:?}` / panic formatting.
impl fmt::Debug for ProviderConn {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ProviderConn")
            .field("url", &self.url)
            .field("socket_path", &self.socket_path)
            .field("token", &self.token.as_ref().map(|_| "<redacted>"))
            .finish()
    }
}

#[derive(Deserialize, Clone, PartialEq)]
pub struct SecretPayload {
    #[serde(rename = "entropyHex")]
    pub entropy_hex: String,
    #[serde(rename = "sidecarSocketPath")]
    pub sidecar_socket_path: String,
    /// Bearer token the app uses to authenticate to THIS sidecar's socket.
    pub token: String,
    pub provider: ProviderConn,
}

// Manual Debug: the master entropy (the shielded-account seed) and the bearer token are
// the two secrets here — NEVER format them, even in a panic/log. This struct is the fd-5
// contract, so a derived Debug would be a standing footgun.
impl fmt::Debug for SecretPayload {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SecretPayload")
            .field("entropy_hex", &"<redacted>")
            .field("sidecar_socket_path", &self.sidecar_socket_path)
            .field("token", &"<redacted>")
            .field("provider", &self.provider)
            .finish()
    }
}

/// fd-5 secret for `railgun-helper`: the RAILGUN entropy only (its shielded-account seed).
/// The helper derives BOTH the RAILGUN account and every ephemeral exit sender from this
/// one root.
#[derive(Deserialize, Clone, PartialEq)]
pub struct HelperFd5 {
    #[serde(rename = "entropyHex")]
    pub entropy_hex: String,
}

impl fmt::Debug for HelperFd5 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("HelperFd5")
            .field("entropy_hex", &"<redacted>")
            .finish()
    }
}

/// Normalize a hex entropy string to exactly 32 bytes, erroring on bad length/chars.
pub fn parse_entropy_32(entropy_hex: &str) -> Result<[u8; 32], SecretError> {
    let clean = entropy_hex.strip_prefix("0x").unwrap_or(entropy_hex);
    if clean.len() != 64 {
        return Err(SecretError::EntropyLength(clean.len()));
    }
    let bytes = hex::decode(clean).map_err(|_| SecretError::EntropyHex)?;
    let arr: [u8; 32] = bytes.try_into().map_err(|_| SecretError::EntropyHex)?;
    Ok(arr)
}

pub fn parse_secret_payload(bytes: &[u8]) -> Result<SecretPayload, SecretError> {
    let payload: SecretPayload =
        serde_json::from_slice(bytes).map_err(|e| SecretError::Json(e.to_string()))?;
    // Validate entropy up front so a bad seed fails at parse time, not at first use.
    parse_entropy_32(&payload.entropy_hex)?;
    Ok(payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_json() -> &'static str {
        r#"{
            "entropyHex": "0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
            "sidecarSocketPath": "/tmp/railgun.sock",
            "token": "sekret",
            "provider": { "url": "http://127.0.0.1:8546" }
        }"#
    }

    #[test]
    fn parses_a_valid_payload() {
        let p = parse_secret_payload(valid_json().as_bytes()).unwrap();
        assert_eq!(p.sidecar_socket_path, "/tmp/railgun.sock");
        assert_eq!(p.token, "sekret");
        assert_eq!(p.provider.url.as_deref(), Some("http://127.0.0.1:8546"));
        assert_eq!(p.provider.socket_path, None);
    }

    #[test]
    fn entropy_round_trips_to_32_bytes() {
        let p = parse_secret_payload(valid_json().as_bytes()).unwrap();
        let e = parse_entropy_32(&p.entropy_hex).unwrap();
        assert_eq!(e[0], 0x01);
        assert_eq!(e[31], 0x20);
    }

    #[test]
    fn rejects_short_entropy() {
        let j = r#"{"entropyHex":"0x01","sidecarSocketPath":"/s","token":"t","provider":{}}"#;
        assert_eq!(
            parse_secret_payload(j.as_bytes()),
            Err(SecretError::EntropyLength(2))
        );
    }

    #[test]
    fn rejects_non_hex_entropy() {
        let bad = "zz".repeat(32);
        let j = format!(
            r#"{{"entropyHex":"{bad}","sidecarSocketPath":"/s","token":"t","provider":{{}}}}"#
        );
        assert_eq!(
            parse_secret_payload(j.as_bytes()),
            Err(SecretError::EntropyHex)
        );
    }

    #[test]
    fn rejects_malformed_json() {
        assert!(matches!(
            parse_secret_payload(b"not json"),
            Err(SecretError::Json(_))
        ));
    }

    #[test]
    fn helper_fd5_parses_single_entropy_field() {
        let j = r#"{"entropyHex":"0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"}"#;
        let s: HelperFd5 = serde_json::from_slice(j.as_bytes()).unwrap();
        assert_eq!(s.entropy_hex.len(), 66);
        assert!(
            !format!("{s:?}").contains("0102030405"),
            "entropy leaked in Debug"
        );
    }

    #[test]
    fn debug_never_leaks_entropy_or_token() {
        let p = parse_secret_payload(valid_json().as_bytes()).unwrap();
        let dbg = format!("{p:?}");
        assert!(
            !dbg.contains("0102030405"),
            "entropy leaked in Debug: {dbg}"
        );
        assert!(!dbg.contains("sekret"), "token leaked in Debug: {dbg}");
        assert!(dbg.contains("<redacted>"));
        // Non-secret fields still visible for diagnostics.
        assert!(dbg.contains("/tmp/railgun.sock"));
    }
}
