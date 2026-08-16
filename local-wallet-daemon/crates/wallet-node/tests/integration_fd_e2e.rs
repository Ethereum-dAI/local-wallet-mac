use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus};
use std::time::{Duration, Instant};

use nix::unistd::pipe;
use serde_json::Value;

#[test]
#[ignore = "requires AF_UNIX bind capability + fd inheritance; run with --include-ignored"]
fn fd_handshake_full_lifecycle() {
    let test_home = TempHome::new("");
    let Spawned {
        mut process,
        ready_read_fd,
        alive_write_fd,
        secret_write_fd,
    } = spawn_wallet_node(&test_home);

    let mut secret_writer = File::from(secret_write_fd);
    secret_writer
        .write_all(
            br#"{"keys":[{"keyRef":"bundler-eoa:default:1:1","secret":"0x0101010101010101010101010101010101010101010101010101010101010101"}]}"#,
        )
        .expect("write secret payload");
    drop(secret_writer);

    let ready = read_ready_event(ready_read_fd);

    assert!(
        wait_for_path(
            ready
                .socket_path
                .to_str()
                .expect("socket path should be UTF-8"),
            Duration::from_secs(5)
        ),
        "socket file should exist at {}",
        ready.socket_path.display()
    );
    assert_secret_fd_inserted_active_bundler_account(&ready.socket_path);

    drop(alive_write_fd);

    let status = process
        .wait_for_exit(Duration::from_secs(3))
        .expect("wallet-node should exit within 3 seconds after alive pipe EOF");
    assert!(status.success(), "wallet-node exited with {status}");

    let Spawned {
        mut process,
        ready_read_fd,
        alive_write_fd,
        secret_write_fd,
    } = spawn_wallet_node(&test_home);

    let mut secret_writer = File::from(secret_write_fd);
    secret_writer
        .write_all(br#"{"keys":[]}"#)
        .expect("write read-only secret payload");
    drop(secret_writer);

    let ready = read_ready_event(ready_read_fd);
    assert!(
        wait_for_path(
            ready
                .socket_path
                .to_str()
                .expect("socket path should be UTF-8"),
            Duration::from_secs(5)
        ),
        "read-only socket file should exist at {}",
        ready.socket_path.display()
    );
    let response = send_json_rpc(
        &ready.socket_path,
        &ready.token,
        &serde_json::json!({
            "jsonrpc": "2.0",
            "method": "wallet_bundlerStatus",
            "params": [],
            "id": 1,
        }),
    );
    let result = &response["result"];
    assert_eq!(result["keyRef"], "bundler-eoa:default:1:1");
    assert_eq!(result["eoa"], "0x1a642f0e3c3af545e7acbd38b07251b3990914f1");
    assert_eq!(result["lifecycle"], "active");
    assert_eq!(result["keyLoaded"], false);
    assert_eq!(result["reason"], "bundler_eoa_locked");

    drop(alive_write_fd);
    let status = process
        .wait_for_exit(Duration::from_secs(3))
        .expect("read-only wallet-node should exit within 3 seconds after alive pipe EOF");
    assert!(
        status.success(),
        "read-only wallet-node exited with {status}"
    );
}

/// A fatal startup failure must reach the parent as a JSON `error` line on the
/// ready fd. Without it the parent only sees the fd close and can say nothing
/// about why — the exact hole that made a dead Sepolia RPC look like a generic
/// "ready pipe closed before ready event".
#[test]
#[ignore = "requires fd inheritance; run with --include-ignored"]
fn startup_failure_is_reported_on_the_ready_fd() {
    let test_home = TempHome::new("f");
    let Spawned {
        mut process,
        ready_read_fd,
        alive_write_fd,
        secret_write_fd,
    } = spawn_wallet_node(&test_home);

    // Malformed secret payload: deterministic, offline, and it fails at a
    // startup stage that runs after logging and the store are up.
    let mut secret_writer = File::from(secret_write_fd);
    secret_writer
        .write_all(br#"{"keys":"not-an-array"}"#)
        .expect("write malformed secret payload");
    drop(secret_writer);

    wait_for_readable(&ready_read_fd, READY_TIMEOUT);
    let mut ready_reader = BufReader::new(File::from(ready_read_fd));
    let mut line = String::new();
    let bytes_read = ready_reader
        .read_line(&mut line)
        .expect("read failure line from fd");
    assert!(
        bytes_read > 0,
        "ready fd closed without reporting a failure reason"
    );

    let event: Value = serde_json::from_str(line.trim_end()).expect("failure event JSON");
    let reason = event["error"]
        .as_str()
        .unwrap_or_else(|| panic!("expected an error field, got {line}"));
    assert!(
        reason.contains("bundler secrets"),
        "failure reason should name the failing stage, got {reason:?}"
    );
    // The parent tells the shapes apart by `error`, so a failure must not also
    // look like a ready event.
    assert!(event["token"].is_null(), "failure must carry no token");

    drop(alive_write_fd);
    let status = process
        .wait_for_exit(Duration::from_secs(5))
        .expect("wallet-node should exit after a fatal startup failure");
    assert!(
        !status.success(),
        "wallet-node should exit non-zero, got {status}"
    );
}

/// A pipe neither end of which survives an unrelated `exec`.
fn cloexec_pipe(name: &str) -> (std::os::fd::OwnedFd, std::os::fd::OwnedFd) {
    let (read_fd, write_fd) = pipe().unwrap_or_else(|err| panic!("create {name} pipe: {err}"));
    for fd in [&read_fd, &write_fd] {
        // SAFETY: `fd` is a live descriptor this function owns.
        let result = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) };
        assert_ne!(
            result,
            -1,
            "set FD_CLOEXEC on {name} pipe: {}",
            std::io::Error::last_os_error()
        );
    }
    (read_fd, write_fd)
}

