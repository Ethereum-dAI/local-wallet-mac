#![allow(dead_code)]

use std::fs::{self, DirBuilder};
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::path::PathBuf;

use thiserror::Error;

#[derive(Debug, Clone)]
pub struct Paths {
    pub app_support_dir: PathBuf,
    pub socket_path: PathBuf,
    pub db_path: PathBuf,
    pub helios_dir: PathBuf,
    pub logs_dir: PathBuf,
    pub config_path: PathBuf,
}

#[derive(Debug, Error)]
pub enum PathsError {
    #[error("could not resolve a user data directory")]
    NoHomeDirectory,

    #[error(transparent)]
    Io(#[from] std::io::Error),

    #[error("directory permissions are too loose for {path}: mode {mode:o}")]
    PermissionsTooLoose { path: PathBuf, mode: u32 },
}

impl Paths {
    pub fn resolve(config_override: Option<PathBuf>) -> Result<Paths, PathsError> {
        let app_support_dir = dirs::data_dir()
            .ok_or(PathsError::NoHomeDirectory)?
            .join("Local Wallet")
            .join("wallet-node");

        resolve_with_base(app_support_dir, config_override)
    }
}

fn resolve_with_base(
    app_support_dir: PathBuf,
    config_override: Option<PathBuf>,
) -> Result<Paths, PathsError> {
    if app_support_dir.exists() {
        ensure_owner_only_dir(&app_support_dir)?;
    } else {
        create_private_dir(&app_support_dir)?;
    }

    let helios_dir = app_support_dir.join("helios");
    let logs_dir = app_support_dir.join("logs");

    create_private_dir(&helios_dir)?;
    create_private_dir(&logs_dir)?;

    Ok(Paths {
        socket_path: app_support_dir.join("wallet-node.sock"),
        db_path: app_support_dir.join("node.sqlite"),
        helios_dir,
        logs_dir,
        config_path: config_override.unwrap_or_else(|| app_support_dir.join("config.toml")),
        app_support_dir,
    })
}

fn create_private_dir(path: &PathBuf) -> Result<(), PathsError> {
    let mut builder = DirBuilder::new();
    builder.recursive(true);
    builder.mode(0o700);
    builder.create(path)?;
    Ok(())
}

fn ensure_owner_only_dir(path: &PathBuf) -> Result<(), PathsError> {
    let metadata = fs::metadata(path)?;
    let mode = metadata.mode() & 0o777;

    if mode & 0o077 != 0 {
        return Err(PathsError::PermissionsTooLoose {
            path: path.clone(),
            mode,
        });
    }

    Ok(())
}

#[cfg(all(test, unix))]
mod tests {
    use super::{resolve_with_base, PathsError};
    use std::fs::{self, DirBuilder};
    use std::os::unix::fs::DirBuilderExt;
    use std::path::{Path, PathBuf};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_path(name: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should be after unix epoch")
            .as_nanos();

        std::env::temp_dir().join(format!(
            "wallet-node-paths-{name}-{}-{nanos}",
            std::process::id()
        ))
    }

    fn create_dir_with_mode(path: &Path, mode: u32) {
        let mut builder = DirBuilder::new();
        builder.mode(mode);
        builder
            .create(path)
            .expect("test directory should be created");
    }

    #[test]
    fn rejects_existing_app_support_dir_with_loose_permissions() {
        let app_support_dir = temp_path("loose");
        create_dir_with_mode(&app_support_dir, 0o755);

        let result = resolve_with_base(app_support_dir.clone(), None);

        assert!(matches!(
            result,
            Err(PathsError::PermissionsTooLoose { mode: 0o755, .. })
        ));

        fs::remove_dir_all(app_support_dir).expect("test directory should be removed");
    }

    #[test]
    fn accepts_existing_app_support_dir_with_private_permissions() {
        let app_support_dir = temp_path("private");
        create_dir_with_mode(&app_support_dir, 0o700);

        let paths = resolve_with_base(app_support_dir.clone(), None)
            .expect("private app support directory should resolve");

        assert_eq!(paths.app_support_dir, app_support_dir);
        assert!(paths.helios_dir.is_dir());
        assert!(paths.logs_dir.is_dir());

        fs::remove_dir_all(paths.app_support_dir).expect("test directory should be removed");
    }
}
