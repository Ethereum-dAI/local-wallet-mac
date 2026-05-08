use std::io::BufRead;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::process::Command;
use tokio::time::timeout;

#[test]
fn print_api_version_prints_one_and_exits_zero() {
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_wallet-node"))
        .arg("--print-api-version")
        .output()
        .expect("run wallet-node --print-api-version");

    assert_eq!(output.status.code(), Some(0));
    assert_eq!(output.stdout, b"1\n");
    assert!(output.stderr.is_empty());
}

#[tokio::test]
#[ignore = "requires TCP loopback bind capability; run with --include-ignored"]
async fn http_health_and_shutdown_e2e() {
    let test_home = std::env::current_dir()
        .expect("current dir")
        .join("target")
        .join(format!("wallet-node-e2e-home-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&test_home);
    std::fs::create_dir_all(&test_home).expect("create test home");

    let mut command = Command::new(env!("CARGO_BIN_EXE_wallet-node"));
    command
        .args(["--http", "127.0.0.1:0", "--print-ready"])
        .env("HOME", &test_home)
        .env("XDG_DATA_HOME", test_home.join(".local").join("share"))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    let mut child = command.spawn().expect("spawn wallet-node");
    let stdout = child.stdout.take().expect("child stdout");
    let mut stderr = Some(child.stderr.take().expect("child stderr"));
    let mut stdout = BufReader::new(stdout).lines();

    let ready_line = match timeout(Duration::from_secs(5), stdout.next_line()).await {
        Ok(Ok(Some(line))) => line,
        Ok(Ok(None)) => {
            let stderr = read_stderr(stderr.take()).await;
            panic!("ready line should be present; stderr: {stderr}");
        }
        Ok(Err(err)) => panic!("failed to read ready line: {err}"),
        Err(_) => {
            let stderr = read_stderr(stderr.take()).await;
            panic!("ready line timeout; stderr: {stderr}");
        }
    };
    let ready: Value = serde_json::from_str(&ready_line).expect("ready event JSON");
    let token = ready["token"].as_str().expect("ready token");
    let http_addr = ready["httpAddr"].as_str().expect("ready httpAddr");

    let health = send_json_rpc(
        http_addr,
        token,
        &json!({
            "jsonrpc": "2.0",
            "method": "wallet_health",
            "params": null,
            "id": 1,
        }),
    )
    .await;

    assert!(health.starts_with("HTTP/1.1 200 OK"), "{health}");
    let health_body = response_body_json(&health);
    // Real Helios startup can be offline, starting, or syncing depending on checkpoint
    // freshness and how far the light client gets before this immediate health probe.
    assert!(
        ["starting", "syncing_consensus", "offline"]
            .contains(&health_body["result"]["status"].as_str().unwrap()),
        "{health_body}"
    );
    assert_eq!(health_body["result"]["apiVersion"], 1);

    let shutdown = send_json_rpc(
        http_addr,
        token,
        &json!({
            "jsonrpc": "2.0",
            "method": "wallet_shutdown",
            "params": null,
            "id": 2,
        }),
    )
    .await;

    assert!(shutdown.starts_with("HTTP/1.1 200 OK"), "{shutdown}");
    let shutdown_body = response_body_json(&shutdown);
    assert_eq!(shutdown_body["result"]["ok"], true);

    let status = timeout(Duration::from_secs(3), child.wait())
        .await
        .expect("child exit timeout")
        .expect("child wait succeeds");
    assert!(status.success(), "wallet-node exited with {status}");
}

#[tokio::test]
#[ignore = "requires TCP loopback bind capability; run with --include-ignored"]
async fn daemon_serves_wallet_health_while_real_helios_is_not_ready() {
    let (mut guard, ready) = spawn_ready_wallet_node("chain-not-ready").await;

    let health = send_json_rpc(
        &ready.http_addr,
        &ready.token,
        &json!({
            "jsonrpc": "2.0",
            "method": "wallet_health",
            "params": null,
            "id": 1,
        }),
    )
    .await;

    assert!(health.starts_with("HTTP/1.1 200 OK"), "{health}");
    let health_body = response_body_json(&health);
    assert!(
        ["starting", "syncing_consensus", "offline"]
            .contains(&health_body["result"]["status"].as_str().unwrap()),
        "{health_body}"
    );
    assert_eq!(health_body["result"]["helios"]["ready"], false);
    if health_body["result"]["status"] == "offline" {
        assert!(health_body["result"]["reason"].as_str().is_some());
    }

    let shutdown = send_json_rpc(
        &ready.http_addr,
        &ready.token,
        &json!({
            "jsonrpc": "2.0",
            "method": "wallet_shutdown",
            "params": null,
            "id": 2,
        }),
    )
    .await;

    assert!(shutdown.starts_with("HTTP/1.1 200 OK"), "{shutdown}");
    let shutdown_body = response_body_json(&shutdown);
    assert_eq!(shutdown_body["result"]["ok"], true);

    let status = timeout(Duration::from_secs(3), async {
        loop {
            if let Some(status) = guard.child.try_wait().expect("child try_wait succeeds") {
                break status;
            }

            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("child exit timeout");
    assert!(status.success(), "wallet-node exited with {status}");
}

#[tokio::test]
#[ignore = "requires TCP loopback bind capability; run with --include-ignored"]
async fn sigterm_triggers_graceful_shutdown() {
    signal_triggers_graceful_shutdown("sigterm", libc::SIGTERM).await;
}

#[tokio::test]
#[ignore = "requires TCP loopback bind capability; run with --include-ignored"]
async fn sigint_triggers_graceful_shutdown() {
    signal_triggers_graceful_shutdown("sigint", libc::SIGINT).await;
}

#[tokio::test]
#[ignore = "requires TCP loopback bind capability; run with --include-ignored"]
async fn auth_failure_returns_minus_32001_over_http() {
    timeout(Duration::from_secs(5), async {
        let (mut guard, ready) = spawn_ready_wallet_node("auth-failure").await;
        let wrong_token = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        let body = r#"{"jsonrpc":"2.0","method":"wallet_health","params":null,"id":1}"#;
        let request = http_request(&ready.http_addr, body, wrong_token);

        let response = send_raw_http(&ready.http_addr, request).await;

        assert!(
            response.starts_with("HTTP/1.1 401 Unauthorized"),
            "{response}"
        );
        assert_eq!(response_error_code(&response), -32001);
        let _ = guard.child.kill();
    })
    .await
    .expect("auth failure e2e timeout");
}

#[tokio::test]
#[ignore = "requires TCP loopback bind capability; run with --include-ignored"]
async fn body_too_large_returns_minus_32012_over_http() {
    timeout(Duration::from_secs(5), async {
        let (mut guard, ready) = spawn_ready_wallet_node("body-too-large").await;
        let body = "x".repeat(300_000);
        let request = http_request(&ready.http_addr, &body, &ready.token);

        let response = send_raw_http(&ready.http_addr, request).await;

        assert!(
            response.starts_with("HTTP/1.1 413 Payload Too Large"),
            "{response}"
        );
        assert_eq!(response_error_code(&response), -32012);
        let _ = guard.child.kill();
    })
    .await
    .expect("body too large e2e timeout");
}

#[tokio::test]
#[ignore = "requires TCP loopback bind capability; run with --include-ignored"]
async fn unknown_method_returns_minus_32601_over_http() {
    timeout(Duration::from_secs(5), async {
        let (mut guard, ready) = spawn_ready_wallet_node("unknown-method").await;
        let request = http_request(
            &ready.http_addr,
            &serde_json::to_string(&json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "totally_made_up_method_name",
                "params": {},
            }))
            .expect("serialize JSON-RPC body"),
            &ready.token,
        );

        let response = send_raw_http(&ready.http_addr, request).await;

        assert!(response.starts_with("HTTP/1.1 200 OK"), "{response}");
        let body = response_body_json(&response);
        assert_eq!(body["error"]["code"], -32601);
        assert_eq!(
            body["error"]["data"]["method"],
            "totally_made_up_method_name"
        );
        let _ = guard.child.kill();
    })
    .await
    .expect("unknown method e2e timeout");
}

async fn send_json_rpc(addr: &str, token: &str, body: &Value) -> String {
    let body = serde_json::to_string(body).expect("serialize JSON-RPC body");
    let request = format!(
        "POST / HTTP/1.1\r\nHost: {addr}\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len(),
    );

    let mut stream = TcpStream::connect(addr)
        .await
        .expect("connect to wallet-node");
    stream
        .write_all(request.as_bytes())
        .await
        .expect("write request");

    let mut bytes = Vec::new();
    stream.read_to_end(&mut bytes).await.expect("read response");

    String::from_utf8(bytes).expect("HTTP response is UTF-8")
}

async fn signal_triggers_graceful_shutdown(test_name: &str, signal: libc::c_int) {
    let test_home = temp_home(test_name);
    let mut command = Command::new(env!("CARGO_BIN_EXE_wallet-node"));
    command
        .args(["--http", "127.0.0.1:0", "--print-ready"])
        .env("HOME", &test_home)
        .env("XDG_DATA_HOME", test_home.join(".local").join("share"))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    let mut child = command.spawn().expect("spawn wallet-node");
    let stdout = child.stdout.take().expect("child stdout");
    let mut stderr = Some(child.stderr.take().expect("child stderr"));
    let mut stdout = BufReader::new(stdout).lines();

    let ready_line = match timeout(Duration::from_secs(5), stdout.next_line()).await {
        Ok(Ok(Some(line))) => line,
        Ok(Ok(None)) => {
            let stderr = read_stderr(stderr.take()).await;
            panic!("ready line should be present; stderr: {stderr}");
        }
        Ok(Err(err)) => panic!("failed to read ready line: {err}"),
        Err(_) => {
            let stderr = read_stderr(stderr.take()).await;
            panic!("ready line timeout; stderr: {stderr}");
        }
    };
    let ready: Value = serde_json::from_str(&ready_line).expect("ready event JSON");
    let _http_addr = ready["httpAddr"].as_str().expect("ready httpAddr");

    let kill_result = unsafe { libc::kill(child.id().expect("child id") as libc::pid_t, signal) };
    assert_eq!(kill_result, 0, "libc::kill failed");

    let status = timeout(Duration::from_secs(3), child.wait())
        .await
        .expect("child exit timeout")
        .expect("child wait succeeds");
    let _ = std::fs::remove_dir_all(&test_home);

    assert!(status.success(), "wallet-node exited with {status}");
}

fn http_request(addr: &str, body: &str, token: &str) -> Vec<u8> {
    format!(
        "POST / HTTP/1.1\r\nHost: {addr}\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len(),
    )
    .into_bytes()
}

async fn send_raw_http(addr: &str, request: Vec<u8>) -> String {
    let mut stream = TcpStream::connect(addr)
        .await
        .expect("connect to wallet-node");
    stream.write_all(&request).await.expect("write request");

    let mut bytes = Vec::new();
    stream.read_to_end(&mut bytes).await.expect("read response");

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

struct ReadyInfo {
    http_addr: String,
    token: String,
}

struct TestGuard {
    child: std::process::Child,
    dir: PathBuf,
}

impl Drop for TestGuard {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

async fn spawn_ready_wallet_node(test_name: &str) -> (TestGuard, ReadyInfo) {
    let dir = temp_home(test_name);
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_wallet-node"))
        .args(["--http", "127.0.0.1:0", "--print-ready"])
        .env("HOME", &dir)
        .env("XDG_DATA_HOME", dir.join(".local").join("share"))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn wallet-node");

    let stdout = child.stdout.take().expect("child stdout");
    let stderr = child.stderr.take().expect("child stderr");
    let guard = TestGuard { child, dir };
    let ready = read_ready_event(stdout, stderr).await;

    (guard, ready)
}

async fn read_ready_event(
    stdout: std::process::ChildStdout,
    stderr: std::process::ChildStderr,
) -> ReadyInfo {
    let ready_line = tokio::task::spawn_blocking(move || {
        let mut stdout = std::io::BufReader::new(stdout);
        let mut line = String::new();
        let read = stdout.read_line(&mut line).expect("read ready line");
        if read == 0 {
            let mut stderr = std::io::BufReader::new(stderr);
            let mut stderr_output = String::new();
            let _ = std::io::Read::read_to_string(&mut stderr, &mut stderr_output);
            panic!("ready line should be present; stderr: {stderr_output}");
        }
        line
    })
    .await
    .expect("ready reader task joins");

    let ready: Value = serde_json::from_str(ready_line.trim_end()).expect("ready event JSON");
    ReadyInfo {
        http_addr: ready["httpAddr"]
            .as_str()
            .expect("ready httpAddr")
            .to_owned(),
        token: ready["token"].as_str().expect("ready token").to_owned(),
    }
}

fn temp_home(test_name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "wallet-node-test-{test_name}-{:016x}",
        random_u64()
    ));
    std::fs::create_dir_all(&dir).expect("create test home");
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))
        .expect("set test home permissions");
    dir
}

fn random_u64() -> u64 {
    if let Ok(mut file) = std::fs::File::open("/dev/urandom") {
        let mut bytes = [0_u8; 8];
        if std::io::Read::read_exact(&mut file, &mut bytes).is_ok() {
            return u64::from_ne_bytes(bytes);
        }
    }

    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock should be after unix epoch")
        .as_nanos() as u64
}

async fn read_stderr(stderr: Option<tokio::process::ChildStderr>) -> String {
    let Some(mut stderr) = stderr else {
        return String::new();
    };

    let mut output = String::new();
    let _ = timeout(Duration::from_secs(1), stderr.read_to_string(&mut output)).await;
    output
}

#[tokio::test]
#[ignore = "requires TCP loopback bind capability + filesystem; run with --include-ignored"]
async fn daemon_creates_and_migrates_sqlite_on_first_launch() {
    let (mut guard, ready) = spawn_ready_wallet_node("sqlite-first-launch").await;
    let db_path = guard
        .dir
        .join("Library")
        .join("Application Support")
        .join("Local Wallet")
        .join("wallet-node")
        .join("node.sqlite");

    assert!(
        db_path.exists(),
        "sqlite database should exist at {db_path:?}"
    );

    let conn =
        rusqlite::Connection::open_with_flags(&db_path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .expect("open sqlite database read-only");
    let user_version: u32 = conn
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .expect("read sqlite user_version");
    assert_eq!(
        user_version,
        wallet_node_store::migrations::HIGHEST_MIGRATION
    );
    drop(conn);

    let shutdown = send_json_rpc(
        &ready.http_addr,
        &ready.token,
        &json!({
            "jsonrpc": "2.0",
            "method": "wallet_shutdown",
            "params": null,
            "id": 1,
        }),
    )
    .await;

    assert!(shutdown.starts_with("HTTP/1.1 200 OK"), "{shutdown}");
    let shutdown_body = response_body_json(&shutdown);
    assert_eq!(shutdown_body["result"]["ok"], true);

    let status = timeout(Duration::from_secs(3), async {
        loop {
            if let Some(status) = guard.child.try_wait().expect("child try_wait succeeds") {
                break status;
            }

            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("child exit timeout");
    assert!(status.success(), "wallet-node exited with {status}");
}
