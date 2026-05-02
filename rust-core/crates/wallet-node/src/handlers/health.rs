use serde::Serialize;
use serde_json::{json, Value};
use wallet_chain::BlockTag;

use crate::handlers::wallet::bundler_status::THRESHOLD_LOW;
use crate::state::{DaemonState, StateOverrideSmokeStatus};

pub(crate) const DEGRADED_REASON_HELIOS_LAGGING: &str = "helios_lagging";
pub(crate) const DEGRADED_REASON_HELIOS_UNREACHABLE: &str = "helios_unreachable";
pub(crate) const DEGRADED_REASON_BUNDLER_NEEDS_TOPUP: &str = "bundler_needs_topup";
pub(crate) const DEGRADED_REASON_GAS_RELAY_STUCK: &str =
    crate::handlers::wallet::replacement::GAS_RELAY_STUCK_REASON;

const STATUS_SYNCING_CONSENSUS: &str = "syncing_consensus";
const STATUS_VERIFIED_READS_READY: &str = "verified_reads_ready";
const STATUS_BUNDLER_READY: &str = "bundler_ready";
const STATUS_DEGRADED: &str = "degraded";
const STATUS_OFFLINE: &str = "offline";

pub async fn handle(state: &DaemonState) -> Value {
    #[cfg(test)]
    if !state.health_uses_chain {
        return phase_one_starting_response(state);
    }

    let chain_health = if let Some(reason) = state.chain.offline_reason() {
        ChainHealth::offline(reason)
    } else {
        resolve_chain_health(state).await
    };
    let bundler_health = if chain_health.helios.ready {
        resolve_bundler_health(state).await
    } else {
        bundler_not_ready(state, "verified_reads_not_ready")
    };
    let (status, reason) = combined_status(&chain_health, &bundler_health);
    let response = HealthResponse {
        status,
        reason,
        api_version: wallet_node_api::API_VERSION,
        chain_id: state.config.network.chain_id,
        daemon_version: daemon_version(),
        transport: TransportStatus {
            kind: state.transport.kind.as_str(),
            authenticated: true,
        },
        helios: chain_health.helios,
        bundler: bundler_health,
        wallet: None,
    };

    serde_json::to_value(response).expect("health response should serialize")
}

async fn resolve_chain_health(state: &DaemonState) -> ChainHealth {
    let synced = state.chain.is_synced().await;
    if !synced {
        return ChainHealth::syncing(false);
    }

    let head = match state.chain.current_head().await {
        Ok(head) => head,
        Err(error) => {
            tracing::warn!(error = %error, "helios current head unavailable for health");
            return ChainHealth::syncing(true);
        }
    };

    let helios_head = BlockHead {
        number: head.number,
        hash: format!("{:#x}", head.hash),
    };

    match state.chain.execution_rpc_head().await {
        Ok(exec_num) if head.number + 8u64 < exec_num => ChainHealth {
            status: STATUS_DEGRADED.to_string(),
            reason: Some(DEGRADED_REASON_HELIOS_LAGGING.to_string()),
            helios: HeliosStatus::ready(Some(helios_head)),
        },
        Ok(_) => ChainHealth::ready(helios_head),
        Err(error) => {
            tracing::warn!(
                error = %error,
                reason = DEGRADED_REASON_HELIOS_UNREACHABLE,
                "execution rpc head unavailable for health"
            );
            ChainHealth::ready(helios_head)
        }
    }
}

