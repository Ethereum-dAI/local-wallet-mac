use std::{io, net::SocketAddr, sync::Arc};

use bytes::Bytes;
use http_body_util::Full;
use hyper::body::Incoming;
use hyper::http::header::AUTHORIZATION;
use hyper::http::{Request, Response};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper_util::rt::TokioIo;
use thiserror::Error;
use tokio::net::TcpListener;
use tokio::sync::{oneshot, watch, Semaphore};
use tokio::task::JoinSet;
use tokio::{io::AsyncWriteExt, time::timeout};

use super::handler::{
    body_too_large_response, can_accept_connection, drain_with_deadline, read_body_limited,
    with_connection_deadline, DrainResult, Handler, REQUEST_DEADLINE,
};
use super::TransportError;

const SHUTDOWN_DRAIN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);
const CONNECTION_CAP_RETRY_AFTER_SECONDS: u64 = 1;
const MAX_REJECTION_WRITERS: usize = 16;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum BindError {
    #[error("refusing non-loopback HTTP bind address {addr}; pass --allow-public to allow public HTTP binds")]
    NonLoopbackRequiresAllowPublic { addr: SocketAddr },
}

pub fn validate_bind_address(bind_addr: SocketAddr, allow_public: bool) -> Result<(), BindError> {
    if !allow_public && !bind_addr.ip().is_loopback() {
        return Err(BindError::NonLoopbackRequiresAllowPublic { addr: bind_addr });
    }

    Ok(())
}

pub async fn serve(
    bind_addr: SocketAddr,
    allow_public: bool,
    handler: Handler,
    ready_addr_tx: Option<oneshot::Sender<SocketAddr>>,
    mut shutdown: watch::Receiver<bool>,
) -> Result<(), TransportError> {
    validate_bind_address(bind_addr, allow_public).map_err(|err| {
        TransportError::BindFailed(io::Error::new(io::ErrorKind::PermissionDenied, err))
    })?;

    let listener = TcpListener::bind(bind_addr)
        .await
        .map_err(TransportError::BindFailed)?;
    let local_addr = listener.local_addr()?;
    if allow_public && !local_addr.ip().is_loopback() {
        eprintln!(
            "warning: wallet-node HTTP transport is bound to non-loopback address {local_addr}; authenticated local-wallet APIs may be reachable from other hosts"
        );
    }
    let mut connections = JoinSet::new();
    let rejection_writers = Arc::new(Semaphore::new(MAX_REJECTION_WRITERS));

    if let Some(tx) = ready_addr_tx {
        let _ = tx.send(local_addr);
    }

    loop {
        tokio::select! {
            changed = shutdown.changed() => {
                match changed {
                    Ok(()) | Err(_) => break,
                }
            }
            joined = connections.join_next(), if !connections.is_empty() => {
                if let Some(Err(err)) = joined {
                    eprintln!("wallet-node http connection task failed: {err}");
                }
            }
            accepted = listener.accept() => {
                let (stream, _) = accepted?;
                if !can_accept_connection(connections.len()) {
                    tracing::warn!(
                        event = "wallet_node_http_connection_limit_reached",
                        active_connections = connections.len(),
                        "dropping HTTP connection because the active connection cap was reached"
                    );
                    if let Ok(permit) = rejection_writers.clone().try_acquire_owned() {
                        tokio::spawn(async move {
                            reject_connection_cap(stream).await;
                            drop(permit);
                        });
                    }
                    continue;
                }
                let connection_handler = handler.clone();

                connections.spawn(async move {
                    let io = TokioIo::new(stream);
                    let service = service_fn(move |request| {
                        handle_request(request, connection_handler.clone())
                    });

                    match with_connection_deadline(
                        REQUEST_DEADLINE,
                        http1::Builder::new()
                        .keep_alive(false)
                        .serve_connection(io, service),
                    )
                    .await
                    {
                        Ok(Ok(())) => {}
                        Ok(Err(err)) => eprintln!("wallet-node http connection failed: {err}"),
                        Err(_) => tracing::warn!(
                            event = "wallet_node_http_connection_timed_out",
                            deadline_ms = REQUEST_DEADLINE.as_millis(),
                            "closing HTTP connection after request deadline"
                        ),
                    }
                });
            }
        }
    }

    drop(listener);
    if let DrainResult::TimedOut(remaining) =
        drain_with_deadline(&mut connections, SHUTDOWN_DRAIN_TIMEOUT).await
    {
        tracing::warn!(
            N = remaining,
            "shutdown drain timed out; {remaining} tasks aborted"
        );
        connections.abort_all();
        connections.shutdown().await;
    }

    Ok(())
}

async fn reject_connection_cap(mut stream: tokio::net::TcpStream) {
    let body = format!(
        r#"{{"jsonrpc":"2.0","error":{{"code":{},"message":"Service unavailable: connection cap"}},"id":null}}"#,
        wallet_node_api::SERVICE_UNAVAILABLE
    );
    let response = format!(
        "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nRetry-After: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        CONNECTION_CAP_RETRY_AFTER_SECONDS,
        body.len(),
        body
    );
    let _ = timeout(
        std::time::Duration::from_secs(CONNECTION_CAP_RETRY_AFTER_SECONDS),
        stream.write_all(response.as_bytes()),
    )
    .await;
}

