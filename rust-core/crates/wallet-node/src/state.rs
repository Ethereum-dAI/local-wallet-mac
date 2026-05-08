use std::sync::Arc;
use std::sync::RwLock;
use std::time::SystemTime;

use tokio::sync::watch;
use wallet_bundler::{
    RawTransactionSubmitClient, RawTransactionSubmitOutcome, RawTransactionSubmitter,
};

use crate::bundler_keys::BundlerKeyStore;

#[derive(Clone)]
#[allow(dead_code)]
pub struct DaemonState {
    pub token: Arc<crate::auth::Token>,
    pub config: Arc<crate::config::Config>,
    pub paths: Arc<crate::paths::Paths>,
    pub started_at: SystemTime,
    pub shutdown_tx: watch::Sender<bool>,
    pub store: wallet_node_store::StoreHandle,
    pub chain: Arc<dyn wallet_chain::ChainAdapter>,
    pub bundler_keys: Arc<dyn BundlerKeyStore>,
    pub raw_submitter: Arc<dyn RawTransactionSubmitter>,
    pub rate_limiter: Arc<crate::rate_limit::RateLimiter>,
    pub per_sender_rate_limiter: Arc<crate::rate_limit::PerSenderRateLimiter>,
    pub admin_challenges: Arc<crate::admin_challenge::AdminChallengeStore>,
    pub relayer_lifecycle_locks: Arc<crate::relayer_lifecycle::RelayerLifecycleLocks>,
    state_override_smoke: Arc<RwLock<StateOverrideSmokeStatus>>,
    pub transport: TransportInfo,
    #[cfg(test)]
    pub(crate) health_uses_chain: bool,
}

impl DaemonState {
    pub fn new<T>(
        token: Arc<crate::auth::Token>,
        config: Arc<crate::config::Config>,
        paths: Arc<crate::paths::Paths>,
        shutdown_tx: watch::Sender<bool>,
        init: T,
    ) -> Self
    where
        T: Into<DaemonStateInit>,
    {
        let init = init.into();
        let raw_submitter = init.raw_submitter.unwrap_or_else(|| {
            configured_raw_submitter(config.bundler.submit_rpcs.first().cloned())
        });

        Self {
            token,
            config,
            paths,
            started_at: SystemTime::now(),
            shutdown_tx,
            store: init.store,
            chain: init.chain,
            bundler_keys: init
                .bundler_keys
                .unwrap_or_else(crate::bundler_keys::default_bundler_key_store),
            raw_submitter,
            rate_limiter: Arc::new(crate::rate_limit::RateLimiter::default()),
            per_sender_rate_limiter: Arc::new(crate::rate_limit::PerSenderRateLimiter::default()),
            admin_challenges: Arc::new(crate::admin_challenge::AdminChallengeStore::default()),
            relayer_lifecycle_locks: Arc::new(
                crate::relayer_lifecycle::RelayerLifecycleLocks::default(),
            ),
            state_override_smoke: Arc::new(RwLock::new(StateOverrideSmokeStatus::Pending)),
            transport: init.transport,
            #[cfg(test)]
            health_uses_chain: init.health_uses_chain,
        }
    }

    #[cfg(test)]
    pub(crate) fn for_tests(chain: Arc<dyn wallet_chain::ChainAdapter>) -> Self {
        let (shutdown_tx, _shutdown_rx) = watch::channel(false);
        let mut conn = wallet_node_store::db::open_in_memory()
            .expect("test store connection should open in memory");
        wallet_node_store::migrations::apply(&mut conn)
            .expect("test store migrations should apply");
        let store = wallet_node_store::StoreActor::start(conn);

        Self {
            token: Arc::new(crate::auth::Token::generate()),
            config: Arc::new(crate::config::Config::default()),
            paths: Arc::new(crate::paths::Paths {
                app_support_dir: std::path::PathBuf::from("/tmp/wallet-node-test"),
                socket_path: std::path::PathBuf::from("/tmp/wallet-node-test/wallet-node.sock"),
                db_path: std::path::PathBuf::from("/tmp/wallet-node-test/node.sqlite"),
                helios_dir: std::path::PathBuf::from("/tmp/wallet-node-test/helios"),
                logs_dir: std::path::PathBuf::from("/tmp/wallet-node-test/logs"),
                config_path: std::path::PathBuf::from("/tmp/wallet-node-test/config.toml"),
            }),
            started_at: SystemTime::now(),
            shutdown_tx,
            store,
            chain,
            bundler_keys: Arc::new(crate::bundler_keys::MemoryBundlerKeyStore::new()),
            raw_submitter: Arc::new(TestRawTransactionSubmitter),
            rate_limiter: Arc::new(crate::rate_limit::RateLimiter::default()),
            per_sender_rate_limiter: Arc::new(crate::rate_limit::PerSenderRateLimiter::default()),
            admin_challenges: Arc::new(crate::admin_challenge::AdminChallengeStore::default()),
            relayer_lifecycle_locks: Arc::new(
                crate::relayer_lifecycle::RelayerLifecycleLocks::default(),
            ),
            state_override_smoke: Arc::new(RwLock::new(StateOverrideSmokeStatus::Pending)),
            transport: TransportInfo::http(),
            health_uses_chain: true,
        }
    }

