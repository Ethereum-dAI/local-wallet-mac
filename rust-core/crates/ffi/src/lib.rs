use alloy_primitives::{Address, Bytes, FixedBytes, B256, U256};
use secp256k1::rand::Rng;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::panic::catch_unwind;
use wallet_kernel::{
    call_policy, ecdsa_signer_entry, enable_digest, encode_enable_data, encode_initialize_call,
    encode_permission_nonce_key, encode_selector_data_default_action, gas_policy,
    grant_access_calldata, install_validations_calldata, invalidate_nonce_calldata, permission_id,
    permission_validation_id, predict_kernel_account_address, rate_limit_policy, timestamp_policy,
    uninstall_permission_calldata, AllowRule, AllowedCall, Condition,
};
use wallet_signature::{
    abi_encode_dummy_signature as signature_abi_encode_dummy_signature,
    abi_encode_webauthn_signature, build_signature, compute_userop_hash,
    dummy_permission_signature_enable, dummy_permission_signature_installed, normalise_low_s,
    sign_session_userop_hash,
    webauthn::{build_authenticator_data, build_client_data_json},
    wrap_enable_signature, wrap_installed_signature, PackedUserOperation,
};
use zeroize::Zeroizing;

/// Result codes for FFI functions.
#[repr(i32)]
pub enum WalletResult {
    Ok = 0,
    InvalidInput = -1,
    InternalError = -2,
}

fn fixed_32(slice: &[u8]) -> Result<[u8; 32], WalletResult> {
    <[u8; 32]>::try_from(slice).map_err(|_| WalletResult::InvalidInput)
}

fn parse_hex_bytes(value: &str) -> Result<Vec<u8>, WalletResult> {
    let hex = value.strip_prefix("0x").unwrap_or(value);
    if !hex.len().is_multiple_of(2) {
        return Err(WalletResult::InvalidInput);
    }

    (0..hex.len())
        .step_by(2)
        .map(|idx| {
            u8::from_str_radix(&hex[idx..idx + 2], 16).map_err(|_| WalletResult::InvalidInput)
        })
        .collect()
}

fn parse_address(value: &str) -> Result<Address, WalletResult> {
    value.parse().map_err(|_| WalletResult::InvalidInput)
}

fn parse_selector(value: &str) -> Result<[u8; 4], WalletResult> {
    let bytes = parse_hex_bytes(value)?;
    <[u8; 4]>::try_from(bytes.as_slice()).map_err(|_| WalletResult::InvalidInput)
}

fn parse_b256(value: &str) -> Result<B256, WalletResult> {
    let bytes = parse_hex_bytes(value)?;
    if bytes.len() != 32 {
        return Err(WalletResult::InvalidInput);
    }
    Ok(B256::from_slice(&bytes))
}

fn parse_u256(value: &str) -> Result<U256, WalletResult> {
    if let Some(hex) = value.strip_prefix("0x") {
        U256::from_str_radix(hex, 16).map_err(|_| WalletResult::InvalidInput)
    } else {
        U256::from_str_radix(value, 10).map_err(|_| WalletResult::InvalidInput)
    }
}

fn parse_u128(value: &str) -> Result<u128, WalletResult> {
    let parsed = parse_u256(value)?;
    if parsed > U256::from(u128::MAX) {
        return Err(WalletResult::InvalidInput);
    }
    Ok(parsed.to::<u128>())
}

fn read_abi_usize_word(bytes: &[u8], offset: usize) -> Result<usize, WalletResult> {
    let end = offset.checked_add(32).ok_or(WalletResult::InvalidInput)?;
    let word = bytes.get(offset..end).ok_or(WalletResult::InvalidInput)?;
    if word[..24].iter().any(|byte| *byte != 0) {
        return Err(WalletResult::InvalidInput);
    }
    let mut low = [0u8; 8];
    low.copy_from_slice(&word[24..]);
    let value = u64::from_be_bytes(low);
    usize::try_from(value).map_err(|_| WalletResult::InvalidInput)
}

fn write_abi_usize_word(out: &mut Vec<u8>, value: usize) -> Result<(), WalletResult> {
    let value = u64::try_from(value).map_err(|_| WalletResult::InvalidInput)?;
    out.extend_from_slice(&[0u8; 24]);
    out.extend_from_slice(&value.to_be_bytes());
    Ok(())
}

