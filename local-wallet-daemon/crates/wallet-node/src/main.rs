mod admin;
mod admin_challenge;
pub mod auth;
mod bundler_account_reconciliation;
mod bundler_keys;
mod cli;
mod config;
mod handlers;
mod lifecycle;
mod logging;
mod paths;
mod rate_limit;
mod ready;
mod redact;
mod relayer_lifecycle;
mod relayer_signer;
mod state;
mod transport;
mod watcher;

use std::net::SocketAddr;
use std::os::fd::FromRawFd;
use std::os::unix::io::RawFd;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use clap::Parser;
use serde::Deserialize;
use wallet_node_store::BundlerLifecycle;

use crate::bundler_account_reconciliation::SuppliedBundlerKey;
use crate::bundler_keys::{BundlerKeyStore, InMemoryBundlerKeyStore};
use cli::{Cli, CliCommand};
use handlers::offline_chain::OfflineChainAdapter;
use lifecycle::{LifecycleHandles, ShutdownOnDrop, StartupStageResult};
use ready::ReadyEvent;
use state::{DaemonState, TransportInfo};
use transport::handler::Handler;
use wallet_chain::{ChainConfig, ChainError, ExecutionRpcChainAdapter, HeliosChainAdapter};

/// Report a fatal startup failure and exit.
///
/// Prints to stderr as before, and — when the parent gave us a ready fd —
/// sends the same reason down it before exiting, so the app can say what went
/// wrong instead of only that the pipe closed. Use this for every failure that
/// returns before the `ReadyEvent` is written; afterwards the fd is spent.
macro_rules! fail_before_ready {
    ($cli:expr, $($arg:tt)*) => {{
        let reason = format!($($arg)*);
        eprintln!("{reason}");
        if let Some(fd) = $cli.ready_fd {
            let _ = ready::write_failure_to_fd(&reason, fd as RawFd);
        }
        return ExitCode::FAILURE;
    }};
}

