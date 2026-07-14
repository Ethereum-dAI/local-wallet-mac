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

pub type RpcResult = Result<Value, String>;
// Not `Send`: the RAILGUN provider (via `dyn RailgunSigner`) is not Send, so handler
// futures aren't either. The server therefore handles connections sequentially on the
// runtime's block_on task (never moved across threads) rather than spawning per-conn —
// fine for a single-user sidecar, and requests are naturally serialized anyway.
pub type BoxFuture = Pin<Box<dyn Future<Output = RpcResult>>>;
pub type Handler = Arc<dyn Fn(Value) -> BoxFuture>;
pub type Handlers = HashMap<String, Handler>;

/// Pure bearer check — the unit-testable core of auth.
pub fn check_auth(auth_header: Option<&str>, token: &str) -> bool {
    match auth_header {
        Some(h) => h == format!("Bearer {token}"),
        None => false,
    }
}

/// Serve JSON-RPC on `socket_path` until the process exits. Removes a stale socket first.
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
    // Non-Send by design (single-threaded server); shared only within this task.
    #[allow(clippy::arc_with_non_send_sync)]
    let handlers = Arc::new(handlers);
    loop {
        let (stream, _) = listener.accept().await?;
        let token = token.clone();
        let handlers = handlers.clone();
        let io = hyper_util::rt::TokioIo::new(stream);
        let service = hyper::service::service_fn(move |req: Request<hyper::body::Incoming>| {
            let token = token.clone();
            let handlers = handlers.clone();
            async move { Ok::<_, std::convert::Infallible>(handle(req, token, handlers).await) }
        });
        // Handle this connection to completion before accepting the next (see BoxFuture note).
        if let Err(e) = hyper::server::conn::http1::Builder::new()
            .serve_connection(io, service)
            .await
        {
            tracing::debug!("connection error: {e}");
        }
    }
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
                json_resp(json!({"jsonrpc":"2.0","id":id,"error":{"code":-32000,"message":e}}))
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
/// Returns the parsed `result` value, or an error carrying the RPC `error.message`.
pub async fn call(
    socket_path: &str,
    token: &str,
    method: &str,
    params: Value,
) -> Result<Value, String> {
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
        return Err(format!("HTTP error: {}", head.lines().next().unwrap_or("")));
    }
    let v: Value = serde_json::from_str(payload.trim())
        .map_err(|e| format!("bad JSON body: {e}: {payload}"))?;
    if let Some(err) = v.get("error") {
        return Err(err
            .get("message")
            .and_then(|m| m.as_str())
            .unwrap_or("rpc error")
            .to_string());
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
}
