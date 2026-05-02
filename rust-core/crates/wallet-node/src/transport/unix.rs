use std::io;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

use bytes::Bytes;
use http_body_util::Full;
use hyper::body::Incoming;
use hyper::http::header::AUTHORIZATION;
use hyper::http::{Request, Response};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper_util::rt::TokioIo;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::watch;
use tokio::task::JoinSet;
use tokio::time::timeout;

use super::handler::{
    body_too_large_response, drain_with_deadline, read_body_limited, DrainResult, Handler,
};
use super::TransportError;

const STALE_SOCKET_CONNECT_TIMEOUT: Duration = Duration::from_millis(200);
const SHUTDOWN_DRAIN_TIMEOUT: Duration = Duration::from_secs(2);

pub async fn serve(
    socket_path: PathBuf,
    handler: Handler,
    mut shutdown: watch::Receiver<bool>,
) -> Result<(), TransportError> {
    check_stale_socket(&socket_path).await?;

    let listener = UnixListener::bind(&socket_path).map_err(TransportError::BindFailed)?;
    let mut connections = JoinSet::new();

    let parent = socket_path.parent().ok_or_else(|| {
        TransportError::Io(io::Error::new(
            io::ErrorKind::InvalidInput,
            "socket path has no parent directory",
        ))
    })?;
    let mode = std::fs::metadata(parent)?.permissions().mode() & 0o777;
    if mode != 0o700 {
        return Err(TransportError::ParentDirPermissionsTooLoose {
            path: parent.to_path_buf(),
            mode,
        });
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
                    eprintln!("wallet-node unix connection task failed: {err}");
                }
            }
            accepted = listener.accept() => {
                let (stream, _) = accepted?;
                let connection_handler = handler.clone();

                connections.spawn(async move {
                    let io = TokioIo::new(stream);
                    let service = service_fn(move |request| {
                        handle_request(request, connection_handler.clone())
                    });

                    if let Err(err) = http1::Builder::new()
                        .keep_alive(false)
                        .serve_connection(io, service)
                        .await
                    {
                        eprintln!("wallet-node unix connection failed: {err}");
                    }
                });
            }
        }
    }

    drop(listener);
    match tokio::fs::remove_file(&socket_path).await {
        Ok(()) => {}
        Err(err) if err.kind() == io::ErrorKind::NotFound => {}
        Err(err) => tracing::warn!("failed to remove unix socket during shutdown: {err}"),
    }

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

async fn check_stale_socket(socket_path: &Path) -> Result<(), TransportError> {
    let metadata = match tokio::fs::symlink_metadata(socket_path).await {
        Ok(metadata) => metadata,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(source) => {
            return Err(TransportError::StaleSocketCheckFailed {
                path: socket_path.to_path_buf(),
                source,
            });
        }
    };
    let file_type = metadata.file_type();

    if file_type.is_symlink() {
        return Err(TransportError::StaleSocketCheckFailed {
            path: socket_path.to_path_buf(),
            source: io::Error::new(io::ErrorKind::Other, "unexpected symlink at socket path"),
        });
    }

    if !file_type.is_socket() {
        tokio::fs::remove_file(socket_path).await?;
        return Ok(());
    }

    match timeout(
        STALE_SOCKET_CONNECT_TIMEOUT,
        UnixStream::connect(socket_path),
    )
    .await
    {
        Ok(Ok(_stream)) => Err(TransportError::LiveSocketDetected {
            path: socket_path.to_path_buf(),
        }),
        Ok(Err(err)) if is_stale_socket_error(&err) => {
            match tokio::fs::remove_file(socket_path).await {
                Ok(()) => Ok(()),
                Err(remove_err) if remove_err.kind() == io::ErrorKind::NotFound => Ok(()),
                Err(remove_err) => Err(TransportError::Io(remove_err)),
            }
        }
        Ok(Err(source)) => Err(TransportError::StaleSocketCheckFailed {
            path: socket_path.to_path_buf(),
            source,
        }),
        Err(_elapsed) => Err(TransportError::LiveSocketDetected {
            path: socket_path.to_path_buf(),
        }),
    }
}

