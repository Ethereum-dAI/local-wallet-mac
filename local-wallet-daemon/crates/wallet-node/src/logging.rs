//! Structured logging for the wallet-node daemon.
//!
//! Never log bearer tokens; `Token::Debug` already redacts them. Never log
//! private keys, full request bodies, or raw transactions by default. If a
//! request body is logged at all, truncate it to 256 bytes first.

#![allow(dead_code)]

use std::io;
use std::path::Path;

use file_rotate::compression::Compression;
use file_rotate::suffix::AppendCount;
use file_rotate::{ContentLimit, FileRotate};
use tracing::Subscriber;
use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::fmt;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::EnvFilter;

// Wraps tracing_appender::non_blocking::WorkerGuard; dropping this flushes pending log writes.
pub struct LoggingGuard {
    worker: WorkerGuard,
}

pub fn init(debug: bool, logs_dir: Option<&Path>) -> io::Result<LoggingGuard> {
    if debug {
        let layer = fmt::layer().pretty().with_writer(io::stderr);
        let (_writer, worker) = tracing_appender::non_blocking(io::sink());

        tracing_subscriber::registry()
            .with(env_filter())
            .with(layer)
            .init();

        return Ok(LoggingGuard { worker });
    }

    let logs_dir = logs_dir.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "logs_dir is required when debug logging is disabled",
        )
    })?;
    let (subscriber, worker) = build_subscriber(logs_dir);

    subscriber.init();

    Ok(LoggingGuard { worker })
}

pub(crate) fn build_subscriber(logs_dir: &Path) -> (impl Subscriber, WorkerGuard) {
    let log_path = logs_dir.join("wallet-node.log");
    // Rotation tested manually; integration with file-rotate is upstream's responsibility.
    let file = FileRotate::new(
        log_path,
        AppendCount::new(3),
        ContentLimit::Bytes(16 * 1024 * 1024),
        Compression::None,
        #[cfg(unix)]
        None,
    );
    let (writer, worker) = tracing_appender::non_blocking(file);
    let layer = fmt::layer().json().with_writer(writer);

    (
        tracing_subscriber::registry()
            .with(env_filter())
            .with(layer),
        worker,
    )
}

fn env_filter() -> EnvFilter {
    EnvFilter::try_from_default_env().unwrap_or_else(|_| {
        EnvFilter::new(
            [
                "wallet_node=info",
                "wallet_node_api=info",
                "wallet_node_store=info",
                "wallet_chain=info",
                "wallet_bundler=info",
                "helios=info",
                "warn",
            ]
            .join(","),
        )
    })
}

