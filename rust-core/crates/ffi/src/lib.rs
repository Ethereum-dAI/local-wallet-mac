use std::panic::catch_unwind;
use wallet_signature::{
    compute_userop_hash, build_signature, abi_encode_webauthn_signature,
    normalise_low_s, PackedUserOperation,
    webauthn::{build_authenticator_data, build_client_data_json},
};
use wallet_kernel::{encode_initialize_call, predict_kernel_account_address};
use alloy_primitives::{Address, B256, Bytes, FixedBytes, U256};
use sha2::{Sha256, Digest};

/// Result codes for FFI functions.
#[repr(i32)]
pub enum WalletResult {
    Ok = 0,
    InvalidInput = -1,
    InternalError = -2,
}

/// # Safety
/// All pointer parameters must be valid and point to buffers of the documented sizes.
#[no_mangle]
pub unsafe extern "C" fn wallet_compute_userop_hash(
    sender: *const u8,                      // 20 bytes
    nonce: *const u8,                       // 32 bytes big-endian
    init_code: *const u8,                   init_code_len: u32,
    call_data: *const u8,                   call_data_len: u32,
    account_gas_limits: *const u8,          // 32 bytes
    pre_verification_gas: *const u8,        // 32 bytes big-endian
    gas_fees: *const u8,                    // 32 bytes
    paymaster_and_data: *const u8,          paymaster_and_data_len: u32,
    entry_point: *const u8,                 // 20 bytes
    chain_id: u64,
    out_hash: *mut u8,                      // 32 bytes, caller-allocated
) -> i32 {
    let result = catch_unwind(|| {
        if sender.is_null() || nonce.is_null() || account_gas_limits.is_null()
            || pre_verification_gas.is_null() || gas_fees.is_null()
            || entry_point.is_null() || out_hash.is_null()
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

        let userop = PackedUserOperation {
            sender: Address::from_slice(sender_slice),
            nonce: U256::from_be_bytes::<32>(nonce_slice.try_into().unwrap()),
            init_code: Bytes::from(init_code_slice.to_vec()),
            call_data: Bytes::from(call_data_slice.to_vec()),
            account_gas_limits: FixedBytes::from_slice(agl_slice),
            pre_verification_gas: U256::from_be_bytes::<32>(pvg_slice.try_into().unwrap()),
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
pub unsafe extern "C" fn wallet_normalise_low_s(
    s_inout: *mut u8,
) -> i32 {
    let result = catch_unwind(|| {
        if s_inout.is_null() {
            return WalletResult::InvalidInput as i32;
        }
        let s_slice = std::slice::from_raw_parts(s_inout, 32);
        let s: [u8; 32] = s_slice.try_into().unwrap();
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
        if userop_hash.is_null() || r.is_null() || s.is_null()
            || out_ptr.is_null() || out_len.is_null()
        {
            return WalletResult::InvalidInput as i32;
        }
        let hash: &[u8; 32] = &*(userop_hash as *const [u8; 32]);
        let r_bytes: [u8; 32] = std::slice::from_raw_parts(r, 32).try_into().unwrap();
        let s_bytes: [u8; 32] = std::slice::from_raw_parts(s, 32).try_into().unwrap();

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

        let sig = build_signature(&[0u8; 32], [0u8; 32], [0u8; 32], use_precompiled);
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
/// All pointer parameters must be valid and point to fixed-size buffers.
#[no_mangle]
pub unsafe extern "C" fn wallet_predict_kernel_account_address(
    factory: *const u8,                // 20 bytes
    implementation: *const u8,         // 20 bytes
    webauthn_validator: *const u8,     // 20 bytes
    pub_key_x: *const u8,              // 32 bytes big-endian
    pub_key_y: *const u8,              // 32 bytes big-endian
    authenticator_id_hash: *const u8,  // 32 bytes
    salt: *const u8,                   // 32 bytes
    out_address: *mut u8,              // 20 bytes caller-allocated
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

        let predicted = predict_kernel_account_address(
            Address::from_slice(std::slice::from_raw_parts(factory, 20)),
            Address::from_slice(std::slice::from_raw_parts(implementation, 20)),
            Address::from_slice(std::slice::from_raw_parts(webauthn_validator, 20)),
            U256::from_be_bytes::<32>(std::slice::from_raw_parts(pub_key_x, 32).try_into().unwrap()),
            U256::from_be_bytes::<32>(std::slice::from_raw_parts(pub_key_y, 32).try_into().unwrap()),
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
    webauthn_validator: *const u8,     // 20 bytes
    pub_key_x: *const u8,              // 32 bytes big-endian
    pub_key_y: *const u8,              // 32 bytes big-endian
    authenticator_id_hash: *const u8,  // 32 bytes
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

        let encoded = encode_initialize_call(
            Address::from_slice(std::slice::from_raw_parts(webauthn_validator, 20)),
            U256::from_be_bytes::<32>(std::slice::from_raw_parts(pub_key_x, 32).try_into().unwrap()),
            U256::from_be_bytes::<32>(std::slice::from_raw_parts(pub_key_y, 32).try_into().unwrap()),
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
/// `ptr` must have been returned by `wallet_abi_encode_signature`. Call exactly once.
#[no_mangle]
pub unsafe extern "C" fn wallet_free_buffer(ptr: *mut u8, len: u32) {
    if !ptr.is_null() && len > 0 {
        let _ = Box::from_raw(std::slice::from_raw_parts_mut(ptr, len as usize));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hex_literal::hex;

    #[test]
    fn ffi_compute_userop_hash_matches_direct() {
        let sender = hex!("d73c7780b1c1da1586a8332d5499f36b7cbb33c2");
        let nonce = hex!("0000baac0ddb0000000000000000000000000000000000000000000000000001");
        let init_code: &[u8] = &[];
        let call_data = include_bytes!("../../signature/testdata/neKodex_calldata.bin");
        let account_gas_limits = hex!("00000000000000000000000000098a2100000000000000000000000000023dad");
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
        let entry_point_bytes = hex!("0000000071727De22E5E9d8BAf0edAc6f37da032");

        let mut out_hash = [0u8; 32];

        let result = unsafe {
            wallet_compute_userop_hash(
                sender.as_ptr(), nonce.as_ptr(),
                init_code.as_ptr(), 0,
                call_data.as_ptr(), call_data.len() as u32,
                account_gas_limits.as_ptr(),
                pre_verification_gas.as_ptr(),
                gas_fees.as_ptr(),
                paymaster_and_data.as_ptr(), paymaster_and_data.len() as u32,
                entry_point_bytes.as_ptr(),
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

        let result = unsafe {
            wallet_compute_signing_preimage(userop_hash.as_ptr(), out.as_mut_ptr())
        };

        assert_eq!(result, WalletResult::Ok as i32);
        assert_eq!(out[32], 0x05); // flags byte
        assert_eq!(&out[33..37], &[0, 0, 0, 0]); // signCount

        // sha256(preimage) must equal what compute_signing_message returns
        let signing_msg: [u8; 32] = Sha256::digest(&out).into();
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
                userop_hash.as_ptr(), r.as_ptr(), s.as_ptr(),
                true, &mut out_ptr, &mut out_len,
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
}
