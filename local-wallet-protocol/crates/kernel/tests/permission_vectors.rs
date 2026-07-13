use alloy_primitives::{Address, U256};
use wallet_kernel::permission::*;

mod common;

fn hex_string(bytes: impl AsRef<[u8]>) -> String {
    format!("0x{}", hex::encode(bytes))
}

fn assert_hex_bytes_eq(actual: impl AsRef<[u8]>, expected: &str) {
    assert_eq!(actual.as_ref(), common::hex_bytes(expected));
}

#[test]
fn permission_id_matches_sdk() {
    let fixture = common::load();
    let policies = common::policies(&fixture);
    let (signer_contract, signer_data) = common::signer(&fixture);

    let got = permission_id(&policies, signer_contract, &signer_data);

    assert_eq!(
        hex_string(got),
        fixture["permissionId"].as_str().expect("permissionId")
    );
}

#[test]
fn policy_helpers_match_sdk() {
    let fixture = common::load();
    let policies = common::policies(&fixture);
    let usdc = common::meta_address(&fixture, "USDC");
    let session_key = common::meta_address(&fixture, "SESSION_KEY");

    assert_eq!(
        gas_policy(5_000_000_000_000_000, false, Address::ZERO),
        policies[0]
    );
    assert_eq!(rate_limit_policy(86400, 20, 0), policies[1]);
    assert_eq!(timestamp_policy(0, 1_900_000_000), policies[2]);
    assert_eq!(
        call_policy(&[
            AllowedCall {
                target: usdc,
                selector: [0xa9, 0x05, 0x9c, 0xbb],
                value_limit: U256::ZERO,
                rules: vec![],
            },
            AllowedCall {
                target: usdc,
                selector: [0x09, 0x5e, 0xa7, 0xb3],
                value_limit: U256::ZERO,
                rules: vec![],
            },
        ]),
        policies[3]
    );

    let (signer_contract, signer_data) = ecdsa_signer_entry(session_key);
    assert_eq!(signer_contract, common::signer(&fixture).0);
    assert_eq!(signer_data, common::signer(&fixture).1);
}

#[test]
fn enable_data_matches_sdk() {
    let fixture = common::load();
    let policies = common::policies(&fixture);
    let (signer_contract, signer_data) = common::signer(&fixture);

    let got = encode_enable_data(&policies, signer_contract, &signer_data);

    assert_hex_bytes_eq(got, fixture["enableData"].as_str().expect("enableData"));
}

#[test]
fn selector_data_and_enable_digest_match_sdk() {
    let fixture = common::load();
    let message = &fixture["enableTypedData"]["message"];
    let selector_data = encode_selector_data_default_action([0xe9, 0xae, 0x5c, 0x53]);
    assert_hex_bytes_eq(
        &selector_data,
        message["selectorData"].as_str().expect("selectorData"),
    );
    assert_eq!(
        hex_string(enable_type_hash()),
        "0xb17ab1224aca0d4255ef8161acaf2ac121b8faa32a4b2258c912cc5f8308c505"
    );

    let account = common::meta_address(&fixture, "ACCOUNT");
    let chain_id = fixture["meta"]["CHAIN_ID"]
        .as_u64()
        .expect("fixture has chain id");
    let validation_id: [u8; 21] =
        common::hex_array(message["validationId"].as_str().expect("validationId"));
    let nonce = message["nonce"].as_u64().expect("nonce") as u32;
    let hook: Address = message["hook"]
        .as_str()
        .expect("hook")
        .parse()
        .expect("hook is address");
    let validator_data = common::hex_bytes(message["validatorData"].as_str().expect("data"));
    let hook_data = common::hex_bytes(message["hookData"].as_str().expect("hookData"));

    let got = enable_digest(
        account,
        chain_id,
        validation_id,
        nonce,
        hook,
        &validator_data,
        &hook_data,
        &selector_data,
    );

    assert_eq!(
        hex_string(got),
        fixture["enableDigest"].as_str().expect("enableDigest")
    );
}

#[test]
fn full_permission_composition_matches_sdk() {
    let fixture = common::load();
    let usdc = common::meta_address(&fixture, "USDC");
    let session_key = common::meta_address(&fixture, "SESSION_KEY");
    let policies = vec![
        gas_policy(5_000_000_000_000_000, false, Address::ZERO),
        rate_limit_policy(86400, 20, 0),
        timestamp_policy(0, 1_900_000_000),
        call_policy(&[
            AllowedCall {
                target: usdc,
                selector: [0xa9, 0x05, 0x9c, 0xbb],
                value_limit: U256::ZERO,
                rules: vec![],
            },
            AllowedCall {
                target: usdc,
                selector: [0x09, 0x5e, 0xa7, 0xb3],
                value_limit: U256::ZERO,
                rules: vec![],
            },
        ]),
    ];
    let (signer_contract, signer_data) = ecdsa_signer_entry(session_key);
    let permission_id = permission_id(&policies, signer_contract, &signer_data);

    assert_eq!(
        hex_string(permission_id),
        fixture["permissionId"].as_str().expect("permissionId")
    );
    assert_hex_bytes_eq(
        encode_enable_data(&policies, signer_contract, &signer_data),
        fixture["enableData"].as_str().expect("enableData"),
    );
}
