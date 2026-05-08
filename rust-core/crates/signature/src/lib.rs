//! `wallet-signature` is the reusable protocol/signature layer for this repo.
//!
//! It contains deterministic logic for:
//!
//! - ERC-4337 `PackedUserOperation` hashing
//! - WebAuthn signing-message construction for the Kernel validator flow
//! - P-256 signature normalization and parsing helpers
//! - ABI encoding of the validator-specific signature payload
//!
//! For Kernel-specific account initialization and address prediction, see the
//! companion crate `wallet-kernel`.
//!
//! It deliberately does **not** handle:
//!
//! - Secure Enclave / Keychain access
//! - networking or RPC
//! - bundler submission
//! - app-specific wallet persistence

pub mod encoding;
mod error;
pub mod p256;
pub mod userop_hash;
pub mod webauthn;

pub use encoding::{
    abi_encode_dummy_signature, abi_encode_webauthn_signature, decode_use_precompiled,
};
pub use error::{Result, SignatureError};
pub use p256::{der_to_raw, normalise_low_s};
pub use userop_hash::{compute_userop_hash, PackedUserOperation, ENTRY_POINT_V07};
pub use wallet_addresses::DAIMO_P256_VERIFIER_ADDRESS as DAIMO_P256_VERIFIER;
pub use webauthn::{
    build_authenticator_data, build_authenticator_data_with_context, build_client_data_json,
    build_client_data_json_with_context, build_rp_id_hash, build_signature,
    build_signature_with_context, compute_signing_message, compute_signing_message_with_context,
    WebAuthnContext, WebAuthnSignature, CHALLENGE_LOCATION, DEFAULT_ORIGIN, DEFAULT_RP_ID, ORIGIN,
    RESPONSE_TYPE_LOCATION, RP_ID, RP_ID_HASH,
};

/// RIP-7212 P-256 precompile address.
pub const P256_PRECOMPILE: &str = "0x0000000000000000000000000000000000000100";
