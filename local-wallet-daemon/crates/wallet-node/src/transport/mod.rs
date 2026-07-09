#![allow(dead_code)]

pub mod handler;
pub mod http;
pub mod unix;

use std::io;
use std::path::PathBuf;

#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error("live socket detected at {path}")]
    LiveSocketDetected { path: PathBuf },
    #[error("stale socket check failed at {path}: {source}")]
    StaleSocketCheckFailed { path: PathBuf, source: io::Error },
    #[error("failed to bind unix socket: {0}")]
    BindFailed(#[source] io::Error),
    #[error("parent directory permissions too loose at {path}: {mode:o}")]
    ParentDirPermissionsTooLoose { path: PathBuf, mode: u32 },
    #[error(transparent)]
    Io(#[from] io::Error),
}
