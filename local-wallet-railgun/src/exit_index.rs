//! Monotonic per-exit counter, persisted as `<state_dir>/exit-index`.
//!
//! Each exit derives its single-use EIP-7702 sender at `m/44'/60'/0'/1/{index}` — BIP-44's
//! internal branch, kept disjoint from the external `change = 0` chain — so the counter is
//! what makes senders rotate. It is NOT a secret: it holds no key material, only a rotation
//! index. Losing it risks reusing an index, which costs unlinkability for that one exit; it
//! never risks funds, because the key is re-derivable from the seed either way.
//!
//! The counter starts at 0 and stays 1:1 with the derivation index, which is why the disjoint
//! keyspace is a separate BIP-44 branch rather than an offset applied here.

use std::fs;
use std::io;
use std::path::Path;

const FILE_NAME: &str = "exit-index";

/// Read the counter, return it, and persist the incremented value. Starts at 0.
///
/// Unparseable contents restart at 0 rather than failing every exit forever — the failure
/// mode of a corrupt counter should be a reused index, not a permanently broken sidecar.
pub fn next_index(state_dir: &Path) -> Result<u32, io::Error> {
    fs::create_dir_all(state_dir)?;
    let path = state_dir.join(FILE_NAME);

    let current = fs::read_to_string(&path)
        .ok()
        .and_then(|s| s.trim().parse::<u32>().ok())
        .unwrap_or(0);

    let next = current.saturating_add(1);
    fs::write(&path, next.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    }
    Ok(current)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_call_returns_zero_then_increments() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(next_index(dir.path()).unwrap(), 0);
        assert_eq!(next_index(dir.path()).unwrap(), 1);
        assert_eq!(next_index(dir.path()).unwrap(), 2);
    }

    #[test]
    fn survives_across_calls_via_the_file() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(next_index(dir.path()).unwrap(), 0);
        // A fresh read of the same dir continues rather than restarting.
        assert_eq!(next_index(dir.path()).unwrap(), 1);
        assert!(dir.path().join("exit-index").exists());
    }

    #[test]
    fn file_is_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        next_index(dir.path()).unwrap();
        let mode = std::fs::metadata(dir.path().join("exit-index"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
    }

    #[test]
    fn corrupt_contents_do_not_wedge_the_sidecar() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("exit-index"), b"not-a-number").unwrap();
        // Recover by restarting at 0 rather than failing every exit forever.
        assert_eq!(next_index(dir.path()).unwrap(), 0);
        assert_eq!(next_index(dir.path()).unwrap(), 1);
    }

    #[test]
    fn creates_a_missing_state_dir() {
        let dir = tempfile::tempdir().unwrap();
        let nested = dir.path().join("nested").join("state");
        assert_eq!(next_index(&nested).unwrap(), 0);
    }
}
