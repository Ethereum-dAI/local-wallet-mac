//! Minimal JSON-RPC over a Unix socket, bearer-authenticated — shared by both bins.
//!
//! Transport mirrors the wallet-node daemon: one request per connection,
//! `Connection: close`, body read to EOF. The client reads to EOF for the same reason.

use std::collections::HashMap;
use std::future::Future;
use std::path::Path;
use std::pin::Pin;
use std::sync::Arc;

use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use hyper::{Request, Response};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};

/// A handler failure: a stable machine code plus human text.
///
/// The code exists because JSON-RPC's own `error.code` is a transport-level integer — every
/// handler failure is `-32000` — so without this the app can only tell "insufficient shielded
/// balance" from "the bundler's gas endpoint returned 502" by substring-matching a sentence.
/// It travels in the JSON-RPC error object's `data.code`, which is exactly what `data` is for,
/// and mirrors [`crate::exit::ExitError::code`] on the async (job-status) path so both paths
/// give the app the same kind of switchable string.
///
/// `From<String>` maps any plain-string error to code `"error"` — the same generic code
/// `ExitError::Other` uses — so a handler only names a code where it has something specific
/// to say.
///
/// `code` is a `String` rather than `&'static str` so [`call`] can reconstruct the code a peer
/// sent, making the type round-trip across the socket instead of only outbound.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RpcError {
    pub code: String,
    pub message: String,
}

/// The generic code, used whenever a handler has nothing more specific to say. Matches
/// `ExitError::Other.code()` so the two paths agree on the fallback.
pub const CODE_GENERIC: &str = "error";

impl RpcError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}

impl From<String> for RpcError {
    fn from(message: String) -> Self {
        Self::new(CODE_GENERIC, message)
    }
}

impl From<&str> for RpcError {
    fn from(message: &str) -> Self {
        Self::new(CODE_GENERIC, message)
    }
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} ({})", self.message, self.code)
    }
}

pub type RpcResult = Result<Value, RpcError>;
// Not `Send`: the RAILGUN provider (via `dyn RailgunSigner`) is not Send, so handler futures
// aren't either. That rules out `tokio::spawn`, but NOT `spawn_local` — see `serve_rpc`, which
// serves each connection as its own local task so a slow handler cannot block the listener.
pub type BoxFuture = Pin<Box<dyn Future<Output = RpcResult>>>;
pub type Handler = Arc<dyn Fn(Value) -> BoxFuture>;
pub type Handlers = HashMap<String, Handler>;

/// Pure bearer check — the unit-testable core of auth. Constant-time in the token bytes
/// (matches the wallet-node daemon's `subtle::ConstantTimeEq` convention) so a timing
/// side-channel can't reveal the token, even though the local socket makes that remote.
pub fn check_auth(auth_header: Option<&str>, token: &str) -> bool {
    use subtle::ConstantTimeEq;
    let expected = format!("Bearer {token}");
    match auth_header {
        // Length is not secret; compare bytes in constant time only when lengths match.
        Some(h) if h.len() == expected.len() => h.as_bytes().ct_eq(expected.as_bytes()).into(),
        _ => false,
    }
}

