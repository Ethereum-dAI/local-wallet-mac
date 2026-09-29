//! Shared by the integration tests: find `edw`, and give each test a throwaway wallet.

use std::path::PathBuf;

use edw_tui::edw::EdwConfig;

/// `EDW_BIN`, or `edw` on PATH; `None` when it does not run.
pub fn edw_binary() -> Option<PathBuf> {
    let binary = PathBuf::from(std::env::var_os("EDW_BIN").unwrap_or_else(|| "edw".into()));
    std::process::Command::new(&binary)
        .arg("--help")
        .output()
        .ok()?
        .status
        .success()
        .then_some(binary)
}

/// A data and runtime dir that is removed when the test ends.
pub struct TempWallet {
    pub config: EdwConfig,
    dir: PathBuf,
}

impl TempWallet {
    pub fn new(binary: PathBuf, name: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("edw-tui-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let config = EdwConfig {
            binary,
            data_dir: dir.join("data"),
            runtime_dir: dir.join("runtime"),
            password: "test-password".into(),
        };
        Self { config, dir }
    }
}

impl Drop for TempWallet {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}