struct Spawned {
    process: TestProcess,
    ready_read_fd: std::os::fd::OwnedFd,
    alive_write_fd: std::os::fd::OwnedFd,
    secret_write_fd: std::os::fd::OwnedFd,
}

/// Launch `wallet-node` over the fd 3/4/5 contract the macOS app uses.
///
/// Every pipe is created `O_CLOEXEC`, which is what makes two of these tests
/// safe to run at once. Without it, a `spawn` on one thread forks while another
/// test's pipes are open, and the child inherits them: that child then holds a
/// copy of the *other* test's secret-pipe write end, so dropping the writer never
/// closes the pipe, the other daemon blocks forever on its fd-5 read, and both
/// tests time out waiting for a ready event that cannot arrive. `dup2` onto
/// 3/4/5 below is what deliberately re-exposes the three we do want to pass.
fn spawn_wallet_node(test_home: &TempHome) -> Spawned {
    let (ready_read_fd, ready_write_fd) = cloexec_pipe("ready");
    let (alive_read_fd, alive_write_fd) = cloexec_pipe("alive");
    let (secret_read_fd, secret_write_fd) = cloexec_pipe("secret");

    let ready_read_raw = ready_read_fd.as_raw_fd();
    let ready_write_raw = ready_write_fd.as_raw_fd();
    let alive_read_raw = alive_read_fd.as_raw_fd();
    let alive_write_raw = alive_write_fd.as_raw_fd();
    let secret_read_raw = secret_read_fd.as_raw_fd();
    let secret_write_raw = secret_write_fd.as_raw_fd();

    let mut command = Command::new(env!("CARGO_BIN_EXE_wallet-node"));
    command
        .args(["--ready-fd", "3", "--alive-fd", "4", "--secret-fd", "5"])
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

            if secret_read_raw != 5 && libc::dup2(secret_read_raw, 5) == -1 {
                return Err(std::io::Error::last_os_error());
            }

            for raw in [
                ready_read_raw,
                ready_write_raw,
                alive_read_raw,
                alive_write_raw,
                secret_read_raw,
                secret_write_raw,
            ] {
                if raw != 3 && raw != 4 && raw != 5 {
                    libc::close(raw);
                }
            }

            // The pipes are O_CLOEXEC, and `dup2` clears that flag on the new
            // descriptor — except when oldfd == newfd, where POSIX makes it a
            // no-op that changes nothing. Clear it explicitly so the daemon
            // still receives all three however the parent's fds happened to be
            // numbered.
            for target in [3, 4, 5] {
                if libc::fcntl(target, libc::F_SETFD, 0) == -1 {
                    return Err(std::io::Error::last_os_error());
                }
            }

            Ok(())
        });
    }

    let child = command.spawn().expect("spawn wallet-node");

    drop(ready_write_fd);
    drop(alive_read_fd);
    drop(secret_read_fd);

    Spawned {
        process: TestProcess { child },
        ready_read_fd,
        alive_write_fd,
        secret_write_fd,
    }
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

