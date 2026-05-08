//! `wallet-kernel` contains Kernel smart-account helpers that are deterministic
//! and reusable across app, script, and backend contexts.
//!
//! It focuses on:
//!
//! - WebAuthn root-validator wiring
//! - `Kernel.initialize(...)` calldata encoding
//! - CREATE2 salt derivation for Kernel factory deployment
//! - counterfactual account-address prediction
//! - Kernel v3 nonce decoding

use alloy_primitives::{keccak256, Address, Bytes, FixedBytes, B256, U256};
use alloy_sol_types::{sol, SolCall, SolValue};

/// Validation type byte for a root validator.
pub const VALIDATOR_TYPE: u8 = 0x01;

pub const VALIDATION_MODE_DEFAULT: u8 = 0x00;
pub const VALIDATION_MODE_ENABLE: u8 = 0x01;
pub const VALIDATION_MODE_INSTALL: u8 = 0x02;

pub const VALIDATION_TYPE_ROOT: u8 = 0x00;
pub const VALIDATION_TYPE_VALIDATOR: u8 = 0x01;
pub const VALIDATION_TYPE_PERMISSION: u8 = 0x02;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KernelNonce {
    pub validation_mode: u8,
    pub validation_type: u8,
    pub validation_id_without_type: [u8; 20],
    pub parallel_key: u16,
    pub sequence: u64,
}

impl KernelNonce {
    pub fn decode(nonce: U256) -> Self {
        let bytes = nonce.to_be_bytes::<32>();
        let mut validation_id_without_type = [0u8; 20];
        validation_id_without_type.copy_from_slice(&bytes[2..22]);

        Self {
            validation_mode: bytes[0],
            validation_type: bytes[1],
            validation_id_without_type,
            parallel_key: u16::from_be_bytes([bytes[22], bytes[23]]),
            sequence: u64::from_be_bytes([
                bytes[24], bytes[25], bytes[26], bytes[27], bytes[28], bytes[29], bytes[30],
                bytes[31],
            ]),
        }
    }

    pub fn validation_id(&self) -> FixedBytes<21> {
        let mut validation_id = [0u8; 21];
        validation_id[0] = self.validation_type;
        validation_id[1..].copy_from_slice(&self.validation_id_without_type);
        FixedBytes::from(validation_id)
    }

    pub fn is_default_root_key_zero(&self) -> bool {
        self.validation_mode == VALIDATION_MODE_DEFAULT
            && self.validation_type == VALIDATION_TYPE_ROOT
            && self.validation_id_without_type == [0u8; 20]
            && self.parallel_key == 0
    }
}

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
    use wallet_addresses::{
        PINNED_KERNEL_FACTORY_ADDRESS, PINNED_KERNEL_IMPLEMENTATION_ADDRESS,
        PINNED_WEBAUTHN_VALIDATOR_ADDRESS,
    };

    use super::*;

    #[test]
    fn initialize_call_has_expected_selector_and_length() {
        let call = encode_initialize_call(
            PINNED_WEBAUTHN_VALIDATOR_ADDRESS,
            uint!(1_U256),
            uint!(2_U256),
            B256::ZERO,
        );

        assert_eq!(&call[..4], &[0x3c, 0x3b, 0x75, 0x2b]);
        assert_eq!(call.len(), 356);
    }

    #[test]
    fn validation_id_prefixes_validator_type() {
        let validation_id = build_validation_id(PINNED_WEBAUTHN_VALIDATOR_ADDRESS);

        assert_eq!(validation_id[0], VALIDATOR_TYPE);
        assert_eq!(
            &validation_id[1..21],
            PINNED_WEBAUTHN_VALIDATOR_ADDRESS.as_slice()
        );
    }

    #[test]
    fn decodes_kernel_v3_root_nonce_key_zero() {
        let decoded = KernelNonce::decode(U256::from(7u64));

        assert_eq!(decoded.validation_mode, VALIDATION_MODE_DEFAULT);
        assert_eq!(decoded.validation_type, VALIDATION_TYPE_ROOT);
        assert_eq!(decoded.validation_id_without_type, [0u8; 20]);
        assert_eq!(decoded.parallel_key, 0);
        assert_eq!(decoded.sequence, 7);
        assert_eq!(decoded.validation_id(), FixedBytes::<21>::ZERO);
        assert!(decoded.is_default_root_key_zero());
    }

    #[test]
    fn decodes_kernel_v3_permission_nonce_layout() {
        let mut bytes = [0u8; 32];
        bytes[0] = VALIDATION_MODE_DEFAULT;
        bytes[1] = VALIDATION_TYPE_PERMISSION;
        bytes[18..22].copy_from_slice(&[0xaa, 0xbb, 0xcc, 0xdd]);
        bytes[22..24].copy_from_slice(&0x1234u16.to_be_bytes());
        bytes[24..32].copy_from_slice(&9u64.to_be_bytes());

        let decoded = KernelNonce::decode(U256::from_be_bytes(bytes));

        assert_eq!(decoded.validation_mode, VALIDATION_MODE_DEFAULT);
        assert_eq!(decoded.validation_type, VALIDATION_TYPE_PERMISSION);
        assert_eq!(decoded.parallel_key, 0x1234);
        assert_eq!(decoded.sequence, 9);
        assert_eq!(
            &decoded.validation_id_without_type[16..20],
            &[0xaa, 0xbb, 0xcc, 0xdd]
        );
        assert!(!decoded.is_default_root_key_zero());
    }

    #[test]
    fn predicts_kernel_account_address_for_pinned_vector() {
        let predicted = predict_kernel_account_address(
            PINNED_KERNEL_FACTORY_ADDRESS,
            PINNED_KERNEL_IMPLEMENTATION_ADDRESS,
            PINNED_WEBAUTHN_VALIDATOR_ADDRESS,
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
