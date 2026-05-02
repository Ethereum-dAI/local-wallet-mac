use std::fs::File;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::AsRawFd;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus};
use std::time::{Duration, Instant};

use nix::unistd::pipe;
use serde_json::Value;

#[test]
#[ignore = "requires AF_UNIX bind capability + fd inheritance; run with --include-ignored"]
fn fd_handshake_full_lifecycle() {
    let test_home = TempHome::new();
    let (ready_read_fd, ready_write_fd) = pipe().expect("create ready pipe");
    let (alive_read_fd, alive_write_fd) = pipe().expect("create alive pipe");

    let ready_read_raw = ready_read_fd.as_raw_fd();
    let ready_write_raw = ready_write_fd.as_raw_fd();
    let alive_read_raw = alive_read_fd.as_raw_fd();
    let alive_write_raw = alive_write_fd.as_raw_fd();

    let mut command = Command::new(env!("CARGO_BIN_EXE_wallet-node"));
    command
        .args(["--ready-fd", "3", "--alive-fd", "4"])
        .env("HOME", test_home.path())
        .env_remove("XDG_DATA_HOME");

    // SAFETY: pre_exec runs after fork and before exec. The closure below only
    // calls async-signal-safe libc functions plus last_os_error for reporting a
    // failed syscall back to the parent process.
    unsafe {
        command.pre_exec(move || -> std::io::Result<()> {
            if ready_write_raw != 3 && libc::dup2(ready_write_raw, 3) == -1 {
                return Err(std::io::Error::last_os_error());
            }

            if alive_read_raw != 4 && libc::dup2(alive_read_raw, 4) == -1 {
                return Err(std::io::Error::last_os_error());
            }

            if ready_read_raw != 3 && ready_read_raw != 4 {
                libc::close(ready_read_raw);
            }
            if ready_write_raw != 3 && ready_write_raw != 4 {
                libc::close(ready_write_raw);
            }
            if alive_read_raw != 3 && alive_read_raw != 4 {
                libc::close(alive_read_raw);
            }
            if alive_write_raw != 3 && alive_write_raw != 4 {
                libc::close(alive_write_raw);
            }

            Ok(())
        });
    }

    let child = command.spawn().expect("spawn wallet-node");
    let mut process = TestProcess { child };

    drop(ready_write_fd);
    drop(alive_read_fd);

    wait_for_readable(&ready_read_fd, Duration::from_secs(5));
    let mut ready_reader = BufReader::new(File::from(ready_read_fd));
    let mut ready_line = String::new();
    let bytes_read = ready_reader
        .read_line(&mut ready_line)
        .expect("read ready line from fd");
    assert!(bytes_read > 0, "ready fd closed without data");
    assert!(
        ready_line.ends_with('\n'),
        "ready event should be newline-terminated: {ready_line:?}"
    );

    let ready: Value = serde_json::from_str(ready_line.trim_end()).expect("ready event JSON");
    assert_eq!(ready["apiVersion"], 1);
    let socket_path = ready["socketPath"]
        .as_str()
        .expect("socketPath should be a string");
    assert!(
        socket_path.ends_with("wallet-node.sock"),
        "unexpected socketPath: {socket_path}"
    );
    assert!(ready["httpAddr"].is_null(), "httpAddr should be null");
    let token = ready["token"].as_str().expect("token should be a string");
    assert_eq!(token.len(), 43, "token should be 43 chars");

    assert!(
        wait_for_path(socket_path, Duration::from_secs(5)),
        "socket file should exist at {socket_path}"
    );

    drop(alive_write_fd);

    let status = process
        .wait_for_exit(Duration::from_secs(3))
        .expect("wallet-node should exit within 3 seconds after alive pipe EOF");
    assert!(status.success(), "wallet-node exited with {status}");
}

struct TestProcess {
    child: Child,
}

impl TestProcess {
    fn wait_for_exit(&mut self, timeout: Duration) -> Option<ExitStatus> {
        let deadline = Instant::now() + timeout;
        loop {
            match self.child.try_wait() {
                Ok(Some(status)) => return Some(status),
                Ok(None) => {
                    if Instant::now() >= deadline {
                        return None;
                    }
                    std::thread::sleep(Duration::from_millis(25));
                }
                Err(err) => panic!("failed to wait for wallet-node: {err}"),
            }
        }
    }
}

impl Drop for TestProcess {
    fn drop(&mut self) {
        match self.child.try_wait() {
            Ok(Some(_)) => {}
            Ok(None) | Err(_) => {
                let _ = self.child.kill();
                let _ = self.child.wait();
            }
        }
    }
}

struct TempHome {
    path: PathBuf,
}

impl TempHome {
    fn new() -> Self {
        let path = PathBuf::from("/tmp").join(format!("wnfd-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("create temp HOME");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))
            .expect("chmod temp HOME 0700");
        Self { path }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempHome {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

fn wait_for_readable(fd: &impl AsRawFd, timeout: Duration) {
    let deadline = Instant::now() + timeout;
    loop {
        let now = Instant::now();
        if now >= deadline {
            panic!("ready fd did not become readable within 5 seconds");
        }

        let remaining = deadline.saturating_duration_since(now);
        let timeout_ms = remaining.as_millis().min(i32::MAX as u128) as i32;
        let mut poll_fd = libc::pollfd {
            fd: fd.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };

        let result = unsafe { libc::poll(&mut poll_fd, 1, timeout_ms) };
        if result == 0 {
            panic!("ready fd did not become readable within 5 seconds");
        }
        if result > 0 {
            return;
        }

        let err = std::io::Error::last_os_error();
        match err.raw_os_error() {
            Some(code) if code == libc::EINTR => continue,
            _ => panic!("poll ready fd failed: {err}"),
        }
    }
}

fn wait_for_path(path: &str, timeout: Duration) -> bool {
    let path = Path::new(path);
    let deadline = Instant::now() + timeout;
    loop {
        if path.exists() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}