    pub(crate) fn state_override_smoke_status(&self) -> StateOverrideSmokeStatus {
        self.state_override_smoke
            .read()
            .expect("state override smoke status lock is not poisoned")
            .clone()
    }

    pub(crate) fn mark_state_override_smoke_passed(&self) {
        *self
            .state_override_smoke
            .write()
            .expect("state override smoke status lock is not poisoned") =
            StateOverrideSmokeStatus::Passed;
    }

    pub(crate) fn mark_state_override_smoke_failed(&self, reason: impl Into<String>) {
        *self
            .state_override_smoke
            .write()
            .expect("state override smoke status lock is not poisoned") =
            StateOverrideSmokeStatus::Failed(reason.into());
    }
}

impl std::fmt::Debug for DaemonState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DaemonState")
            .field("token", &self.token)
            .field("config", &self.config)
            .field("paths", &self.paths)
            .field("started_at", &self.started_at)
            .field("shutdown_tx", &self.shutdown_tx)
            .field("store", &"<StoreHandle>")
            .field("chain", &"<ChainAdapter>")
            .field("bundler_keys", &"<BundlerKeyStore>")
            .field("raw_submitter", &"<RawTransactionSubmitter>")
            .field("rate_limiter", &"<RateLimiter>")
            .field("per_sender_rate_limiter", &"<PerSenderRateLimiter>")
            .field("admin_challenges", &"<AdminChallengeStore>")
            .field("relayer_lifecycle_locks", &"<RelayerLifecycleLocks>")
            .field("state_override_smoke", &self.state_override_smoke_status())
            .field("transport", &self.transport)
            .field("health_uses_chain", &{
                #[cfg(test)]
                {
                    self.health_uses_chain
                }
                #[cfg(not(test))]
                {
                    true
                }
            })
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum StateOverrideSmokeStatus {
    Pending,
    Passed,
    Failed(String),
}

pub struct DaemonStateInit {
    store: wallet_node_store::StoreHandle,
    chain: Arc<dyn wallet_chain::ChainAdapter>,
    bundler_keys: Option<Arc<dyn BundlerKeyStore>>,
    raw_submitter: Option<Arc<dyn RawTransactionSubmitter>>,
    transport: TransportInfo,
    #[cfg(test)]
    health_uses_chain: bool,
}

impl From<(TransportInfo, wallet_node_store::StoreHandle)> for DaemonStateInit {
    fn from((transport, store): (TransportInfo, wallet_node_store::StoreHandle)) -> Self {
        Self {
            store,
            chain: Arc::new(wallet_chain::MockChainAdapter::new()),
            bundler_keys: None,
            raw_submitter: None,
            transport,
            #[cfg(test)]
            health_uses_chain: true,
        }
    }
}

impl
    From<(
        TransportInfo,
        wallet_node_store::StoreHandle,
        Arc<dyn wallet_chain::ChainAdapter>,
    )> for DaemonStateInit
{
    fn from(
        (transport, store, chain): (
            TransportInfo,
            wallet_node_store::StoreHandle,
            Arc<dyn wallet_chain::ChainAdapter>,
        ),
    ) -> Self {
        Self {
            store,
            chain,
            bundler_keys: None,
            raw_submitter: None,
            transport,
            #[cfg(test)]
            health_uses_chain: true,
        }
    }
}

#[cfg(test)]
impl From<TransportInfo> for DaemonStateInit {
    fn from(transport: TransportInfo) -> Self {
        let mut conn = wallet_node_store::db::open_in_memory()
            .expect("test store connection should open in memory");
        wallet_node_store::migrations::apply(&mut conn)
            .expect("test store migrations should apply");
        let store = wallet_node_store::StoreActor::start(conn);

        Self {
            store,
            chain: Arc::new(wallet_chain::MockChainAdapter::new()),
            bundler_keys: None,
            raw_submitter: None,
            transport,
            health_uses_chain: false,
        }
    }
}

