use std::fs::{self, DirBuilder, File};
use std::io::{self, BufRead, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, OwnedFd, RawFd};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

const READY_FD: RawFd = 3;
const ALIVE_FD: RawFd = 4;

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReadyEvent {
    token: String,
    api_version: u32,
    socket_path: Option<PathBuf>,
    http_addr: Option<String>,
}

struct TestHarness {
    child: Child,
    ready_event: ReadyEvent,
    socket_path: PathBuf,
    alive_write_fd: OwnedFd,
    tempdir: PathBuf,
}

impl TestHarness {
    fn launch() -> io::Result<TestHarness> {
        let tempdir = temp_home()?;
        let (ready_read, ready_write) = cloexec_pipe()?;
        let (alive_read, alive_write) = cloexec_pipe()?;
        let ready_write_raw = ready_write.as_raw_fd();
        let alive_read_raw = alive_read.as_raw_fd();

        let mut command = Command::new(env!("CARGO_BIN_EXE_wallet-node"));
        command
            .args(["--ready-fd", "3", "--alive-fd", "4"])
            .env("HOME", &tempdir)
            .env("XDG_DATA_HOME", tempdir.join(".local").join("share"))
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());

        // SAFETY: pre_exec runs in the child after fork and before exec. The
        // closure only calls libc fd operations and returns io::Result errors.
        unsafe {
            command.pre_exec(move || configure_child_fds(ready_write_raw, alive_read_raw));
        }

        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(err) => {
                let _ = fs::remove_dir_all(&tempdir);
                return Err(err);
            }
        };

        drop(ready_write);
        drop(alive_read);

        let (tx, rx) = mpsc::channel();
        let reader = std::thread::spawn(move || {
            let result = read_ready_line(ready_read);
            let _ = tx.send(result);
        });

        let ready_line = match rx.recv_timeout(Duration::from_secs(5)) {
            Ok(result) => result,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                cleanup_failed_launch(&mut child, &tempdir);
                let _ = reader.join();
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "timed out waiting for wallet-node ready event",
                ));
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "ready reader exited without sending a result",
            )),
        };
        let _ = reader.join();
        let ready_line = match ready_line {
            Ok(line) => line,
            Err(err) => {
                cleanup_failed_launch(&mut child, &tempdir);
                return Err(err);
            }
        };

        let ready_event: ReadyEvent = match serde_json::from_str(ready_line.trim_end()) {
            Ok(event) => event,
            Err(err) => {
                cleanup_failed_launch(&mut child, &tempdir);
                return Err(io::Error::new(io::ErrorKind::InvalidData, err));
            }
        };
        let socket_path = match ready_event.socket_path.clone() {
            Some(socket_path) => socket_path,
            None => {
                cleanup_failed_launch(&mut child, &tempdir);
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "ready event did not include socketPath",
                ));
            }
        };

        Ok(TestHarness {
            child,
            ready_event,
            socket_path,
            alive_write_fd: alive_write,
            tempdir,
        })
    }

    fn close_alive_write_fd(&mut self) -> io::Result<()> {
        let replacement = unsafe { OwnedFd::from_raw_fd(File::open("/dev/null")?.into_raw_fd()) };
        let old = std::mem::replace(&mut self.alive_write_fd, replacement);
        drop(old);
        Ok(())
    }
}

impl Drop for TestHarness {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = self.close_alive_write_fd();
        let _ = fs::remove_dir_all(&self.tempdir);
    }
}

#[test]
#[ignore = "requires AF_UNIX bind capability; run with --include-ignored"]
fn unix_socket_health_round_trip() {
    let mut harness = TestHarness::launch().expect("launch wallet-node");
    assert_eq!(harness.ready_event.api_version, 1);
    assert!(harness.ready_event.http_addr.is_none());

    let response = send_json_rpc(
        &harness.socket_path,
        &harness.ready_event.token,
        &json!({
            "jsonrpc": "2.0",
            "method": "wallet_health",
            "params": null,
            "id": 1,
        }),
    );

    assert!(response.starts_with("HTTP/1.1 200 OK"), "{response}");
    let body = response_body_json(&response);
    assert!(
        ["starting", "syncing_consensus", "offline"]
            .contains(&body["result"]["status"].as_str().unwrap()),
        "{body}"
    );
    assert_eq!(body["result"]["apiVersion"], 1);

    harness
        .close_alive_write_fd()
        .expect("close alive write fd");
    assert_child_exits_success(&mut harness.child, Duration::from_secs(3));
}

