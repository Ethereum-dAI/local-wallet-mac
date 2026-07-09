use core::fmt;

/// Errors returned by `wallet-signature`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignatureError {
    InvalidDerEncoding,
    Signing,
}

impl fmt::Display for SignatureError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SignatureError::InvalidDerEncoding => {
                write!(f, "invalid DER-encoded P-256 signature")
            }
            SignatureError::Signing => write!(f, "signing error"),
        }
    }
}

impl std::error::Error for SignatureError {}

impl From<k256::ecdsa::Error> for SignatureError {
    fn from(_: k256::ecdsa::Error) -> Self {
        SignatureError::Signing
    }
}

pub type Result<T> = core::result::Result<T, SignatureError>;
