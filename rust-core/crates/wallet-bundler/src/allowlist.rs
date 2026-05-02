use alloy_primitives::{address, b256, keccak256, Address, Bytes, FixedBytes, B256, U256};
use alloy_sol_types::{sol, SolCall};

use crate::{BundlerError, Result};

sol! {
    function createAccount(bytes initData, bytes32 salt);

    function initialize(
        bytes21 rootValidator,
        address hook,
        bytes validatorData,
        bytes hookData,
        bytes[] initConfig
    );
}

pub const SOLADY_ERC1967_PROXY_RUNTIME: &[u8] = &[
    0x36, 0x3d, 0x3d, 0x37, 0x3d, 0x3d, 0x36, 0x3d, 0x7f, 0x36, 0x08, 0x94, 0xa1, 0x3b, 0xa1, 0xa3,
    0x21, 0x06, 0x67, 0xc8, 0x28, 0x49, 0x2d, 0xb9, 0x8d, 0xca, 0x3e, 0x20, 0x76, 0xcc, 0x37, 0x35,
    0xa9, 0x20, 0xa3, 0xca, 0x50, 0x5d, 0x38, 0x2b, 0xbc, 0x54, 0x5a, 0xf4, 0x3d, 0x60, 0x00, 0x80,
    0x3e, 0x60, 0x38, 0x57, 0x3d, 0x60, 0x00, 0xfd, 0x5b, 0x3d, 0x60, 0x00, 0xf3,
];

pub const SOLADY_ERC1967_PROXY_RUNTIME_HASH: B256 =
    b256!("aaa52c8cc8a0e3fd27ce756cc6b4e70c51423e9b597b11f32d3e49f8b1fc890d");

pub const ERC1967_IMPLEMENTATION_SLOT: B256 =
    b256!("360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc");

pub const PINNED_KERNEL_FACTORY_ADDRESS: Address =
    address!("2577507b78c2008Ff367261CB6285d44ba5eF2E9");
pub const PINNED_KERNEL_IMPLEMENTATION_ADDRESS: Address =
    address!("d6CEDDe84be40893d153Be9d467CD6aD37875b28");
pub const PINNED_WEBAUTHN_VALIDATOR_ADDRESS: Address =
    address!("7ab16Ff354AcB328452F1D445b3Ddee9a91e9e69");

pub const STATIC_KERNEL_PROXY_CODE_HASHES: &[AllowlistedCodeHash] = &[];
pub const STATIC_KERNEL_FACTORY_CODE_HASHES: &[AllowlistedCodeHash] = &[AllowlistedCodeHash {
    hash: b256!("cc4b1b98f5716bf61042d87bfedd4709a5c9a597c41f3bb0e6fb6fe1a4ebd37a"),
    label: "kernel factory mainnet",
}];
pub const STATIC_KERNEL_IMPLEMENTATION_CODE_HASHES: &[AllowlistedCodeHash] = &[
    AllowlistedCodeHash {
        hash: b256!("d748c6060679ccb34583963e5edc21299e4c6723e7c7a80561d255861ed209b7"),
        label: "kernel-v3.3.0 implementation mainnet",
    },
    AllowlistedCodeHash {
        hash: b256!("1cacd781072bcb657a6306afd074049f35d0a9d7f50eccda9b12bdd00c636995"),
        label: "kernel-v3.3.0 implementation sepolia",
    },
];
pub const STATIC_WEBAUTHN_VALIDATOR_CODE_HASHES: &[AllowlistedCodeHash] = &[AllowlistedCodeHash {
    hash: b256!("726d987ac55574f77f5184326631c5c51142f94c16c9b9281b751f97519c9eea"),
    label: "kernel webauthn validator mainnet",
}];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AllowlistedCodeHash {
    pub hash: B256,
    pub label: &'static str,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AccountCodeCheck {
    pub layer: &'static str,
    pub module_type: &'static str,
    pub address: Address,
    pub code_hash: B256,
    pub label: Option<&'static str>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KernelFactoryAccountCheck {
    pub factory: Address,
    pub salt: B256,
    pub init_data_hash: B256,
}

pub fn validate_sender_proxy_code(
    sender: Address,
    code: &Bytes,
) -> Result<Option<AccountCodeCheck>> {
    if code.is_empty() {
        return Ok(None);
    }

    let code_hash = keccak256(code);
    let label = STATIC_KERNEL_PROXY_CODE_HASHES
        .iter()
        .find(|entry| entry.hash == code_hash)
        .map(|entry| entry.label);

    match label {
        Some(label) => Ok(Some(AccountCodeCheck {
            layer: "proxy",
            module_type: "kernel_proxy",
            address: sender,
            code_hash,
            label: Some(label),
        })),
        None => Err(BundlerError::AccountCodeNotAllowlisted {
            layer: "proxy",
            module_type: "kernel_proxy",
            address: sender,
            code_hash,
        }),
    }
}

