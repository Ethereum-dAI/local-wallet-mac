//! `wallet-kernel` contains Kernel smart-account helpers that are deterministic
//! and reusable across app, script, and backend contexts.
//!
//! It focuses on:
//!
//! - WebAuthn root-validator wiring
//! - `Kernel.initialize(...)` calldata encoding
//! - CREATE2 salt derivation for Kernel factory deployment
//! - counterfactual account-address prediction

use alloy_primitives::{keccak256, Address, Bytes, FixedBytes, B256, U256};
use alloy_sol_types::{sol, SolCall, SolValue};

/// Validation type byte for a root validator.
pub const VALIDATOR_TYPE: u8 = 0x01;

sol! {
    struct WebAuthnValidatorDataEncoded {
        uint256 pubKeyX;
        uint256 pubKeyY;
        bytes32 authenticatorIdHash;
    }

    function initialize(
        bytes21 rootValidator,
        address hook,
        bytes validatorData,
        bytes hookData,
        bytes[] initConfig
    );
}

/// `0x01 ++ validator_address`
pub fn build_validation_id(validator: Address) -> FixedBytes<21> {
    let mut validation_id = [0u8; 21];
    validation_id[0] = VALIDATOR_TYPE;
    validation_id[1..21].copy_from_slice(validator.as_slice());
    FixedBytes::from(validation_id)
}

/// `abi.encode(uint256 pubKeyX, uint256 pubKeyY, bytes32 authenticatorIdHash)`
pub fn encode_webauthn_validator_data(
    pub_key_x: U256,
    pub_key_y: U256,
    authenticator_id_hash: B256,
) -> Vec<u8> {
    WebAuthnValidatorDataEncoded {
        pubKeyX: pub_key_x,
        pubKeyY: pub_key_y,
        authenticatorIdHash: authenticator_id_hash,
    }
    .abi_encode_params()
}

/// Full `Kernel.initialize(...)` calldata for a WebAuthn root-validator account.
pub fn encode_initialize_call(
    webauthn_validator: Address,
    pub_key_x: U256,
    pub_key_y: U256,
    authenticator_id_hash: B256,
) -> Vec<u8> {
    let validator_data =
        encode_webauthn_validator_data(pub_key_x, pub_key_y, authenticator_id_hash);

    initializeCall {
        rootValidator: build_validation_id(webauthn_validator),
        hook: Address::ZERO,
        validatorData: Bytes::from(validator_data),
        hookData: Bytes::new(),
        initConfig: vec![],
    }
    .abi_encode()
}

/// `keccak256(abi.encodePacked(initData, salt))`
pub fn compute_actual_salt(init_data: &[u8], salt: B256) -> B256 {
    let mut salt_preimage = Vec::with_capacity(init_data.len() + 32);
    salt_preimage.extend_from_slice(init_data);
    salt_preimage.extend_from_slice(salt.as_slice());
    keccak256(salt_preimage)
}

/// Solady `LibClone.initCodeHashERC1967(implementation)` for the factory's deterministic clone.
pub fn erc1967_init_code_hash(implementation: Address) -> B256 {
    let mut init_code = Vec::with_capacity(95);
    init_code.extend_from_slice(&[0x60, 0x3d, 0x3d, 0x81, 0x60, 0x22, 0x3d, 0x39, 0x73]);
    init_code.extend_from_slice(implementation.as_slice());
    init_code.extend_from_slice(&[0x60, 0x09]);
    init_code.extend_from_slice(&[
        0x51, 0x55, 0xf3, 0x36, 0x3d, 0x3d, 0x37, 0x3d, 0x3d, 0x36, 0x3d, 0x7f, 0x36, 0x08, 0x94,
        0xa1, 0x3b, 0xa1, 0xa3, 0x21, 0x06, 0x67, 0xc8, 0x28, 0x49, 0x2d, 0xb9, 0x8d, 0xca, 0x3e,
        0x20, 0x76,
    ]);
    init_code.extend_from_slice(&[
        0xcc, 0x37, 0x35, 0xa9, 0x20, 0xa3, 0xca, 0x50, 0x5d, 0x38, 0x2b, 0xbc, 0x54, 0x5a, 0xf4,
        0x3d, 0x60, 0x00, 0x80, 0x3e, 0x60, 0x38, 0x57, 0x3d, 0x60, 0x00, 0xfd, 0x5b, 0x3d, 0x60,
        0x00, 0xf3,
    ]);
    debug_assert_eq!(init_code.len(), 95);
    keccak256(init_code)
}

pub fn predict_create2_address(
    factory: Address,
    actual_salt: B256,
    init_code_hash: B256,
) -> Address {
    let mut preimage = Vec::with_capacity(85);
    preimage.push(0xff);
    preimage.extend_from_slice(factory.as_slice());
    preimage.extend_from_slice(actual_salt.as_slice());
    preimage.extend_from_slice(init_code_hash.as_slice());
    let hash = keccak256(preimage);
    Address::from_slice(&hash[12..32])
}

pub fn predict_kernel_account_address(
    factory: Address,
    implementation: Address,
    webauthn_validator: Address,
    pub_key_x: U256,
    pub_key_y: U256,
    authenticator_id_hash: B256,
    salt: B256,
) -> Address {
    let init_data = encode_initialize_call(
        webauthn_validator,
        pub_key_x,
        pub_key_y,
        authenticator_id_hash,
    );
    let actual_salt = compute_actual_salt(&init_data, salt);
    let init_code_hash = erc1967_init_code_hash(implementation);
    predict_create2_address(factory, actual_salt, init_code_hash)
}

#[cfg(test)]
mod tests {
    use alloy_primitives::{address, b256, uint};

    use super::*;

    #[test]
    fn initialize_call_has_expected_selector_and_length() {
        let call = encode_initialize_call(
            address!("7ab16Ff354AcB328452F1D445b3Ddee9a91e9e69"),
            uint!(1_U256),
            uint!(2_U256),
            B256::ZERO,
        );

        assert_eq!(&call[..4], &[0x3c, 0x3b, 0x75, 0x2b]);
        assert_eq!(call.len(), 356);
    }

    #[test]
    fn validation_id_prefixes_validator_type() {
        let validation_id =
            build_validation_id(address!("7ab16Ff354AcB328452F1D445b3Ddee9a91e9e69"));

        assert_eq!(validation_id[0], VALIDATOR_TYPE);
        assert_eq!(
            &validation_id[1..21],
            address!("7ab16Ff354AcB328452F1D445b3Ddee9a91e9e69").as_slice()
        );
    }

    #[test]
    fn predicts_kernel_account_address_for_pinned_vector() {
        let predicted = predict_kernel_account_address(
            address!("2577507b78c2008Ff367261CB6285d44ba5eF2E9"),
            address!("d6CEDDe84be40893d153Be9d467CD6aD37875b28"),
            address!("7ab16Ff354AcB328452F1D445b3Ddee9a91e9e69"),
            b256!("0000000000000000000000000000000000000000000000000000000000000001").into(),
            b256!("0000000000000000000000000000000000000000000000000000000000000002").into(),
            B256::ZERO,
            B256::ZERO,
        );

        assert_eq!(
            predicted,
            address!("ea18d505d23f0b73a91409cd468aecf3beab03ba")
        );
    }
}