#[tokio::main]
async fn main() -> ExitCode {
    let cli = Cli::parse();

    if cli.print_api_version {
        println!("{}", wallet_node_api::API_VERSION);
        return ExitCode::SUCCESS;
    }

    if let Some(CliCommand::Admin(admin_args)) = cli.command.as_ref() {
        match admin::run(admin_args).await {
            Ok(()) => return ExitCode::SUCCESS,
            Err(err) => {
                eprintln!("{err}");
                return ExitCode::FAILURE;
            }
        }
    }

    if let Err(err) = cli.validate() {
        fail_before_ready!(cli, "{err}");
    }

    // Arm every parent-death path before reading fd 5. In particular, the
    // alive-pipe watcher must already be live while secret material is loaded
    // and while the slower reconciliation and chain-startup stages run.
    let LifecycleHandles {
        shutdown_tx,
        mut shutdown_rx,
    } = LifecycleHandles::new();
    let _shutdown_on_drop = ShutdownOnDrop::new(shutdown_tx.clone());
    let _signal_handlers = lifecycle::install_signal_handlers(shutdown_tx.clone());
    let _alive_pipe_watcher = match cli.alive_fd {
        Some(alive_fd) => {
            match lifecycle::install_alive_pipe_watcher(
                alive_fd as RawFd,
                shutdown_tx.clone(),
                shutdown_rx.clone(),
            ) {
                Ok(watcher) => Some(watcher),
                Err(err) => {
                    fail_before_ready!(cli, "failed to install alive pipe watcher: {err}");
                }
            }
        }
        None => None,
    };
    let _ppid_backstop = cli
        .alive_fd
        .map(|_| lifecycle::install_ppid_backstop(shutdown_tx.clone(), Duration::from_secs(5)));

    let http_addr = match cli.http.as_deref() {
        Some(addr) => {
            let addr: SocketAddr = match addr.parse() {
                Ok(addr) => addr,
                Err(err) => {
                    fail_before_ready!(cli, "failed to parse --http address: {err}");
                }
            };
            if let Err(err) = transport::http::validate_bind_address(addr, cli.allow_public) {
                fail_before_ready!(cli, "{err}");
            }
            Some(addr)
        }
        None => None,
    };

    let paths = match paths::Paths::resolve(cli.config.clone()) {
        Ok(paths) => paths,
        Err(err) => {
            fail_before_ready!(cli, "failed to resolve wallet-node paths: {err}");
        }
    };

    let _logging_guard = match logging::init(cli.debug, Some(&paths.logs_dir)) {
        Ok(guard) => guard,
        Err(err) => {
            fail_before_ready!(cli, "failed to initialize wallet-node logging: {err}");
        }
    };
    if let Some(manifest_url) = cli.manifest_url.as_deref() {
        tracing::warn!(
            manifest_url,
            "debug manifest URL override accepted; signed manifest promotion is not enabled in this build"
        );
    }

    let config = match config::Config::load(&paths.config_path) {
        Ok(config) => Arc::new(config),
        Err(err) => {
            fail_before_ready!(cli, "failed to load wallet-node config: {err}");
        }
    };

    let mut conn = match wallet_node_store::db::open(&paths.db_path) {
        Ok(conn) => conn,
        Err(err) => {
            fail_before_ready!(cli, "failed to open wallet-node store: {err}");
        }
    };
    if let Err(err) = wallet_node_store::migrations::apply(&mut conn) {
        fail_before_ready!(cli, "failed to migrate wallet-node store: {err}");
    }
    let store = wallet_node_store::StoreActor::start(conn);
    if *shutdown_rx.borrow() {
        return exit_after_startup_shutdown(&store).await;
    }
    if let Err(err) = store.release_orphaned_prebundle_nonces().await {
        fail_before_ready!(
            cli,
            "failed to recover pre-submission nonce reservations: {err}"
        );
    }
    let bundler_key_store = Arc::new(InMemoryBundlerKeyStore::new());
    let installed_bundler_keys = match cli.secret_fd {
        Some(fd) => match load_secrets_from_fd(
            fd,
            &bundler_key_store,
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            config.network.chain_id,
        ) {
            Ok(keys) => keys,
            Err(err) => {
                fail_before_ready!(cli, "failed to load bundler secrets from fd {fd}: {err}");
            }
        },
        None => Vec::new(),
    };
    for key in &installed_bundler_keys {
        let reconciliation = lifecycle::run_startup_stage(
            &mut shutdown_rx,
            bundler_account_reconciliation::reconcile(
                &store,
                SuppliedBundlerKey {
                    owner_scope: &key.owner_scope,
                    chain_id: key.chain_id,
                    key_ref: &key.key_ref,
                    address: &key.address,
                },
                BundlerLifecycle::Active,
            ),
        )
        .await;
        match reconciliation {
            StartupStageResult::Completed(Ok(_)) => {}
            StartupStageResult::Completed(Err(err)) => {
                fail_before_ready!(
                    cli,
                    "failed to register supplied bundler key {}: {err}",
                    key.key_ref
                );
            }
            StartupStageResult::ShutdownRequested => {
                return exit_after_startup_shutdown(&store).await;
            }
        }
    }

    let chain: Arc<dyn wallet_chain::ChainAdapter> = match config.read_verification_mode() {
        config::ReadVerificationMode::Helios => {
            let chain_config = ChainConfig {
                chain_id: config.chain_id_for_helios(),
                execution_rpc: config.execution_rpc_for_helios().to_owned(),
                consensus_rpc: config.consensus_rpc_for_helios().to_owned(),
                data_dir: paths.helios_dir.clone(),
                max_helios_lag_blocks: 8,
            };
            let startup = lifecycle::run_startup_stage(
                &mut shutdown_rx,
                HeliosChainAdapter::start(chain_config),
            )
            .await;
            match startup {
                StartupStageResult::ShutdownRequested => {
                    return exit_after_startup_shutdown(&store).await;
                }
                StartupStageResult::Completed(Ok((adapter, _handle))) => Arc::new(adapter),
                StartupStageResult::Completed(Err(ChainError::CheckpointTooOld { reason })) => {
                    // T-P3-7 option b: keep the daemon serving authenticated control APIs while
                    // verified chain reads are soft-degraded until a fresh checkpoint ships.
                    tracing::warn!(
                        reason = %reason,
                        "helios checkpoint is too old; starting with offline chain adapter"
                    );
                    Arc::new(OfflineChainAdapter::new())
                }
                StartupStageResult::Completed(Err(err)) => {
                    tracing::error!(error = %err, "failed to start helios chain adapter");
                    fail_before_ready!(cli, "failed to start helios chain adapter: {err}");
                }
            }
        }
        config::ReadVerificationMode::ExecutionRpc => {
            tracing::warn!(
                execution_rpc = %redact::redact_url(config.execution_rpc_for_helios()),
                "helios read verification disabled; serving reads directly from execution RPC"
            );
            let adapter =
                ExecutionRpcChainAdapter::new(config.execution_rpc_for_helios().to_owned());
            let validation = lifecycle::run_startup_stage(
                &mut shutdown_rx,
                adapter.validate_chain_id(config.chain_id_for_helios()),
            )
            .await;
            match validation {
                StartupStageResult::Completed(Ok(())) => {}
                StartupStageResult::Completed(Err(err)) => {
                    tracing::error!(
                        error = %err,
                        expected_chain_id = config.chain_id_for_helios(),
                        "execution RPC chain id validation failed"
                    );
                    fail_before_ready!(
                        cli,
                        "execution RPC {} rejected chain id {}: {err}",
                        redact::redact_url(config.execution_rpc_for_helios()),
                        config.chain_id_for_helios()
                    );
                }
                StartupStageResult::ShutdownRequested => {
                    return exit_after_startup_shutdown(&store).await;
                }
            }
            Arc::new(adapter)
        }
    };

    let token = Arc::new(auth::Token::generate());
    let transport_info = if cli.http.is_some() {
        TransportInfo::http()
    } else {
        TransportInfo::unix()
    };
    let paths = Arc::new(paths);
    let state = Arc::new(DaemonState::new(
        token.clone(),
        config,
        paths.clone(),
        shutdown_tx.clone(),
        (
            transport_info,
            store,
            chain,
            bundler_key_store as Arc<dyn BundlerKeyStore>,
        ),
    ));
    let mut state_override_smoke_task = watcher::spawn_state_override_smoke(
        state.clone(),
        shutdown_rx.clone(),
        Duration::from_secs(1),
    );
    let mut p256_probe_task =
        watcher::spawn_p256_probe(state.clone(), shutdown_rx.clone(), Duration::from_secs(1));
    let mut receipt_watcher_task =
        watcher::spawn_receipt_watcher(state.clone(), shutdown_rx.clone(), Duration::from_secs(6));
    let handler = Handler {
        state: state.clone(),
    };

    let mut transport_task = if let Some(addr) = http_addr {
        let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
        let transport_shutdown_rx = shutdown_rx.clone();
        let task = tokio::spawn(transport::http::serve(
            addr,
            cli.allow_public,
            handler,
            Some(ready_tx),
            transport_shutdown_rx,
        ));
        let bound_addr = match ready_rx.await {
            Ok(addr) => addr,
            Err(err) => {
                match task.await {
                    Ok(Err(transport_err)) => {
                        eprintln!("http transport failed before ready: {transport_err}");
                    }
                    Ok(Ok(())) => {
                        eprintln!("http transport stopped before ready: {err}");
                    }
                    Err(join_err) => {
                        eprintln!("http transport task failed before ready: {join_err}");
                    }
                }
                return ExitCode::FAILURE;
            }
        };

        if !cli.print_ready {
            unreachable!("Cli::validate requires --print-ready with --http");
        }

        let event = ReadyEvent {
            token: token.encoded(),
            api_version: wallet_node_api::API_VERSION,
            daemon_spawn_protocol: wallet_node_api::DAEMON_SPAWN_PROTOCOL,
            socket_path: None,
            http_addr: Some(bound_addr.to_string()),
        };
        if let Err(err) = ready::write_to_stdout(&event) {
            eprintln!("failed to write ready event to stdout: {err}");
            task.abort();
            return ExitCode::FAILURE;
        }

        task
    } else if let (Some(ready_fd), Some(_alive_fd)) = (cli.ready_fd, cli.alive_fd) {
        let transport_shutdown_rx = shutdown_rx.clone();
        let socket_path = paths.socket_path.clone();
        let task = tokio::spawn(transport::unix::serve(
            socket_path.clone(),
            handler,
            transport_shutdown_rx,
        ));
        let event = ReadyEvent {
            token: token.encoded(),
            api_version: wallet_node_api::API_VERSION,
            daemon_spawn_protocol: wallet_node_api::DAEMON_SPAWN_PROTOCOL,
            socket_path: Some(socket_path),
            http_addr: None,
        };
        if let Err(err) = ready::write_to_fd(&event, ready_fd as RawFd) {
            eprintln!("failed to write ready event to fd {ready_fd}: {err}");
            task.abort();
            return ExitCode::FAILURE;
        }

        task
    } else {
        unreachable!("Cli::validate requires either --http or --ready-fd/--alive-fd");
    };

    let _ = shutdown_rx.changed().await;

    let exit_code = match tokio::time::timeout(Duration::from_secs(2), &mut transport_task).await {
        Ok(Ok(Ok(()))) => ExitCode::SUCCESS,
        Ok(Ok(Err(err))) => {
            eprintln!("wallet-node transport failed: {err}");
            ExitCode::FAILURE
        }
        Ok(Err(err)) => {
            eprintln!("wallet-node transport task failed to join: {err}");
            ExitCode::FAILURE
        }
        Err(_) => {
            transport_task.abort();
            eprintln!("wallet-node transport did not stop within 2 seconds");
            ExitCode::FAILURE
        }
    };

    match tokio::time::timeout(Duration::from_secs(1), &mut receipt_watcher_task).await {
        Ok(Ok(())) => {}
        Ok(Err(err)) => {
            tracing::warn!(error = %err, "receipt watcher task failed to join");
        }
        Err(_) => {
            receipt_watcher_task.abort();
            tracing::warn!("receipt watcher did not stop within 1 second");
        }
    }

    match tokio::time::timeout(Duration::from_secs(1), &mut state_override_smoke_task).await {
        Ok(Ok(())) => {}
        Ok(Err(err)) => {
            tracing::warn!(error = %err, "stateOverride smoke task failed to join");
        }
        Err(_) => {
            state_override_smoke_task.abort();
            tracing::warn!("stateOverride smoke task did not stop within 1 second");
        }
    }

    match tokio::time::timeout(Duration::from_secs(1), &mut p256_probe_task).await {
        Ok(Ok(())) => {}
        Ok(Err(err)) => {
            tracing::warn!(error = %err, "p256 precompile probe task failed to join");
        }
        Err(_) => {
            p256_probe_task.abort();
            tracing::warn!("p256 precompile probe task did not stop within 1 second");
        }
    }

    state.chain.shutdown().await;
    tracing::info!("chain adapter shutdown complete");

    if let Err(e) = state.store.shutdown_and_wait().await {
        tracing::warn!(error = %e, "store shutdown failed");
    }

    exit_code
}