/// Serve JSON-RPC on `socket_path` until the process exits. Removes a stale socket first.
///
/// Connections are served CONCURRENTLY, each as its own `spawn_local` task. Serving them one at
/// a time was safe while every request was short, but the two-phase `unshield` API broke that
/// assumption: phase 1 holds the helper lock for ~13-28s of proving, so a `balance` request that
/// arrives during it occupies the listener while it waits on that lock, and every
/// `unshieldStatus` poll behind it cannot even be accepted — each one burning its client-side
/// timeout instead of answering. `unshieldStatus` reads only the job map and takes no helper
/// lock, so with per-connection tasks it answers straight through a prove.
///
/// The handler futures are still `!Send` and still never leave this thread; `spawn_local`
/// requires only that, which is why the `LocalSet` below is enough. Owning the `LocalSet` here
/// rather than requiring one from the caller keeps every existing call site — the two bins and
/// the tests, which all `block_on` this directly — working unchanged.
pub async fn serve_rpc(
    socket_path: &str,
    token: String,
    handlers: Handlers,
) -> std::io::Result<()> {
    let _ = std::fs::remove_file(socket_path);
    if let Some(parent) = Path::new(socket_path).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let listener = UnixListener::bind(socket_path)?;
    // Owner-only socket: defense-in-depth beyond the bearer token. Both callers already place
    // the socket in a private tempdir (`RailgunHelperDaemon` deliberately keeps it under
    // `NSTemporaryDirectory()` and puts only the state dir in Application Support), so this is
    // belt-and-braces rather than the primary control — but it costs one syscall.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(socket_path, std::fs::Permissions::from_mode(0o600))?;
    }
    // Non-Send by design (single-threaded server); shared only within this task.
    #[allow(clippy::arc_with_non_send_sync)]
    let handlers = Arc::new(handlers);
    let local = tokio::task::LocalSet::new();
    local
        .run_until(async move {
            loop {
                let (stream, _) = listener.accept().await?;
                let token = token.clone();
                let handlers = handlers.clone();
                let io = hyper_util::rt::TokioIo::new(stream);
                let service =
                    hyper::service::service_fn(move |req: Request<hyper::body::Incoming>| {
                        let token = token.clone();
                        let handlers = handlers.clone();
                        async move {
                            Ok::<_, std::convert::Infallible>(handle(req, token, handlers).await)
                        }
                    });
                // Detached: this connection makes progress on the same thread while `accept`
                // keeps running, so one slow handler no longer delays every later request.
                tokio::task::spawn_local(async move {
                    if let Err(e) = hyper::server::conn::http1::Builder::new()
                        .serve_connection(io, service)
                        .await
                    {
                        tracing::debug!("connection error: {e}");
                    }
                });
            }
        })
        .await
}

async fn handle(
    req: Request<hyper::body::Incoming>,
    token: String,
    handlers: Arc<Handlers>,
) -> Response<Full<Bytes>> {
    let auth = req
        .headers()
        .get(hyper::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned);
    if !check_auth(auth.as_deref(), &token) {
        return resp(401, Bytes::new());
    }
    let body = match req.collect().await {
        Ok(b) => b.to_bytes(),
        Err(_) => {
            return json_resp(
                json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"read error"}}),
            )
        }
    };
    let reqv: Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(e) => {
            return json_resp(
                json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":e.to_string()}}),
            )
        }
    };
    let id = reqv.get("id").cloned().unwrap_or(Value::Null);
    let method = reqv.get("method").and_then(|m| m.as_str()).unwrap_or("");
    let params = reqv.get("params").cloned().unwrap_or(Value::Null);

    match handlers.get(method) {
        None => json_resp(
            json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":format!("unknown method: {method}")}}),
        ),
        Some(h) => match h(params).await {
            Ok(result) => json_resp(json!({"jsonrpc":"2.0","id":id,"result":result})),
            Err(e) => {
                tracing::warn!("handler error for {method}: {e}");
                // `data.code` is the stable, switchable code; `-32000` stays the transport-level
                // "server error" every handler failure carries.
                json_resp(json!({"jsonrpc":"2.0","id":id,"error":{
                    "code": -32000,
                    "message": e.message,
                    "data": {"code": e.code},
                }}))
            }
        },
    }
}

fn json_resp(v: Value) -> Response<Full<Bytes>> {
    resp(200, Bytes::from(serde_json::to_vec(&v).unwrap()))
}

fn resp(status: u16, body: Bytes) -> Response<Full<Bytes>> {
    Response::builder()
        .status(status)
        .header(hyper::header::CONNECTION, "close")
        .header(hyper::header::CONTENT_TYPE, "application/json")
        .body(Full::new(body))
        .unwrap()
}

/// Register a `(String, Handler)` from an async closure — ergonomic handler construction.
#[macro_export]
macro_rules! rpc_handler {
    ($f:expr) => {{
        let f = $f;
        ::std::sync::Arc::new(move |params: ::serde_json::Value| {
            ::std::boxed::Box::pin(f(params)) as $crate::rpc::BoxFuture
        }) as $crate::rpc::Handler
    }};
}

