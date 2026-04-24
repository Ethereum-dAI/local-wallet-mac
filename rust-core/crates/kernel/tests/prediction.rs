use alloy_primitives::{address, b256, keccak256, B256, U256};
use wallet_kernel::{
    build_validation_id, compute_actual_salt, encode_initialize_call,
    encode_webauthn_validator_data, erc1967_init_code_hash, predict_create2_address,
    predict_kernel_account_address, VALIDATOR_TYPE,
};

#[test]
fn validator_data_is_three_words() {
    let encoded = encode_webauthn_validator_data(
        U256::from(1u64),
        U256::from(2u64),
        B256::ZERO,
    );

    assert_eq!(encoded.len(), 96);
}

#[test]
fn validation_id_is_twenty_one_bytes() {
    let encoded = build_validation_id(address!("7ab16Ff354AcB328452F1D445b3Ddee9a91e9e69"));
    assert_eq!(encoded.len(), 21);
    assert_eq!(encoded[0], VALIDATOR_TYPE);
}

#[test]
fn actual_salt_matches_packed_concat_hash() {
    let init_data = encode_initialize_call(
        address!("7ab16Ff354AcB328452F1D445b3Ddee9a91e9e69"),
        U256::from(1u64),
        U256::from(2u64),
        B256::ZERO,
    );
    let salt = b256!("0102030405060708090a0b0c0d0e0f1000000000000000000000000000000000");

    let mut manual = init_data.clone();
    manual.extend_from_slice(salt.as_slice());

    assert_eq!(compute_actual_salt(&init_data, salt), keccak256(manual));
}

#[test]
fn create2_prediction_matches_kernel_prediction() {
    let factory = address!("2577507b78c2008Ff367261CB6285d44ba5eF2E9");
    let implementation = address!("d6CEDDe84be40893d153Be9d467CD6aD37875b28");
    let validator = address!("7ab16Ff354AcB328452F1D445b3Ddee9a91e9e69");
    let pub_key_x = U256::from(1u64);
    let pub_key_y = U256::from(2u64);
    let authenticator_id_hash = B256::ZERO;
    let salt = B256::ZERO;

    let init_data = encode_initialize_call(
        validator,
        pub_key_x,
        pub_key_y,
        authenticator_id_hash,
    );
    let actual_salt = compute_actual_salt(&init_data, salt);
    let init_code_hash = erc1967_init_code_hash(implementation);

    let decomposed = predict_create2_address(factory, actual_salt, init_code_hash);
    let direct = predict_kernel_account_address(
        factory,
        implementation,
        validator,
        pub_key_x,
        pub_key_y,
        authenticator_id_hash,
        salt,
    );

    assert_eq!(decomposed, direct);
    assert_eq!(direct, address!("ea18d505d23f0b73a91409cd468aecf3beab03ba"));
}
