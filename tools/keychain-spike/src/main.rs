use rand::{rngs::OsRng, RngCore};
use security_framework::base::Error as SecurityError;
use std::env;
use std::error::Error;
use std::ffi::{c_char, c_void, CString, NulError};
use std::fmt;
use std::ptr;
use std::slice;

const SERVICE: &str = "com.localwallet.spike";
const ACCOUNT: &str = "keychain-spike-test-1";
const ERR_SEC_SUCCESS: OSStatus = 0;
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
    static kSecAttrAccessGroup: CFStringRef;
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
    fn SecItemDelete(query: CFDictionaryRef) -> OSStatus;
}

#[derive(Debug)]
enum SpikeError {
    CoreFoundation(&'static str),
    DataTypeMismatch,
    Nul(NulError),
    RoundTripMismatch { expected: usize, actual: usize },
    Security(SecurityError),
}

impl fmt::Display for SpikeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::CoreFoundation(context) => write!(f, "CoreFoundation call failed: {context}"),
            Self::DataTypeMismatch => write!(f, "SecItemCopyMatching did not return CFData"),
            Self::Nul(err) => write!(f, "string contained an interior NUL byte: {err}"),
            Self::RoundTripMismatch { expected, actual } => write!(
                f,
                "Keychain round-trip mismatch: expected {expected} bytes, got {actual} bytes"
            ),
            Self::Security(err) => {
                let message = err.message().unwrap_or_else(|| err.to_string());
                write!(f, "Security.framework OSStatus {}: {message}", err.code())
            }
        }
    }
}

impl Error for SpikeError {}

impl From<NulError> for SpikeError {
    fn from(err: NulError) -> Self {
        Self::Nul(err)
    }
}

struct OwnedCf(CFTypeRef);

impl OwnedCf {
    fn new(ptr: CFTypeRef, context: &'static str) -> Result<Self, SpikeError> {
        if ptr.is_null() {
            Err(SpikeError::CoreFoundation(context))
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

fn main() {
    if let Err(err) = run() {
        eprintln!("ERROR: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), SpikeError> {
    let mut secret = [0_u8; 32];
    OsRng.fill_bytes(&mut secret);

    println!("Storing ...");
    store_with_access_group(&secret)?;

    println!("Reading ...");
    let read_back = read_with_access_group()?;
    if read_back != secret {
        return Err(SpikeError::RoundTripMismatch {
            expected: secret.len(),
            actual: read_back.len(),
        });
    }
    println!("Keychain round-trip OK (32 bytes match)");

    println!("Deleting ...");
    delete_with_access_group()?;

    Ok(())
}

fn store_with_access_group(secret: &[u8; 32]) -> Result<(), SpikeError> {
    let service = cf_string(SERVICE)?;
    let account = cf_string(ACCOUNT)?;
    let secret_data = cf_data(secret)?;
    let access_group = access_group_cf_string()?;

    let mut pairs = base_query_pairs(&service, &account, access_group.as_ref());
    pairs.push(unsafe { (cf_void(kSecValueData), secret_data.as_void()) });

    // security-framework 2.x exposes item builders with kSecAttrAccessGroup, but
    // not kSecAttrAccessible. This spike therefore builds the CFDictionaryRef
    // directly and calls SecItemAdd / SecItemCopyMatching / SecItemDelete.
    let attributes = cf_dictionary(&pairs)?;
    let status = unsafe { SecItemAdd(attributes.as_dictionary(), ptr::null_mut()) };
    check_status(status)
}

fn read_with_access_group() -> Result<Vec<u8>, SpikeError> {
    let service = cf_string(SERVICE)?;
    let account = cf_string(ACCOUNT)?;
    let access_group = access_group_cf_string()?;

    let mut pairs = base_query_pairs(&service, &account, access_group.as_ref());
    pairs.push(unsafe { (cf_void(kSecReturnData), cf_void(kCFBooleanTrue)) });
    pairs.push(unsafe { (cf_void(kSecMatchLimit), cf_void(kSecMatchLimitOne)) });

    let query = cf_dictionary(&pairs)?;
    let mut result = ptr::null();
    let status = unsafe { SecItemCopyMatching(query.as_dictionary(), &mut result) };
    check_status(status)?;

    let data = OwnedCf::new(result, "SecItemCopyMatching returned null data")?;
    let is_data = unsafe { CFGetTypeID(data.as_void()) == CFDataGetTypeID() };
    if !is_data {
        return Err(SpikeError::DataTypeMismatch);
    }

    let len = unsafe { CFDataGetLength(data.as_data()) };
    let ptr = unsafe { CFDataGetBytePtr(data.as_data()) };
    if len < 0 || ptr.is_null() {
        return Err(SpikeError::CoreFoundation("invalid CFData result"));
    }

    let bytes = unsafe { slice::from_raw_parts(ptr, len as usize) };
    Ok(bytes.to_vec())
}

fn delete_with_access_group() -> Result<(), SpikeError> {
    let service = cf_string(SERVICE)?;
    let account = cf_string(ACCOUNT)?;
    let access_group = access_group_cf_string()?;

    let pairs = base_query_pairs(&service, &account, access_group.as_ref());
    let query = cf_dictionary(&pairs)?;
    let status = unsafe { SecItemDelete(query.as_dictionary()) };
    check_status(status)
}

fn base_query_pairs(
    service: &OwnedCf,
    account: &OwnedCf,
    access_group: Option<&OwnedCf>,
) -> Vec<(*const c_void, *const c_void)> {
    let mut pairs = vec![
        unsafe { (cf_void(kSecClass), cf_void(kSecClassGenericPassword)) },
        unsafe { (cf_void(kSecAttrService), service.as_void()) },
        unsafe { (cf_void(kSecAttrAccount), account.as_void()) },
        unsafe {
            (
                cf_void(kSecAttrAccessible),
                cf_void(kSecAttrAccessibleWhenUnlockedThisDeviceOnly),
            )
        },
    ];

    if let Some(access_group) = access_group {
        pairs.push(unsafe { (cf_void(kSecAttrAccessGroup), access_group.as_void()) });
    }

    pairs
}

fn access_group_cf_string() -> Result<Option<OwnedCf>, SpikeError> {
    match env::var("KEYCHAIN_ACCESS_GROUP") {
        Ok(access_group) if !access_group.is_empty() => cf_string(&access_group).map(Some),
        _ => Ok(None),
    }
}

fn cf_string(value: &str) -> Result<OwnedCf, SpikeError> {
    let value = CString::new(value)?;
    let cf = unsafe {
        CFStringCreateWithCString(ptr::null(), value.as_ptr(), K_CF_STRING_ENCODING_UTF8)
    };
    OwnedCf::new(cf.cast(), "CFStringCreateWithCString")
}

fn cf_data(value: &[u8]) -> Result<OwnedCf, SpikeError> {
    let cf = unsafe { CFDataCreate(ptr::null(), value.as_ptr(), value.len() as CFIndex) };
    OwnedCf::new(cf.cast(), "CFDataCreate")
}

fn cf_dictionary(pairs: &[(*const c_void, *const c_void)]) -> Result<OwnedCf, SpikeError> {
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

fn check_status(status: OSStatus) -> Result<(), SpikeError> {
    if status == ERR_SEC_SUCCESS {
        Ok(())
    } else {
        Err(SpikeError::Security(SecurityError::from_code(status)))
    }
}
