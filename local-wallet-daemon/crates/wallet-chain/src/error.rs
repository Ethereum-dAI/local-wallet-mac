use thiserror::Error;

use crate::types::Bytes;

#[derive(Debug, Error)]
pub enum ChainError {
    #[error("rpc error: {0}")]
    RpcError(String),
    #[error("helios error: {0}")]
    Helios(String),
    #[error("block not found")]
    BlockNotFound,
    #[error("helios head {helios_head} is stale relative to execution head {exec_head}")]
    Stale { helios_head: u64, exec_head: u64 },
    #[error("state override is not supported by the linked chain adapter")]
    StateOverrideUnsupported,
    #[error("eth_call reverted")]
    CallReverted(Bytes),
    #[error("checkpoint is too old: {reason}")]
    CheckpointTooOld { reason: String },
    #[error(transparent)]
    Internal(#[from] anyhow::Error),
}