fn empty_permission_deinit_data_from_enable_data(
    enable_data: &[u8],
) -> Result<Vec<u8>, WalletResult> {
    let array_offset = read_abi_usize_word(enable_data, 0)?;
    if array_offset % 32 != 0 {
        return Err(WalletResult::InvalidInput);
    }
    let entry_count = read_abi_usize_word(enable_data, array_offset)?;
    if entry_count == 0 {
        return Err(WalletResult::InvalidInput);
    }
    let array_head_len = entry_count
        .checked_mul(32)
        .and_then(|len| len.checked_add(32))
        .ok_or(WalletResult::InvalidInput)?;
    let array_head_end = array_offset
        .checked_add(array_head_len)
        .ok_or(WalletResult::InvalidInput)?;
    if array_head_end > enable_data.len() {
        return Err(WalletResult::InvalidInput);
    }

    let word_count = 2usize
        .checked_add(entry_count)
        .and_then(|count| count.checked_add(entry_count))
        .ok_or(WalletResult::InvalidInput)?;
    let capacity = word_count
        .checked_mul(32)
        .ok_or(WalletResult::InvalidInput)?;
    let mut out = Vec::with_capacity(capacity);
    write_abi_usize_word(&mut out, 32)?;
    write_abi_usize_word(&mut out, entry_count)?;
    for idx in 0..entry_count {
        let element_tail_offset = idx.checked_mul(32).ok_or(WalletResult::InvalidInput)?;
        let offset = entry_count
            .checked_mul(32)
            .and_then(|base| base.checked_add(element_tail_offset))
            .ok_or(WalletResult::InvalidInput)?;
        write_abi_usize_word(&mut out, offset)?;
    }
    for _ in 0..entry_count {
        write_abi_usize_word(&mut out, 0)?;
    }
    Ok(out)
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionPermissionConfig {
    account: String,
    chain_id: u64,
    session_key: String,
    execute_selector: String,
    #[serde(default)]
    validation_nonce: u32,
    gas_budget_wei: String,
    #[serde(default)]
    enforce_paymaster: bool,
    #[serde(default)]
    allowed_paymaster: Option<String>,
    rate_limit_interval_sec: u64,
    rate_limit_count: u64,
    #[serde(default)]
    rate_limit_start_at: u64,
    #[serde(default)]
    valid_after: u64,
    valid_until: u64,
    #[serde(default)]
    allowed_calls: Vec<AllowedCallConfig>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AllowedCallConfig {
    target: String,
    selector: String,
    #[serde(alias = "valueLimit")]
    value_limit_wei: String,
    #[serde(default)]
    rules: Vec<AllowRuleConfig>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AllowRuleConfig {
    condition: ConditionConfig,
    offset: u64,
    #[serde(default)]
    params: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(untagged)]
enum ConditionConfig {
    Number(u8),
    Name(String),
}

impl ConditionConfig {
    fn to_condition(&self) -> Result<Condition, WalletResult> {
        match self {
            Self::Number(0) => Ok(Condition::Equal),
            Self::Number(1) => Ok(Condition::GreaterThan),
            Self::Number(2) => Ok(Condition::LessThan),
            Self::Number(3) => Ok(Condition::GreaterEqual),
            Self::Number(4) => Ok(Condition::LessEqual),
            Self::Number(5) => Ok(Condition::NotEqual),
            Self::Number(6) => Ok(Condition::OneOf),
            Self::Number(7) => Ok(Condition::SliceEqual),
            Self::Number(_) => Err(WalletResult::InvalidInput),
            Self::Name(name) => match name.as_str() {
                "equal" | "Equal" | "EQUAL" => Ok(Condition::Equal),
                "greaterThan" | "GreaterThan" | "GREATER_THAN" => Ok(Condition::GreaterThan),
                "lessThan" | "LessThan" | "LESS_THAN" => Ok(Condition::LessThan),
                "greaterEqual" | "GreaterEqual" | "GREATER_EQUAL" => Ok(Condition::GreaterEqual),
                "lessEqual" | "LessEqual" | "LESS_EQUAL" => Ok(Condition::LessEqual),
                "notEqual" | "NotEqual" | "NOT_EQUAL" => Ok(Condition::NotEqual),
                "oneOf" | "OneOf" | "ONE_OF" => Ok(Condition::OneOf),
                "sliceEqual" | "SliceEqual" | "SLICE_EQUAL" => Ok(Condition::SliceEqual),
                _ => Err(WalletResult::InvalidInput),
            },
        }
    }
}

struct SessionPermissionOutput {
    permission_id: [u8; 4],
    enable_data: Vec<u8>,
    selector_data: Vec<u8>,
    enable_digest: B256,
    nonce_key_default: [u8; 32],
    nonce_key_enable: [u8; 32],
}

fn nonce_key_192(permission_id: [u8; 4], mode: u8) -> [u8; 32] {
    let key: U256 = encode_permission_nonce_key(permission_id, mode) >> 64usize;
    key.to_be_bytes::<32>()
}

fn build_session_permission(
    config: &SessionPermissionConfig,
) -> Result<SessionPermissionOutput, WalletResult> {
    let account = parse_address(&config.account)?;
    let session_key = parse_address(&config.session_key)?;
    let execute_selector = parse_selector(&config.execute_selector)?;
    let allowed_paymaster = config
        .allowed_paymaster
        .as_deref()
        .map(parse_address)
        .transpose()?
        .unwrap_or(Address::ZERO);
    let calls = config
        .allowed_calls
        .iter()
        .map(|call| {
            let rules = call
                .rules
                .iter()
                .map(|rule| {
                    Ok(AllowRule {
                        condition: rule.condition.to_condition()?,
                        offset: rule.offset,
                        params: rule
                            .params
                            .iter()
                            .map(|param| parse_b256(param))
                            .collect::<Result<Vec<_>, _>>()?,
                    })
                })
                .collect::<Result<Vec<_>, WalletResult>>()?;

            Ok(AllowedCall {
                target: parse_address(&call.target)?,
                selector: parse_selector(&call.selector)?,
                value_limit: parse_u256(&call.value_limit_wei)?,
                rules,
            })
        })
        .collect::<Result<Vec<_>, WalletResult>>()?;
    let policies = vec![
        gas_policy(
            parse_u128(&config.gas_budget_wei)?,
            config.enforce_paymaster,
            allowed_paymaster,
        ),
        rate_limit_policy(
            config.rate_limit_interval_sec,
            config.rate_limit_count,
            config.rate_limit_start_at,
        ),
        timestamp_policy(config.valid_after, config.valid_until),
        call_policy(&calls),
    ];
    let (signer_contract, signer_data) = ecdsa_signer_entry(session_key);
    let permission_id = permission_id(&policies, signer_contract, &signer_data);
    let enable_data = encode_enable_data(&policies, signer_contract, &signer_data);
    let selector_data = encode_selector_data_default_action(execute_selector);
    let enable_digest = enable_digest(
        account,
        config.chain_id,
        permission_validation_id(permission_id),
        config.validation_nonce,
        Address::ZERO,
        &enable_data,
        &[],
        &selector_data,
    );

    Ok(SessionPermissionOutput {
        permission_id,
        enable_data,
        selector_data,
        enable_digest,
        nonce_key_default: nonce_key_192(permission_id, wallet_kernel::VALIDATION_MODE_DEFAULT),
        nonce_key_enable: nonce_key_192(permission_id, wallet_kernel::VALIDATION_MODE_ENABLE),
    })
}

unsafe fn write_heap_buffer(
    bytes: Vec<u8>,
    out_ptr: *mut *const u8,
    out_len: *mut u32,
) -> Result<(), WalletResult> {
    if bytes.len() > u32::MAX as usize {
        return Err(WalletResult::InvalidInput);
    }
    let len = bytes.len();
    let boxed = bytes.into_boxed_slice();
    let raw_ptr = Box::into_raw(boxed) as *mut u8;
    *out_ptr = raw_ptr;
    *out_len = len as u32;
    Ok(())
}

/// # Safety
/// `out_secret` must point to 32 writable bytes and `out_address` to 20 writable bytes.
#[no_mangle]
pub unsafe extern "C" fn wallet_generate_bundler_secret(
    out_secret: *mut u8,
    out_address: *mut u8,
) -> i32 {
    let result = catch_unwind(|| {
        if out_secret.is_null() || out_address.is_null() {
            return WalletResult::InvalidInput as i32;
        }

        let secp = secp256k1::Secp256k1::signing_only();
        let mut rng = secp256k1::rand::thread_rng();
        let mut secret_bytes = Zeroizing::new([0u8; 32]);
        let public = loop {
            rng.fill(&mut secret_bytes[..]);
            if let Ok(secret) = secp256k1::SecretKey::from_byte_array(&secret_bytes) {
                break secp256k1::PublicKey::from_secret_key(&secp, &secret);
            }
        };
        let uncompressed = public.serialize_uncompressed();
        let hash = alloy_primitives::keccak256(&uncompressed[1..]);

        std::ptr::copy_nonoverlapping(secret_bytes.as_ptr(), out_secret, 32);
        std::ptr::copy_nonoverlapping(hash[12..].as_ptr(), out_address, 20);
        WalletResult::Ok as i32
    });

    result.unwrap_or(WalletResult::InternalError as i32)
}

/// # Safety
/// `secret` must point to 32 bytes and `out_address` to 20 writable bytes.
#[no_mangle]
pub unsafe extern "C" fn wallet_bundler_address_from_secret(
    secret: *const u8,
    out_address: *mut u8,
) -> i32 {
    let result = catch_unwind(|| {
        if secret.is_null() || out_address.is_null() {
            return WalletResult::InvalidInput as i32;
        }

        let secret_slice = std::slice::from_raw_parts(secret, 32);
        let Ok(secret_bytes) = <[u8; 32]>::try_from(secret_slice) else {
            return WalletResult::InvalidInput as i32;
        };
        let Ok(secret_key) = secp256k1::SecretKey::from_byte_array(&secret_bytes) else {
            return WalletResult::InvalidInput as i32;
        };

        let secp = secp256k1::Secp256k1::signing_only();
        let public = secp256k1::PublicKey::from_secret_key(&secp, &secret_key);
        let uncompressed = public.serialize_uncompressed();
        let hash = alloy_primitives::keccak256(&uncompressed[1..]);

        std::ptr::copy_nonoverlapping(hash[12..].as_ptr(), out_address, 20);
        WalletResult::Ok as i32
    });

    result.unwrap_or(WalletResult::InternalError as i32)
}

/// # Safety
/// All pointer parameters must be valid and point to buffers of the documented sizes.
#[no_mangle]
pub unsafe extern "C" fn wallet_compute_userop_hash(
    sender: *const u8, // 20 bytes
    nonce: *const u8,  // 32 bytes big-endian
    init_code: *const u8,
    init_code_len: u32,
    call_data: *const u8,
    call_data_len: u32,
    account_gas_limits: *const u8,   // 32 bytes
    pre_verification_gas: *const u8, // 32 bytes big-endian
    gas_fees: *const u8,             // 32 bytes
    paymaster_and_data: *const u8,
    paymaster_and_data_len: u32,
    entry_point: *const u8, // 20 bytes
    chain_id: u64,
    out_hash: *mut u8, // 32 bytes, caller-allocated
) -> i32 {
    let result = catch_unwind(|| {
        if sender.is_null()
            || nonce.is_null()
            || account_gas_limits.is_null()
            || pre_verification_gas.is_null()
            || gas_fees.is_null()
            || entry_point.is_null()
            || out_hash.is_null()
        {
            return WalletResult::InvalidInput as i32;
        }

        let sender_slice = std::slice::from_raw_parts(sender, 20);
        let nonce_slice = std::slice::from_raw_parts(nonce, 32);
        let init_code_slice = if init_code.is_null() || init_code_len == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(init_code, init_code_len as usize)
        };
        let call_data_slice = if call_data.is_null() || call_data_len == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(call_data, call_data_len as usize)
        };
        let agl_slice = std::slice::from_raw_parts(account_gas_limits, 32);
        let pvg_slice = std::slice::from_raw_parts(pre_verification_gas, 32);
        let gf_slice = std::slice::from_raw_parts(gas_fees, 32);
        let pm_slice = if paymaster_and_data.is_null() || paymaster_and_data_len == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(paymaster_and_data, paymaster_and_data_len as usize)
        };
        let ep_slice = std::slice::from_raw_parts(entry_point, 20);

        let nonce = match fixed_32(nonce_slice) {
            Ok(value) => value,
            Err(result) => return result as i32,
        };
        let pre_verification_gas = match fixed_32(pvg_slice) {
            Ok(value) => value,
            Err(result) => return result as i32,
        };

        let userop = PackedUserOperation {
            sender: Address::from_slice(sender_slice),
            nonce: U256::from_be_bytes::<32>(nonce),
            init_code: Bytes::from(init_code_slice.to_vec()),
            call_data: Bytes::from(call_data_slice.to_vec()),
            account_gas_limits: FixedBytes::from_slice(agl_slice),
            pre_verification_gas: U256::from_be_bytes::<32>(pre_verification_gas),
            gas_fees: FixedBytes::from_slice(gf_slice),
            paymaster_and_data: Bytes::from(pm_slice.to_vec()),
        };

        let ep = Address::from_slice(ep_slice);
        let hash = compute_userop_hash(&userop, ep, chain_id);
        std::ptr::copy_nonoverlapping(hash.as_ptr(), out_hash, 32);
        WalletResult::Ok as i32
    });

    result.unwrap_or(WalletResult::InternalError as i32)
}