async fn handle_request(
    request: Request<Incoming>,
    handler: Handler,
) -> Result<Response<Full<Bytes>>, hyper::Error> {
    let auth_header = request
        .headers()
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .map(ToOwned::to_owned);

    let max_body_bytes = handler.max_request_body_bytes();
    match read_body_limited(request.into_body(), max_body_bytes).await? {
        Ok(body) => Ok(handler.handle(body, auth_header).await),
        Err(actual) => Ok(body_too_large_response(actual, max_body_bytes)),
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::Arc;

    use serde_json::Value;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpStream;
    use tokio::task::JoinSet;

    use super::*;
    use crate::auth::Token;
    use crate::config::Config;
    use crate::paths::Paths;
    use crate::state::{DaemonState, TransportInfo};
    use crate::transport::handler::DrainResult;

    #[test]
    fn bind_validation_accepts_loopback_v4_without_allow_public() {
        let addr = "127.0.0.1:0".parse().expect("parse socket addr");

        assert_eq!(validate_bind_address(addr, false), Ok(()));
    }

    #[test]
    fn bind_validation_accepts_loopback_v6_without_allow_public() {
        let addr = "[::1]:0".parse().expect("parse socket addr");

        assert_eq!(validate_bind_address(addr, false), Ok(()));
    }

    #[test]
    fn bind_validation_rejects_non_loopback_without_allow_public() {
        let addr = "0.0.0.0:0".parse().expect("parse socket addr");

        assert_eq!(
            validate_bind_address(addr, false),
            Err(BindError::NonLoopbackRequiresAllowPublic { addr })
        );
    }

    #[test]
    fn bind_validation_accepts_non_loopback_with_allow_public() {
        let addr = "0.0.0.0:0".parse().expect("parse socket addr");

        assert_eq!(validate_bind_address(addr, true), Ok(()));
    }

    #[test]
    fn bind_validation_rejects_lan_without_allow_public() {
        let addr = "192.168.1.10:0".parse().expect("parse socket addr");

        assert_eq!(
            validate_bind_address(addr, false),
            Err(BindError::NonLoopbackRequiresAllowPublic { addr })
        );
    }

    #[tokio::test]
    #[ignore = "requires TCP loopback bind capability; run with --include-ignored"]
    async fn bind_picks_ephemeral_port_when_zero() {
        let handler = test_handler(Arc::new(Token::generate()));
        let (ready_tx, ready_rx) = oneshot::channel();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);

        let server = tokio::spawn(serve(
            "127.0.0.1:0".parse().expect("parse socket addr"),
            false,
            handler,
            Some(ready_tx),
            shutdown_rx,
        ));

        let addr = ready_rx.await.expect("server ready");
        assert_ne!(addr.port(), 0);

        shutdown_tx.send(true).expect("send shutdown");
        let result = server.await.expect("server task joins");
        assert!(result.is_ok(), "serve returned {result:?}");
    }

    #[tokio::test]
    #[ignore = "requires TCP loopback bind capability; run with --include-ignored"]
    async fn wallet_health_returns_phase_one_health_shape() {
        let token = Arc::new(Token::generate());
        let handler = test_handler(token.clone());
        let (ready_tx, ready_rx) = oneshot::channel();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);

        let server = tokio::spawn(serve(
            "127.0.0.1:0".parse().expect("parse socket addr"),
            false,
            handler,
            Some(ready_tx),
            shutdown_rx,
        ));
        let addr = ready_rx.await.expect("server ready");
        let body = r#"{"jsonrpc":"2.0","method":"wallet_health","params":null,"id":1}"#;
        let request = http_request(addr, body, Some(&format!("Bearer {}", token.encoded())));

        let response = send_raw_http(addr, request).await;

        assert!(response.starts_with("HTTP/1.1 200 OK"), "{response}");
        let value = response_body_json(&response);
        assert_eq!(value["result"]["status"], "starting");
        assert_eq!(value["result"]["apiVersion"], 1);
        assert_eq!(value["result"]["chainId"], 1);

        shutdown_tx.send(true).expect("send shutdown");
        let result = server.await.expect("server task joins");
        assert!(result.is_ok(), "serve returned {result:?}");
    }

    #[tokio::test]
    #[ignore = "requires TCP loopback bind capability; run with --include-ignored"]
    async fn wallet_shutdown_returns_ok_and_signals_shutdown() {
        let token = Arc::new(Token::generate());
        let (ready_tx, ready_rx) = oneshot::channel();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let mut observed_shutdown_rx = shutdown_rx.clone();
        let handler = Handler {
            state: test_state(token.clone(), shutdown_tx),
        };

        let server = tokio::spawn(serve(
            "127.0.0.1:0".parse().expect("parse socket addr"),
            false,
            handler,
            Some(ready_tx),
            shutdown_rx,
        ));
        let addr = ready_rx.await.expect("server ready");
        let body = r#"{"jsonrpc":"2.0","method":"wallet_shutdown","params":null,"id":1}"#;
        let request = http_request(addr, body, Some(&format!("Bearer {}", token.encoded())));

        let response = send_raw_http(addr, request).await;

        assert!(response.starts_with("HTTP/1.1 200 OK"), "{response}");
        let value = response_body_json(&response);
        assert_eq!(value["result"]["ok"], true);
        observed_shutdown_rx
            .changed()
            .await
            .expect("shutdown signal");
        assert!(*observed_shutdown_rx.borrow());

        let result = server.await.expect("server task joins");
        assert!(result.is_ok(), "serve returned {result:?}");
    }

    #[tokio::test]
    async fn slow_handler_completes_during_drain() {
        // Exercise the shared drain primitive directly instead of going through
        // TCP/hyper so the test stays deterministic and does not depend on
        // socket scheduling or connection internals.
        let mut set = JoinSet::new();
        set.spawn(async {
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        });

        let result = drain_with_deadline(&mut set, std::time::Duration::from_secs(1)).await;

        assert_eq!(result, DrainResult::Completed);
    }

    #[tokio::test]
    #[ignore = "requires TCP loopback bind capability; run with --include-ignored"]
    async fn shutdown_completes_within_2_seconds_after_signal() {
        let handler = test_handler(Arc::new(Token::generate()));
        let (shutdown_tx, shutdown_rx) = watch::channel(false);

        let server = tokio::spawn(serve(
            "127.0.0.1:0".parse().expect("parse socket addr"),
            false,
            handler,
            None,
            shutdown_rx,
        ));

        shutdown_tx.send(true).expect("send shutdown");
        let result = tokio::time::timeout(std::time::Duration::from_secs(3), server)
            .await
            .expect("server exits before timeout")
            .expect("server task joins");

        assert!(result.is_ok(), "serve returned {result:?}");
    }

    #[tokio::test]
    #[ignore = "requires TCP loopback bind capability; run with --include-ignored"]
    async fn rejects_unauth_request_with_401() {
        let handler = test_handler(Arc::new(Token::generate()));
        let (ready_tx, ready_rx) = oneshot::channel();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);

        let server = tokio::spawn(serve(
            "127.0.0.1:0".parse().expect("parse socket addr"),
            false,
            handler,
            Some(ready_tx),
            shutdown_rx,
        ));
        let addr = ready_rx.await.expect("server ready");
        let body = r#"{"jsonrpc":"2.0","method":"wallet_health","params":null,"id":1}"#;
        let request = http_request(addr, body, None);

        let response = send_raw_http(addr, request).await;

        assert!(
            response.starts_with("HTTP/1.1 401 Unauthorized"),
            "{response}"
        );
        assert_eq!(response_error_code(&response), -32001);

        shutdown_tx.send(true).expect("send shutdown");
        let result = server.await.expect("server task joins");
        assert!(result.is_ok(), "serve returned {result:?}");
    }

    fn test_handler(token: Arc<Token>) -> Handler {
        let (shutdown_tx, _shutdown_rx) = watch::channel(false);
        Handler {
            state: test_state(token, shutdown_tx),
        }
    }

    fn http_request(addr: SocketAddr, body: &str, auth_header: Option<&str>) -> Vec<u8> {
        let auth = auth_header
            .map(|value| format!("Authorization: {value}\r\n"))
            .unwrap_or_default();
        format!(
            "POST / HTTP/1.1\r\nHost: {addr}\r\n{auth}Content-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len(),
        )
        .into_bytes()
    }

    async fn send_raw_http(addr: SocketAddr, request: Vec<u8>) -> String {
        let mut stream = TcpStream::connect(addr).await.expect("connect to server");
        stream.write_all(&request).await.expect("write request");

        let mut bytes = Vec::new();
        stream.read_to_end(&mut bytes).await.expect("read response");

        String::from_utf8(bytes).expect("response is UTF-8")
    }

    fn response_error_code(response: &str) -> i64 {
        let value = response_body_json(response);
        value["error"]["code"].as_i64().expect("numeric error code")
    }

    fn response_body_json(response: &str) -> Value {
        let (_, body) = response.split_once("\r\n\r\n").expect("response has body");
        serde_json::from_str(body).expect("response body is JSON")
    }

    fn test_state(token: Arc<Token>, shutdown_tx: watch::Sender<bool>) -> Arc<DaemonState> {
        Arc::new(DaemonState::new(
            token,
            Arc::new(Config::default()),
            Arc::new(Paths {
                app_support_dir: PathBuf::from("/tmp/wallet-node-test"),
                socket_path: PathBuf::from("/tmp/wallet-node-test/wallet-node.sock"),
                db_path: PathBuf::from("/tmp/wallet-node-test/node.sqlite"),
                helios_dir: PathBuf::from("/tmp/wallet-node-test/helios"),
                logs_dir: PathBuf::from("/tmp/wallet-node-test/logs"),
                config_path: PathBuf::from("/tmp/wallet-node-test/config.toml"),
            }),
            shutdown_tx,
            TransportInfo::http(),
        ))
    }
}
