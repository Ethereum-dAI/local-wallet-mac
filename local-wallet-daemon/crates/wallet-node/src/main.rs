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
use wallet_node_store::{BundlerAccount, BundlerLifecycle, StoreError, SubmittedTxStatus};

use crate::bundler_keys::{BundlerKeyStore, InMemoryBundlerKeyStore};
use cli::{Cli, CliCommand};
use handlers::offline_chain::OfflineChainAdapter;
use lifecycle::LifecycleHandles;
use ready::ReadyEvent;
use state::{DaemonState, TransportInfo};
use transport::handler::Handler;
use wallet_chain::{ChainConfig, ChainError, ExecutionRpcChainAdapter, HeliosChainAdapter};

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

    let http_addr = match cli.http.as_deref() {
        Some(addr) => {
            let addr: SocketAddr = match addr.parse() {
                Ok(addr) => addr,
                Err(err) => {
                    eprintln!("failed to parse --http address: {err}");
                    return ExitCode::FAILURE;
                }
            };
            if let Err(err) = transport::http::validate_bind_address(addr, cli.allow_public) {
                eprintln!("{err}");
                return ExitCode::FAILURE;
            }
            Some(addr)
        }
        None => None,
    };

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

    let chain: Arc<dyn wallet_chain::ChainAdapter> = match config.read_verification_mode() {
        config::ReadVerificationMode::Helios => {
            let chain_config = ChainConfig {
                chain_id: config.chain_id_for_helios(),
                execution_rpc: config.execution_rpc_for_helios().to_owned(),
                consensus_rpc: config.consensus_rpc_for_helios().to_owned(),
                data_dir: paths.helios_dir.clone(),
                max_helios_lag_blocks: 8,
            };
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
            }
        }
        config::ReadVerificationMode::ExecutionRpc => {
            tracing::warn!(
                execution_rpc = %config.execution_rpc_for_helios(),
                "helios read verification disabled; serving reads directly from execution RPC"
            );
            let adapter =
                ExecutionRpcChainAdapter::new(config.execution_rpc_for_helios().to_owned());
            if let Err(err) = adapter
                .validate_chain_id(config.chain_id_for_helios())
                .await
            {
                tracing::error!(
                    error = %err,
                    expected_chain_id = config.chain_id_for_helios(),
                    "execution RPC chain id validation failed"
                );
                return ExitCode::FAILURE;
            }
            Arc::new(adapter)
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
) -> Result<(), StoreError> {
    let accounts = store
        .bundler_account_list_for_owner(&key.owner_scope, key.chain_id)
        .await?;
    if let Some(account) = accounts
        .iter()
        .find(|account| account.address.eq_ignore_ascii_case(&key.address))
    {
        if account.key_ref != key.key_ref {
            return Err(StoreError::DataIntegrity {
                table: "bundler_accounts",
                reason: "supplied bundler address is registered under a different key_ref",
            });
        }
        if account.lifecycle == BundlerLifecycle::Active {
            return Ok(());
        }

        if let Some(active) = accounts
            .iter()
            .find(|account| account.lifecycle == BundlerLifecycle::Active)
        {
            if active.key_ref == key.key_ref
                && !bundler_account_has_live_local_work(store, active).await?
            {
                tracing::warn!(
                    owner_scope = %key.owner_scope,
                    chain_id = key.chain_id,
                    key_ref = %key.key_ref,
                    old_address = %active.address,
                    new_address = %key.address,
                    "retiring stale active bundler account metadata and adopting supplied key"
                );
                return store
                    .bundler_account_replace_active_for_owner(
                        &key.owner_scope,
                        key.chain_id,
                        &active.address,
                        &key.address,
                        &key.key_ref,
                    )
                    .await;
            }
            return Err(StoreError::DataIntegrity {
                table: "bundler_accounts",
                reason: "supplied bundler address is not active",
            });
        }

        return store
            .bundler_account_set_lifecycle_for_owner(
                &key.owner_scope,
                key.chain_id,
                &key.address,
                BundlerLifecycle::Active,
            )
            .await;
    }

    if let Some(active) = accounts
        .iter()
        .find(|account| account.lifecycle == BundlerLifecycle::Active)
    {
        if active.key_ref == key.key_ref {
            if bundler_account_has_live_local_work(store, active).await? {
                return Err(StoreError::DataIntegrity {
                    table: "bundler_accounts",
                    reason:
                        "supplied bundler key_ref resolves to a different address with live local submissions",
                });
            }
            tracing::warn!(
                owner_scope = %key.owner_scope,
                chain_id = key.chain_id,
                key_ref = %key.key_ref,
                old_address = %active.address,
                new_address = %key.address,
                "retiring stale active bundler account metadata and adopting supplied key"
            );
            return store
                .bundler_account_replace_active_for_owner(
                    &key.owner_scope,
                    key.chain_id,
                    &active.address,
                    &key.address,
                    &key.key_ref,
                )
                .await;
        }

        return Err(StoreError::DataIntegrity {
            table: "bundler_accounts",
            reason: "active bundler account differs from supplied key",
        });
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

async fn bundler_account_has_live_local_work(
    store: &wallet_node_store::StoreHandle,
    account: &BundlerAccount,
) -> Result<bool, StoreError> {
    let pending_nonces = store
        .nonces_list_pending(account.chain_id, &account.address)
        .await?;
    if !pending_nonces.is_empty() {
        return Ok(true);
    }

    let live_txs = store.submitted_txs_list_for_watcher().await?;
    Ok(live_txs.iter().any(|tx| {
        tx.chain_id == account.chain_id
            && tx.bundler_address.eq_ignore_ascii_case(&account.address)
            && matches!(
                tx.status,
                SubmittedTxStatus::Submitting | SubmittedTxStatus::Submitted
            )
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use wallet_node_store::{db, migrations, StoreActor, StoreError};

    fn migrated_store() -> wallet_node_store::StoreHandle {
        let mut conn = db::open_in_memory().expect("in-memory store should open");
        migrations::apply(&mut conn).expect("migrations should apply");
        StoreActor::start(conn)
    }

    #[tokio::test]
    async fn supplied_bundler_key_registration_is_idempotent() {
        let store = migrated_store();
        let key = InstalledBundlerKey {
            key_ref: "bundler-eoa:default:11155111:1".to_owned(),
            owner_scope: "default".to_owned(),
            chain_id: 11_155_111,
            address: "0xa09d9ce68cb323ee2b2ba939084b13a8eeaa5bcc".to_owned(),
        };
        store
            .bundler_account_insert_for_owner(
                &key.owner_scope,
                key.chain_id,
                &key.address,
                &key.key_ref,
                BundlerLifecycle::Active,
            )
            .await
            .expect("pre-existing relayer account should insert");

        ensure_bundler_account_for_installed_key(&store, &key)
            .await
            .expect("same supplied key should be accepted on restart");

        let accounts = store
            .bundler_account_list_for_owner(&key.owner_scope, key.chain_id)
            .await
            .expect("accounts should list");
        assert_eq!(accounts.len(), 1);
        assert_eq!(accounts[0].key_ref, key.key_ref);
        assert!(accounts[0].address.eq_ignore_ascii_case(&key.address));

        store.shutdown_and_wait().await.expect("store should stop");
    }

    #[tokio::test]
    async fn supplied_bundler_key_registration_rejects_key_ref_address_mismatch() {
        let store = migrated_store();
        let existing_address = "0xa09d9ce68cb323ee2b2ba939084b13a8eeaa5bcc";
        store
            .bundler_account_insert_for_owner(
                "default",
                11_155_111,
                existing_address,
                "bundler-eoa:default:11155111:1",
                BundlerLifecycle::Active,
            )
            .await
            .expect("pre-existing relayer account should insert");

        let mismatched = InstalledBundlerKey {
            key_ref: "bundler-eoa:default:11155111:2".to_owned(),
            owner_scope: "default".to_owned(),
            chain_id: 11_155_111,
            address: existing_address.to_owned(),
        };
        let err = ensure_bundler_account_for_installed_key(&store, &mismatched)
            .await
            .expect_err("same address under a different key_ref should fail clearly");
        assert!(matches!(
            err,
            StoreError::DataIntegrity {
                table: "bundler_accounts",
                reason: "supplied bundler address is registered under a different key_ref"
            }
        ));

        store.shutdown_and_wait().await.expect("store should stop");
    }

    #[tokio::test]
    async fn supplied_bundler_key_registration_adopts_idle_key_ref_address_mismatch() {
        let store = migrated_store();
        let key_ref = "bundler-eoa:default:11155111:1";
        let old_address = "0xa09d9ce68cb323ee2b2ba939084b13a8eeaa5bcc";
        let new_address = "0x122cbfd6b318e468625fa9f2264dc77d887b8393";
        store
            .bundler_account_insert_for_owner(
                "default",
                11_155_111,
                old_address,
                key_ref,
                BundlerLifecycle::Active,
            )
            .await
            .expect("pre-existing relayer account should insert");

        let supplied = InstalledBundlerKey {
            key_ref: key_ref.to_owned(),
            owner_scope: "default".to_owned(),
            chain_id: 11_155_111,
            address: new_address.to_owned(),
        };
        ensure_bundler_account_for_installed_key(&store, &supplied)
            .await
            .expect("idle stale metadata should be retired");

        let active = store
            .bundler_account_active_for_owner("default", 11_155_111)
            .await
            .expect("active account should load")
            .expect("replacement should be active");
        assert_eq!(active.key_ref, key_ref);
        assert!(active.address.eq_ignore_ascii_case(new_address));
        let accounts = store
            .bundler_account_list_for_owner("default", 11_155_111)
            .await
            .expect("accounts should list");
        assert!(accounts.iter().any(|account| {
            account.address.eq_ignore_ascii_case(old_address)
                && account.lifecycle == BundlerLifecycle::Retired
        }));

        store.shutdown_and_wait().await.expect("store should stop");
    }

    #[tokio::test]
    async fn supplied_bundler_key_registration_rejects_live_key_ref_address_mismatch() {
        let store = migrated_store();
        let key_ref = "bundler-eoa:default:11155111:1";
        let old_address = "0xa09d9ce68cb323ee2b2ba939084b13a8eeaa5bcc";
        store
            .bundler_account_insert_for_owner(
                "default",
                11_155_111,
                old_address,
                key_ref,
                BundlerLifecycle::Active,
            )
            .await
            .expect("pre-existing relayer account should insert");
        store
            .reserve_next_nonce(11_155_111, old_address, 0)
            .await
            .expect("live local nonce should reserve");

        let supplied = InstalledBundlerKey {
            key_ref: key_ref.to_owned(),
            owner_scope: "default".to_owned(),
            chain_id: 11_155_111,
            address: "0x122cbfd6b318e468625fa9f2264dc77d887b8393".to_owned(),
        };
        let err = ensure_bundler_account_for_installed_key(&store, &supplied)
            .await
            .expect_err("live stale metadata should not be auto-retired");
        assert!(matches!(
            err,
            StoreError::DataIntegrity {
                table: "bundler_accounts",
                reason:
                    "supplied bundler key_ref resolves to a different address with live local submissions"
            }
        ));

        let active = store
            .bundler_account_active_for_owner("default", 11_155_111)
            .await
            .expect("active account should load")
            .expect("old account should remain active");
        assert!(active.address.eq_ignore_ascii_case(old_address));

        store.shutdown_and_wait().await.expect("store should stop");
    }
}