async fn resolve_bundler_health(state: &DaemonState) -> Value {
    let active = match state
        .store
        .bundler_account_active(state.config.network.chain_id)
        .await
    {
        Ok(active) => active,
        Err(error) => {
            tracing::warn!(error = %error, "bundler account lookup failed for health");
            return bundler_not_ready(state, "bundler_store_unavailable");
        }
    };

    let Some(active) = active else {
        return bundler_not_ready(state, "bundler_eoa_missing");
    };

    let address = match active.address.parse() {
        Ok(address) => address,
        Err(error) => {
            tracing::warn!(
                error = %error,
                address = active.address,
                "stored bundler account address is invalid"
            );
            return bundler_not_ready(state, "invalid_bundler_eoa");
        }
    };

    let balance = match state.chain.eth_get_balance(address, BlockTag::Latest).await {
        Ok(balance) => balance,
        Err(error) => {
            tracing::warn!(error = %error, "bundler EOA balance unavailable for health");
            return json!({
                "ready": false,
                "entryPoints": state.config.bundler.entry_points,
                "eoa": active.address,
                "balance": null,
                "thresholdLow": THRESHOLD_LOW,
                "needsTopup": false,
                "lifecycle": active.lifecycle.as_str(),
                "reason": "bundler_balance_unavailable"
            });
        }
    };

    let threshold = match parse_low_balance_threshold(THRESHOLD_LOW) {
        Ok(threshold) => threshold,
        Err(error) => {
            tracing::error!(error = %error, "invalid bundler EOA low-balance threshold");
            return bundler_not_ready(state, "invalid_bundler_threshold");
        }
    };
    let smoke_status = state.state_override_smoke_status();
    let compromise = match crate::handlers::wallet::bundler_account::compromise_status(
        state, &active, balance, threshold,
    )
    .await
    {
        Ok(compromise) => compromise,
        Err(_) => Some("compromise_status_unavailable".to_string()),
    };
    let ready = balance >= threshold && compromise.is_none();
    let replacement = replacement_health(state, &active.address)
        .await
        .unwrap_or_else(|reason| {
            json!({
                "eligible": false,
                "blocked": false,
                "blockedReason": Value::Null,
                "reason": reason
            })
        });
    let (ready, reason) = match smoke_status {
        StateOverrideSmokeStatus::Passed => (
            ready,
            if ready {
                Value::Null
            } else {
                Value::String("bundler_eoa_needs_topup".to_string())
            },
        ),
        StateOverrideSmokeStatus::Pending => (
            false,
            Value::String("state_override_smoke_pending".to_string()),
        ),
        StateOverrideSmokeStatus::Failed(_) => (
            false,
            Value::String("helios_state_override_unsupported".to_string()),
        ),
    };

    json!({
        "ready": ready,
        "entryPoints": state.config.bundler.entry_points,
        "eoa": active.address,
        "balance": wallet_bundler::gas::u256_hex(balance),
        "thresholdLow": THRESHOLD_LOW,
        "needsTopup": balance < threshold,
        "lifecycle": active.lifecycle.as_str(),
        "replacement": replacement,
        "compromise": {
            "suspected": compromise.is_some(),
            "reason": compromise,
            "submissionBlocked": compromise.is_some()
        },
        "reason": reason
    })
}

fn bundler_not_ready(state: &DaemonState, reason: &str) -> Value {
    json!({
        "ready": false,
        "entryPoints": state.config.bundler.entry_points,
        "eoa": null,
        "balance": null,
        "thresholdLow": THRESHOLD_LOW,
        "needsTopup": reason == "bundler_eoa_missing",
        "reason": reason
    })
}

fn parse_low_balance_threshold(value: &str) -> Result<alloy_primitives::U256, String> {
    alloy_primitives::U256::from_str_radix(value.trim_start_matches("0x"), 16)
        .map_err(|error| error.to_string())
}

fn combined_status(chain_health: &ChainHealth, bundler_health: &Value) -> (String, Option<String>) {
    if chain_health.status != STATUS_VERIFIED_READS_READY {
        return (chain_health.status.clone(), chain_health.reason.clone());
    }

    if bundler_health["reason"].as_str() == Some("helios_state_override_unsupported") {
        return (
            STATUS_DEGRADED.to_string(),
            Some("helios_state_override_unsupported".to_string()),
        );
    }

    if bundler_health["replacement"]["blockedReason"]["reason"].as_str()
        == Some(DEGRADED_REASON_GAS_RELAY_STUCK)
    {
        return (
            STATUS_DEGRADED.to_string(),
            Some(DEGRADED_REASON_GAS_RELAY_STUCK.to_string()),
        );
    }

    if bundler_health["compromise"]["suspected"].as_bool() == Some(true) {
        return (
            STATUS_DEGRADED.to_string(),
            Some("bundler_eoa_compromise_suspected".to_string()),
        );
    }

    if bundler_health["ready"].as_bool() == Some(true) {
        return (STATUS_BUNDLER_READY.to_string(), None);
    }

    if bundler_health["eoa"].is_string() && bundler_health["needsTopup"].as_bool() == Some(true) {
        return (
            STATUS_DEGRADED.to_string(),
            Some(DEGRADED_REASON_BUNDLER_NEEDS_TOPUP.to_string()),
        );
    }

    (chain_health.status.clone(), chain_health.reason.clone())
}

