use std::sync::Arc;

use alloy_primitives::{keccak256, Address, Bytes, U256};
use secp256k1::{ecdsa::RecoveryId, Message, PublicKey, Secp256k1, SecretKey};
use thiserror::Error;
use wallet_bundler::Eip1559Signature;

pub(crate) const DEV_KEYCHAIN_SERVICE: &str = "com.localwallet.wallet-node.bundler-eoa.dev";
pub(crate) const KEY_REF_PREFIX: &str = "bundler-eoa:";

#[derive(Debug, Error)]
pub(crate) enum BundlerKeyError {
    #[error("bundler keychain unavailable: {0}")]
    KeychainUnavailable(String),

    #[error("bundler key not found: {0}")]
    KeyNotFound(String),

    #[error("invalid bundler key material: {0}")]
    InvalidKey(String),

    #[error("bundler signing failed: {0}")]
    Signing(String),
}

pub(crate) trait BundlerKeyStore: Send + Sync {
    fn create_key(&self, key_ref: &str) -> Result<Address, BundlerKeyError>;
    #[cfg(test)]
    fn address_for_key(&self, key_ref: &str) -> Result<Address, BundlerKeyError>;
    fn sign_eip1559_payload(
        &self,
        key_ref: &str,
        payload: &Bytes,
    ) -> Result<Eip1559Signature, BundlerKeyError>;
}

pub(crate) fn default_bundler_key_store() -> Arc<dyn BundlerKeyStore> {
    #[cfg(target_os = "macos")]
    {
        Arc::new(MacosDevKeychainBundlerKeyStore::new(
            DEV_KEYCHAIN_SERVICE.to_owned(),
        ))
    }

    #[cfg(not(target_os = "macos"))]
    {
        Arc::new(UnsupportedBundlerKeyStore)
    }
}

pub(crate) fn next_key_ref<'a>(
    existing_refs: impl Iterator<Item = &'a str>,
) -> Result<String, BundlerKeyError> {
    let mut max = 0_u64;
    for key_ref in existing_refs {
        let Some(value) = key_ref.strip_prefix(KEY_REF_PREFIX) else {
            continue;
        };
        let parsed = value.parse::<u64>().map_err(|_| {
            BundlerKeyError::InvalidKey(format!("invalid bundler key ref: {key_ref}"))
        })?;
        max = max.max(parsed);
    }
    Ok(format!("{KEY_REF_PREFIX}{}", max + 1))
}

fn secret_address(secret: &SecretKey) -> Address {
    let secp = Secp256k1::signing_only();
    let public = PublicKey::from_secret_key(&secp, secret);
    let uncompressed = public.serialize_uncompressed();
    let hash = keccak256(&uncompressed[1..]);
    Address::from_slice(&hash[12..])
}

fn sign_payload(secret: &SecretKey, payload: &Bytes) -> Result<Eip1559Signature, BundlerKeyError> {
    let secp = Secp256k1::signing_only();
    let digest = keccak256(payload);
    let msg = Message::from_digest(*digest);
    let sig = secp.sign_ecdsa_recoverable(&msg, secret);
    let (recovery_id, compact) = sig.serialize_compact();
    let y_parity = match recovery_id {
        RecoveryId::Zero | RecoveryId::Two => false,
        RecoveryId::One | RecoveryId::Three => true,
    };
    let r = U256::from_be_bytes::<32>(
        compact[..32]
            .try_into()
            .map_err(|_| BundlerKeyError::Signing("invalid r length".to_string()))?,
    );
    let s = U256::from_be_bytes::<32>(
        compact[32..]
            .try_into()
            .map_err(|_| BundlerKeyError::Signing("invalid s length".to_string()))?,
    );

    Ok(Eip1559Signature { y_parity, r, s })
}

#[cfg(not(target_os = "macos"))]
struct UnsupportedBundlerKeyStore;

#[cfg(not(target_os = "macos"))]
impl BundlerKeyStore for UnsupportedBundlerKeyStore {
    fn create_key(&self, _key_ref: &str) -> Result<Address, BundlerKeyError> {
        Err(BundlerKeyError::KeychainUnavailable(
            "development Keychain fallback is macOS-only".to_string(),
        ))
    }

    #[cfg(test)]
    fn address_for_key(&self, key_ref: &str) -> Result<Address, BundlerKeyError> {
        Err(BundlerKeyError::KeyNotFound(key_ref.to_string()))
    }

    fn sign_eip1559_payload(
        &self,
        key_ref: &str,
        _payload: &Bytes,
    ) -> Result<Eip1559Signature, BundlerKeyError> {
        Err(BundlerKeyError::KeyNotFound(key_ref.to_string()))
    }
}

#[cfg(target_os = "macos")]
struct MacosDevKeychainBundlerKeyStore {
    service: String,
}