#[cfg(test)]
mod tests {
    use std::env;
    use std::fs;
    use std::io::{self, Write};
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};

    use serde_json::Value;
    use tracing_subscriber::layer::SubscriberExt;

    use super::{build_subscriber, init};
    use crate::auth::Token;

    static NEXT_TEMP_ID: AtomicUsize = AtomicUsize::new(0);
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn init_debug_layer_does_not_panic() {
        // This is the only logging test that installs the global subscriber.
        // A process can install that subscriber only once; other tests use a
        // scoped local subscriber through `tracing::dispatcher::with_default`.
        let guard = init(true, None).expect("debug logging should initialize");

        drop(guard);
    }

    #[test]
    fn redacts_token_in_log_output() {
        // A regression in Token::Debug would silently leak bearer tokens
        // through info logs.
        let output = CapturedOutput::default();
        let subscriber = tracing_subscriber::registry().with(
            tracing_subscriber::fmt::layer()
                .with_ansi(false)
                .with_writer(output.clone()),
        );
        let dispatch = tracing::Dispatch::new(subscriber);
        let token = crate::auth::Token::generate();
        let encoded = token.encoded();

        tracing::dispatcher::with_default(&dispatch, || {
            tracing::info!("token: {token:?}");
        });

        let output = output.as_string();
        assert_eq!(encoded.len(), 43);
        assert!(!output.contains(&encoded), "log output leaked bearer token");
        assert!(
            output.contains("<redacted>"),
            "log output did not include redaction marker: {output}"
        );
        eprintln!("captured redaction-test output: {output}");
    }

    #[test]
    fn requires_logs_dir_in_production_mode() {
        let error = match init(false, None) {
            Ok(_) => panic!("production logging requires a logs directory"),
            Err(error) => error,
        };

        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    }

    #[test]
    fn production_mode_creates_log_file() {
        let tempdir = TempLogsDir::new("production_mode_creates_log_file");

        with_production_subscriber(tempdir.path(), || {
            tracing::info!("startup test");
        });

        let log_path = tempdir.path().join("wallet-node.log");
        let metadata = fs::metadata(&log_path).expect("production log file should exist");
        assert!(
            metadata.len() > 0,
            "production log file should be non-empty"
        );
    }

    #[test]
    fn production_log_lines_are_valid_json() {
        let tempdir = TempLogsDir::new("production_log_lines_are_valid_json");

        with_production_subscriber(tempdir.path(), || {
            tracing::info!("first event");
            tracing::info!("second event");
            tracing::info!("third event");
        });

        let contents = fs::read_to_string(tempdir.path().join("wallet-node.log"))
            .expect("read production log file");
        let mut line_count = 0;

        for line in contents.split('\n').filter(|line| !line.is_empty()) {
            line_count += 1;
            let value: Value = serde_json::from_str(line).expect("log line should be valid JSON");

            assert!(
                value.get("level").is_some(),
                "log line missing level: {line}"
            );
            assert!(
                value.get("target").is_some(),
                "log line missing target: {line}"
            );
        }

        assert_eq!(line_count, 3);
    }

    #[test]
    fn production_log_redacts_token_in_field_value() {
        let tempdir = TempLogsDir::new("production_log_redacts_token_in_field_value");
        let token = Token::generate();
        let encoded = token.encoded();

        with_production_subscriber(tempdir.path(), || {
            tracing::info!(token = ?token, "test");
        });

        let contents = fs::read_to_string(tempdir.path().join("wallet-node.log"))
            .expect("read production log file");

        assert_eq!(encoded.len(), 43);
        assert!(
            !contents.contains(&encoded),
            "production log output leaked bearer token"
        );
        assert!(
            contents.contains("<redacted>"),
            "production log output did not include redaction marker: {contents}"
        );
    }

    #[test]
    fn env_filter_default_suppresses_debug_output() {
        let tempdir = TempLogsDir::new("env_filter_default_suppresses_debug_output");

        with_production_subscriber_without_rust_log(tempdir.path(), || {
            tracing::debug!("noisy");
            tracing::info!("must appear");
        });

        let contents = fs::read_to_string(tempdir.path().join("wallet-node.log"))
            .expect("read production log file");

        assert!(
            !contents.contains("noisy"),
            "default env filter should suppress debug output: {contents}"
        );
        assert!(
            contents.contains("must appear"),
            "default env filter should keep info output: {contents}"
        );
    }

    #[test]
    fn env_filter_default_includes_chain_and_helios_info() {
        let tempdir = TempLogsDir::new("env_filter_default_includes_chain_and_helios_info");

        with_production_subscriber_without_rust_log(tempdir.path(), || {
            tracing::info!(target: "wallet_chain::helios", "chain info appears");
            tracing::info!(target: "helios::consensus", "helios info appears");
            tracing::info!(target: "wallet_bundler::submit", "bundler info appears");
            tracing::info!(target: "wallet_node_store::db", "store info appears");
            tracing::debug!(target: "wallet_chain::helios", "debug still suppressed");
        });

        let contents = fs::read_to_string(tempdir.path().join("wallet-node.log"))
            .expect("read production log file");

        assert!(contents.contains("chain info appears"));
        assert!(contents.contains("helios info appears"));
        assert!(contents.contains("bundler info appears"));
        assert!(contents.contains("store info appears"));
        assert!(!contents.contains("debug still suppressed"));
    }

    #[derive(Clone, Default)]
    struct CapturedOutput {
        bytes: Arc<Mutex<Vec<u8>>>,
    }

    struct CapturedWriter {
        bytes: Arc<Mutex<Vec<u8>>>,
    }

    impl CapturedOutput {
        fn as_string(&self) -> String {
            let bytes = self
                .bytes
                .lock()
                .expect("captured log output lock poisoned");

            String::from_utf8(bytes.clone()).expect("captured log output should be UTF-8")
        }
    }

    impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for CapturedOutput {
        type Writer = CapturedWriter;

        fn make_writer(&'a self) -> Self::Writer {
            CapturedWriter {
                bytes: self.bytes.clone(),
            }
        }
    }

    impl Write for CapturedWriter {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            let mut bytes = self
                .bytes
                .lock()
                .expect("captured log output lock poisoned");
            bytes.extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    struct TempLogsDir {
        path: PathBuf,
    }

    impl TempLogsDir {
        fn new(test_name: &str) -> TempLogsDir {
            let id = NEXT_TEMP_ID.fetch_add(1, Ordering::Relaxed);
            let path = env::temp_dir().join(format!(
                "wallet-node-logging-{test_name}-{}-{id}",
                std::process::id()
            ));

            let _ = fs::remove_dir_all(&path);
            fs::create_dir_all(&path).expect("create temporary log directory");

            TempLogsDir { path }
        }

        fn path(&self) -> &Path {
            &self.path
        }
    }

    impl Drop for TempLogsDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    struct EnvVarGuard {
        key: &'static str,
        value: Option<String>,
    }

    impl EnvVarGuard {
        fn replace(key: &'static str, replacement: Option<&str>) -> EnvVarGuard {
            let value = env::var(key).ok();
            match replacement {
                Some(replacement) => env::set_var(key, replacement),
                None => env::remove_var(key),
            }

            EnvVarGuard { key, value }
        }
    }

    impl Drop for EnvVarGuard {
        fn drop(&mut self) {
            match &self.value {
                Some(value) => env::set_var(self.key, value),
                None => env::remove_var(self.key),
            }
        }
    }

    fn with_production_subscriber(logs_dir: &Path, run: impl FnOnce()) {
        with_production_subscriber_with_rust_log(logs_dir, Some("trace"), run);
    }

    fn with_production_subscriber_without_rust_log(logs_dir: &Path, run: impl FnOnce()) {
        with_production_subscriber_with_rust_log(logs_dir, None, run);
    }

    fn with_production_subscriber_with_rust_log(
        logs_dir: &Path,
        rust_log: Option<&str>,
        run: impl FnOnce(),
    ) {
        let (subscriber, worker) = {
            let _env_lock = ENV_LOCK.lock().expect("RUST_LOG test lock poisoned");
            let _rust_log = EnvVarGuard::replace("RUST_LOG", rust_log);

            build_subscriber(logs_dir)
        };
        let dispatch = tracing::Dispatch::new(subscriber);

        tracing::dispatcher::with_default(&dispatch, run);

        drop(dispatch);
        drop(worker);
    }
}