#[test]
#[ignore = "requires AF_UNIX bind capability; run with --include-ignored"]
fn unix_socket_auth_failure() {
    let harness = TestHarness::launch().expect("launch wallet-node");
    let wrong_token = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    let body = r#"{"jsonrpc":"2.0","method":"wallet_health","params":null,"id":1}"#;
    let request = http_request(body, wrong_token);

    let response = send_raw_http(&harness.socket_path, request);

    assert!(
        response.starts_with("HTTP/1.1 401 Unauthorized"),
        "{response}"
    );
    assert_eq!(response_error_code(&response), -32001);
}

#[test]
#[ignore = "requires AF_UNIX bind capability; run with --include-ignored"]
fn unix_socket_body_too_large() {
    let harness = TestHarness::launch().expect("launch wallet-node");
    let body = "x".repeat(300_000);
    let request = http_request(&body, &harness.ready_event.token);

    let response = send_oversized_raw_http(&harness.socket_path, request);

    assert!(
        response.starts_with("HTTP/1.1 413 Payload Too Large"),
        "{response}"
    );
    assert_eq!(response_error_code(&response), -32012);
}

#[test]
#[ignore = "requires AF_UNIX bind capability; run with --include-ignored"]
fn unix_socket_unknown_method() {
    let harness = TestHarness::launch().expect("launch wallet-node");
    let response = send_json_rpc(
        &harness.socket_path,
        &harness.ready_event.token,
        &json!({
            "jsonrpc": "2.0",
            "method": "totally_made_up",
            "params": null,
            "id": 1,
        }),
    );

    assert!(response.starts_with("HTTP/1.1 200 OK"), "{response}");
    assert_eq!(response_error_code(&response), -32601);
}

#[test]
#[ignore = "requires AF_UNIX bind capability; run with --include-ignored"]
fn unix_socket_shutdown_method_exits_cleanly() {
    let mut harness = TestHarness::launch().expect("launch wallet-node");
    let response = send_json_rpc(
        &harness.socket_path,
        &harness.ready_event.token,
        &json!({
            "jsonrpc": "2.0",
            "method": "wallet_shutdown",
            "params": null,
            "id": 1,
        }),
    );

    assert!(response.starts_with("HTTP/1.1 200 OK"), "{response}");
    let body = response_body_json(&response);
    assert_eq!(body["result"]["ok"], true);
    assert_child_exits_success(&mut harness.child, Duration::from_secs(3));
}

fn send_json_rpc(socket_path: &Path, token: &str, body: &Value) -> String {
    let body = serde_json::to_string(body).expect("serialize JSON-RPC body");
    let request = http_request(&body, token);
    send_raw_http(socket_path, request)
}

fn http_request(body: &str, token: &str) -> Vec<u8> {
    format!(
        "POST / HTTP/1.1\r\nHost: wallet-node.local\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len(),
    )
    .into_bytes()
}

fn send_raw_http(socket_path: &Path, request: Vec<u8>) -> String {
    let mut stream = connect_unix_socket(socket_path);
    stream.write_all(&request).expect("write request");
    read_response(&mut stream)
}

fn send_oversized_raw_http(socket_path: &Path, request: Vec<u8>) -> String {
    let mut stream = connect_unix_socket(socket_path);

    for chunk in request.chunks(8192) {
        match stream.write_all(chunk) {
            Ok(()) => {}
            Err(err)
                if matches!(
                    err.kind(),
                    io::ErrorKind::BrokenPipe | io::ErrorKind::NotConnected
                ) =>
            {
                break
            }
            Err(err) => panic!("write oversized request: {err}"),
        }
    }

    read_response(&mut stream)
}

fn read_response(stream: &mut UnixStream) -> String {
    let mut bytes = Vec::new();
    stream.read_to_end(&mut bytes).expect("read response");
    String::from_utf8(bytes).expect("HTTP response is UTF-8")
}

fn response_body_json(response: &str) -> Value {
    let (_, body) = response.split_once("\r\n\r\n").expect("response has body");
    serde_json::from_str(body).expect("response body is JSON")
}

fn response_error_code(response: &str) -> i64 {
    response_body_json(response)["error"]["code"]
        .as_i64()
        .expect("numeric error code")
}