#[cfg(target_os = "macos")]
impl MacosDevKeychainBundlerKeyStore {
    fn new(service: String) -> Self {
        Self { service }
    }

    fn read_secret(&self, key_ref: &str) -> Result<SecretKey, BundlerKeyError> {
        let bytes = keychain::read_generic_password(&self.service, key_ref)?;
        SecretKey::from_slice(&bytes)
            .map_err(|err| BundlerKeyError::InvalidKey(format!("{key_ref}: {err}")))
    }
}

#[cfg(target_os = "macos")]
impl BundlerKeyStore for MacosDevKeychainBundlerKeyStore {
    fn create_key(&self, key_ref: &str) -> Result<Address, BundlerKeyError> {
        if let Ok(existing) = self.read_secret(key_ref) {
            return Ok(secret_address(&existing));
        }

        let mut rng = secp256k1::rand::thread_rng();
        let secret = SecretKey::new(&mut rng);
        keychain::add_generic_password(&self.service, key_ref, &secret.secret_bytes())?;
        Ok(secret_address(&secret))
    }

    #[cfg(test)]
    fn address_for_key(&self, key_ref: &str) -> Result<Address, BundlerKeyError> {
        self.read_secret(key_ref)
            .map(|secret| secret_address(&secret))
    }

    fn sign_eip1559_payload(
        &self,
        key_ref: &str,
        payload: &Bytes,
    ) -> Result<Eip1559Signature, BundlerKeyError> {
        sign_payload(&self.read_secret(key_ref)?, payload)
    }
}

#[cfg(target_os = "macos")]
mod keychain {
    use std::ffi::{c_char, c_void, CString, NulError};
    use std::ptr;
    use std::slice;

    use super::BundlerKeyError;

    const ERR_SEC_SUCCESS: OSStatus = 0;
    const ERR_SEC_DUPLICATE_ITEM: OSStatus = -25299;
    const ERR_SEC_ITEM_NOT_FOUND: OSStatus = -25300;
    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;

    type Boolean = u8;
    type CFHashCode = usize;
    type CFIndex = isize;
    type CFTypeID = usize;
    type OSStatus = i32;
    type CFAllocatorRef = *const c_void;
    type CFTypeRef = *const c_void;

    #[repr(C)]
    struct __CFBoolean {
        _private: [u8; 0],
    }
    type CFBooleanRef = *const __CFBoolean;

    #[repr(C)]
    struct __CFData {
        _private: [u8; 0],
    }
    type CFDataRef = *const __CFData;

    #[repr(C)]
    struct __CFDictionary {
        _private: [u8; 0],
    }
    type CFDictionaryRef = *const __CFDictionary;

    #[repr(C)]
    struct __CFString {
        _private: [u8; 0],
    }
    type CFStringRef = *const __CFString;

    #[repr(C)]
    struct CFDictionaryKeyCallBacks {
        version: CFIndex,
        retain: Option<unsafe extern "C" fn(CFAllocatorRef, *const c_void) -> *const c_void>,
        release: Option<unsafe extern "C" fn(CFAllocatorRef, *const c_void)>,
        copy_description: Option<unsafe extern "C" fn(*const c_void) -> CFStringRef>,
        equal: Option<unsafe extern "C" fn(*const c_void, *const c_void) -> Boolean>,
        hash: Option<unsafe extern "C" fn(*const c_void) -> CFHashCode>,
    }

    #[repr(C)]
    struct CFDictionaryValueCallBacks {
        version: CFIndex,
        retain: Option<unsafe extern "C" fn(CFAllocatorRef, *const c_void) -> *const c_void>,
        release: Option<unsafe extern "C" fn(CFAllocatorRef, *const c_void)>,
        copy_description: Option<unsafe extern "C" fn(*const c_void) -> CFStringRef>,
        equal: Option<unsafe extern "C" fn(*const c_void, *const c_void) -> Boolean>,
    }

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        static kCFBooleanTrue: CFBooleanRef;
        static kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
        static kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;

