use alloy_primitives::{keccak256, Address, Bytes};
use alloy_sol_types::SolValue;
use k256::ecdsa::{RecoveryId, Signature, VerifyingKey};
use wallet_signature::{
    dummy_permission_signature_enable, dummy_permission_signature_installed,
    sign_session_userop_hash, wrap_enable_signature, wrap_installed_signature,
};

mod common;

fn hex_string(bytes: impl AsRef<[u8]>) -> String {
    format!("0x{}", hex::encode(bytes))
}

fn personal_sign_digest(userop_hash: &[u8; 32]) -> [u8; 32] {
    let mut preimage = Vec::with_capacity(28 + 32);
    preimage.extend_from_slice(b"\x19Ethereum Signed Message:\n32");
    preimage.extend_from_slice(userop_hash);
    *keccak256(preimage)
}

fn address_from_verifying_key(key: &VerifyingKey) -> Address {
    let point = key.to_encoded_point(false);
    let bytes = point.as_bytes();
    let hash = keccak256(&bytes[1..]);
    Address::from_slice(&hash[12..])
}

type EnableTail = (Bytes, Bytes, Bytes, Bytes, Bytes);

fn decode_enable_tail(signature: &[u8]) -> EnableTail {
    assert!(signature.len() > 20);
    EnableTail::abi_decode_params(&signature[20..]).expect("enable wrapper tail decodes")
}

#[test]
fn session_signing_matches_sdk_installed_signature() {
    let fixture = common::load();
    let secret: [u8; 32] = common::hex_array(fixture["meta"]["SESSION_PK"].as_str().unwrap());
    let userop_hash: [u8; 32] = common::hex_array(fixture["dummyUserOpHash"].as_str().unwrap());
    let expected_installed = common::hex_bytes(fixture["installedUserOpSig"].as_str().unwrap());
    let expected_inner = &expected_installed[1..];

    let got = sign_session_userop_hash(&userop_hash, &secret).expect("session signing succeeds");

    assert_eq!(got.as_slice(), expected_inner);

    let digest = personal_sign_digest(&userop_hash);
    let signature = Signature::from_slice(&got[..64]).expect("signature parses");
    let recovery_id = RecoveryId::from_byte(got[64] - 27).expect("recovery id parses");
    let recovered = VerifyingKey::recover_from_prehash(digest.as_slice(), &signature, recovery_id)
        .expect("signature recovers");
    assert_eq!(
        address_from_verifying_key(&recovered),
        common::meta_address(&fixture, "SESSION_KEY")
    );
}

#[test]
fn installed_wrapper_matches_sdk() {
    let fixture = common::load();
    let secret: [u8; 32] = common::hex_array(fixture["meta"]["SESSION_PK"].as_str().unwrap());
    let userop_hash: [u8; 32] = common::hex_array(fixture["dummyUserOpHash"].as_str().unwrap());
    let inner = sign_session_userop_hash(&userop_hash, &secret).expect("session signing succeeds");

    let wrapped = wrap_installed_signature(&inner);

    assert_eq!(
        hex_string(wrapped),
        fixture["installedUserOpSig"].as_str().unwrap()
    );
}

#[test]
fn enable_wrapper_matches_sdk_when_reassembled() {
    let fixture = common::load();
    let enable_sig = common::hex_bytes(fixture["enableUserOpSig"].as_str().unwrap());
    let (validator_data, hook_data, selector_data, root_sig, userop_sig) =
        decode_enable_tail(&enable_sig);

    let rewrapped = wrap_enable_signature(
        Address::ZERO,
        &validator_data,
        &hook_data,
        &selector_data,
        &root_sig,
        &userop_sig,
    );

    assert_eq!(rewrapped, enable_sig);
}

#[test]
fn permission_dummies_have_expected_shape() {
    assert_eq!(dummy_permission_signature_installed().len(), 66);

    let fixture = common::load();
    let message = &fixture["enableTypedData"]["message"];
    let validator_data = common::hex_bytes(message["validatorData"].as_str().unwrap());
    let selector_data = common::hex_bytes(message["selectorData"].as_str().unwrap());
    let dummy = dummy_permission_signature_enable(
        Address::ZERO,
        &validator_data,
        &[],
        &selector_data,
        false,
    );
    let (decoded_validator_data, hook_data, decoded_selector_data, root_sig, userop_sig) =
        decode_enable_tail(&dummy);

    assert_eq!(decoded_validator_data, validator_data);
    assert!(hook_data.is_empty());
    assert_eq!(decoded_selector_data, selector_data);
    assert!(!root_sig.is_empty());
    assert_eq!(
        userop_sig,
        Bytes::from(dummy_permission_signature_installed())
    );
}