#[cfg(test)]
impl From<(TransportInfo, Arc<dyn wallet_chain::ChainAdapter>)> for DaemonStateInit {
    fn from((transport, chain): (TransportInfo, Arc<dyn wallet_chain::ChainAdapter>)) -> Self {
        let mut conn = wallet_node_store::db::open_in_memory()
            .expect("test store connection should open in memory");
        wallet_node_store::migrations::apply(&mut conn)
            .expect("test store migrations should apply");
        let store = wallet_node_store::StoreActor::start(conn);

        Self {
            store,
            chain,
            bundler_keys: None,
            raw_submitter: None,
            transport,
            health_uses_chain: true,
        }
    }
}

impl
    From<(
        TransportInfo,
        wallet_node_store::StoreHandle,
        Arc<dyn wallet_chain::ChainAdapter>,
        Arc<dyn BundlerKeyStore>,
    )> for DaemonStateInit
{
    fn from(
        (transport, store, chain, bundler_keys): (
            TransportInfo,
            wallet_node_store::StoreHandle,
            Arc<dyn wallet_chain::ChainAdapter>,
            Arc<dyn BundlerKeyStore>,
        ),
    ) -> Self {
        Self {
            store,
            chain,
            bundler_keys: Some(bundler_keys),
            raw_submitter: None,
            transport,
            #[cfg(test)]
            health_uses_chain: true,
        }
    }
}

impl
    From<(
        TransportInfo,
        wallet_node_store::StoreHandle,
        Arc<dyn wallet_chain::ChainAdapter>,
        Arc<dyn BundlerKeyStore>,
        Arc<dyn RawTransactionSubmitter>,
    )> for DaemonStateInit
{
    fn from(
        (transport, store, chain, bundler_keys, raw_submitter): (
            TransportInfo,
            wallet_node_store::StoreHandle,
            Arc<dyn wallet_chain::ChainAdapter>,
            Arc<dyn BundlerKeyStore>,
            Arc<dyn RawTransactionSubmitter>,
        ),
    ) -> Self {
        Self {
            store,
            chain,
            bundler_keys: Some(bundler_keys),
            raw_submitter: Some(raw_submitter),
            transport,
            #[cfg(test)]
            health_uses_chain: true,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TransportInfo {
    pub kind: TransportKind,
}

impl TransportInfo {
    pub fn unix() -> Self {
        Self {
            kind: TransportKind::Unix,
        }
    }

    pub fn http() -> Self {
        Self {
            kind: TransportKind::Http,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransportKind {
    Unix,
    Http,
}

fn configured_raw_submitter(endpoint: Option<String>) -> Arc<dyn RawTransactionSubmitter> {
    match endpoint {
        Some(endpoint) if !endpoint.trim().is_empty() => {
            Arc::new(RawTransactionSubmitClient::new(endpoint))
        }
        _ => Arc::new(DisabledRawTransactionSubmitter),
    }
}

struct DisabledRawTransactionSubmitter;

#[async_trait::async_trait]
impl RawTransactionSubmitter for DisabledRawTransactionSubmitter {
    async fn submit_raw_transaction(
        &self,
        _raw_tx: &alloy_primitives::Bytes,
        _expected_tx_hash: alloy_primitives::B256,
    ) -> wallet_bundler::Result<RawTransactionSubmitOutcome> {
        Err(wallet_bundler::BundlerError::RawTransactionSubmission {
            reason: "submit_rpc_not_configured".to_string(),
        })
    }
}

#[cfg(test)]
struct TestRawTransactionSubmitter;

#[cfg(test)]
#[async_trait::async_trait]
impl RawTransactionSubmitter for TestRawTransactionSubmitter {
    async fn submit_raw_transaction(
        &self,
        _raw_tx: &alloy_primitives::Bytes,
        expected_tx_hash: alloy_primitives::B256,
    ) -> wallet_bundler::Result<RawTransactionSubmitOutcome> {
        Ok(RawTransactionSubmitOutcome::Accepted(expected_tx_hash))
    }
}

impl TransportKind {
    pub fn as_str(self) -> &'static str {
        match self {
            TransportKind::Unix => "unix",
            TransportKind::Http => "http",
        }
    }
}