async fn replacement_health(
    state: &DaemonState,
    bundler_address: &str,
) -> Result<Value, &'static str> {
    let head = state
        .chain
        .current_head()
        .await
        .map_err(|_| "replacement_head_unavailable")?;
    let pending = state
        .store
        .submitted_txs_list_for_watcher()
        .await
        .map_err(|_| "replacement_store_unavailable")?;
    let candidate = wallet_bundler::eligible_replacement_candidate(
        &pending,
        state.config.network.chain_id,
        bundler_address,
        head.number,
        wallet_bundler::DEFAULT_REPLACEMENT_ELIGIBILITY_BLOCKS,
    );
    let Some(candidate) = candidate else {
        return Ok(json!({
            "eligible": false,
            "blocked": false,
            "blockedReason": Value::Null,
            "txHash": Value::Null,
            "userOpHash": Value::Null,
            "nonce": Value::Null,
            "currentBlock": head.number,
            "minAgeBlocks": wallet_bundler::DEFAULT_REPLACEMENT_ELIGIBILITY_BLOCKS
        }));
    };

    let blocked_reason =
        crate::handlers::wallet::replacement::blocked_reason(state, candidate).await;
    Ok(json!({
        "eligible": true,
        "blocked": blocked_reason.is_some(),
        "blockedReason": blocked_reason.unwrap_or(Value::Null),
        "txHash": candidate.tx_hash,
        "userOpHash": candidate.user_op_hash,
        "nonce": candidate.nonce,
        "submittedAtBlock": candidate.submitted_at_block,
        "currentBlock": head.number,
        "minAgeBlocks": wallet_bundler::DEFAULT_REPLACEMENT_ELIGIBILITY_BLOCKS
    }))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HealthResponse {
    status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<String>,
    api_version: u32,
    chain_id: u64,
    daemon_version: String,
    transport: TransportStatus,
    helios: HeliosStatus,
    bundler: Value,
    wallet: Option<Value>,
}

#[derive(Serialize)]
struct TransportStatus {
    kind: &'static str,
    authenticated: bool,
}

struct ChainHealth {
    status: String,
    reason: Option<String>,
    helios: HeliosStatus,
}

impl ChainHealth {
    fn syncing(checkpoint_loaded: bool) -> Self {
        Self {
            status: STATUS_SYNCING_CONSENSUS.to_string(),
            reason: None,
            helios: HeliosStatus {
                ready: false,
                checkpoint_loaded,
                checkpoint_age_days: None,
                head: None,
            },
        }
    }

    fn ready(head: BlockHead) -> Self {
        Self {
            status: STATUS_VERIFIED_READS_READY.to_string(),
            reason: None,
            helios: HeliosStatus::ready(Some(head)),
        }
    }