pub fn pinned_webauthn_root_validator_id() -> FixedBytes<21> {
    let mut validation_id = [0u8; 21];
    validation_id[0] = wallet_kernel::VALIDATOR_TYPE;
    validation_id[1..].copy_from_slice(PINNED_WEBAUTHN_VALIDATOR_ADDRESS.as_slice());
    FixedBytes::from(validation_id)
}

pub fn validate_kernel_factory_code(factory: Address, code: &Bytes) -> Result<AccountCodeCheck> {
    if factory != PINNED_KERNEL_FACTORY_ADDRESS {
        return Err(BundlerError::AccountCodeNotAllowlisted {
            layer: "factory",
            module_type: "kernel_factory_address",
            address: factory,
            code_hash: B256::ZERO,
        });
    }

    let code_hash = keccak256(code);
    let label = STATIC_KERNEL_FACTORY_CODE_HASHES
        .iter()
        .find(|entry| entry.hash == code_hash)
        .map(|entry| entry.label);

    match label {
        Some(label) => Ok(AccountCodeCheck {
            layer: "factory",
            module_type: "kernel_factory",
            address: factory,
            code_hash,
            label: Some(label),
        }),
        None => Err(BundlerError::AccountCodeNotAllowlisted {
            layer: "factory",
            module_type: "kernel_factory",
            address: factory,
            code_hash,
        }),
    }
}

pub fn validate_webauthn_validator_code(code: &Bytes) -> Result<AccountCodeCheck> {
    let code_hash = keccak256(code);
    let label = STATIC_WEBAUTHN_VALIDATOR_CODE_HASHES
        .iter()
        .find(|entry| entry.hash == code_hash)
        .map(|entry| entry.label);

    match label {
        Some(label) => Ok(AccountCodeCheck {
            layer: "validator",
            module_type: "webauthn_validator",
            address: PINNED_WEBAUTHN_VALIDATOR_ADDRESS,
            code_hash,
            label: Some(label),
        }),
        None => Err(BundlerError::AccountCodeNotAllowlisted {
            layer: "validator",
            module_type: "webauthn_validator",
            address: PINNED_WEBAUTHN_VALIDATOR_ADDRESS,
            code_hash,
        }),
    }
}

pub fn validate_kernel_root_validator(
    sender: Address,
    root_validator: FixedBytes<21>,
) -> Result<AccountCodeCheck> {
    if root_validator == pinned_webauthn_root_validator_id() {
        return Ok(AccountCodeCheck {
            layer: "validator",
            module_type: "kernel_root_validator",
            address: PINNED_WEBAUTHN_VALIDATOR_ADDRESS,
            code_hash: root_validator_marker(root_validator),
            label: Some("kernel webauthn root validator"),
        });
    }

    Err(BundlerError::AccountCodeNotAllowlisted {
        layer: "validator",
        module_type: "kernel_root_validator",
        address: sender,
        code_hash: root_validator_marker(root_validator),
    })
}

pub fn validate_kernel_nonce_key(sender: Address, nonce: U256) -> Result<()> {
    if (nonce >> 64) == U256::ZERO {
        return Ok(());
    }

    Err(BundlerError::AccountCodeNotAllowlisted {
        layer: "module",
        module_type: "kernel_nonce_key",
        address: sender,
        code_hash: B256::from(nonce.to_be_bytes::<32>()),
    })
}