/// # Safety
/// `userop_hash` must point to 32 bytes. `out_preimage` must point to 69 bytes.
#[no_mangle]
pub unsafe extern "C" fn wallet_compute_signing_preimage(
    userop_hash: *const u8,
    out_preimage: *mut u8,
) -> i32 {
    let result = catch_unwind(|| {
        if userop_hash.is_null() || out_preimage.is_null() {
            return WalletResult::InvalidInput as i32;
        }

        let hash: &[u8; 32] = &*(userop_hash as *const [u8; 32]);
        let auth_data = build_authenticator_data();
        let cdj = build_client_data_json(hash);
        let cdj_hash: [u8; 32] = Sha256::digest(cdj.as_bytes()).into();

        std::ptr::copy_nonoverlapping(auth_data.as_ptr(), out_preimage, 37);
        std::ptr::copy_nonoverlapping(cdj_hash.as_ptr(), out_preimage.add(37), 32);

        WalletResult::Ok as i32
    });

    result.unwrap_or(WalletResult::InternalError as i32)
}

/// # Safety
/// `s_inout` must point to 32 bytes.
#[no_mangle]
pub unsafe extern "C" fn wallet_normalise_low_s(s_inout: *mut u8) -> i32 {
    let result = catch_unwind(|| {
        if s_inout.is_null() {
            return WalletResult::InvalidInput as i32;
        }
        let s_slice = std::slice::from_raw_parts(s_inout, 32);
        let s = match fixed_32(s_slice) {
            Ok(value) => value,
            Err(result) => return result as i32,
        };
        let r_dummy = [0u8; 32];
        let (_, new_s) = normalise_low_s(r_dummy, s);
        std::ptr::copy_nonoverlapping(new_s.as_ptr(), s_inout, 32);
        WalletResult::Ok as i32
    });
    result.unwrap_or(WalletResult::InternalError as i32)
}

/// # Safety
/// All pointer parameters must be valid. Caller must free returned buffer with `wallet_free_buffer`.
#[no_mangle]
pub unsafe extern "C" fn wallet_abi_encode_signature(
    userop_hash: *const u8,
    r: *const u8,
    s: *const u8,
    use_precompiled: bool,
    out_ptr: *mut *const u8,
    out_len: *mut u32,
) -> i32 {
    let result = catch_unwind(|| {
        if userop_hash.is_null()
            || r.is_null()
            || s.is_null()
            || out_ptr.is_null()
            || out_len.is_null()
        {
            return WalletResult::InvalidInput as i32;
        }
        let hash: &[u8; 32] = &*(userop_hash as *const [u8; 32]);
        let r_bytes = match fixed_32(std::slice::from_raw_parts(r, 32)) {
            Ok(value) => value,
            Err(result) => return result as i32,
        };
        let s_bytes = match fixed_32(std::slice::from_raw_parts(s, 32)) {
            Ok(value) => value,
            Err(result) => return result as i32,
        };

        let sig = build_signature(hash, r_bytes, s_bytes, use_precompiled);
        let encoded = abi_encode_webauthn_signature(&sig);
        let len = encoded.len();
        let boxed = encoded.into_boxed_slice();
        let raw_ptr = Box::into_raw(boxed) as *mut u8;
        *out_ptr = raw_ptr;
        *out_len = len as u32;
        WalletResult::Ok as i32
    });
    result.unwrap_or(WalletResult::InternalError as i32)
}

/// # Safety
/// Caller must free returned buffer with `wallet_free_buffer`.
#[no_mangle]
pub unsafe extern "C" fn wallet_abi_encode_dummy_signature(
    use_precompiled: bool,
    out_ptr: *mut *const u8,
    out_len: *mut u32,
) -> i32 {
    let result = catch_unwind(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return WalletResult::InvalidInput as i32;
        }

        let encoded = signature_abi_encode_dummy_signature(use_precompiled);
        let len = encoded.len();
        let boxed = encoded.into_boxed_slice();
        let raw_ptr = Box::into_raw(boxed) as *mut u8;
        *out_ptr = raw_ptr;
        *out_len = len as u32;
        WalletResult::Ok as i32
    });
    result.unwrap_or(WalletResult::InternalError as i32)
}

/// # Safety
/// All pointer parameters must be valid and point to fixed-size buffers.
#[no_mangle]
pub unsafe extern "C" fn wallet_predict_kernel_account_address(
    factory: *const u8,               // 20 bytes
    implementation: *const u8,        // 20 bytes
    webauthn_validator: *const u8,    // 20 bytes
    pub_key_x: *const u8,             // 32 bytes big-endian
    pub_key_y: *const u8,             // 32 bytes big-endian
    authenticator_id_hash: *const u8, // 32 bytes
    salt: *const u8,                  // 32 bytes
    out_address: *mut u8,             // 20 bytes caller-allocated
) -> i32 {
    let result = catch_unwind(|| {
        if factory.is_null()
            || implementation.is_null()
            || webauthn_validator.is_null()
            || pub_key_x.is_null()
            || pub_key_y.is_null()
            || authenticator_id_hash.is_null()
            || salt.is_null()
            || out_address.is_null()
        {
            return WalletResult::InvalidInput as i32;
        }

        let pub_key_x = match fixed_32(std::slice::from_raw_parts(pub_key_x, 32)) {
            Ok(value) => value,
            Err(result) => return result as i32,
        };
        let pub_key_y = match fixed_32(std::slice::from_raw_parts(pub_key_y, 32)) {
            Ok(value) => value,
            Err(result) => return result as i32,
        };

        let predicted = predict_kernel_account_address(
            Address::from_slice(std::slice::from_raw_parts(factory, 20)),
            Address::from_slice(std::slice::from_raw_parts(implementation, 20)),
            Address::from_slice(std::slice::from_raw_parts(webauthn_validator, 20)),
            U256::from_be_bytes::<32>(pub_key_x),
            U256::from_be_bytes::<32>(pub_key_y),
            B256::from_slice(std::slice::from_raw_parts(authenticator_id_hash, 32)),
            B256::from_slice(std::slice::from_raw_parts(salt, 32)),
        );

        std::ptr::copy_nonoverlapping(predicted.as_slice().as_ptr(), out_address, 20);
        WalletResult::Ok as i32
    });

    result.unwrap_or(WalletResult::InternalError as i32)
}