    fn offline(reason: &'static str) -> Self {
        Self {
            status: STATUS_OFFLINE.to_string(),
            reason: Some(reason.to_string()),
            helios: HeliosStatus {
                ready: false,
                checkpoint_loaded: false,
                checkpoint_age_days: None,
                head: None,
            },
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HeliosStatus {
    ready: bool,
    checkpoint_loaded: bool,
    checkpoint_age_days: Option<f64>,
    head: Option<BlockHead>,
}

impl HeliosStatus {
    fn ready(head: Option<BlockHead>) -> Self {
        Self {
            ready: true,
            checkpoint_loaded: true,
            checkpoint_age_days: None,
            head,
        }
    }
}

#[derive(Serialize)]
struct BlockHead {
    number: u64,
    hash: String,
}

#[cfg(test)]
fn phase_one_starting_response(state: &DaemonState) -> Value {
    json!({
        "status": "starting",
        "apiVersion": wallet_node_api::API_VERSION,
        "chainId": state.config.network.chain_id,
        "daemonVersion": daemon_version(),
        "transport": {
            "kind": state.transport.kind.as_str(),
            "authenticated": true,
        },
        "helios": {
            "ready": false,
            "checkpointLoaded": false,
            "checkpointAgeDays": null,
            "head": null,
        },
        "bundler": {
            "ready": false,
            "entryPoints": [],
            "eoa": null,
            "balance": null,
            "thresholdLow": null,
            "needsTopup": false,
        },
        "wallet": null,
    })
}

fn daemon_version() -> String {
    format!(
        "{}+{}",
        env!("CARGO_PKG_VERSION"),
        option_env!("WALLET_NODE_GIT_SHA").unwrap_or("unknown")
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::future::Future;
    use std::pin::Pin;
    use std::sync::Arc;
    use wallet_chain::{
        Address, Block, BlockHeader, BlockTag, Bytes, CallRequest, ChainAdapter, ChainError,
        MockChainAdapter, StateOverride, TransactionReceipt, B256, U256,
    };
    use wallet_node_store::{
        SubmittedTransaction, SubmittedTxStatus, UserOpStatus, UserOperation as StoredUserOperation,
    };

    fn hash(byte: u8) -> B256 {
        B256::from([byte; 32])
    }

    fn header(number: u64) -> BlockHeader {
        BlockHeader {
            number,
            hash: hash(1),
            parent_hash: hash(2),
            timestamp: 1_700_000_000,
            state_root: Some(hash(3)),
            transactions_root: Some(hash(4)),
            receipts_root: Some(hash(5)),
            gas_used: Some(21_000),
            gas_limit: Some(30_000_000),
            base_fee_per_gas: Some(U256::from(1_000_000_000_u64)),
        }
    }

    fn test_state(chain: Arc<dyn ChainAdapter>) -> DaemonState {
        DaemonState::for_tests(chain)
    }

    fn synced_chain(helios_head: u64, exec_head: u64) -> Arc<MockChainAdapter> {
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        chain
            .set_current_head(header(helios_head))
            .set_execution_rpc_head(exec_head);
        chain
    }

    struct ExecutionHeadErrorChain {
        inner: MockChainAdapter,
    }

    impl ExecutionHeadErrorChain {
        fn synced(helios_head: u64) -> Self {
            let inner = MockChainAdapter::with_synced(true);
            inner.set_current_head(header(helios_head));
            Self { inner }
        }
    }

    impl ChainAdapter for ExecutionHeadErrorChain {
        fn eth_get_balance<'life0, 'async_trait>(
            &'life0 self,
            address: Address,
            block: BlockTag,
        ) -> Pin<Box<dyn Future<Output = Result<U256, ChainError>> + Send + 'async_trait>>
        where
            'life0: 'async_trait,
            Self: 'async_trait,
        {
            Box::pin(async move { self.inner.eth_get_balance(address, block).await })
        }

        fn eth_get_code<'life0, 'async_trait>(
            &'life0 self,
            address: Address,
            block: BlockTag,
        ) -> Pin<Box<dyn Future<Output = Result<Bytes, ChainError>> + Send + 'async_trait>>
        where
            'life0: 'async_trait,
            Self: 'async_trait,
        {
            Box::pin(async move { self.inner.eth_get_code(address, block).await })
        }

        fn eth_get_storage_at<'life0, 'async_trait>(
            &'life0 self,
            address: Address,
            slot: B256,
            block: BlockTag,
        ) -> Pin<Box<dyn Future<Output = Result<B256, ChainError>> + Send + 'async_trait>>
        where
            'life0: 'async_trait,
            Self: 'async_trait,
        {
            Box::pin(async move { self.inner.eth_get_storage_at(address, slot, block).await })
        }

        fn eth_get_transaction_count<'life0, 'async_trait>(
            &'life0 self,
            address: Address,
            block: BlockTag,
        ) -> Pin<Box<dyn Future<Output = Result<u64, ChainError>> + Send + 'async_trait>>
        where
            'life0: 'async_trait,
            Self: 'async_trait,
        {
            Box::pin(async move { self.inner.eth_get_transaction_count(address, block).await })
        }

        fn eth_call<'life0, 'async_trait>(
            &'life0 self,
            tx: CallRequest,
            block: BlockTag,
            state_overrides: Option<StateOverride>,
        ) -> Pin<Box<dyn Future<Output = Result<Bytes, ChainError>> + Send + 'async_trait>>
        where
            'life0: 'async_trait,
            Self: 'async_trait,
        {
            Box::pin(async move { self.inner.eth_call(tx, block, state_overrides).await })
        }

        fn eth_estimate_gas<'life0, 'async_trait>(
            &'life0 self,
            tx: CallRequest,
            block: Option<BlockTag>,
            state_overrides: Option<StateOverride>,
        ) -> Pin<Box<dyn Future<Output = Result<u64, ChainError>> + Send + 'async_trait>>
        where
            'life0: 'async_trait,
            Self: 'async_trait,
        {
            Box::pin(async move {
                self.inner
                    .eth_estimate_gas(tx, block, state_overrides)
                    .await
            })
        }

        fn eth_get_transaction_receipt<'life0, 'async_trait>(
            &'life0 self,
            tx_hash: B256,
        ) -> Pin<
            Box<
                dyn Future<Output = Result<Option<TransactionReceipt>, ChainError>>
                    + Send
                    + 'async_trait,
            >,
        >
        where
            'life0: 'async_trait,
            Self: 'async_trait,
        {
            Box::pin(async move { self.inner.eth_get_transaction_receipt(tx_hash).await })
        }

        fn eth_get_block_by_number<'life0, 'async_trait>(
            &'life0 self,
            block: BlockTag,
            full_txs: bool,
        ) -> Pin<Box<dyn Future<Output = Result<Option<Block>, ChainError>> + Send + 'async_trait>>
        where
            'life0: 'async_trait,
            Self: 'async_trait,
        {
            Box::pin(async move { self.inner.eth_get_block_by_number(block, full_txs).await })
        }

        fn current_head<'life0, 'async_trait>(
            &'life0 self,
        ) -> Pin<Box<dyn Future<Output = Result<BlockHeader, ChainError>> + Send + 'async_trait>>
        where
            'life0: 'async_trait,
            Self: 'async_trait,
        {
            Box::pin(async move { self.inner.current_head().await })
        }

        fn execution_rpc_head<'life0, 'async_trait>(
            &'life0 self,
        ) -> Pin<Box<dyn Future<Output = Result<u64, ChainError>> + Send + 'async_trait>>
        where
            'life0: 'async_trait,
            Self: 'async_trait,
        {
            Box::pin(async { Err(ChainError::RpcError("execution rpc down".to_string())) })
        }

        fn is_synced<'life0, 'async_trait>(
            &'life0 self,
        ) -> Pin<Box<dyn Future<Output = bool> + Send + 'async_trait>>
        where
            'life0: 'async_trait,
            Self: 'async_trait,
        {
            Box::pin(async move { self.inner.is_synced().await })
        }
    }

    #[test]
    fn daemon_version_format() {
        let version = format!(
            "{}+{}",
            env!("CARGO_PKG_VERSION"),
            option_env!("WALLET_NODE_GIT_SHA").unwrap_or("unknown")
        );

        let parts: Vec<_> = version.split('+').collect();
        assert_eq!(
            parts.len(),
            2,
            "daemon_version does not match expected format: {}",
            version
        );
        assert!(
            parts[0].chars().all(|ch| ch.is_ascii_digit() || ch == '.'),
            "daemon_version does not match expected format: {}",
            version
        );
        assert!(
            parts[1] == "unknown"
                || (parts[1].len() >= 7
                    && parts[1].len() <= 12
                    && parts[1]
                        .chars()
                        .all(|ch| ch.is_ascii_digit() || ('a'..='f').contains(&ch))),
            "daemon_version does not match expected format: {}",
            version
        );
    }

    #[test]
    fn low_balance_threshold_parser_accepts_hex_and_rejects_malformed_values() {
        assert_eq!(
            super::parse_low_balance_threshold(THRESHOLD_LOW).unwrap(),
            U256::from(5_000_000_000_000_000_u64)
        );
        assert!(super::parse_low_balance_threshold("0xnot-hex").is_err());
    }

    #[tokio::test]
    async fn health_starting_when_chain_not_synced() {
        let chain = Arc::new(MockChainAdapter::with_synced(false));
        let value = handle(&test_state(chain)).await;

        assert_eq!(value["status"], STATUS_SYNCING_CONSENSUS);
        assert_eq!(value["helios"]["ready"], false);
        assert_eq!(value["helios"]["head"], Value::Null);
        assert_eq!(value["bundler"]["entryPoints"].as_array().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn health_verified_reads_ready_when_synced_and_fresh() {
        let value = handle(&test_state(synced_chain(100, 105))).await;

        assert_eq!(value["status"], STATUS_VERIFIED_READS_READY);
        assert_eq!(value["helios"]["ready"], true);
        assert_eq!(value["helios"]["head"]["number"], 100);
        assert_eq!(value["bundler"]["ready"], false);
        assert_eq!(value["bundler"]["reason"], "bundler_eoa_missing");
        assert_eq!(value["bundler"]["entryPoints"].as_array().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn health_bundler_ready_when_active_eoa_is_funded() {
        let bundler_eoa = "0xbeef000000000000000000000000000000000000";
        let address: Address = bundler_eoa.parse().unwrap();
        let chain = synced_chain(100, 105);
        chain.set_balance(
            address,
            BlockTag::Latest,
            U256::from(5_000_000_000_000_000_u64),
        );
        let state = test_state(chain);
        state
            .store
            .bundler_account_insert(1, bundler_eoa, "bundler-eoa:1")
            .await
            .unwrap();
        state.mark_state_override_smoke_passed();

        let value = handle(&state).await;

        assert_eq!(value["status"], STATUS_BUNDLER_READY);
        assert_eq!(value["bundler"]["ready"], true);
        assert_eq!(value["bundler"]["eoa"], bundler_eoa);
        assert_eq!(value["bundler"]["needsTopup"], false);
    }

    #[tokio::test]
    async fn health_degraded_when_replacement_bump_exceeds_userop_caps() {
        let bundler_eoa = "0xbeef000000000000000000000000000000000000";
        let address: Address = bundler_eoa.parse().unwrap();
        let chain = synced_chain(106, 106);
        chain.set_balance(
            address,
            BlockTag::Latest,
            U256::from(5_000_000_000_000_000_u64),
        );
        let state = test_state(chain);
        state
            .store
            .bundler_account_insert(1, bundler_eoa, "bundler-eoa:1")
            .await
            .unwrap();
        state.mark_state_override_smoke_passed();

        let user_op_hash = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let raw_op = json!({
            "sender": "0xd73c7780b1c1da1586a8332d5499f36b7cbb33c2",
            "nonce": "0x01",
            "callData": "0x",
            "callGasLimit": "0x10",
            "verificationGasLimit": "0x20",
            "preVerificationGas": "0x30",
            "maxFeePerGas": "0x40",
            "maxPriorityFeePerGas": "0x05",
            "signature": "0xab"
        });
        state
            .store
            .user_op_insert(StoredUserOperation {
                user_op_hash: user_op_hash.to_string(),
                chain_id: 1,
                entry_point: "0x0000000071727de22e5e9d8baf0edac6f37da032".to_string(),
                sender: "0xd73c7780b1c1da1586a8332d5499f36b7cbb33c2".to_string(),
                nonce: "0x1".to_string(),
                user_op_json: raw_op.to_string(),
                status: UserOpStatus::Submitted,
                created_at: 1,
                updated_at: 1,
            })
            .await
            .unwrap();
        state
            .store
            .submitted_tx_insert(SubmittedTransaction {
                tx_hash: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                    .to_string(),
                user_op_hash: user_op_hash.to_string(),
                chain_id: 1,
                bundler_address: bundler_eoa.to_string(),
                nonce: 7,
                raw_tx: "0x02".to_string(),
                max_fee_per_gas: "0x40".to_string(),
                max_priority_fee_per_gas: "0x05".to_string(),
                status: SubmittedTxStatus::Submitted,
                replacement_of: None,
                submitted_at_block: Some(100),
                created_at: 1,
                updated_at: 1,
            })
            .await
            .unwrap();

        let value = handle(&state).await;

        assert_eq!(value["status"], STATUS_DEGRADED);
        assert_eq!(value["reason"], DEGRADED_REASON_GAS_RELAY_STUCK);
        assert_eq!(value["bundler"]["ready"], true);
        assert_eq!(value["bundler"]["replacement"]["eligible"], true);
        assert_eq!(value["bundler"]["replacement"]["blocked"], true);
        assert_eq!(
            value["bundler"]["replacement"]["blockedReason"]["reason"],
            DEGRADED_REASON_GAS_RELAY_STUCK
        );
    }

    #[tokio::test]
    async fn health_degraded_when_active_eoa_needs_topup() {
        let bundler_eoa = "0xbeef000000000000000000000000000000000000";
        let address: Address = bundler_eoa.parse().unwrap();
        let chain = synced_chain(100, 105);
        chain.set_balance(address, BlockTag::Latest, U256::from(1_u64));
        let state = test_state(chain);
        state
            .store
            .bundler_account_insert(1, bundler_eoa, "bundler-eoa:1")
            .await
            .unwrap();
        state.mark_state_override_smoke_passed();

        let value = handle(&state).await;

        assert_eq!(value["status"], STATUS_DEGRADED);
        assert_eq!(value["reason"], DEGRADED_REASON_BUNDLER_NEEDS_TOPUP);
        assert_eq!(value["bundler"]["ready"], false);
        assert_eq!(value["bundler"]["needsTopup"], true);
    }

    #[tokio::test]
    async fn health_blocks_bundler_ready_until_state_override_smoke_passes() {
        let bundler_eoa = "0xbeef000000000000000000000000000000000000";
        let address: Address = bundler_eoa.parse().unwrap();
        let chain = synced_chain(100, 105);
        chain.set_balance(
            address,
            BlockTag::Latest,
            U256::from(5_000_000_000_000_000_u64),
        );
        let state = test_state(chain);
        state
            .store
            .bundler_account_insert(1, bundler_eoa, "bundler-eoa:1")
            .await
            .unwrap();

        let value = handle(&state).await;

        assert_eq!(value["status"], STATUS_VERIFIED_READS_READY);
        assert_eq!(value["bundler"]["ready"], false);
        assert_eq!(value["bundler"]["reason"], "state_override_smoke_pending");
    }

    #[tokio::test]
    async fn health_degraded_when_state_override_smoke_fails() {
        let bundler_eoa = "0xbeef000000000000000000000000000000000000";
        let address: Address = bundler_eoa.parse().unwrap();
        let chain = synced_chain(100, 105);
        chain.set_balance(
            address,
            BlockTag::Latest,
            U256::from(5_000_000_000_000_000_u64),
        );
        let state = test_state(chain);
        state
            .store
            .bundler_account_insert(1, bundler_eoa, "bundler-eoa:1")
            .await
            .unwrap();
        state.mark_state_override_smoke_failed("state override unavailable");

        let value = handle(&state).await;

        assert_eq!(value["status"], STATUS_DEGRADED);
        assert_eq!(value["reason"], "helios_state_override_unsupported");
        assert_eq!(value["bundler"]["ready"], false);
        assert_eq!(
            value["bundler"]["reason"],
            "helios_state_override_unsupported"
        );
    }

    #[tokio::test]
    async fn health_degraded_when_lagging() {
        let value = handle(&test_state(synced_chain(100, 120))).await;

        assert_eq!(value["status"], STATUS_DEGRADED);
        assert_eq!(value["reason"], DEGRADED_REASON_HELIOS_LAGGING);
        assert_eq!(value["helios"]["ready"], true);
    }

    #[tokio::test]
    async fn health_tolerates_exec_head_error_returns_verified_reads_ready() {
        let chain = Arc::new(ExecutionHeadErrorChain::synced(100));
        let value = handle(&test_state(chain)).await;

        assert_eq!(value["status"], STATUS_VERIFIED_READS_READY);
        assert_eq!(value.get("reason"), None);
    }

    #[tokio::test]
    async fn health_handles_head_error_as_syncing() {
        let chain = Arc::new(MockChainAdapter::with_synced(true));
        let value = handle(&test_state(chain)).await;

        assert_eq!(value["status"], STATUS_SYNCING_CONSENSUS);
        assert_eq!(value["helios"]["ready"], false);
        assert_eq!(value["helios"]["head"], Value::Null);
    }

    #[tokio::test]
    async fn health_boundary_at_exactly_8_blocks_lag() {
        let value = handle(&test_state(synced_chain(100, 108))).await;

        // The staleness check is strict: 100 + 8 < 108 is false, so 8 blocks is allowed.
        assert_eq!(value["status"], STATUS_VERIFIED_READS_READY);
    }

    #[tokio::test]
    async fn health_boundary_at_9_blocks_lag() {
        let value = handle(&test_state(synced_chain(100, 109))).await;

        assert_eq!(value["status"], STATUS_DEGRADED);
        assert_eq!(value["reason"], DEGRADED_REASON_HELIOS_LAGGING);
    }
}