pub fn validate_counterfactual_kernel_account(
    sender: Address,
    nonce: U256,
    factory: Option<Address>,
    factory_data: &Bytes,
) -> Result<KernelFactoryAccountCheck> {
    validate_kernel_nonce_key(sender, nonce)?;

    let factory = factory.ok_or(BundlerError::AccountCodeNotAllowlisted {
        layer: "factory",
        module_type: "kernel_factory_missing",
        address: Address::ZERO,
        code_hash: B256::ZERO,
    })?;
    if factory != PINNED_KERNEL_FACTORY_ADDRESS {
        return Err(BundlerError::AccountCodeNotAllowlisted {
            layer: "factory",
            module_type: "kernel_factory_address",
            address: factory,
            code_hash: B256::ZERO,
        });
    }

    let call = createAccountCall::abi_decode(factory_data).map_err(|_| {
        BundlerError::AccountCodeNotAllowlisted {
            layer: "factory",
            module_type: "kernel_factory_call",
            address: factory,
            code_hash: keccak256(factory_data),
        }
    })?;
    let initialize = initializeCall::abi_decode(&call.initData).map_err(|_| {
        BundlerError::AccountCodeNotAllowlisted {
            layer: "validator",
            module_type: "kernel_initialize_call",
            address: sender,
            code_hash: keccak256(&call.initData),
        }
    })?;

    validate_kernel_root_validator(sender, initialize.rootValidator)?;
    if initialize.hook != Address::ZERO
        || !initialize.hookData.is_empty()
        || !initialize.initConfig.is_empty()
    {
        return Err(BundlerError::AccountCodeNotAllowlisted {
            layer: "module",
            module_type: "kernel_initialize_modules",
            address: sender,
            code_hash: keccak256(&call.initData),
        });
    }

    let actual_salt = wallet_kernel::compute_actual_salt(&call.initData, call.salt);
    let init_code_hash =
        wallet_kernel::erc1967_init_code_hash(PINNED_KERNEL_IMPLEMENTATION_ADDRESS);
    let predicted = wallet_kernel::predict_create2_address(
        PINNED_KERNEL_FACTORY_ADDRESS,
        actual_salt,
        init_code_hash,
    );
    if predicted != sender {
        return Err(BundlerError::AccountCodeNotAllowlisted {
            layer: "factory",
            module_type: "kernel_predicted_sender",
            address: sender,
            code_hash: B256::from(predicted.into_word()),
        });
    }

    Ok(KernelFactoryAccountCheck {
        factory,
        salt: call.salt,
        init_data_hash: keccak256(&call.initData),
    })
}

pub fn erc1967_implementation_address(storage_word: B256) -> Option<Address> {
    let bytes = storage_word.as_slice();
    if bytes[..12].iter().any(|byte| *byte != 0) {
        return None;
    }

    let address = Address::from_slice(&bytes[12..]);
    if address == Address::ZERO {
        return None;
    }

    Some(address)
}

pub fn validate_kernel_implementation_code(
    implementation: Address,
    code: &Bytes,
) -> Result<AccountCodeCheck> {
    let code_hash = keccak256(code);
    let label = STATIC_KERNEL_IMPLEMENTATION_CODE_HASHES
        .iter()
        .find(|entry| entry.hash == code_hash)
        .map(|entry| entry.label);

    match label {
        Some(label) => Ok(AccountCodeCheck {
            layer: "implementation",
            module_type: "kernel_implementation",
            address: implementation,
            code_hash,
            label: Some(label),
        }),
        None => Err(BundlerError::AccountCodeNotAllowlisted {
            layer: "implementation",
            module_type: "kernel_implementation",
            address: implementation,
            code_hash,
        }),
    }
}

fn root_validator_marker(root_validator: FixedBytes<21>) -> B256 {
    let mut marker = [0u8; 32];
    marker[..21].copy_from_slice(root_validator.as_slice());
    B256::from(marker)
}

#[cfg(test)]
mod tests {
    use alloy_primitives::{address, b256, Bytes, B256, U256};
    use wallet_kernel::{
        compute_actual_salt, encode_initialize_call, erc1967_init_code_hash,
        predict_create2_address,
    };

    use super::*;

    #[test]
    fn solady_erc1967_proxy_runtime_hash_matches_pinned_constant() {
        assert_eq!(SOLADY_ERC1967_PROXY_RUNTIME.len(), 61);
        assert_eq!(
            keccak256(SOLADY_ERC1967_PROXY_RUNTIME),
            SOLADY_ERC1967_PROXY_RUNTIME_HASH
        );
    }

    #[test]
    fn empty_sender_code_is_treated_as_counterfactual_for_this_layer() {
        assert_eq!(
            validate_sender_proxy_code(
                address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2"),
                &Bytes::new()
            )
            .unwrap(),
            None
        );
    }

    #[test]
    fn non_empty_unknown_sender_code_fails_closed() {
        let sender = address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2");
        let code = Bytes::from_static(&[0x60, 0x00]);
        let error = validate_sender_proxy_code(sender, &code).unwrap_err();

        assert!(matches!(
            error,
            BundlerError::AccountCodeNotAllowlisted {
                layer: "proxy",
                module_type: "kernel_proxy",
                address,
                ..
            } if address == sender
        ));
    }

    #[test]
    fn solady_proxy_runtime_is_not_allowlisted_until_implementation_resolver_exists() {
        let sender = address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2");
        let code = Bytes::copy_from_slice(SOLADY_ERC1967_PROXY_RUNTIME);

        assert!(matches!(
            validate_sender_proxy_code(sender, &code),
            Err(BundlerError::AccountCodeNotAllowlisted { .. })
        ));
    }

