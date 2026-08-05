//! Monotonic per-exit counter, persisted as `<state_dir>/exit-index`.
//!
//! Each exit derives its single-use EIP-7702 sender at `m/44'/60'/0'/1/{index}` — BIP-44's
//! internal branch, kept disjoint from the external `change = 0` chain — so the counter is
//! what makes senders rotate. It is NOT a secret: it holds no key material, only a rotation
//! index. Losing it never risks funds, because the key is re-derivable from the seed either way.
//!
//! **It is bound to the machine, not to the seed, and losing it is not a one-exit problem.**
//! A reset counter restarts at 0 and then walks the SAME sequence of indices the wallet has
//! already spent from — so it is exit `n+1` reusing sender 0, exit `n+2` reusing sender 1, and
//! so on for as long as the wallet keeps exiting. Restoring the same entropy on a second
//! machine has exactly this effect by construction: the new machine has no counter, starts at
//! 0, and every sender it derives is one the first machine already published on-chain. That
//! links those exits to each other, which is the whole property the rotation buys.
//!
//! Keeping the counter next to the entropy (in the app's Keychain, where it would travel with
//! a restore) would close the second-machine case; it lives here for now, which is why both
//! callers treat the state dir as privacy-critical and why the standalone fallback warns.
//!
//! The counter starts at 0 and stays 1:1 with the derivation index, which is why the disjoint
//! keyspace is a separate BIP-44 branch rather than an offset applied here.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::io::AsRawFd;
use std::path::Path;

const FILE_NAME: &str = "exit-index";

/// RAII exclusive `flock(2)` on the counter file, released on drop.
///
/// Read-then-write on this file is NOT safe to interleave: two overlapping helper instances —
/// which happen in practice, because an RPC/chain switch tears down and re-spawns the sidecar
/// while an exit is in flight and `SIGTERM` is not synchronous — would both read the same value
/// and both derive the SAME sender. A reused sender links two exits to each other, which is the
/// one property this counter exists to provide.
///
/// `flock` rather than an `O_EXCL` lockfile: the lock is owned by the open file description, so
/// the kernel releases it when the process dies for any reason. A crashed helper therefore cannot
/// leave a stale lockfile that wedges every subsequent exit — the failure mode an `O_EXCL` marker
/// would introduce.
/// Holds the raw fd rather than a `&File` so the guard does not borrow the file for its whole
/// lifetime — the locked region still needs `&mut File` to read and write. Safe because the guard
/// is declared AFTER the `File` in the one call site below, so it drops first; and even if it did
/// not, closing the fd releases the lock regardless.
struct FileLock(std::os::unix::io::RawFd);

impl FileLock {
    /// Blocking `LOCK_EX`. Blocking is correct here: the critical section is two syscalls on a
    /// handful of bytes, and waiting for the other instance is strictly better than handing out a
    /// duplicate index.
    fn acquire(file: &File) -> io::Result<Self> {
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self(file.as_raw_fd()))
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        // Closing the fd would release it anyway; unlocking explicitly keeps the critical
        // section's end where the code says it is.
        unsafe { libc::flock(self.0, libc::LOCK_UN) };
    }
}

/// Read the counter, return it, and persist the incremented value. Starts at 0.
///
/// The whole read-modify-write runs under an exclusive [`FileLock`], so concurrent callers — in
/// this process or in an overlapping second helper instance — can never be handed the same index.
///
/// Unparseable contents restart at 0 rather than failing every exit forever — the failure
/// mode of a corrupt counter should be a reused index, not a permanently broken sidecar.
pub fn next_index(state_dir: &Path) -> Result<u32, io::Error> {
    fs::create_dir_all(state_dir)?;
    let path = state_dir.join(FILE_NAME);

    // `truncate(false)`: the existing value must survive being opened, since we are about to read
    // it. Truncation happens inside the lock, after the read.
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
    }

    let _lock = FileLock::acquire(&file)?;

    let mut raw = String::new();
    file.read_to_string(&mut raw)?;
    let current = raw.trim().parse::<u32>().unwrap_or(0);

    // `checked_add`, not `saturating_add`: saturation would hand out `u32::MAX` on every
    // subsequent exit, silently reusing one sender forever — the exact unlinkability failure the
    // counter exists to prevent. Unreachable in practice (4 billion exits), so failing closed
    // costs nothing and matches this file's posture everywhere else.
    let next = current.checked_add(1).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "exit index counter is exhausted; refusing to reuse the final index",
        )
    })?;
    file.seek(SeekFrom::Start(0))?;
    file.set_len(0)?;
    file.write_all(next.to_string().as_bytes())?;
    // Durable before the caller derives a sender at `current`: a lost increment reuses an index.
    file.sync_all()?;
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

    #[test]
    fn concurrent_callers_never_get_the_same_index() {
        // The defect this guards: an unlocked read-then-write lets two overlapping callers both
        // read N and both derive the sender at N, linking two exits to each other. Each
        // `next_index` opens its own file description, so this exercises the real `flock` path —
        // the same mutual exclusion two helper processes rely on.
        let dir = tempfile::tempdir().unwrap();
        const THREADS: u32 = 8;
        const PER_THREAD: u32 = 25;

        let handles: Vec<_> = (0..THREADS)
            .map(|_| {
                let path = dir.path().to_path_buf();
                std::thread::spawn(move || {
                    (0..PER_THREAD)
                        .map(|_| next_index(&path).expect("next_index"))
                        .collect::<Vec<u32>>()
                })
            })
            .collect();

        let mut seen: Vec<u32> = handles
            .into_iter()
            .flat_map(|h| h.join().expect("thread panicked"))
            .collect();
        seen.sort_unstable();
        // Every index handed out exactly once, with no gaps: 0..THREADS*PER_THREAD.
        assert_eq!(
            seen,
            (0..THREADS * PER_THREAD).collect::<Vec<u32>>(),
            "indices must be unique and gapless"
        );
    }
}