        fn CFDataCreate(allocator: CFAllocatorRef, bytes: *const u8, length: CFIndex) -> CFDataRef;
        fn CFDataGetBytePtr(data: CFDataRef) -> *const u8;
        fn CFDataGetLength(data: CFDataRef) -> CFIndex;
        fn CFDataGetTypeID() -> CFTypeID;
        fn CFDictionaryCreate(
            allocator: CFAllocatorRef,
            keys: *const *const c_void,
            values: *const *const c_void,
            num_values: CFIndex,
            key_callbacks: *const CFDictionaryKeyCallBacks,
            value_callbacks: *const CFDictionaryValueCallBacks,
        ) -> CFDictionaryRef;
        fn CFGetTypeID(cf: CFTypeRef) -> CFTypeID;
        fn CFRelease(cf: CFTypeRef);
        fn CFStringCreateWithCString(
            allocator: CFAllocatorRef,
            c_str: *const c_char,
            encoding: u32,
        ) -> CFStringRef;
    }

    #[link(name = "Security", kind = "framework")]
    unsafe extern "C" {
        static kSecAttrAccount: CFStringRef;
        static kSecAttrAccessible: CFStringRef;
        static kSecAttrAccessibleWhenUnlockedThisDeviceOnly: CFStringRef;
        static kSecAttrService: CFStringRef;
        static kSecClass: CFStringRef;
        static kSecClassGenericPassword: CFStringRef;
        static kSecMatchLimit: CFStringRef;
        static kSecMatchLimitOne: CFStringRef;
        static kSecReturnData: CFStringRef;
        static kSecValueData: CFStringRef;

        fn SecItemAdd(attributes: CFDictionaryRef, result: *mut CFTypeRef) -> OSStatus;
        fn SecItemCopyMatching(query: CFDictionaryRef, result: *mut CFTypeRef) -> OSStatus;
    }

    struct OwnedCf(CFTypeRef);

    impl OwnedCf {
        fn new(ptr: CFTypeRef, context: &'static str) -> Result<Self, BundlerKeyError> {
            if ptr.is_null() {
                Err(BundlerKeyError::KeychainUnavailable(context.to_string()))
            } else {
                Ok(Self(ptr))
            }
        }

        fn as_void(&self) -> *const c_void {
            self.0
        }

        fn as_dictionary(&self) -> CFDictionaryRef {
            self.0.cast()
        }

        fn as_data(&self) -> CFDataRef {
            self.0.cast()
        }
    }

    impl Drop for OwnedCf {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe {
                    CFRelease(self.0);
                }
            }
        }
    }

    pub(super) fn add_generic_password(
        service: &str,
        account: &str,
        secret: &[u8; 32],
    ) -> Result<(), BundlerKeyError> {
        let service = cf_string(service)?;
        let account = cf_string(account)?;
        let secret_data = cf_data(secret)?;
        let mut pairs = base_query_pairs(&service, &account);
        pairs.push(unsafe { (cf_void(kSecValueData), secret_data.as_void()) });
        let attributes = cf_dictionary(&pairs)?;
        let status = unsafe { SecItemAdd(attributes.as_dictionary(), ptr::null_mut()) };
        match status {
            ERR_SEC_SUCCESS | ERR_SEC_DUPLICATE_ITEM => Ok(()),
            other => Err(status_error("SecItemAdd", other)),
        }
    }

    pub(super) fn read_generic_password(
        service: &str,
        account: &str,
    ) -> Result<Vec<u8>, BundlerKeyError> {
        let service = cf_string(service)?;
        let account_cf = cf_string(account)?;
        let mut pairs = base_query_pairs(&service, &account_cf);
        pairs.push(unsafe { (cf_void(kSecReturnData), cf_void(kCFBooleanTrue)) });
        pairs.push(unsafe { (cf_void(kSecMatchLimit), cf_void(kSecMatchLimitOne)) });
        let query = cf_dictionary(&pairs)?;
        let mut result = ptr::null();
        let status = unsafe { SecItemCopyMatching(query.as_dictionary(), &mut result) };
        match status {
            ERR_SEC_SUCCESS => {}
            ERR_SEC_ITEM_NOT_FOUND => {
                return Err(BundlerKeyError::KeyNotFound(account.to_string()))
            }
            other => return Err(status_error("SecItemCopyMatching", other)),
        }

        let data = OwnedCf::new(result, "SecItemCopyMatching returned null data")?;
        let is_data = unsafe { CFGetTypeID(data.as_void()) == CFDataGetTypeID() };
        if !is_data {
            return Err(BundlerKeyError::KeychainUnavailable(
                "SecItemCopyMatching returned non-data item".to_string(),
            ));
        }
        let len = unsafe { CFDataGetLength(data.as_data()) };
        let ptr = unsafe { CFDataGetBytePtr(data.as_data()) };
        if len < 0 || ptr.is_null() {
            return Err(BundlerKeyError::KeychainUnavailable(
                "SecItemCopyMatching returned invalid data".to_string(),
            ));
        }
        Ok(unsafe { slice::from_raw_parts(ptr, len as usize) }.to_vec())
    }

    fn base_query_pairs(
        service: &OwnedCf,
        account: &OwnedCf,
    ) -> Vec<(*const c_void, *const c_void)> {
        vec![
            unsafe { (cf_void(kSecClass), cf_void(kSecClassGenericPassword)) },
            unsafe { (cf_void(kSecAttrService), service.as_void()) },
            unsafe { (cf_void(kSecAttrAccount), account.as_void()) },
            unsafe {
                (
                    cf_void(kSecAttrAccessible),
                    cf_void(kSecAttrAccessibleWhenUnlockedThisDeviceOnly),
                )
            },
        ]
    }

    fn cf_string(value: &str) -> Result<OwnedCf, BundlerKeyError> {
        let value = CString::new(value).map_err(nul_error)?;
        let cf = unsafe {
            CFStringCreateWithCString(ptr::null(), value.as_ptr(), K_CF_STRING_ENCODING_UTF8)
        };
        OwnedCf::new(cf.cast(), "CFStringCreateWithCString")
    }

    fn cf_data(value: &[u8]) -> Result<OwnedCf, BundlerKeyError> {
        let cf = unsafe { CFDataCreate(ptr::null(), value.as_ptr(), value.len() as CFIndex) };
        OwnedCf::new(cf.cast(), "CFDataCreate")
    }

    fn cf_dictionary(pairs: &[(*const c_void, *const c_void)]) -> Result<OwnedCf, BundlerKeyError> {
        let keys = pairs.iter().map(|(key, _)| *key).collect::<Vec<_>>();
        let values = pairs.iter().map(|(_, value)| *value).collect::<Vec<_>>();
        let cf = unsafe {
            CFDictionaryCreate(
                ptr::null(),
                keys.as_ptr(),
                values.as_ptr(),
                pairs.len() as CFIndex,
                &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks,
            )
        };
        OwnedCf::new(cf.cast(), "CFDictionaryCreate")
    }

    unsafe fn cf_void<T>(ptr: *const T) -> *const c_void {
        ptr.cast()
    }

    fn nul_error(err: NulError) -> BundlerKeyError {
        BundlerKeyError::InvalidKey(format!("interior NUL byte: {err}"))
    }

    fn status_error(context: &'static str, status: OSStatus) -> BundlerKeyError {
        BundlerKeyError::KeychainUnavailable(format!("{context} returned OSStatus {status}"))
    }
}

