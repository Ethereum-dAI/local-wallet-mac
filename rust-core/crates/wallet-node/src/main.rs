mod admin;
mod admin_challenge;
pub mod auth;
mod bundler_keys;
mod cli;
mod config;
mod handlers;
mod lifecycle;
mod logging;
mod paths;
mod rate_limit;
mod ready;
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

use crate::bundler_keys::{BundlerKeyStore, InMemoryBundlerKeyStore};
use cli::{Cli, CliCommand};
use handlers::offline_chain::OfflineChainAdapter;
use lifecycle::LifecycleHandles;
use ready::ReadyEvent;
use state::{DaemonState, TransportInfo};
use transport::handler::Handler;
use wallet_chain::{ChainConfig, ChainError, HeliosChainAdapter};

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
        eprintln!("{err}");
        return ExitCode::FAILURE;
    }

    let paths = match paths::Paths::resolve(cli.config.clone()) {
        Ok(paths) => paths,
        Err(err) => {
            eprintln!("failed to resolve wallet-node paths: {err}");
            return ExitCode::FAILURE;
        }
    };

    let _logging_guard = match logging::init(cli.debug, Some(&paths.logs_dir)) {
        Ok(guard) => guard,
        Err(err) => {
            eprintln!("failed to initialize wallet-node logging: {err}");
            return ExitCode::FAILURE;
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
            eprintln!("failed to load wallet-node config: {err}");
            return ExitCode::FAILURE;
        }
    };

    let mut conn = match wallet_node_store::db::open(&paths.db_path) {
        Ok(conn) => conn,
        Err(err) => {
            eprintln!("failed to open wallet-node store: {err}");
            return ExitCode::FAILURE;
        }
    };
    if let Err(err) = wallet_node_store::migrations::apply(&mut conn) {
        eprintln!("failed to migrate wallet-node store: {err}");
        return ExitCode::FAILURE;
    }
    let store = wallet_node_store::StoreActor::start(conn);
    let bundler_key_store = Arc::new(InMemoryBundlerKeyStore::new());
    let installed_bundler_keys = match cli.secret_fd {
        Some(fd) => match load_secrets_from_fd(fd, &bundler_key_store) {
            Ok(keys) => keys,
            Err(err) => {
                eprintln!("failed to load bundler secrets from fd {fd}: {err}");
                return ExitCode::FAILURE;
            }
        },
        None => Vec::new(),
    };
    for key in &installed_bundler_keys {
        if let Err(err) = ensure_bundler_account_for_installed_key(&store, key).await {
            eprintln!(
                "failed to register supplied bundler key {}: {err}",
                key.key_ref
            );
            return ExitCode::FAILURE;
        }
    }

    let chain_config = ChainConfig {
        chain_id: config.chain_id_for_helios(),
        execution_rpc: config.execution_rpc_for_helios().to_owned(),
        consensus_rpc: config.consensus_rpc_for_helios().to_owned(),
        data_dir: paths.helios_dir.clone(),
        max_helios_lag_blocks: 8,
    };
    let chain: Arc<dyn wallet_chain::ChainAdapter> =
        match HeliosChainAdapter::start(chain_config).await {
            Ok((adapter, _handle)) => Arc::new(adapter),
            Err(ChainError::CheckpointTooOld { reason }) => {
                // T-P3-7 option b: keep the daemon serving authenticated control APIs while
                // verified chain reads are soft-degraded until a fresh checkpoint ships.
                tracing::warn!(
                    reason = %reason,
                    "helios checkpoint is too old; starting with offline chain adapter"
                );
                Arc::new(OfflineChainAdapter::new())
            }
            Err(err) => {
                tracing::error!(error = %err, "failed to start helios chain adapter");
                return ExitCode::FAILURE;
            }
        };

    let token = Arc::new(auth::Token::generate());
    let lifecycle = LifecycleHandles::new();
    let LifecycleHandles {
        shutdown_tx,
        mut shutdown_rx,
    } = lifecycle;
    let _signal_handlers = lifecycle::install_signal_handlers(shutdown_tx.clone());
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
    let mut receipt_watcher_task =
        watcher::spawn_receipt_watcher(state.clone(), shutdown_rx.clone(), Duration::from_secs(6));
    let handler = Handler {
        state: state.clone(),
    };

    let mut transport_task = if let Some(addr) = cli.http.as_deref() {
        let addr: SocketAddr = match addr.parse() {
            Ok(addr) => addr,
            Err(err) => {
                eprintln!("failed to parse --http address: {err}");
                return ExitCode::FAILURE;
            }
        };
        let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
        let transport_shutdown_rx = shutdown_rx.clone();
        let task = tokio::spawn(transport::http::serve(
            addr,
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
    } else if let (Some(ready_fd), Some(alive_fd)) = (cli.ready_fd, cli.alive_fd) {
        if let Err(err) = lifecycle::install_alive_pipe_watcher(
            alive_fd as RawFd,
            shutdown_tx.clone(),
            shutdown_rx.clone(),
        ) {
            eprintln!("failed to install alive pipe watcher: {err}");
            return ExitCode::FAILURE;
        }
        let _ppid_backstop =
            lifecycle::install_ppid_backstop(shutdown_tx.clone(), Duration::from_secs(5));
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

    state.chain.shutdown().await;
    tracing::info!("chain adapter shutdown complete");

    if let Err(e) = state.store.shutdown_and_wait().await {
        tracing::warn!(error = %e, "store shutdown failed");
    }

    exit_code
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
    #[serde(default)]
    keys: Vec<SecretFdEntry>,
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
) -> Result<Vec<InstalledBundlerKey>, String> {
    use std::io::Read;

    let mut file = unsafe { std::fs::File::from_raw_fd(fd as RawFd) };
    let mut body = String::new();
    file.read_to_string(&mut body)
        .map_err(|err| format!("read failed: {err}"))?;
    drop(file);

    let payload: SecretFdPayload =
        serde_json::from_str(&body).map_err(|err| format!("invalid json: {err}"))?;
    let entries = if payload.keys.is_empty() {
        match (payload.key_ref, payload.secret) {
            (Some(key_ref), Some(secret)) => vec![SecretFdEntry { key_ref, secret }],
            _ => Vec::new(),
        }
    } else {
        payload.keys
    };
    if entries.is_empty() {
        return Err("payload contains no keys".to_string());
    }

    let mut installed = Vec::new();
    for entry in entries {
        let (owner_scope, chain_id) = parse_bundler_key_ref(&entry.key_ref)?;
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
        let address = store
            .install_key(&entry.key_ref, secret)
            .map_err(|err| format!("install failed for {}: {err}", entry.key_ref))?;
        installed.push(InstalledBundlerKey {
            key_ref: entry.key_ref,
            owner_scope,
            chain_id,
            address: format!("{address:#x}"),
        });
    }
    Ok(installed)
}

fn parse_bundler_key_ref(key_ref: &str) -> Result<(String, u64), String> {
    let parts = key_ref.split(':').collect::<Vec<_>>();
    if parts.len() != 4 || parts[0] != "bundler-eoa" {
        return Err(format!(
            "invalid keyRef {key_ref}; expected bundler-eoa:<ownerScope>:<chainId>:<index>"
        ));
    }
    let chain_id = parts[2]
        .parse::<u64>()
        .map_err(|err| format!("invalid chain id in keyRef {key_ref}: {err}"))?;
    Ok((parts[1].to_string(), chain_id))
}

async fn ensure_bundler_account_for_installed_key(
    store: &wallet_node_store::StoreHandle,
    key: &InstalledBundlerKey,
) -> Result<(), wallet_node_store::StoreError> {
    let accounts = store
        .bundler_account_list_for_owner(&key.owner_scope, key.chain_id)
        .await?;
    if accounts.iter().any(|account| {
        account.key_ref == key.key_ref && account.address.eq_ignore_ascii_case(&key.address)
    }) {
        return Ok(());
    }
    store
        .bundler_account_insert_for_owner(
            &key.owner_scope,
            key.chain_id,
            &key.address,
            &key.key_ref,
            BundlerLifecycle::Active,
        )
        .await
}