fn connect_unix_socket(socket_path: &Path) -> UnixStream {
    let deadline = Instant::now() + Duration::from_secs(3);

    loop {
        match UnixStream::connect(socket_path) {
            Ok(stream) => {
                stream
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .expect("set read timeout");
                stream
                    .set_write_timeout(Some(Duration::from_secs(5)))
                    .expect("set write timeout");
                return stream;
            }
            Err(_) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(err) => panic!("connect to wallet-node Unix socket failed: {err}"),
        }
    }
}

fn assert_child_exits_success(child: &mut Child, timeout: Duration) {
    let deadline = Instant::now() + timeout;

    loop {
        match child.try_wait().expect("child wait succeeds") {
            Some(status) => {
                assert!(status.success(), "wallet-node exited with {status}");
                return;
            }
            None if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(25)),
            None => panic!("child exit timeout"),
        }
    }
}

fn read_ready_line(ready_read: OwnedFd) -> io::Result<String> {
    let file = unsafe { File::from_raw_fd(ready_read.into_raw_fd()) };
    let mut reader = io::BufReader::new(file);
    let mut line = String::new();
    let read = reader.read_line(&mut line)?;

    if read == 0 {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "ready fd closed before emitting a ready event",
        ));
    }

    Ok(line)
}

fn configure_child_fds(ready_write_raw: RawFd, alive_read_raw: RawFd) -> io::Result<()> {
    let ready_src = duplicate_if_target_fd(ready_write_raw)?;
    let alive_src = duplicate_if_target_fd(alive_read_raw)?;

    dup2_to(ready_src, READY_FD)?;
    dup2_to(alive_src, ALIVE_FD)?;
    clear_cloexec(READY_FD)?;
    clear_cloexec(ALIVE_FD)?;
    close_child_source_fd(ready_src);
    close_child_source_fd(alive_src);

    Ok(())
}

fn duplicate_if_target_fd(fd: RawFd) -> io::Result<RawFd> {
    if fd != READY_FD && fd != ALIVE_FD {
        return Ok(fd);
    }

    let duplicated = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, ALIVE_FD + 1) };
    if duplicated == -1 {
        Err(io::Error::last_os_error())
    } else {
        Ok(duplicated)
    }
}

fn dup2_to(src: RawFd, target: RawFd) -> io::Result<()> {
    if unsafe { libc::dup2(src, target) } == -1 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn clear_cloexec(fd: RawFd) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags == -1 {
        return Err(io::Error::last_os_error());
    }

    if unsafe { libc::fcntl(fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) } == -1 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn set_cloexec(fd: RawFd) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags == -1 {
        return Err(io::Error::last_os_error());
    }

    if unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) } == -1 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn close_child_source_fd(fd: RawFd) {
    if fd != READY_FD && fd != ALIVE_FD {
        let _ = unsafe { libc::close(fd) };
    }
}

fn cloexec_pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let mut fds = [0; 2];
    if unsafe { libc::pipe(fds.as_mut_ptr()) } == -1 {
        return Err(io::Error::last_os_error());
    }

    if let Err(err) = set_cloexec(fds[0]).and_then(|_| set_cloexec(fds[1])) {
        let _ = unsafe { libc::close(fds[0]) };
        let _ = unsafe { libc::close(fds[1]) };
        return Err(err);
    }

    Ok(unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) })
}

fn temp_home() -> io::Result<PathBuf> {
    for _ in 0..16 {
        let dir =
            PathBuf::from("/tmp").join(format!("wn-{}-{:016x}", std::process::id(), random_u64()));

        let mut builder = DirBuilder::new();
        builder.mode(0o700);
        match builder.create(&dir) {
            Ok(()) => {
                fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
                return Ok(dir);
            }
            Err(err) if err.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(err) => return Err(err),
        }
    }

    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "could not allocate unique wallet-node test home",
    ))
}

fn random_u64() -> u64 {
    if let Ok(mut file) = File::open("/dev/urandom") {
        let mut bytes = [0_u8; 8];
        if file.read_exact(&mut bytes).is_ok() {
            return u64::from_ne_bytes(bytes);
        }
    }

    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock should be after unix epoch")
        .as_nanos() as u64
}

fn cleanup_failed_launch(child: &mut Child, tempdir: &Path) {
    let _ = child.kill();
    let _ = child.wait();
    let _ = fs::remove_dir_all(tempdir);
}