struct ReadyEvent {
    socket_path: PathBuf,
    token: String,
}

fn read_ready_event(ready_read_fd: std::os::fd::OwnedFd) -> ReadyEvent {
    wait_for_readable(&ready_read_fd, READY_TIMEOUT);
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

    ReadyEvent {
        socket_path: PathBuf::from(socket_path),
        token: token.to_owned(),
    }
}

fn send_json_rpc(socket_path: &Path, token: &str, body: &Value) -> Value {
    let body = serde_json::to_string(body).expect("serialize JSON-RPC body");
    let request = format!(
        "POST / HTTP/1.1\r\nHost: wallet-node.local\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len(),
    );
    let mut stream = UnixStream::connect(socket_path).unwrap_or_else(|error| {
        panic!(
            "connect to wallet-node Unix socket at {}: {error}",
            socket_path.display()
        )
    });
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .expect("set RPC read timeout");
    stream
        .set_write_timeout(Some(Duration::from_secs(10)))
        .expect("set RPC write timeout");
    stream
        .write_all(request.as_bytes())
        .expect("write authenticated JSON-RPC request");

    let mut response = String::new();
    stream
        .read_to_string(&mut response)
        .expect("read JSON-RPC response");
    assert!(response.starts_with("HTTP/1.1 200 OK"), "{response}");
    let (_, response_body) = response
        .split_once("\r\n\r\n")
        .expect("HTTP response should have a body");
    let value: Value = serde_json::from_str(response_body).expect("response body should be JSON");
    assert!(value.get("error").is_none(), "{value}");
    value
}

fn assert_secret_fd_inserted_active_bundler_account(socket_path: &Path) {
    let db_path = socket_path
        .parent()
        .expect("socket path should have parent")
        .join("node.sqlite");
    assert!(
        wait_for_path(
            db_path.to_str().expect("db path should be UTF-8"),
            Duration::from_secs(5)
        ),
        "node sqlite db should exist at {}",
        db_path.display()
    );
    let conn = rusqlite::Connection::open(db_path).expect("open node sqlite db");
    let lifecycle: String = conn
        .query_row(
            "SELECT lifecycle FROM bundler_accounts WHERE owner_scope = ?1 AND chain_id = ?2 AND key_ref = ?3",
            ("default", 1_i64, "bundler-eoa:default:1:1"),
            |row| row.get(0),
        )
        .expect("secret-fd bundler account row should exist");
    assert_eq!(lifecycle, "active");
}

struct TempHome {
    path: PathBuf,
}

impl TempHome {
    /// `suffix` keeps concurrent tests off each other's HOME, and **must stay a
    /// character or two**. The daemon binds its socket at
    /// `<HOME>/Library/Application Support/Local Wallet/wallet-node/wallet-node.sock`,
    /// and `sun_path` is 104 bytes on macOS: a descriptive suffix like
    /// `-startup-failure` overruns it, and the only symptom is the daemon never
    /// reaching ready — no error, just a silent hang.
    fn new(suffix: &str) -> Self {
        let path = PathBuf::from("/tmp").join(format!("wnfd-{}{suffix}", std::process::id()));
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

/// How long a spawned daemon gets to reach its ready event.
///
/// Generous on purpose. These tests are `#[ignore]`d and opt-in, they start real
/// daemons, and they run concurrently with each other — a full startup does real
/// work (chain adapter included) and a tight budget turns load into a failure
/// that looks like a bug in the fd contract. A long timeout costs nothing on a
/// passing run.
const READY_TIMEOUT: Duration = Duration::from_secs(30);

fn wait_for_readable(fd: &impl AsRawFd, timeout: Duration) {
    let deadline = Instant::now() + timeout;
    loop {
        let now = Instant::now();
        if now >= deadline {
            panic!("ready fd did not become readable within {timeout:?}");
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
            panic!("ready fd did not become readable within {timeout:?}");
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
