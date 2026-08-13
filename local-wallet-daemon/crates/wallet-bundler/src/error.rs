use alloy_primitives::{Address, B256};
use thiserror::Error;
use wallet_userop_policy::GasPolicyError;

pub type Result<T> = std::result::Result<T, BundlerError>;

#[derive(Debug, Error)]
pub enum BundlerError {
    #[error("invalid user operation: {0}")]
    InvalidUserOperation(String),

    #[error("invalid transaction: {0}")]
    InvalidTransaction(String),

    #[error("entrypoint not allowlisted: {0}")]
    EntrypointNotAllowlisted(String),

    #[error("chain mismatch: expected {expected}, actual {actual}")]
    ChainMismatch { expected: u64, actual: u64 },

    #[error("policy cap exceeded: {field}")]
    PolicyCapExceeded { field: &'static str },

    #[error("paymaster not supported")]
    PaymasterNotSupported,

    #[error("signature missing")]
    SignatureMissing,

    #[error("replacement not possible: {reason}")]
    ReplacementNotPossible { reason: &'static str },

    #[error("raw transaction submission failed: {reason}")]
    RawTransactionSubmission { reason: String },

    #[error("simulation failed: {reason}")]
    SimulationFailed { reason: String },

    #[error("invalid pinned artifact: {reason}")]
    InvalidPinnedArtifact { reason: String },

    #[error("account code not allowlisted: {layer}/{module_type} {address:#x} {code_hash:#x}")]
    AccountCodeNotAllowlisted {
        layer: &'static str,
        module_type: &'static str,
        address: Address,
        code_hash: B256,
    },

    #[error("chain error: {0}")]
    Chain(#[from] wallet_chain::ChainError),

    #[error("store error: {0}")]
    Store(#[from] wallet_node_store::StoreError),
}

impl From<GasPolicyError> for BundlerError {
    fn from(error: GasPolicyError) -> Self {
        match error {
            GasPolicyError::EntryPointFieldWidth { field }
            | GasPolicyError::CapExceeded { field } => Self::PolicyCapExceeded { field },
            GasPolicyError::PriorityFeeAboveMaxFee => {
                Self::InvalidUserOperation("maxPriorityFeePerGas exceeds maxFeePerGas".to_string())
            }
            GasPolicyError::PaymasterNotSupported => Self::PaymasterNotSupported,
            GasPolicyError::ArithmeticOverflow { operation } => Self::InvalidUserOperation(
                format!("arithmetic overflow while computing {operation}"),
            ),
            GasPolicyError::SignatureLengthTooLarge => Self::InvalidUserOperation(
                "signature length cannot be represented safely".to_string(),
            ),
        }
    }
}