#[cfg(test)]
pub(crate) struct MemoryBundlerKeyStore {
    keys: std::sync::Mutex<std::collections::BTreeMap<String, SecretKey>>,
}

#[cfg(test)]
impl MemoryBundlerKeyStore {
    pub(crate) fn new() -> Self {
        Self {
            keys: std::sync::Mutex::new(std::collections::BTreeMap::new()),
        }
    }
}

#[cfg(test)]
impl BundlerKeyStore for MemoryBundlerKeyStore {
    fn create_key(&self, key_ref: &str) -> Result<Address, BundlerKeyError> {
        let mut keys = self
            .keys
            .lock()
            .map_err(|_| BundlerKeyError::KeychainUnavailable("lock poisoned".to_string()))?;
        if let Some(secret) = keys.get(key_ref) {
            return Ok(secret_address(secret));
        }
        let mut rng = secp256k1::rand::thread_rng();
        let secret = SecretKey::new(&mut rng);
        let address = secret_address(&secret);
        keys.insert(key_ref.to_string(), secret);
        Ok(address)
    }

    fn address_for_key(&self, key_ref: &str) -> Result<Address, BundlerKeyError> {
        let keys = self
            .keys
            .lock()
            .map_err(|_| BundlerKeyError::KeychainUnavailable("lock poisoned".to_string()))?;
        keys.get(key_ref)
            .map(secret_address)
            .ok_or_else(|| BundlerKeyError::KeyNotFound(key_ref.to_string()))
    }

    fn sign_eip1559_payload(
        &self,
        key_ref: &str,
        payload: &Bytes,
    ) -> Result<Eip1559Signature, BundlerKeyError> {
        let keys = self
            .keys
            .lock()
            .map_err(|_| BundlerKeyError::KeychainUnavailable("lock poisoned".to_string()))?;
        let secret = keys
            .get(key_ref)
            .ok_or_else(|| BundlerKeyError::KeyNotFound(key_ref.to_string()))?;
        sign_payload(secret, payload)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn next_key_ref_advances_numeric_suffix() {
        let refs = ["bundler-eoa:1", "other", "bundler-eoa:4"];
        assert_eq!(next_key_ref(refs.into_iter()).unwrap(), "bundler-eoa:5");
    }

    #[test]
    fn memory_key_store_creates_address_and_signs_payload() {
        let store = MemoryBundlerKeyStore::new();
        let address = store.create_key("bundler-eoa:1").unwrap();
        assert_eq!(store.address_for_key("bundler-eoa:1").unwrap(), address);
        let sig = store
            .sign_eip1559_payload("bundler-eoa:1", &Bytes::from_static(&[0x02, 0xc0]))
            .unwrap();
        assert!(!sig.r.is_zero());
        assert!(!sig.s.is_zero());
    }
}