/// # Safety
/// All pointer parameters must be valid and point to fixed-size buffers.
/// Caller must free returned buffer with `wallet_free_buffer`.
#[no_mangle]
pub unsafe extern "C" fn wallet_encode_kernel_initialize_call(
    webauthn_validator: *const u8,    // 20 bytes
    pub_key_x: *const u8,             // 32 bytes big-endian
    pub_key_y: *const u8,             // 32 bytes big-endian
    authenticator_id_hash: *const u8, // 32 bytes
    out_ptr: *mut *const u8,
    out_len: *mut u32,
) -> i32 {
    let result = catch_unwind(|| {
        if webauthn_validator.is_null()
            || pub_key_x.is_null()
            || pub_key_y.is_null()
            || authenticator_id_hash.is_null()
            || out_ptr.is_null()
            || out_len.is_null()
        {
            return WalletResult::InvalidInput as i32;
        }

        let pub_key_x = match fixed_32(std::slice::from_raw_parts(pub_key_x, 32)) {
            Ok(value) => value,
            Err(result) => return result as i32,
        };
        let pub_key_y = match fixed_32(std::slice::from_raw_parts(pub_key_y, 32)) {
            Ok(value) => value,
            Err(result) => return result as i32,
        };

        let encoded = encode_initialize_call(
            Address::from_slice(std::slice::from_raw_parts(webauthn_validator, 20)),
            U256::from_be_bytes::<32>(pub_key_x),
            U256::from_be_bytes::<32>(pub_key_y),
            B256::from_slice(std::slice::from_raw_parts(authenticator_id_hash, 32)),
        );

        let len = encoded.len();
        let boxed = encoded.into_boxed_slice();
        let raw_ptr = Box::into_raw(boxed) as *mut u8;
        *out_ptr = raw_ptr;
        *out_len = len as u32;
        WalletResult::Ok as i32
    });

    result.unwrap_or(WalletResult::InternalError as i32)
}

/// # Safety
/// `config_json` must point to a UTF-8 JSON buffer.
/// Fixed outputs must point to writable buffers of their documented sizes.
/// Caller must free returned heap buffers with `wallet_free_buffer`.
#[no_mangle]
pub unsafe extern "C" fn wallet_session_build_permission(
    config_json: *const u8,
    config_json_len: u32,
    out_permission_id: *mut u8, // 4 bytes
    out_enable_data_ptr: *mut *const u8,
    out_enable_data_len: *mut u32,
    out_selector_data_ptr: *mut *const u8,
    out_selector_data_len: *mut u32,
    out_enable_digest: *mut u8,     // 32 bytes
    out_nonce_key_default: *mut u8, // 32-byte uint192 key value
    out_nonce_key_enable: *mut u8,  // 32-byte uint192 key value
) -> i32 {
    let result = catch_unwind(|| {
        if config_json.is_null()
            || config_json_len == 0
            || out_permission_id.is_null()
            || out_enable_data_ptr.is_null()
            || out_enable_data_len.is_null()
            || out_selector_data_ptr.is_null()
            || out_selector_data_len.is_null()
            || out_enable_digest.is_null()
            || out_nonce_key_default.is_null()
            || out_nonce_key_enable.is_null()
        {
            return WalletResult::InvalidInput as i32;
        }

        let config_slice = std::slice::from_raw_parts(config_json, config_json_len as usize);
        let config: SessionPermissionConfig = match serde_json::from_slice(config_slice) {
            Ok(config) => config,
            Err(_) => return WalletResult::InvalidInput as i32,
        };
        let output = match build_session_permission(&config) {
            Ok(output) => output,
            Err(result) => return result as i32,
        };

        std::ptr::copy_nonoverlapping(output.permission_id.as_ptr(), out_permission_id, 4);
        std::ptr::copy_nonoverlapping(
            output.enable_digest.as_slice().as_ptr(),
            out_enable_digest,
            32,
        );
        std::ptr::copy_nonoverlapping(output.nonce_key_default.as_ptr(), out_nonce_key_default, 32);
        std::ptr::copy_nonoverlapping(output.nonce_key_enable.as_ptr(), out_nonce_key_enable, 32);
        if write_heap_buffer(output.enable_data, out_enable_data_ptr, out_enable_data_len).is_err()
            || write_heap_buffer(
                output.selector_data,
                out_selector_data_ptr,
                out_selector_data_len,
            )
            .is_err()
        {
            return WalletResult::InvalidInput as i32;
        }

        WalletResult::Ok as i32
    });

    result.unwrap_or(WalletResult::InternalError as i32)
}

/// # Safety
/// `session_secret` and `userop_hash` must point to 32 bytes.
/// Enable-mode pointer parameters must be valid when their lengths are non-zero.
/// Caller must free returned heap buffer with `wallet_free_buffer`.
#[no_mangle]
pub unsafe extern "C" fn wallet_session_sign_and_wrap(
    session_secret: *const u8, // 32 bytes
    userop_hash: *const u8,    // 32 bytes
    mode: u8,                  // 0 = installed, 1 = enable
    enable_data: *const u8,
    enable_data_len: u32,
    selector_data: *const u8,
    selector_data_len: u32,
    enable_sig: *const u8,
    enable_sig_len: u32,
    out_ptr: *mut *const u8,
    out_len: *mut u32,
) -> i32 {
    let result = catch_unwind(|| {
        if session_secret.is_null()
            || userop_hash.is_null()
            || out_ptr.is_null()
            || out_len.is_null()
        {
            return WalletResult::InvalidInput as i32;
        }

        let secret = match fixed_32(std::slice::from_raw_parts(session_secret, 32)) {
            Ok(secret) => secret,
            Err(result) => return result as i32,
        };
        let hash = match fixed_32(std::slice::from_raw_parts(userop_hash, 32)) {
            Ok(hash) => hash,
            Err(result) => return result as i32,
        };
        let inner = match sign_session_userop_hash(&hash, &secret) {
            Ok(signature) => signature,
            Err(_) => return WalletResult::InvalidInput as i32,
        };

        let signature = match mode {
            0 => wrap_installed_signature(&inner),
            1 => {
                if enable_data.is_null() || selector_data.is_null() || enable_sig.is_null() {
                    return WalletResult::InvalidInput as i32;
                }
                let enable_data = std::slice::from_raw_parts(enable_data, enable_data_len as usize);
                let selector_data =
                    std::slice::from_raw_parts(selector_data, selector_data_len as usize);
                let enable_sig = std::slice::from_raw_parts(enable_sig, enable_sig_len as usize);
                let userop_sig = wrap_installed_signature(&inner);
                wrap_enable_signature(
                    Address::ZERO,
                    enable_data,
                    &[],
                    selector_data,
                    enable_sig,
                    &userop_sig,
                )
            }
            _ => return WalletResult::InvalidInput as i32,
        };

        match write_heap_buffer(signature, out_ptr, out_len) {
            Ok(()) => WalletResult::Ok as i32,
            Err(result) => result as i32,
        }
    });

    result.unwrap_or(WalletResult::InternalError as i32)
}

