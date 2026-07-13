use alloy_primitives::{b256, keccak256, Address, Bytes, FixedBytes, B256, U256};
use alloy_sol_types::{sol, SolCall};
pub use wallet_addresses::{
    DAIMO_P256_VERIFIER_ADDRESS, ERC1967_IMPLEMENTATION_SLOT, MAINNET_CHAIN_ID,
    PINNED_KERNEL_FACTORY_ADDRESS, PINNED_KERNEL_IMPLEMENTATION_ADDRESS,
    PINNED_WEBAUTHN_VALIDATOR_ADDRESS, SEPOLIA_CHAIN_ID, SOLADY_ERC1967_PROXY_RUNTIME_HASH,
};

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

pub const STATIC_KERNEL_PROXY_CODE_HASHES: &[AllowlistedCodeHash] = &[
    AllowlistedCodeHash {
        chain_id: MAINNET_CHAIN_ID,
        hash: SOLADY_ERC1967_PROXY_RUNTIME_HASH,
        label: "solady erc1967 proxy runtime mainnet",
    },
    AllowlistedCodeHash {
        chain_id: SEPOLIA_CHAIN_ID,
        hash: SOLADY_ERC1967_PROXY_RUNTIME_HASH,
        label: "solady erc1967 proxy runtime sepolia shared hash",
    },
];
pub const STATIC_KERNEL_FACTORY_CODE_HASHES: &[AllowlistedCodeHash] = &[
    AllowlistedCodeHash {
        chain_id: MAINNET_CHAIN_ID,
        hash: b256!("cc4b1b98f5716bf61042d87bfedd4709a5c9a597c41f3bb0e6fb6fe1a4ebd37a"),
        label: "kernel factory mainnet",
    },
    AllowlistedCodeHash {
        chain_id: SEPOLIA_CHAIN_ID,
        hash: b256!("cc4b1b98f5716bf61042d87bfedd4709a5c9a597c41f3bb0e6fb6fe1a4ebd37a"),
        label: "kernel factory sepolia shared hash",
    },
];
pub const STATIC_KERNEL_IMPLEMENTATION_CODE_HASHES: &[AllowlistedCodeHash] = &[
    AllowlistedCodeHash {
        chain_id: MAINNET_CHAIN_ID,
        hash: b256!("d748c6060679ccb34583963e5edc21299e4c6723e7c7a80561d255861ed209b7"),
        label: "kernel-v3.3.0 implementation mainnet",
    },
    AllowlistedCodeHash {
        chain_id: SEPOLIA_CHAIN_ID,
        hash: b256!("1cacd781072bcb657a6306afd074049f35d0a9d7f50eccda9b12bdd00c636995"),
        label: "kernel-v3.3.0 implementation sepolia",
    },
];
pub const STATIC_WEBAUTHN_VALIDATOR_CODE_HASHES: &[AllowlistedCodeHash] = &[
    AllowlistedCodeHash {
        chain_id: MAINNET_CHAIN_ID,
        hash: b256!("726d987ac55574f77f5184326631c5c51142f94c16c9b9281b751f97519c9eea"),
        label: "kernel webauthn validator mainnet",
    },
    AllowlistedCodeHash {
        chain_id: SEPOLIA_CHAIN_ID,
        hash: b256!("726d987ac55574f77f5184326631c5c51142f94c16c9b9281b751f97519c9eea"),
        label: "kernel webauthn validator sepolia shared hash",
    },
];
pub const STATIC_DAIMO_P256_VERIFIER_CODE_HASHES: &[AllowlistedCodeHash] = &[
    AllowlistedCodeHash {
        chain_id: MAINNET_CHAIN_ID,
        hash: b256!("3cd725b6ba67b40b7979190c41a015e82cf21e098eb61832ba623f8538bab7fc"),
        label: "daimo p256 verifier mainnet",
    },
    AllowlistedCodeHash {
        chain_id: SEPOLIA_CHAIN_ID,
        hash: b256!("3cd725b6ba67b40b7979190c41a015e82cf21e098eb61832ba623f8538bab7fc"),
        label: "daimo p256 verifier sepolia shared hash",
    },
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AllowlistedCodeHash {
    pub chain_id: u64,
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
    chain_id: u64,
    sender: Address,
    code: &Bytes,
) -> Result<Option<AccountCodeCheck>> {
    if code.is_empty() {
        return Ok(None);
    }

    let code_hash = keccak256(code);
    let label = STATIC_KERNEL_PROXY_CODE_HASHES
        .iter()
        .find(|entry| entry.chain_id == chain_id && entry.hash == code_hash)
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

pub fn validate_kernel_factory_code(
    chain_id: u64,
    factory: Address,
    code: &Bytes,
) -> Result<AccountCodeCheck> {
    if factory != PINNED_KERNEL_FACTORY_ADDRESS {
        return Err(BundlerError::AccountCodeNotAllowlisted {
            layer: "factory",
            module_type: "kernel_factory_address",
            address: factory,
            code_hash: B256::ZERO,
        });
    }

    let code_hash = keccak256(code);
    let label = allowlisted_code_hash_label(STATIC_KERNEL_FACTORY_CODE_HASHES, chain_id, code_hash);

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

pub fn validate_webauthn_validator_code(chain_id: u64, code: &Bytes) -> Result<AccountCodeCheck> {
    let code_hash = keccak256(code);
    let label =
        allowlisted_code_hash_label(STATIC_WEBAUTHN_VALIDATOR_CODE_HASHES, chain_id, code_hash);

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

pub fn validate_daimo_p256_verifier_code(chain_id: u64, code: &Bytes) -> Result<AccountCodeCheck> {
    let code_hash = keccak256(code);
    let label =
        allowlisted_code_hash_label(STATIC_DAIMO_P256_VERIFIER_CODE_HASHES, chain_id, code_hash);

    match label {
        Some(label) => Ok(AccountCodeCheck {
            layer: "verifier",
            module_type: "daimo_p256_verifier",
            address: DAIMO_P256_VERIFIER_ADDRESS,
            code_hash,
            label: Some(label),
        }),
        None => Err(BundlerError::AccountCodeNotAllowlisted {
            layer: "verifier",
            module_type: "daimo_p256_verifier",
            address: DAIMO_P256_VERIFIER_ADDRESS,
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
    let decoded = wallet_kernel::KernelNonce::decode(nonce);
    if decoded.is_default_root_key_zero() || is_supported_permission_nonce_key(&decoded) {
        return Ok(());
    }

    Err(BundlerError::AccountCodeNotAllowlisted {
        layer: "module",
        module_type: "kernel_nonce_key",
        address: sender,
        code_hash: B256::from(nonce.to_be_bytes::<32>()),
    })
}

fn is_supported_permission_nonce_key(decoded: &wallet_kernel::KernelNonce) -> bool {
    decoded.validation_type == wallet_kernel::VALIDATION_TYPE_PERMISSION
        && matches!(
            decoded.validation_mode,
            wallet_kernel::VALIDATION_MODE_DEFAULT | wallet_kernel::VALIDATION_MODE_ENABLE
        )
        && decoded.parallel_key == 0
}

pub fn validate_counterfactual_kernel_account(
    chain_id: u64,
    sender: Address,
    nonce: U256,
    factory: Option<Address>,
    factory_data: &Bytes,
) -> Result<KernelFactoryAccountCheck> {
    validate_supported_chain(chain_id, sender)?;
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
    chain_id: u64,
    implementation: Address,
    code: &Bytes,
) -> Result<AccountCodeCheck> {
    let code_hash = keccak256(code);
    let label = allowlisted_code_hash_label(
        STATIC_KERNEL_IMPLEMENTATION_CODE_HASHES,
        chain_id,
        code_hash,
    );

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

fn allowlisted_code_hash_label(
    entries: &[AllowlistedCodeHash],
    chain_id: u64,
    code_hash: B256,
) -> Option<&'static str> {
    entries
        .iter()
        .find(|entry| entry.chain_id == chain_id && entry.hash == code_hash)
        .map(|entry| entry.label)
}

fn validate_supported_chain(chain_id: u64, address: Address) -> Result<()> {
    if matches!(chain_id, MAINNET_CHAIN_ID | SEPOLIA_CHAIN_ID) {
        return Ok(());
    }

    Err(BundlerError::AccountCodeNotAllowlisted {
        layer: "chain",
        module_type: "unsupported_chain_id",
        address,
        code_hash: B256::from(U256::from(chain_id).to_be_bytes::<32>()),
    })
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
                MAINNET_CHAIN_ID,
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
        let error = validate_sender_proxy_code(MAINNET_CHAIN_ID, sender, &code).unwrap_err();

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
    fn static_proxy_hashes_include_solady_runtime_for_supported_chains() {
        assert!(STATIC_KERNEL_PROXY_CODE_HASHES.iter().any(|entry| {
            entry.chain_id == MAINNET_CHAIN_ID && entry.hash == SOLADY_ERC1967_PROXY_RUNTIME_HASH
        }));
        assert!(STATIC_KERNEL_PROXY_CODE_HASHES.iter().any(|entry| {
            entry.chain_id == SEPOLIA_CHAIN_ID && entry.hash == SOLADY_ERC1967_PROXY_RUNTIME_HASH
        }));
    }

    #[test]
    fn solady_proxy_runtime_is_allowlisted_at_proxy_layer() {
        let sender = address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2");
        let code = Bytes::copy_from_slice(SOLADY_ERC1967_PROXY_RUNTIME);

        let check = validate_sender_proxy_code(MAINNET_CHAIN_ID, sender, &code)
            .unwrap()
            .unwrap();

        assert_eq!(check.layer, "proxy");
        assert_eq!(check.module_type, "kernel_proxy");
        assert_eq!(check.address, sender);
        assert_eq!(check.code_hash, SOLADY_ERC1967_PROXY_RUNTIME_HASH);
        assert_eq!(check.label, Some("solady erc1967 proxy runtime mainnet"));
    }

    #[test]
    fn sender_proxy_code_is_chain_scoped() {
        let sender = address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2");
        let code = Bytes::copy_from_slice(SOLADY_ERC1967_PROXY_RUNTIME);
        let error = validate_sender_proxy_code(999_999, sender, &code).unwrap_err();

        assert!(matches!(
            error,
            BundlerError::AccountCodeNotAllowlisted {
                layer: "proxy",
                module_type: "kernel_proxy",
                address,
                code_hash,
            } if address == sender && code_hash == SOLADY_ERC1967_PROXY_RUNTIME_HASH
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
            .any(|entry| entry.chain_id == MAINNET_CHAIN_ID && entry.hash == mainnet_hash));

        let error = validate_kernel_implementation_code(
            MAINNET_CHAIN_ID,
            implementation,
            &Bytes::from_static(&[0x60, 0x00]),
        )
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
    fn daimo_p256_verifier_hashes_are_chain_scoped() {
        let verifier_hash =
            b256!("3cd725b6ba67b40b7979190c41a015e82cf21e098eb61832ba623f8538bab7fc");

        assert!(STATIC_DAIMO_P256_VERIFIER_CODE_HASHES
            .iter()
            .any(|entry| entry.chain_id == MAINNET_CHAIN_ID && entry.hash == verifier_hash));
        assert!(STATIC_DAIMO_P256_VERIFIER_CODE_HASHES
            .iter()
            .any(|entry| entry.chain_id == SEPOLIA_CHAIN_ID && entry.hash == verifier_hash));

        let error =
            validate_daimo_p256_verifier_code(MAINNET_CHAIN_ID, &Bytes::from_static(&[0x60, 0x00]))
                .unwrap_err();
        assert!(matches!(
            error,
            BundlerError::AccountCodeNotAllowlisted {
                layer: "verifier",
                module_type: "daimo_p256_verifier",
                address,
                ..
            } if address == DAIMO_P256_VERIFIER_ADDRESS
        ));
    }

    #[test]
    fn kernel_implementation_hashes_are_chain_scoped() {
        let mainnet_hash =
            b256!("d748c6060679ccb34583963e5edc21299e4c6723e7c7a80561d255861ed209b7");
        let sepolia_hash =
            b256!("1cacd781072bcb657a6306afd074049f35d0a9d7f50eccda9b12bdd00c636995");

        assert!(STATIC_KERNEL_IMPLEMENTATION_CODE_HASHES
            .iter()
            .any(|entry| entry.chain_id == MAINNET_CHAIN_ID && entry.hash == mainnet_hash));
        assert!(STATIC_KERNEL_IMPLEMENTATION_CODE_HASHES
            .iter()
            .any(|entry| entry.chain_id == SEPOLIA_CHAIN_ID && entry.hash == sepolia_hash));

        assert_eq!(
            allowlisted_code_hash_label(
                STATIC_KERNEL_IMPLEMENTATION_CODE_HASHES,
                SEPOLIA_CHAIN_ID,
                mainnet_hash,
            ),
            None
        );
        assert_eq!(
            allowlisted_code_hash_label(
                STATIC_KERNEL_IMPLEMENTATION_CODE_HASHES,
                MAINNET_CHAIN_ID,
                sepolia_hash,
            ),
            None
        );
        assert_eq!(
            allowlisted_code_hash_label(
                STATIC_KERNEL_IMPLEMENTATION_CODE_HASHES,
                MAINNET_CHAIN_ID,
                mainnet_hash,
            ),
            Some("kernel-v3.3.0 implementation mainnet")
        );
        assert_eq!(
            allowlisted_code_hash_label(
                STATIC_KERNEL_IMPLEMENTATION_CODE_HASHES,
                SEPOLIA_CHAIN_ID,
                sepolia_hash,
            ),
            Some("kernel-v3.3.0 implementation sepolia")
        );
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
            MAINNET_CHAIN_ID,
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
            MAINNET_CHAIN_ID,
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
            MAINNET_CHAIN_ID,
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

    fn permission_nonce(mode: u8, parallel_key: u16, sequence: u64) -> U256 {
        let mut nonce = [0u8; 32];
        nonce[0] = mode;
        nonce[1] = wallet_kernel::VALIDATION_TYPE_PERMISSION;
        nonce[2..6].copy_from_slice(&[0xaa, 0xbb, 0xcc, 0xdd]);
        nonce[22..24].copy_from_slice(&parallel_key.to_be_bytes());
        nonce[24..32].copy_from_slice(&sequence.to_be_bytes());
        U256::from_be_bytes(nonce)
    }

    #[test]
    fn nonce_key_accepts_permission_default_and_enable() {
        let sender = address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2");

        assert!(validate_kernel_nonce_key(
            sender,
            permission_nonce(wallet_kernel::VALIDATION_MODE_DEFAULT, 0, 0)
        )
        .is_ok());
        assert!(validate_kernel_nonce_key(
            sender,
            permission_nonce(wallet_kernel::VALIDATION_MODE_ENABLE, 0, 9)
        )
        .is_ok());
    }

    #[test]
    fn nonce_key_rejects_other_validators_and_parallel() {
        let sender = address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2");

        let mut validator_nonce = [0u8; 32];
        validator_nonce[1] = wallet_kernel::VALIDATION_TYPE_VALIDATOR;
        let error =
            validate_kernel_nonce_key(sender, U256::from_be_bytes(validator_nonce)).unwrap_err();
        assert!(matches!(
            error,
            BundlerError::AccountCodeNotAllowlisted {
                layer: "module",
                module_type: "kernel_nonce_key",
                ..
            }
        ));

        let error = validate_kernel_nonce_key(
            sender,
            permission_nonce(wallet_kernel::VALIDATION_MODE_INSTALL, 0, 0),
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

        let error = validate_kernel_nonce_key(
            sender,
            permission_nonce(wallet_kernel::VALIDATION_MODE_DEFAULT, 1, 0),
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

        let mut nonce = [0u8; 32];
        nonce[22..24].copy_from_slice(&1u16.to_be_bytes());
        let error = validate_kernel_nonce_key(sender, U256::from_be_bytes(nonce)).unwrap_err();
        assert!(matches!(
            error,
            BundlerError::AccountCodeNotAllowlisted {
                layer: "module",
                module_type: "kernel_nonce_key",
                ..
            }
        ));
    }

    #[test]
    fn nonce_key_accepts_root_zero_and_permission_keys() {
        let sender = address!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2");

        for nonce in [
            U256::ZERO,
            U256::from(7u64),
            permission_nonce(wallet_kernel::VALIDATION_MODE_DEFAULT, 0, 0),
            permission_nonce(wallet_kernel::VALIDATION_MODE_ENABLE, 0, 9),
        ] {
            assert!(
                validate_kernel_nonce_key(sender, nonce).is_ok(),
                "nonce {nonce:#x} should be accepted"
            );
        }
    }
}