fn is_stale_socket_error(err: &io::Error) -> bool {
    matches!(
        err.kind(),
        io::ErrorKind::ConnectionRefused | io::ErrorKind::NotFound
    )
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
    use std::os::unix::fs::FileTypeExt;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    use http_body_util::BodyExt;
    use hyper::StatusCode;
    use serde_json::{json, Value};
    use tokio::task::JoinSet;

    use super::*;
    use crate::auth::Token;
    use crate::config::Config;
    use crate::paths::Paths;
    use crate::state::{DaemonState, TransportInfo};
    use crate::transport::handler::{DrainResult, Handler};

    static NEXT_TEMP_ID: AtomicUsize = AtomicUsize::new(0);

    #[tokio::test]
    #[ignore = "requires AF_UNIX bind capability; run with --include-ignored"]
    async fn bind_succeeds_when_no_socket_exists() {
        let tempdir = temp_dir("bind_succeeds_when_no_socket_exists");
        let socket_path = tempdir.join("wallet-node.sock");
        let handler = test_handler();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);

        let server = tokio::spawn(serve(socket_path, handler, shutdown_rx));
        tokio::task::yield_now().await;
        shutdown_tx.send(true).expect("send shutdown");

        let result = server.await.expect("server task joins");
        assert!(result.is_ok(), "serve returned {result:?}");
    }

    #[tokio::test]
    #[ignore = "requires AF_UNIX bind capability; run with --include-ignored"]
    async fn bind_unlinks_stale_socket_file() {
        let tempdir = temp_dir("bind_unlinks_stale_socket_file");
        let socket_path = tempdir.join("wallet-node.sock");
        tokio::fs::write(&socket_path, b"stale")
            .await
            .expect("write stale socket placeholder");
        let handler = test_handler();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);

        let server = tokio::spawn(serve(socket_path.clone(), handler, shutdown_rx));
        wait_for_socket_recreated(&socket_path).await;
        shutdown_tx.send(true).expect("send shutdown");

        let result = server.await.expect("server task joins");
        assert!(result.is_ok(), "serve returned {result:?}");
        let err = tokio::fs::metadata(&socket_path)
            .await
            .expect_err("socket removed on shutdown");
        assert_eq!(err.kind(), io::ErrorKind::NotFound);
    }

    #[tokio::test]
    #[ignore = "requires AF_UNIX bind capability; run with --include-ignored"]
    async fn bind_refuses_live_listener() {
        let tempdir = temp_dir("bind_refuses_live_listener");
        let socket_path = tempdir.join("wallet-node.sock");
        let _live_listener = UnixListener::bind(&socket_path).expect("bind live listener");
        let handler = test_handler();
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);

        let result = serve(socket_path.clone(), handler, shutdown_rx).await;

        assert!(matches!(
            result,
            Err(TransportError::LiveSocketDetected { path }) if path == socket_path
        ));
    }

    #[tokio::test]
    async fn slow_connection_completes_during_drain() {
        let mut set = JoinSet::new();
        set.spawn(async {
            tokio::time::sleep(Duration::from_millis(50)).await;
        });

        let result = drain_with_deadline(&mut set, Duration::from_secs(1)).await;

        assert_eq!(result, DrainResult::Completed);
    }

    #[tokio::test]
    async fn body_size_cap_returns_413_with_minus_32012() {
        let (handler, auth_header) = test_handler_with_auth();
        let body = Bytes::from(vec![b'x'; 300_000]);

        let response = handler.handle(body, Some(auth_header)).await;

        assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(response_error_code(response).await, -32012);
    }

    #[tokio::test]
    async fn missing_auth_returns_401_with_minus_32001() {
        let (handler, _) = test_handler_with_auth();
        let body = valid_request("wallet_health");

        let response = handler.handle(body, None).await;

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(response_error_code(response).await, -32001);
    }

    #[tokio::test]
    async fn unknown_method_returns_minus_32601() {
        let (handler, auth_header) = test_handler_with_auth();

        let response = handler
            .handle(valid_request("totally_made_up"), Some(auth_header))
            .await;

        assert_eq!(response.status(), StatusCode::OK);
        let value = response_json(response).await;
        assert_eq!(value["error"]["code"], -32601);
        assert_eq!(value["error"]["data"]["method"], "totally_made_up");
    }

    #[tokio::test]
    async fn wallet_health_returns_phase_one_health_shape() {
        let (handler, auth_header) = test_handler_with_auth();

        let response = handler
            .handle(valid_request("wallet_health"), Some(auth_header))
            .await;

        assert_eq!(response.status(), StatusCode::OK);
        let value = response_json(response).await;
        assert_eq!(value["result"]["status"], "starting");
        assert_eq!(value["result"]["apiVersion"], 1);
        assert_eq!(value["result"]["chainId"], 1);
    }

    #[tokio::test]
    async fn wallet_shutdown_returns_ok_and_signals_shutdown() {
        let (shutdown_tx, mut shutdown_rx) = watch::channel(false);
        let token = Arc::new(Token::generate());
        let auth_header = format!("Bearer {}", token.encoded());
        let handler = Handler {
            state: test_state(token, TransportInfo::unix(), shutdown_tx),
        };

        let response = handler
            .handle(valid_request("wallet_shutdown"), Some(auth_header))
            .await;

        assert_eq!(response.status(), StatusCode::OK);
        let value = response_json(response).await;
        assert_eq!(value["result"]["ok"], true);
        shutdown_rx.changed().await.expect("shutdown signal");
        assert!(*shutdown_rx.borrow());
    }

    fn test_handler() -> Handler {
        let (shutdown_tx, _shutdown_rx) = watch::channel(false);
        Handler {
            state: test_state(
                Arc::new(Token::generate()),
                TransportInfo::unix(),
                shutdown_tx,
            ),
        }
    }

    fn test_handler_with_auth() -> (Handler, String) {
        let token = Arc::new(Token::generate());
        let auth_header = format!("Bearer {}", token.encoded());
        let (shutdown_tx, _shutdown_rx) = watch::channel(false);
        (
            Handler {
                state: test_state(token, TransportInfo::unix(), shutdown_tx),
            },
            auth_header,
        )
    }

    fn test_state(
        token: Arc<Token>,
        transport: TransportInfo,
        shutdown_tx: watch::Sender<bool>,
    ) -> Arc<DaemonState> {
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
            transport,
        ))
    }

    fn valid_request(method: &str) -> Bytes {
        Bytes::from(
            serde_json::to_vec(&json!({
                "jsonrpc": "2.0",
                "method": method,
                "params": null,
                "id": 1,
            }))
            .expect("serialize request"),
        )
    }

    async fn response_error_code(response: Response<Full<Bytes>>) -> i64 {
        response_json(response).await["error"]["code"]
            .as_i64()
            .expect("numeric error code")
    }

    async fn response_json(response: Response<Full<Bytes>>) -> Value {
        let bytes = response
            .into_body()
            .collect()
            .await
            .expect("collect response body")
            .to_bytes();
        serde_json::from_slice(&bytes).expect("response JSON")
    }

    async fn wait_for_socket_recreated(socket_path: &Path) {
        for _ in 0..50 {
            if let Ok(metadata) = tokio::fs::metadata(socket_path).await {
                if metadata.file_type().is_socket() {
                    return;
                }
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }

        panic!("socket was not recreated at {}", socket_path.display());
    }

    fn temp_dir(_test_name: &str) -> PathBuf {
        let id = NEXT_TEMP_ID.fetch_add(1, Ordering::Relaxed);
        let base = std::env::current_dir().expect("current dir").join("target");
        std::fs::create_dir_all(&base).expect("create test target dir");
        let dir = base.join(format!("w{id}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir(&dir).expect("create temp dir");
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))
            .expect("set temp dir permissions");
        dir
    }
}