/// # Safety
/// Enable-mode pointer parameters must point to valid buffers.
/// Caller must free returned heap buffer with `wallet_free_buffer`.
#[no_mangle]
pub unsafe extern "C" fn wallet_session_dummy_signature(
    mode: u8, // 0 = installed, 1 = enable
    enable_data: *const u8,
    enable_data_len: u32,
    selector_data: *const u8,
    selector_data_len: u32,
    use_precompiled: bool,
    out_ptr: *mut *const u8,
    out_len: *mut u32,
) -> i32 {
    let result = catch_unwind(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return WalletResult::InvalidInput as i32;
        }

        let signature = match mode {
            0 => dummy_permission_signature_installed(),
            1 => {
                if enable_data.is_null() || selector_data.is_null() {
                    return WalletResult::InvalidInput as i32;
                }
                let enable_data = std::slice::from_raw_parts(enable_data, enable_data_len as usize);
                let selector_data =
                    std::slice::from_raw_parts(selector_data, selector_data_len as usize);
                dummy_permission_signature_enable(
                    Address::ZERO,
                    enable_data,
                    &[],
                    selector_data,
                    use_precompiled,
                )
            }
            _ => return WalletResult::InvalidInput as i32,
        };

        match write_heap_buffer(signature, out_ptr, out_len) {
            Ok(()) => WalletResult::Ok as i32,
            Err(result) => result as i32,
        }
    });

    result.unwrap_or(WalletResult::InternalError as i32)
}

/// # Safety
/// Caller must free returned heap buffer with `wallet_free_buffer`.
#[no_mangle]
pub unsafe extern "C" fn wallet_session_invalidate_nonce_calldata(
    nonce: u32,
    out_ptr: *mut *const u8,
    out_len: *mut u32,
) -> i32 {
    let result = catch_unwind(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return WalletResult::InvalidInput as i32;
        }

        match write_heap_buffer(invalidate_nonce_calldata(nonce), out_ptr, out_len) {
            Ok(()) => WalletResult::Ok as i32,
            Err(result) => result as i32,
        }
    });

    result.unwrap_or(WalletResult::InternalError as i32)
}

/// # Safety
/// `enable_data` must point to a Kernel permission enableData ABI bytes array.
/// Caller must free returned heap buffer with `wallet_free_buffer`.
#[no_mangle]
pub unsafe extern "C" fn wallet_session_empty_permission_deinit_data(
    enable_data: *const u8,
    enable_data_len: u32,
    out_ptr: *mut *const u8,
    out_len: *mut u32,
) -> i32 {
    let result = catch_unwind(|| {
        if enable_data.is_null() || out_ptr.is_null() || out_len.is_null() {
            return WalletResult::InvalidInput as i32;
        }
        let enable_data = std::slice::from_raw_parts(enable_data, enable_data_len as usize);

        match empty_permission_deinit_data_from_enable_data(enable_data)
            .and_then(|bytes| write_heap_buffer(bytes, out_ptr, out_len))
        {
            Ok(()) => WalletResult::Ok as i32,
            Err(result) => result as i32,
        }
    });

    result.unwrap_or(WalletResult::InternalError as i32)
}

/// # Safety
/// `permission_id` must point to 4 bytes. `deinit_data` may be null only when
/// `deinit_data_len` is zero. Caller must free returned heap buffer with
/// `wallet_free_buffer`.
#[no_mangle]
pub unsafe extern "C" fn wallet_session_uninstall_permission_calldata(
    permission_id: *const u8,
    deinit_data: *const u8,
    deinit_data_len: u32,
    out_ptr: *mut *const u8,
    out_len: *mut u32,
) -> i32 {
    let result = catch_unwind(|| {
        if permission_id.is_null() || out_ptr.is_null() || out_len.is_null() {
            return WalletResult::InvalidInput as i32;
        }
        if deinit_data_len > 0 && deinit_data.is_null() {
            return WalletResult::InvalidInput as i32;
        }

        let permission_id = match <[u8; 4]>::try_from(std::slice::from_raw_parts(permission_id, 4))
        {
            Ok(value) => value,
            Err(_) => return WalletResult::InvalidInput as i32,
        };
        let deinit_data = if deinit_data_len == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(deinit_data, deinit_data_len as usize)
        };

        match write_heap_buffer(
            uninstall_permission_calldata(permission_id, deinit_data),
            out_ptr,
            out_len,
        ) {
            Ok(()) => WalletResult::Ok as i32,
            Err(result) => result as i32,
        }
    });

    result.unwrap_or(WalletResult::InternalError as i32)
}

/// Calldata for `installValidations` — installs a session permission as a
/// root(owner)-validated self-call (install runs in execution, bypassing the
/// permission's GasPolicy). `nonce` must equal the account's `currentNonce()`.
///
/// # Safety
/// `permission_id` must point to 4 bytes; `validation_data`/`hook_data` must be
/// valid when their lengths are non-zero. Caller frees the buffer with `wallet_free_buffer`.
#[no_mangle]
pub unsafe extern "C" fn wallet_session_install_validations_calldata(
    permission_id: *const u8,
    nonce: u32,
    validation_data: *const u8,
    validation_data_len: u32,
    hook_data: *const u8,
    hook_data_len: u32,
    out_ptr: *mut *const u8,
    out_len: *mut u32,
) -> i32 {
    let result = catch_unwind(|| {
        if permission_id.is_null() || out_ptr.is_null() || out_len.is_null() {
            return WalletResult::InvalidInput as i32;
        }
        if (validation_data_len > 0 && validation_data.is_null())
            || (hook_data_len > 0 && hook_data.is_null())
        {
            return WalletResult::InvalidInput as i32;
        }
        let permission_id = match <[u8; 4]>::try_from(std::slice::from_raw_parts(permission_id, 4))
        {
            Ok(value) => value,
            Err(_) => return WalletResult::InvalidInput as i32,
        };
        let validation_data = if validation_data_len == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(validation_data, validation_data_len as usize)
        };
        let hook_data = if hook_data_len == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(hook_data, hook_data_len as usize)
        };

        match write_heap_buffer(
            install_validations_calldata(permission_id, nonce, validation_data, hook_data),
            out_ptr,
            out_len,
        ) {
            Ok(()) => WalletResult::Ok as i32,
            Err(result) => result as i32,
        }
    });

    result.unwrap_or(WalletResult::InternalError as i32)
}

/// Calldata for `grantAccess(vId, selector, true)` — grants an installed session
/// permission access to a selector (session user ops call `execute`).
///
/// # Safety
/// `permission_id` and `selector` must each point to 4 bytes. Caller frees the
/// buffer with `wallet_free_buffer`.
#[no_mangle]
pub unsafe extern "C" fn wallet_session_grant_access_calldata(
    permission_id: *const u8,
    selector: *const u8,
    out_ptr: *mut *const u8,
    out_len: *mut u32,
) -> i32 {
    let result = catch_unwind(|| {
        if permission_id.is_null() || selector.is_null() || out_ptr.is_null() || out_len.is_null() {
            return WalletResult::InvalidInput as i32;
        }
        let permission_id = match <[u8; 4]>::try_from(std::slice::from_raw_parts(permission_id, 4))
        {
            Ok(value) => value,
            Err(_) => return WalletResult::InvalidInput as i32,
        };
        let selector = match <[u8; 4]>::try_from(std::slice::from_raw_parts(selector, 4)) {
            Ok(value) => value,
            Err(_) => return WalletResult::InvalidInput as i32,
        };

        match write_heap_buffer(
            grant_access_calldata(permission_id, selector),
            out_ptr,
            out_len,
        ) {
            Ok(()) => WalletResult::Ok as i32,
            Err(result) => result as i32,
        }
    });

    result.unwrap_or(WalletResult::InternalError as i32)
}

