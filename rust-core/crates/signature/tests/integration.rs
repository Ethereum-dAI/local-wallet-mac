use wallet_signature::*;
use alloy_primitives::{address, Bytes, FixedBytes, U256};
use hex_literal::hex;

#[test]
fn full_pipeline_signs_and_encodes() {
    // 1. Build a UserOp and compute the hash
    let userop = PackedUserOperation {
        sender: address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2"),
        nonce: U256::from(1u64),
        init_code: Bytes::new(),
        call_data: Bytes::new(),
        account_gas_limits: FixedBytes::from([0u8; 32]),
        pre_verification_gas: U256::from(21000u64),
        gas_fees: FixedBytes::from([0u8; 32]),
        paymaster_and_data: Bytes::new(),
    };
    let userop_hash: [u8; 32] = compute_userop_hash(&userop, ENTRY_POINT_V07, 1);

    // 2. Compute signing message
    let (signing_msg, client_data_json) = compute_signing_message(&userop_hash);
    assert_ne!(signing_msg, [0u8; 32]);
    assert!(client_data_json.contains("webauthn.get"));

    // 3. Sign with a test p256 key using prehash (matches Secure Enclave behavior)
    use ::p256::ecdsa::{SigningKey, Signature, signature::hazmat::{PrehashSigner, PrehashVerifier}};
    use ::p256::elliptic_curve::rand_core::OsRng;
    let sk = SigningKey::random(&mut OsRng);
    let (sig, _): (Signature, _) = sk.sign_prehash(&signing_msg).unwrap();
    let (r_scalar, s_scalar) = sig.split_scalars();
    let r: [u8; 32] = r_scalar.to_bytes().into();
    let s: [u8; 32] = s_scalar.to_bytes().into();

    // 4. Normalise low-s (mandatory — validator rejects high-s)
    let (r, s) = normalise_low_s(r, s);

    // 5. Build WebAuthn signature
    let webauthn_sig = build_signature(&userop_hash, r, s, true);

    // 6. ABI encode
    let encoded = abi_encode_webauthn_signature(&webauthn_sig);
    assert!(!encoded.is_empty());
    assert_eq!(encoded.len() % 32, 0);

    // 7. Verify the P-256 signature is still valid after low-s normalisation
    let vk = sk.verifying_key();
    let normalized_sig = Signature::from_scalars(r, s).unwrap();
    vk.verify_prehash(&signing_msg, &normalized_sig)
        .expect("signature must verify after pipeline");
}

/// Phase 2: Real Secure Enclave output from swift-probe.
/// Validates that the Rust signing message matches what Swift computed,
/// and that the Enclave signature verifies in Rust.
#[test]
fn real_enclave_signature_verifies() {
    use ::p256::ecdsa::{Signature, VerifyingKey, signature::hazmat::PrehashVerifier};
    use ::p256::EncodedPoint;

    // Values from swift-probe run (real Secure Enclave output).
    // The probe passes the 69-byte preimage (authData || sha256(cdj)) to
    // CryptoKit's signature(for:), which hashes it internally to produce
    // signingMessage = sha256(preimage). This matches the on-chain validator.
    let pubkey_x = hex!("8ea35f44f5e75314e34c77b893cc5f07e1c8c239db11263ae8c839af1d5dd2a0");
    let pubkey_y = hex!("61d745ab16afdb60a42a8385f5e4823476078d44c023089b2d04c006310208b5");
    let r = hex!("885942f43a854e3f832b1e326fef2faa2e9145366c5ad0198e807e6cb4d32ea3");
    let s = hex!("d2ffe882a172e33b7ea9342e0d55b0e7d0997f8898d4759436616eb24936bd82");
    let userop_hash = hex!("6d0a394861c05e39fb043ecfa6bca7ef8976ee6c8300547977c39b8a39b39dda");

    // 1. Verify Rust produces the same signing message as Swift
    let (signing_msg, _cdj) = compute_signing_message(&userop_hash);
    assert_eq!(
        signing_msg,
        hex!("4793eac07d8740aa367f813f52b43e30352fde2f79e43b8879a14e39eb7dbfd5"),
        "Rust signing message must match Swift"
    );

    // 2. Normalise low-s
    let (r, s) = normalise_low_s(r, s);

    // 3. Reconstruct public key and verify the Enclave signature
    let point = EncodedPoint::from_affine_coordinates(
        &pubkey_x.into(),
        &pubkey_y.into(),
        false,
    );
    let vk = VerifyingKey::from_encoded_point(&point)
        .expect("invalid public key");
    let sig = Signature::from_scalars(r, s)
        .expect("invalid signature scalars");

    vk.verify_prehash(&signing_msg, &sig)
        .expect("Enclave signature must verify in Rust");

    // 4. Full pipeline: build + encode
    let webauthn_sig = build_signature(&userop_hash, r, s, true);
    let encoded = abi_encode_webauthn_signature(&webauthn_sig);
    assert!(!encoded.is_empty());
    assert_eq!(encoded.len() % 32, 0);
}