/// Minimal Unix-socket JSON-RPC client: connects, sends one request, reads to EOF.
///
/// Returns the parsed `result`, or an [`RpcError`] carrying the peer's `error.message` AND the
/// stable `error.data.code` the handler set — so a Rust caller can switch on the code instead
/// of matching the sentence, exactly like the app does. Transport/parse failures on our side
/// read as [`CODE_GENERIC`].
pub async fn call(
    socket_path: &str,
    token: &str,
    method: &str,
    params: Value,
) -> Result<Value, RpcError> {
    let mut stream = UnixStream::connect(socket_path)
        .await
        .map_err(|e| format!("connect {socket_path}: {e}"))?;
    let body = json!({"jsonrpc":"2.0","id":1,"method":method,"params":params}).to_string();
    let req = format!(
        "POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream
        .write_all(req.as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    stream.flush().await.map_err(|e| e.to_string())?;
    let mut buf = Vec::new();
    stream
        .read_to_end(&mut buf)
        .await
        .map_err(|e| e.to_string())?;

    let text = String::from_utf8_lossy(&buf);
    let (head, payload) = text
        .split_once("\r\n\r\n")
        .ok_or_else(|| format!("malformed HTTP response: {text}"))?;
    let status_ok = head
        .lines()
        .next()
        .map(|l| l.contains(" 200"))
        .unwrap_or(false);
    if !status_ok {
        // A non-200 (e.g. 401 from a bad bearer token) has no JSON body to carry a domain code.
        return Err(format!("HTTP error: {}", head.lines().next().unwrap_or("")).into());
    }
    let v: Value = serde_json::from_str(payload.trim())
        .map_err(|e| format!("bad JSON body: {e}: {payload}"))?;
    if let Some(err) = v.get("error") {
        let message = err
            .get("message")
            .and_then(|m| m.as_str())
            .unwrap_or("rpc error");
        // A peer that sends no `data.code` (or a transport-level JSON-RPC error like a parse
        // failure) has no domain code to recover, so it reads as generic.
        let code = err
            .get("data")
            .and_then(|d| d.get("code"))
            .and_then(|c| c.as_str())
            .unwrap_or(CODE_GENERIC);
        return Err(RpcError::new(code, message));
    }
    Ok(v.get("result").cloned().unwrap_or(Value::Null))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auth_accepts_matching_bearer() {
        assert!(check_auth(Some("Bearer abc"), "abc"));
    }
    #[test]
    fn auth_rejects_wrong_or_missing() {
        assert!(!check_auth(Some("Bearer abc"), "xyz"));
        assert!(!check_auth(Some("abc"), "abc"));
        assert!(!check_auth(None, "abc"));
    }

    #[tokio::test]
    async fn server_rejects_without_token_and_serves_with_it() {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("t.sock").to_string_lossy().to_string();
        // Handlers are non-Send, so build them INSIDE the server thread (nothing non-Send
        // crosses the boundary) and run the server on a current-thread runtime — exactly
        // how the bins run it via block_on.
        let sock2 = sock.clone();
        std::thread::spawn(move || {
            let mut handlers: Handlers = HashMap::new();
            handlers.insert(
                "echo".to_string(),
                rpc_handler!(|p: Value| async move { Ok(p) }),
            );
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            rt.block_on(async move {
                serve_rpc(&sock2, "tok".to_string(), handlers)
                    .await
                    .unwrap();
            });
        });
        // wait for bind
        for _ in 0..50 {
            if UnixStream::connect(&sock).await.is_ok() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        // wrong token → error
        let bad = call(&sock, "wrong", "echo", json!({"a":1})).await;
        assert!(bad.is_err(), "wrong token must fail: {bad:?}");
        // right token → echoes params
        let ok = call(&sock, "tok", "echo", json!({"a":1})).await.unwrap();
        assert_eq!(ok, json!({"a":1}));
        // unknown method → error
        let unk = call(&sock, "tok", "nope", json!(null)).await;
        assert!(unk.is_err());
    }

    #[tokio::test]
    async fn a_slow_handler_does_not_block_a_later_request() {
        // The regression this guards: `serve_rpc` used to `await serve_connection` inline, so
        // one in-flight request owned the listener. That was invisible while every handler was
        // fast, and became a real bug once phase-1 `unshield` held the helper lock for ~13-28s
        // of proving — a `balance` call arriving in that window stalled the accept loop, and the
        // app's `unshieldStatus` polls behind it could not even be accepted, each burning its
        // client-side timeout. `unshieldStatus` needs no helper lock, so it MUST answer during a
        // prove. Asserting concurrency, not latency: `fast` completes while `slow` is parked.
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("c.sock").to_string_lossy().to_string();
        let sock2 = sock.clone();
        std::thread::spawn(move || {
            let mut handlers: Handlers = HashMap::new();
            handlers.insert(
                "slow".to_string(),
                rpc_handler!(|_p: Value| async move {
                    tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                    Ok(json!("never observed"))
                }),
            );
            handlers.insert(
                "fast".to_string(),
                rpc_handler!(|_p: Value| async move { Ok(json!("quick")) }),
            );
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            rt.block_on(async move {
                serve_rpc(&sock2, "tok".to_string(), handlers)
                    .await
                    .unwrap();
            });
        });
        for _ in 0..50 {
            if UnixStream::connect(&sock).await.is_ok() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        // Park a 30s handler on its own connection and leave it in flight.
        let slow_sock = sock.clone();
        let slow = tokio::spawn(async move { call(&slow_sock, "tok", "slow", json!(null)).await });
        // Give the server a moment to accept it, so `fast` genuinely queues behind it.
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;

        // Generous relative to `fast` (instant) but far below the 30s park, so passing cannot
        // mean "the slow handler finished first".
        let fast = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            call(&sock, "tok", "fast", json!(null)),
        )
        .await
        .expect("a fast request must not wait behind an in-flight slow one")
        .unwrap();
        assert_eq!(fast, json!("quick"));

        slow.abort();
    }

    #[tokio::test]
    async fn handler_error_codes_round_trip_over_the_socket() {
        // The whole point of RpcError: a caller must be able to switch on a stable code rather
        // than substring-match the message. If `data.code` were dropped anywhere between the
        // handler and the client, every distinct failure would collapse into one -32000 blob.
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("e.sock").to_string_lossy().to_string();
        let sock2 = sock.clone();
        std::thread::spawn(move || {
            let mut handlers: Handlers = HashMap::new();
            handlers.insert(
                "coded".to_string(),
                rpc_handler!(|_p: Value| async move {
                    Err(RpcError::new(
                        "insufficientShieldedBalance",
                        "5 wei exceeds the spendable maximum 3 wei",
                    ))
                }),
            );
            // A handler that fails with a plain String must land on the generic code.
            handlers.insert(
                "plain".to_string(),
                rpc_handler!(|_p: Value| async move {
                    Err::<Value, RpcError>("something broke".to_string().into())
                }),
            );
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            rt.block_on(async move {
                serve_rpc(&sock2, "tok".to_string(), handlers)
                    .await
                    .unwrap();
            });
        });
        for _ in 0..50 {
            if UnixStream::connect(&sock).await.is_ok() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }

        let e = call(&sock, "tok", "coded", json!(null))
            .await
            .expect_err("must fail");
        assert_eq!(e.code, "insufficientShieldedBalance");
        assert_eq!(e.message, "5 wei exceeds the spendable maximum 3 wei");

        let e = call(&sock, "tok", "plain", json!(null))
            .await
            .expect_err("must fail");
        assert_eq!(e.code, CODE_GENERIC);
        assert_eq!(e.message, "something broke");

        // An unknown method is a transport-level JSON-RPC error with no `data`, so it reads
        // generic rather than panicking or inventing a code.
        let e = call(&sock, "tok", "nope", json!(null))
            .await
            .expect_err("must fail");
        assert_eq!(e.code, CODE_GENERIC);
    }
}
