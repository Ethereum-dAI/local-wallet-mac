//! fd-5 spawn contract (the secret-delivery half of the wallet-node contract).
//!
//! Secrets (the RAILGUN entropy for the helper; the broadcaster EOA key) are delivered to
//! a child process over **fd 5** — never via argv or env — matching how the macOS app and
//! `wallet-node` already move the bundler secret. The parent writes the secret JSON to a
//! pipe whose read end the child inherits as fd 5, then closes it so the child reads EOF.
//!
//! Reading side: [`read_fd5`] slurps fd 5 to EOF; bins fall back to env only for
//! standalone/dev when no fd-5 was provided.

use std::io;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command};

const SECRET_FD: libc::c_int = 5;

/// Read fd 5 to EOF and close it. Returns `None` if fd 5 is not a valid/open fd
/// (standalone/dev) or is empty. Uses raw `libc` I/O deliberately — wrapping fd 5 in a
/// `File`/`OwnedFd` trips Rust's I/O-safety close-tracking and aborts the process.
pub fn read_fd5() -> Option<Vec<u8>> {
    // Probe: fd 5 must be a valid fd.
    if unsafe { libc::fcntl(SECRET_FD, libc::F_GETFD) } < 0 {
        return None; // EBADF — no fd 5 (standalone)
    }
    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    loop {
        let n = unsafe { libc::read(SECRET_FD, tmp.as_mut_ptr() as *mut libc::c_void, tmp.len()) };
        if n < 0 {
            let err = io::Error::last_os_error();
            if err.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            break; // read error — treat as no secret
        }
        if n == 0 {
            break; // EOF
        }
        buf.extend_from_slice(&tmp[..n as usize]);
    }
    unsafe { libc::close(SECRET_FD) };
    if buf.is_empty() {
        None
    } else {
        Some(buf)
    }
}

fn set_cloexec(fd: libc::c_int) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    if unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Spawn `cmd` with `secret` delivered to the child on **fd 5**.
///
/// Both pipe ends are CLOEXEC so they don't leak across the exec; a `dup2(read, 5)` in the
/// child's pre-exec installs a fresh (non-CLOEXEC) fd 5 that survives exec. The parent
/// writes the secret and closes its write end, so the child sees EOF after the payload.
/// (macOS has no `pipe2`, hence the explicit fcntl CLOEXEC dance.)
pub fn spawn_child_with_fd5(mut cmd: Command, secret: &[u8]) -> io::Result<Child> {
    let mut fds = [0 as libc::c_int; 2];
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let (read_fd, write_fd) = (fds[0], fds[1]);
    set_cloexec(read_fd)?;
    set_cloexec(write_fd)?;

    // In the child, just before exec: put the read end on fd 5. dup2 clears CLOEXEC on the
    // new fd — EXCEPT when read_fd already IS 5 (then dup2 is a no-op and CLOEXEC stays set,
    // which would close fd 5 at exec). So clear CLOEXEC on fd 5 explicitly, unconditionally.
    unsafe {
        cmd.pre_exec(move || {
            if libc::dup2(read_fd, SECRET_FD) < 0 {
                return Err(io::Error::last_os_error());
            }
            let flags = libc::fcntl(SECRET_FD, libc::F_GETFD);
            if flags < 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::fcntl(SECRET_FD, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }

    let child = cmd.spawn();

    // Parent no longer needs the read end regardless of spawn outcome.
    unsafe { libc::close(read_fd) };
    let child = match child {
        Ok(c) => c,
        Err(e) => {
            unsafe { libc::close(write_fd) };
            return Err(e);
        }
    };

    // Write the secret with raw libc, then close the write end so the child reads EOF.
    // (Raw I/O avoids OwnedFd close-tracking, matching read_fd5.)
    let mut off = 0usize;
    while off < secret.len() {
        let n = unsafe {
            libc::write(
                write_fd,
                secret[off..].as_ptr() as *const libc::c_void,
                secret.len() - off,
            )
        };
        if n < 0 {
            let err = io::Error::last_os_error();
            if err.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            unsafe { libc::close(write_fd) };
            return Err(err);
        }
        off += n as usize;
    }
    unsafe { libc::close(write_fd) };

    Ok(child)
}

/// Kills its child on drop so a panicking/exiting parent never leaks the broadcaster.
pub struct ChildGuard(pub Child);
impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fd5_delivers_secret_to_child() {
        // Child = `cat <&5` equivalent: a tiny shell that copies fd 5 to stdout.
        let mut cmd = Command::new("sh");
        cmd.arg("-c").arg("cat <&5");
        cmd.stdout(std::process::Stdio::piped());
        let child = spawn_child_with_fd5(cmd, b"hello-fd5").unwrap();
        let out = child.wait_with_output().unwrap();
        assert_eq!(String::from_utf8_lossy(&out.stdout), "hello-fd5");
    }
}