async fn exit_after_startup_shutdown(store: &wallet_node_store::StoreHandle) -> ExitCode {
    tracing::info!("shutdown requested before wallet-node became ready");
    match tokio::time::timeout(Duration::from_secs(1), store.shutdown_and_wait()).await {
        Ok(Ok(())) => {}
        Ok(Err(err)) => {
            tracing::warn!(error = %err, "store shutdown failed during startup cancellation");
        }
        Err(_) => {
            tracing::warn!("store did not stop within 1 second during startup cancellation");
        }
    }
    ExitCode::SUCCESS
}

#[derive(Debug)]
struct InstalledBundlerKey {
    key_ref: String,
    owner_scope: String,
    chain_id: u64,
    address: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SecretFdPayload {
    keys: Option<Vec<SecretFdEntry>>,
    key_ref: Option<String>,
    secret: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SecretFdEntry {
    key_ref: String,
    secret: String,
}

fn load_secrets_from_fd(
    fd: u32,
    store: &InMemoryBundlerKeyStore,
    expected_owner_scope: &str,
    expected_chain_id: u64,
) -> Result<Vec<InstalledBundlerKey>, String> {
    use std::collections::HashSet;
    use std::io::Read;

    let mut file = unsafe { std::fs::File::from_raw_fd(fd as RawFd) };
    let mut body = String::new();
    file.read_to_string(&mut body)
        .map_err(|err| format!("read failed: {err}"))?;
    drop(file);

    let payload: SecretFdPayload =
        serde_json::from_str(&body).map_err(|err| format!("invalid json: {err}"))?;
    let explicit_key_list = payload.keys.is_some();
    let entries = match payload.keys {
        Some(keys) => keys,
        None => match (payload.key_ref, payload.secret) {
            (Some(key_ref), Some(secret)) => vec![SecretFdEntry { key_ref, secret }],
            _ => Vec::new(),
        },
    };
    if entries.is_empty() && !explicit_key_list {
        return Err("payload contains no keys".to_string());
    }

    let mut validated = Vec::with_capacity(entries.len());
    let mut seen_key_refs = HashSet::with_capacity(entries.len());
    let mut seen_addresses = HashSet::with_capacity(entries.len());
    for entry in entries {
        let parsed = bundler_keys::parse_canonical_key_ref(&entry.key_ref)
            .map_err(|err| format!("invalid keyRef {}: {err}", entry.key_ref))?;
        if parsed.owner_scope != expected_owner_scope || parsed.chain_id != expected_chain_id {
            return Err(format!(
                "keyRef {} does not match configured owner {} and chain {}",
                entry.key_ref, expected_owner_scope, expected_chain_id
            ));
        }
        let owner_scope = parsed.owner_scope.to_string();
        let chain_id = parsed.chain_id;
        let bytes = hex::decode(entry.secret.trim_start_matches("0x"))
            .map_err(|err| format!("invalid secret hex for {}: {err}", entry.key_ref))?;
        if bytes.len() != 32 {
            return Err(format!(
                "invalid secret length for {}: expected 32 bytes, got {}",
                entry.key_ref,
                bytes.len()
            ));
        }
        let mut secret = [0u8; 32];
        secret.copy_from_slice(&bytes);
        let address = bundler_keys::address_for_secret(&entry.key_ref, &secret)
            .map_err(|err| format!("invalid secret for {}: {err}", entry.key_ref))?;
        if !seen_key_refs.insert(entry.key_ref.clone()) {
            return Err(format!("duplicate keyRef {}", entry.key_ref));
        }
        if !seen_addresses.insert(address) {
            return Err(format!(
                "duplicate bundler address {address:#x} in secret payload"
            ));
        }
        validated.push((entry.key_ref, owner_scope, chain_id, secret));
    }

    let mut installed = Vec::with_capacity(validated.len());
    for (key_ref, owner_scope, chain_id, secret) in validated {
        let address = store
            .install_key(&key_ref, secret)
            .map_err(|err| format!("install failed for {key_ref}: {err}"))?;
        installed.push(InstalledBundlerKey {
            key_ref,
            owner_scope,
            chain_id,
            address: format!("{address:#x}"),
        });
    }
    Ok(installed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::os::fd::IntoRawFd;

    #[test]
    fn explicit_empty_secret_list_starts_read_only() {
        let (read_fd, write_fd) = nix::unistd::pipe().expect("secret pipe should open");
        let mut writer = std::fs::File::from(write_fd);
        writer
            .write_all(br#"{"keys":[]}"#)
            .expect("read-only secret payload should write");
        drop(writer);

        let store = InMemoryBundlerKeyStore::new();
        let installed = load_secrets_from_fd(
            read_fd.into_raw_fd() as u32,
            &store,
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            1,
        )
        .expect("an explicit empty key list should be a valid read-only launch");

        assert!(installed.is_empty());
    }

    #[test]
    fn missing_secret_fields_remains_invalid() {
        let (read_fd, write_fd) = nix::unistd::pipe().expect("secret pipe should open");
        let mut writer = std::fs::File::from(write_fd);
        writer
            .write_all(br#"{}"#)
            .expect("invalid secret payload should write");
        drop(writer);

        let store = InMemoryBundlerKeyStore::new();
        let error = load_secrets_from_fd(
            read_fd.into_raw_fd() as u32,
            &store,
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            1,
        )
        .expect_err("an omitted key list must not silently become read-only");

        assert_eq!(error, "payload contains no keys");
    }

    #[test]
    fn secret_fd_rejects_noncanonical_or_out_of_scope_key_refs_without_installing() {
        for key_ref in [
            "bundler-eoa:default:01:1",
            "bundler-eoa:default:1:01",
            "bundler-eoa:default:1:0",
            "bundler-eoa:other:1:1",
            "bundler-eoa:default:2:1",
        ] {
            let (read_fd, write_fd) = nix::unistd::pipe().expect("secret pipe should open");
            let mut writer = std::fs::File::from(write_fd);
            let payload = serde_json::json!({
                "keys": [{
                    "keyRef": key_ref,
                    "secret": format!("0x{}", "01".repeat(32)),
                }]
            });
            writer
                .write_all(payload.to_string().as_bytes())
                .expect("invalid secret payload should write");
            drop(writer);

            let store = InMemoryBundlerKeyStore::new();
            let result = load_secrets_from_fd(
                read_fd.into_raw_fd() as u32,
                &store,
                wallet_node_store::DEFAULT_OWNER_SCOPE,
                1,
            );

            assert!(result.is_err(), "{key_ref}");
            assert!(!store.is_key_loaded(key_ref).unwrap(), "{key_ref}");
        }
    }

    #[test]
    fn secret_fd_validates_every_entry_before_installing_any_key() {
        let valid_key_ref = "bundler-eoa:default:1:1";
        let invalid_key_ref = "bundler-eoa:default:1:02";
        let (read_fd, write_fd) = nix::unistd::pipe().expect("secret pipe should open");
        let mut writer = std::fs::File::from(write_fd);
        let payload = serde_json::json!({
            "keys": [
                {
                    "keyRef": valid_key_ref,
                    "secret": format!("0x{}", "01".repeat(32)),
                },
                {
                    "keyRef": invalid_key_ref,
                    "secret": format!("0x{}", "02".repeat(32)),
                }
            ]
        });
        writer
            .write_all(payload.to_string().as_bytes())
            .expect("mixed secret payload should write");
        drop(writer);

        let store = InMemoryBundlerKeyStore::new();
        let result = load_secrets_from_fd(
            read_fd.into_raw_fd() as u32,
            &store,
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            1,
        );

        assert!(result.is_err());
        assert!(!store.is_key_loaded(valid_key_ref).unwrap());
        assert!(!store.is_key_loaded(invalid_key_ref).unwrap());
    }

    #[test]
    fn secret_fd_rejects_invalid_later_secret_without_partial_install() {
        let valid_key_ref = "bundler-eoa:default:1:1";
        let invalid_key_ref = "bundler-eoa:default:1:2";
        let (read_fd, write_fd) = nix::unistd::pipe().expect("secret pipe should open");
        let mut writer = std::fs::File::from(write_fd);
        let payload = serde_json::json!({
            "keys": [
                {
                    "keyRef": valid_key_ref,
                    "secret": format!("0x{}", "01".repeat(32)),
                },
                {
                    "keyRef": invalid_key_ref,
                    "secret": format!("0x{}", "00".repeat(32)),
                }
            ]
        });
        writer
            .write_all(payload.to_string().as_bytes())
            .expect("mixed secret payload should write");
        drop(writer);

        let store = InMemoryBundlerKeyStore::new();
        let result = load_secrets_from_fd(
            read_fd.into_raw_fd() as u32,
            &store,
            wallet_node_store::DEFAULT_OWNER_SCOPE,
            1,
        );

        assert!(result.is_err());
        assert!(!store.is_key_loaded(valid_key_ref).unwrap());
        assert!(!store.is_key_loaded(invalid_key_ref).unwrap());
    }
}