    #[test]
    fn erc1967_implementation_address_decodes_low_twenty_bytes() {
        let implementation = address!("d6CEDDe84be40893d153Be9d467CD6aD37875b28");
        let mut word = [0u8; 32];
        word[12..].copy_from_slice(implementation.as_slice());

        assert_eq!(
            erc1967_implementation_address(B256::from(word)),
            Some(implementation)
        );
    }

    #[test]
    fn erc1967_implementation_address_rejects_malformed_words() {
        let implementation = address!("d6CEDDe84be40893d153Be9d467CD6aD37875b28");
        let mut word = [0u8; 32];
        word[0] = 1;
        word[12..].copy_from_slice(implementation.as_slice());

        assert_eq!(erc1967_implementation_address(B256::from(word)), None);
        assert_eq!(erc1967_implementation_address(B256::ZERO), None);
    }

    #[test]
    fn validates_pinned_kernel_implementation_code_hashes() {
        let implementation = address!("d6CEDDe84be40893d153Be9d467CD6aD37875b28");
        let mainnet_hash =
            b256!("d748c6060679ccb34583963e5edc21299e4c6723e7c7a80561d255861ed209b7");

        assert!(STATIC_KERNEL_IMPLEMENTATION_CODE_HASHES
            .iter()
            .any(|entry| entry.hash == mainnet_hash));

        let error =
            validate_kernel_implementation_code(implementation, &Bytes::from_static(&[0x60, 0x00]))
                .unwrap_err();
        assert!(matches!(
            error,
            BundlerError::AccountCodeNotAllowlisted {
                layer: "implementation",
                module_type: "kernel_implementation",
                address,
                ..
            } if address == implementation
        ));
    }

    #[test]
    fn pinned_webauthn_root_validator_matches_kernel_validation_id() {
        assert_eq!(
            pinned_webauthn_root_validator_id(),
            wallet_kernel::build_validation_id(PINNED_WEBAUTHN_VALIDATOR_ADDRESS)
        );
    }

    #[test]
    fn validates_counterfactual_kernel_factory_call_for_app_shape() {
        let init_data = encode_initialize_call(
            PINNED_WEBAUTHN_VALIDATOR_ADDRESS,
            U256::from(1u64),
            U256::from(2u64),
            B256::ZERO,
        );
        let salt = B256::ZERO;
        let actual_salt = compute_actual_salt(&init_data, salt);
        let init_code_hash = erc1967_init_code_hash(PINNED_KERNEL_IMPLEMENTATION_ADDRESS);
        let sender =
            predict_create2_address(PINNED_KERNEL_FACTORY_ADDRESS, actual_salt, init_code_hash);
        let factory_data = createAccountCall {
            initData: Bytes::from(init_data.clone()),
            salt,
        }
        .abi_encode();

        let check = validate_counterfactual_kernel_account(
            sender,
            U256::ZERO,
            Some(PINNED_KERNEL_FACTORY_ADDRESS),
            &Bytes::from(factory_data),
        )
        .unwrap();

        assert_eq!(check.factory, PINNED_KERNEL_FACTORY_ADDRESS);
        assert_eq!(check.salt, B256::ZERO);
        assert_eq!(check.init_data_hash, keccak256(init_data));
    }

    #[test]
    fn counterfactual_kernel_factory_call_rejects_wrong_sender() {
        let init_data = encode_initialize_call(
            PINNED_WEBAUTHN_VALIDATOR_ADDRESS,
            U256::from(1u64),
            U256::from(2u64),
            B256::ZERO,
        );
        let factory_data = createAccountCall {
            initData: Bytes::from(init_data),
            salt: B256::ZERO,
        }
        .abi_encode();

        let error = validate_counterfactual_kernel_account(
            address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2"),
            U256::ZERO,
            Some(PINNED_KERNEL_FACTORY_ADDRESS),
            &Bytes::from(factory_data),
        )
        .unwrap_err();

        assert!(matches!(
            error,
            BundlerError::AccountCodeNotAllowlisted {
                layer: "factory",
                module_type: "kernel_predicted_sender",
                ..
            }
        ));
    }

    #[test]
    fn counterfactual_kernel_factory_call_rejects_nonzero_nonce_key() {
        let error = validate_counterfactual_kernel_account(
            address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2"),
            U256::from(1u64) << 64,
            Some(PINNED_KERNEL_FACTORY_ADDRESS),
            &Bytes::new(),
        )
        .unwrap_err();

        assert!(matches!(
            error,
            BundlerError::AccountCodeNotAllowlisted {
                layer: "module",
                module_type: "kernel_nonce_key",
                ..
            }
        ));
    }
}
