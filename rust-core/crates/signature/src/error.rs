use core::fmt;

/// Errors returned by `wallet-signature`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignatureError {
    InvalidDerEncoding,
}

impl fmt::Display for SignatureError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SignatureError::InvalidDerEncoding => {
                write!(f, "invalid DER-encoded P-256 signature")
            }
        }
    }
}

impl std::error::Error for SignatureError {}

pub type Result<T> = core::result::Result<T, SignatureError>;