/// # Safety
/// `ptr` must have been returned by `wallet_abi_encode_signature`. Call exactly once.
#[no_mangle]
pub unsafe extern "C" fn wallet_free_buffer(ptr: *mut u8, len: u32) {
    if !ptr.is_null() && len > 0 {
        let _ = Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len as usize));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hex_literal::hex;
    use serde_json::json;

    fn decode_hex_bytes(value: &str) -> Vec<u8> {
        let hex = value.strip_prefix("0x").unwrap_or(value);
        assert_eq!(hex.len() % 2, 0, "hex string must have even length");
        (0..hex.len())
            .step_by(2)
            .map(|idx| u8::from_str_radix(&hex[idx..idx + 2], 16).expect("valid hex byte"))
            .collect()
    }

    fn permission_fixture() -> serde_json::Value {
        serde_json::from_str(include_str!("../testdata/permission/permission.json"))
            .expect("permission fixture parses")
    }

    fn decode_abi_bytes_tail_element(tail: &[u8], index: usize) -> Vec<u8> {
        let head_start = index * 32;
        let mut offset_bytes = [0u8; 8];
        offset_bytes.copy_from_slice(&tail[head_start + 24..head_start + 32]);
        let offset = u64::from_be_bytes(offset_bytes) as usize;
        let mut len_bytes = [0u8; 8];
        len_bytes.copy_from_slice(&tail[offset + 24..offset + 32]);
        let len = u64::from_be_bytes(len_bytes) as usize;
        tail[offset + 32..offset + 32 + len].to_vec()
    }

    #[test]
    fn ffi_generate_bundler_secret_returns_secret_and_address() {
        let mut secret = [0u8; 32];
        let mut address = [0u8; 20];

        let result =
            unsafe { wallet_generate_bundler_secret(secret.as_mut_ptr(), address.as_mut_ptr()) };

        assert_eq!(result, WalletResult::Ok as i32);
        assert_ne!(secret, [0u8; 32]);
        assert_ne!(address, [0u8; 20]);

        let secp = secp256k1::Secp256k1::signing_only();
        let secret_key = secp256k1::SecretKey::from_byte_array(&secret).expect("valid secret key");
        let public = secp256k1::PublicKey::from_secret_key(&secp, &secret_key);
        let uncompressed = public.serialize_uncompressed();
        let hash = alloy_primitives::keccak256(&uncompressed[1..]);
        assert_eq!(address, hash[12..]);
    }

    #[test]
    fn ffi_derives_bundler_address_from_secret() {
        let secret = hex!("4f3edf983ac636a65a842ce7c78d9aa706d3b113bce9cc81287f7cf15d28b1ef");
        let mut address = [0u8; 20];

        let result =
            unsafe { wallet_bundler_address_from_secret(secret.as_ptr(), address.as_mut_ptr()) };

        assert_eq!(result, WalletResult::Ok as i32);
        assert_eq!(address, hex!("be3f88b31963bedfdf8661eedf605639beaa0c4f"));
    }

    #[test]
    fn ffi_generate_bundler_secret_rejects_null_outputs() {
        let mut secret = [0u8; 32];
        let mut address = [0u8; 20];

        let missing_secret =
            unsafe { wallet_generate_bundler_secret(std::ptr::null_mut(), address.as_mut_ptr()) };
        let missing_address =
            unsafe { wallet_generate_bundler_secret(secret.as_mut_ptr(), std::ptr::null_mut()) };

        assert_eq!(missing_secret, WalletResult::InvalidInput as i32);
        assert_eq!(missing_address, WalletResult::InvalidInput as i32);
    }

    #[test]
    fn ffi_bundler_address_from_secret_rejects_null_outputs() {
        let secret = [1u8; 32];
        let mut address = [0u8; 20];

        let missing_secret =
            unsafe { wallet_bundler_address_from_secret(std::ptr::null(), address.as_mut_ptr()) };
        let missing_address =
            unsafe { wallet_bundler_address_from_secret(secret.as_ptr(), std::ptr::null_mut()) };

        assert_eq!(missing_secret, WalletResult::InvalidInput as i32);
        assert_eq!(missing_address, WalletResult::InvalidInput as i32);
    }

    #[test]
    fn ffi_generate_bundler_secret_recreates_short_lived_secret_key_from_bytes() {
        let source = include_str!("lib.rs");
        let function_start = source
            .find("pub unsafe extern \"C\" fn wallet_generate_bundler_secret")
            .expect("bundler secret function exists");
        let following_function = source[function_start + 1..]
            .find("pub unsafe extern \"C\" fn ")
            .expect("following FFI function exists");
        let function = &source[function_start..function_start + 1 + following_function];

        assert!(function.contains("SecretKey::from_byte_array"));
        assert!(!function.contains("SecretKey::new"));
    }

    #[test]
    fn ffi_compute_userop_hash_matches_direct() {
        let sender = hex!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2");
        let nonce = hex!("0000baac0ddb0000000000000000000000000000000000000000000000000001");
        let init_code: &[u8] = &[];
        let call_data = include_bytes!("../testdata/neKodex_calldata.bin");
        let account_gas_limits =
            hex!("00000000000000000000000000098a2100000000000000000000000000023dad");
        let pre_verification_gas = U256::from(70952u64).to_be_bytes::<32>();
        let gas_fees = hex!("00000000000000000000000001a39de00000000000000000000000000c028d49");
        let paymaster_and_data = hex!(
            "777777777777aec03fd955926dbf81597e66834c"
            "0000000000000000000000000000b578"
            "000000000000000000000000000000010100006982dcf2"
            "000000000000d8d11407392c3df4c4228006b5b955cc1d9fbb63"
            "b7611ee6edb4fb1153b988ca276ccc833f9ce4dde4d6b4a9283b"
            "8745db82a3b1a8fa2555bd17eee3fb9c4f1c1c"
        );
        let entry_point_bytes = wallet_signature::ENTRY_POINT_V07;

        let mut out_hash = [0u8; 32];

        let result = unsafe {
            wallet_compute_userop_hash(
                sender.as_ptr(),
                nonce.as_ptr(),
                init_code.as_ptr(),
                0,
                call_data.as_ptr(),
                call_data.len() as u32,
                account_gas_limits.as_ptr(),
                pre_verification_gas.as_ptr(),
                gas_fees.as_ptr(),
                paymaster_and_data.as_ptr(),
                paymaster_and_data.len() as u32,
                entry_point_bytes.as_slice().as_ptr(),
                1,
                out_hash.as_mut_ptr(),
            )
        };

        assert_eq!(result, WalletResult::Ok as i32);
        assert_eq!(
            out_hash,
            hex!("6d0a394861c05e39fb043ecfa6bca7ef8976ee6c8300547977c39b8a39b39dda")
        );
    }

    #[test]
    fn ffi_compute_signing_preimage_is_69_bytes() {
        let userop_hash = hex!("0d3bcda18875420351920008f9219e06945a31beb0b2699af4cef7da6fdf1c4d");
        let mut out = [0u8; 69];

        let result =
            unsafe { wallet_compute_signing_preimage(userop_hash.as_ptr(), out.as_mut_ptr()) };

        assert_eq!(result, WalletResult::Ok as i32);
        assert_eq!(out[32], 0x05); // flags byte
        assert_eq!(&out[33..37], &[0, 0, 0, 0]); // signCount

        // sha256(preimage) must equal what compute_signing_message returns
        let signing_msg: [u8; 32] = Sha256::digest(out).into();
        let (expected_msg, _) = wallet_signature::compute_signing_message(&userop_hash);
        assert_eq!(signing_msg, expected_msg);
    }

    #[test]
    fn ffi_normalise_low_s_flips_high_s() {
        let low_s = hex!("63bde20ed18273f1d59ae4411fa7abb4c929a4a7476e1934a04c4d4b05bad0e2");
        use ::p256::elliptic_curve::ops::Reduce;
        let s_scalar = ::p256::Scalar::reduce_bytes(&low_s.into());
        let high_s_scalar = -s_scalar;
        let mut s: [u8; 32] = high_s_scalar.to_bytes().into();

        let result = unsafe { wallet_normalise_low_s(s.as_mut_ptr()) };
        assert_eq!(result, WalletResult::Ok as i32);
        assert_eq!(s, low_s);
    }

    #[test]
    fn ffi_normalise_low_s_keeps_low_s() {
        let mut s = hex!("63bde20ed18273f1d59ae4411fa7abb4c929a4a7476e1934a04c4d4b05bad0e2");
        let original = s;
        let result = unsafe { wallet_normalise_low_s(s.as_mut_ptr()) };
        assert_eq!(result, WalletResult::Ok as i32);
        assert_eq!(s, original);
    }

    #[test]
    fn ffi_predicts_kernel_account_address() {
        let factory = hex!("2577507b78c2008ff367261cb6285d44ba5ef2e9");
        let implementation = hex!("d6cedde84be40893d153be9d467cd6ad37875b28");
        let validator = hex!("7ab16ff354acb328452f1d445b3ddee9a91e9e69");
        let pub_key_x = hex!("0000000000000000000000000000000000000000000000000000000000000001");
        let pub_key_y = hex!("0000000000000000000000000000000000000000000000000000000000000002");
        let zero = [0u8; 32];
        let mut out_address = [0u8; 20];

        let result = unsafe {
            wallet_predict_kernel_account_address(
                factory.as_ptr(),
                implementation.as_ptr(),
                validator.as_ptr(),
                pub_key_x.as_ptr(),
                pub_key_y.as_ptr(),
                zero.as_ptr(),
                zero.as_ptr(),
                out_address.as_mut_ptr(),
            )
        };

        assert_eq!(result, WalletResult::Ok as i32);
        assert_ne!(out_address, [0u8; 20]);
    }

    #[test]
    fn ffi_abi_encode_and_free() {
        let userop_hash = hex!("0d3bcda18875420351920008f9219e06945a31beb0b2699af4cef7da6fdf1c4d");
        let r = hex!("4cd35715c349d979b31d029519adaeefda042e1e2f6c158b802c0be89fc8aa07");
        let s = hex!("63bde20ed18273f1d59ae4411fa7abb4c929a4a7476e1934a04c4d4b05bad0e2");

        let mut out_ptr: *const u8 = std::ptr::null();
        let mut out_len: u32 = 0;

        let result = unsafe {
            wallet_abi_encode_signature(
                userop_hash.as_ptr(),
                r.as_ptr(),
                s.as_ptr(),
                true,
                &mut out_ptr,
                &mut out_len,
            )
        };

        assert_eq!(result, WalletResult::Ok as i32);
        assert!(!out_ptr.is_null());
        assert!(out_len > 0);
        assert_eq!(out_len % 32, 0);

        let encoded = unsafe { std::slice::from_raw_parts(out_ptr, out_len as usize) };
        assert!(!encoded.is_empty());

        unsafe { wallet_free_buffer(out_ptr as *mut u8, out_len) };
    }

    #[test]
    fn ffi_dummy_signature_matches_signature_crate_helper() {
        for use_precompiled in [false, true] {
            let mut out_ptr: *const u8 = std::ptr::null();
            let mut out_len: u32 = 0;

            let result = unsafe {
                wallet_abi_encode_dummy_signature(use_precompiled, &mut out_ptr, &mut out_len)
            };

            assert_eq!(result, WalletResult::Ok as i32);
            assert!(!out_ptr.is_null());
            let encoded = unsafe { std::slice::from_raw_parts(out_ptr, out_len as usize) };
            assert_eq!(
                encoded,
                wallet_signature::abi_encode_dummy_signature(use_precompiled)
            );

            unsafe { wallet_free_buffer(out_ptr as *mut u8, out_len) };
        }
    }

    #[test]
    fn ffi_session_build_permission_matches_plan1_fixture() {
        let fixture = permission_fixture();
        let meta = &fixture["meta"];
        let config = json!({
            "account": meta["ACCOUNT"],
            "chainId": meta["CHAIN_ID"],
            "sessionKey": meta["SESSION_KEY"],
            "executeSelector": "0xe9ae5c53",
            "validationNonce": fixture["enableTypedData"]["message"]["nonce"],
            "gasBudgetWei": "5000000000000000",
            "rateLimitIntervalSec": 86400,
            "rateLimitCount": 20,
            "rateLimitStartAt": 0,
            "validAfter": 0,
            "validUntil": 1900000000,
            "allowedCalls": [
                {
                    "target": meta["USDC"],
                    "selector": "0xa9059cbb",
                    "valueLimitWei": "0",
                    "rules": []
                },
                {
                    "target": meta["USDC"],
                    "selector": "0x095ea7b3",
                    "valueLimitWei": "0",
                    "rules": []
                }
            ]
        });
        let config_bytes = serde_json::to_vec(&config).expect("config serializes");
        let mut permission_id = [0u8; 4];
        let mut enable_digest = [0u8; 32];
        let mut nonce_key_default = [0u8; 32];
        let mut nonce_key_enable = [0u8; 32];
        let mut enable_data_ptr: *const u8 = std::ptr::null();
        let mut enable_data_len: u32 = 0;
        let mut selector_data_ptr: *const u8 = std::ptr::null();
        let mut selector_data_len: u32 = 0;

        let result = unsafe {
            wallet_session_build_permission(
                config_bytes.as_ptr(),
                config_bytes.len() as u32,
                permission_id.as_mut_ptr(),
                &mut enable_data_ptr,
                &mut enable_data_len,
                &mut selector_data_ptr,
                &mut selector_data_len,
                enable_digest.as_mut_ptr(),
                nonce_key_default.as_mut_ptr(),
                nonce_key_enable.as_mut_ptr(),
            )
        };

        assert_eq!(result, WalletResult::Ok as i32);
        assert_eq!(
            permission_id.as_slice(),
            decode_hex_bytes(fixture["permissionId"].as_str().unwrap())
        );
        let enable_data =
            unsafe { std::slice::from_raw_parts(enable_data_ptr, enable_data_len as usize) };
        let selector_data =
            unsafe { std::slice::from_raw_parts(selector_data_ptr, selector_data_len as usize) };
        assert_eq!(
            enable_data,
            decode_hex_bytes(fixture["enableData"].as_str().unwrap())
        );
        assert_eq!(
            selector_data,
            decode_hex_bytes(
                fixture["enableTypedData"]["message"]["selectorData"]
                    .as_str()
                    .unwrap()
            )
        );
        assert_eq!(
            enable_digest.as_slice(),
            decode_hex_bytes(fixture["enableDigest"].as_str().unwrap())
        );
        assert_eq!(&nonce_key_default[..8], &[0u8; 8]);
        assert_eq!(&nonce_key_default[8], &0x00);
        assert_eq!(
            &nonce_key_default[9],
            &wallet_kernel::VALIDATION_TYPE_PERMISSION
        );
        assert_eq!(&nonce_key_default[10..14], permission_id.as_slice());
        assert_eq!(&nonce_key_enable[..8], &[0u8; 8]);
        assert_eq!(&nonce_key_enable[8], &wallet_kernel::VALIDATION_MODE_ENABLE);
        assert_eq!(
            &nonce_key_enable[9],
            &wallet_kernel::VALIDATION_TYPE_PERMISSION
        );
        assert_eq!(&nonce_key_enable[10..14], permission_id.as_slice());

        unsafe {
            wallet_free_buffer(enable_data_ptr as *mut u8, enable_data_len);
            wallet_free_buffer(selector_data_ptr as *mut u8, selector_data_len);
        }
    }

    #[test]
    fn ffi_session_sign_and_wrap_matches_installed_fixture() {
        let fixture = permission_fixture();
        let secret = decode_hex_bytes(fixture["meta"]["SESSION_PK"].as_str().unwrap());
        let userop_hash = decode_hex_bytes(fixture["dummyUserOpHash"].as_str().unwrap());
        let mut out_ptr: *const u8 = std::ptr::null();
        let mut out_len: u32 = 0;

        let result = unsafe {
            wallet_session_sign_and_wrap(
                secret.as_ptr(),
                userop_hash.as_ptr(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                &mut out_ptr,
                &mut out_len,
            )
        };

        assert_eq!(result, WalletResult::Ok as i32);
        let signature = unsafe { std::slice::from_raw_parts(out_ptr, out_len as usize) };
        assert_eq!(
            signature,
            decode_hex_bytes(fixture["installedUserOpSig"].as_str().unwrap())
        );

        unsafe { wallet_free_buffer(out_ptr as *mut u8, out_len) };
    }

    #[test]
    fn ffi_session_sign_and_wrap_matches_enable_fixture() {
        let fixture = permission_fixture();
        let secret = decode_hex_bytes(fixture["meta"]["SESSION_PK"].as_str().unwrap());
        let userop_hash = decode_hex_bytes(fixture["dummyUserOpHash"].as_str().unwrap());
        let enable_signature = decode_hex_bytes(fixture["enableUserOpSig"].as_str().unwrap());
        let root_enable_sig = decode_abi_bytes_tail_element(&enable_signature[20..], 3);
        let enable_data = decode_hex_bytes(fixture["enableData"].as_str().unwrap());
        let selector_data = decode_hex_bytes(
            fixture["enableTypedData"]["message"]["selectorData"]
                .as_str()
                .unwrap(),
        );
        let mut out_ptr: *const u8 = std::ptr::null();
        let mut out_len: u32 = 0;

        let result = unsafe {
            wallet_session_sign_and_wrap(
                secret.as_ptr(),
                userop_hash.as_ptr(),
                1,
                enable_data.as_ptr(),
                enable_data.len() as u32,
                selector_data.as_ptr(),
                selector_data.len() as u32,
                root_enable_sig.as_ptr(),
                root_enable_sig.len() as u32,
                &mut out_ptr,
                &mut out_len,
            )
        };

        assert_eq!(result, WalletResult::Ok as i32);
        let signature = unsafe { std::slice::from_raw_parts(out_ptr, out_len as usize) };
        assert_eq!(signature, enable_signature);

        unsafe { wallet_free_buffer(out_ptr as *mut u8, out_len) };
    }

    #[test]
    fn ffi_session_dummy_signature_returns_installed_shape() {
        let mut out_ptr: *const u8 = std::ptr::null();
        let mut out_len: u32 = 0;

        let result = unsafe {
            wallet_session_dummy_signature(
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                false,
                &mut out_ptr,
                &mut out_len,
            )
        };

        assert_eq!(result, WalletResult::Ok as i32);
        let signature = unsafe { std::slice::from_raw_parts(out_ptr, out_len as usize) };
        assert_eq!(signature.len(), 66);
        assert_eq!(signature[0], 0xff);
        assert!(signature[1..].iter().all(|byte| *byte == 0));

        unsafe { wallet_free_buffer(out_ptr as *mut u8, out_len) };
    }

    #[test]
    fn ffi_session_dummy_signature_returns_enable_shape() {
        let fixture = permission_fixture();
        let enable_data = decode_hex_bytes(fixture["enableData"].as_str().unwrap());
        let selector_data = decode_hex_bytes(
            fixture["enableTypedData"]["message"]["selectorData"]
                .as_str()
                .unwrap(),
        );
        let mut out_ptr: *const u8 = std::ptr::null();
        let mut out_len: u32 = 0;

        let result = unsafe {
            wallet_session_dummy_signature(
                1,
                enable_data.as_ptr(),
                enable_data.len() as u32,
                selector_data.as_ptr(),
                selector_data.len() as u32,
                false,
                &mut out_ptr,
                &mut out_len,
            )
        };

        assert_eq!(result, WalletResult::Ok as i32);
        let signature = unsafe { std::slice::from_raw_parts(out_ptr, out_len as usize) };
        let validator_data = decode_abi_bytes_tail_element(&signature[20..], 0);
        let hook_data = decode_abi_bytes_tail_element(&signature[20..], 1);
        let decoded_selector_data = decode_abi_bytes_tail_element(&signature[20..], 2);
        let root_sig = decode_abi_bytes_tail_element(&signature[20..], 3);
        let userop_sig = decode_abi_bytes_tail_element(&signature[20..], 4);

        assert_eq!(validator_data, enable_data);
        assert!(hook_data.is_empty());
        assert_eq!(decoded_selector_data, selector_data);
        assert!(!root_sig.is_empty());
        assert_eq!(userop_sig.len(), 66);
        assert_eq!(userop_sig[0], 0xff);

        unsafe { wallet_free_buffer(out_ptr as *mut u8, out_len) };
    }

    #[test]
    fn ffi_session_invalidate_nonce_calldata_matches_kernel_selector() {
        let mut out_ptr: *const u8 = std::ptr::null();
        let mut out_len: u32 = 0;

        let result =
            unsafe { wallet_session_invalidate_nonce_calldata(7, &mut out_ptr, &mut out_len) };

        assert_eq!(result, WalletResult::Ok as i32);
        let calldata = unsafe { std::slice::from_raw_parts(out_ptr, out_len as usize) };
        assert_eq!(
            calldata,
            hex!("1f1b92e30000000000000000000000000000000000000000000000000000000000000007")
        );

        unsafe { wallet_free_buffer(out_ptr as *mut u8, out_len) };
    }

    #[test]
    fn ffi_session_empty_permission_deinit_data_matches_enable_entries() {
        let fixture = permission_fixture();
        let enable_data = decode_hex_bytes(fixture["enableData"].as_str().unwrap());
        let mut out_ptr: *const u8 = std::ptr::null();
        let mut out_len: u32 = 0;

        let result = unsafe {
            wallet_session_empty_permission_deinit_data(
                enable_data.as_ptr(),
                enable_data.len() as u32,
                &mut out_ptr,
                &mut out_len,
            )
        };

        assert_eq!(result, WalletResult::Ok as i32);
        let deinit_data = unsafe { std::slice::from_raw_parts(out_ptr, out_len as usize) };
        assert_eq!(
            deinit_data,
            hex!(
                "0000000000000000000000000000000000000000000000000000000000000020"
                "0000000000000000000000000000000000000000000000000000000000000005"
                "00000000000000000000000000000000000000000000000000000000000000a0"
                "00000000000000000000000000000000000000000000000000000000000000c0"
                "00000000000000000000000000000000000000000000000000000000000000e0"
                "0000000000000000000000000000000000000000000000000000000000000100"
                "0000000000000000000000000000000000000000000000000000000000000120"
                "0000000000000000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000000000000000000"
            )
        );

        unsafe { wallet_free_buffer(out_ptr as *mut u8, out_len) };
    }

    #[test]
    fn ffi_session_uninstall_permission_calldata_matches_kernel_selector() {
        let permission_id = [0xaa, 0xbb, 0xcc, 0xdd];
        let deinit_data = [0x12, 0x34];
        let mut out_ptr: *const u8 = std::ptr::null();
        let mut out_len: u32 = 0;

        let result = unsafe {
            wallet_session_uninstall_permission_calldata(
                permission_id.as_ptr(),
                deinit_data.as_ptr(),
                deinit_data.len() as u32,
                &mut out_ptr,
                &mut out_len,
            )
        };

        assert_eq!(result, WalletResult::Ok as i32);
        let calldata = unsafe { std::slice::from_raw_parts(out_ptr, out_len as usize) };
        assert_eq!(
            calldata,
            hex!(
                "e6f3d50a"
                "02aabbccdd000000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000000000000000060"
                "00000000000000000000000000000000000000000000000000000000000000a0"
                "0000000000000000000000000000000000000000000000000000000000000002"
                "1234000000000000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000000000000000000"
            )
        );

        unsafe { wallet_free_buffer(out_ptr as *mut u8, out_len) };
    }
}
