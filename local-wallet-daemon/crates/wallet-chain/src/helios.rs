use crate::adapter::ChainAdapter;
use crate::config::ChainConfig;
use crate::error::ChainError;
use crate::types::{
    AccountOverride, Address, Block, BlockHeader, BlockTag, Bytes, CallRequest, StateOverride,
    TransactionReceipt, B256, U256,
};
use alloy::eips::BlockId;
use alloy::primitives::{map::AddressHashMap, TxKind};
use alloy::rpc::types::{
    state::{AccountOverride as HeliosAccountOverride, StateOverride as HeliosStateOverride},
    SyncStatus, TransactionInput, TransactionRequest,
};
use async_trait::async_trait;
use helios_ethereum::config::networks::Network;
use helios_ethereum::database::FileDB;
use helios_ethereum::{EthereumClient, EthereumClientBuilder};
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::json;
use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::task::JoinHandle;

const TWO_WEEKS_SECONDS: u64 = 14 * 24 * 60 * 60;
const CHECKPOINT_TOO_OLD_REASON: &str = "checkpoint_too_old_app_update_required";

pub struct HeliosChainAdapter {
    client: EthereumClient,
    exec_rpc_client: reqwest::Client,
    exec_rpc_url: String,
    max_lag_blocks: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CheckpointDecision {
    Resume,
    UseBundled,
    TooOld,
}

impl HeliosChainAdapter {
    pub async fn start(config: ChainConfig) -> Result<(Self, JoinHandle<()>), ChainError> {
        let data_dir = resolve_data_dir(config.data_dir)?;
        create_private_data_dir(&data_dir)?;

        let network = Network::from_chain_id(config.chain_id).map_err(helios_error)?;
        let mut builder = EthereumClientBuilder::<FileDB>::new()
            .network(network)
            .execution_rpc(config.execution_rpc.as_str())
            .map_err(helios_error)?
            .consensus_rpc(config.consensus_rpc.as_str())
            .map_err(helios_error)?
            .data_dir(data_dir.clone());

        // Prefer a freshly fetched finalized checkpoint from the configured beacon RPC.
        // This keeps the light client bootstrappable on any network (including Sepolia,
        // which ships no bundled checkpoint) and avoids resuming from a stale on-disk
        // root the beacon node may have already pruned. If the fetch fails, fall back to
        // the bundled/cached checkpoint freshness logic.
        match fetch_finalized_checkpoint(&config.consensus_rpc).await {
            Ok(checkpoint) => {
                tracing::info!(%checkpoint, "using fresh finalized checkpoint from beacon RPC");
                builder = builder.checkpoint(checkpoint);
            }
            Err(error) => {
                tracing::warn!(
                    error = %error,
                    "could not fetch fresh checkpoint; falling back to bundled/cached checkpoint"
                );
                let on_disk_exists = fs::read_dir(&data_dir)
                    .map_err(internal_error)?
                    .next()
                    .transpose()
                    .map_err(internal_error)?
                    .is_some();
                let bundled_timestamp = env!("BUNDLED_CHECKPOINT_SLOT_TIMESTAMP")
                    .parse::<u64>()
                    .map_err(internal_error)?;
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map_err(internal_error)?
                    .as_secs();
                match check_checkpoint_freshness(bundled_timestamp, on_disk_exists, now) {
                    CheckpointDecision::TooOld => {
                        return Err(ChainError::CheckpointTooOld {
                            reason: CHECKPOINT_TOO_OLD_REASON.to_string(),
                        });
                    }
                    CheckpointDecision::UseBundled => {
                        let checkpoint = env!("BUNDLED_CHECKPOINT")
                            .parse::<B256>()
                            .map_err(internal_error)?;
                        builder = builder.checkpoint(checkpoint);
                    }
                    CheckpointDecision::Resume => {}
                }
            }
        }

        let client = builder.build().map_err(helios_error)?;
        let join_handle = tokio::spawn(async {});
        let adapter = Self {
            client,
            exec_rpc_client: reqwest::Client::new(),
            exec_rpc_url: config.execution_rpc,
            max_lag_blocks: config.max_helios_lag_blocks,
        };

        Ok((adapter, join_handle))
    }

    pub fn max_lag_blocks(&self) -> u64 {
        self.max_lag_blocks
    }

    pub async fn wait_consensus_synced(&self) -> Result<(), ChainError> {
        self.client.wait_synced().await.map_err(helios_error)
    }

    pub async fn current_checkpoint(&self) -> Result<Option<B256>, ChainError> {
        self.client.current_checkpoint().await.map_err(helios_error)
    }
}

#[async_trait]
impl ChainAdapter for HeliosChainAdapter {
    async fn eth_get_balance(&self, address: Address, block: BlockTag) -> Result<U256, ChainError> {
        let block_id = helios_block_id(block)?;
        self.client
            .get_balance(address, block_id)
            .await
            .map_err(helios_error)
    }

    async fn eth_get_code(&self, address: Address, block: BlockTag) -> Result<Bytes, ChainError> {
        let block_id = helios_block_id(block)?;
        self.client
            .get_code(address, block_id)
            .await
            .map_err(helios_error)
    }

    async fn eth_get_storage_at(
        &self,
        address: Address,
        slot: B256,
        block: BlockTag,
    ) -> Result<B256, ChainError> {
        let slot = U256::from_be_slice(slot.as_slice());
        let block_id = helios_block_id(block)?;
        self.client
            .get_storage_at(address, slot, block_id)
            .await
            .map_err(helios_error)
    }

    async fn eth_get_transaction_count(
        &self,
        address: Address,
        block: BlockTag,
    ) -> Result<u64, ChainError> {
        let block_id = helios_block_id(block)?;
        self.client
            .get_nonce(address, block_id)
            .await
            .map_err(helios_error)
    }

    async fn eth_call(
        &self,
        tx: CallRequest,
        block: BlockTag,
        state_overrides: Option<StateOverride>,
    ) -> Result<Bytes, ChainError> {
        let tx = call_request_to_helios(tx)?;
        let block_id = helios_block_id(block)?;
        let state_overrides = state_overrides.map(state_overrides_to_helios);
        self.client
            .call(&tx, block_id, state_overrides)
            .await
            .map_err(helios_error)
    }

    async fn eth_estimate_gas(
        &self,
        tx: CallRequest,
        block: Option<BlockTag>,
        state_overrides: Option<StateOverride>,
    ) -> Result<u64, ChainError> {
        let tx = call_request_to_helios(tx)?;
        let block_id = block.map(helios_block_id).transpose()?;
        let state_overrides = state_overrides.map(state_overrides_to_helios);
        self.client
            .estimate_gas(&tx, block_id, state_overrides)
            .await
            .map_err(helios_error)
    }

    async fn eth_get_transaction_receipt(
        &self,
        tx_hash: B256,
    ) -> Result<Option<TransactionReceipt>, ChainError> {
        let receipt = self
            .client
            .get_transaction_receipt(tx_hash)
            .await
            .map_err(helios_error)?;
        receipt.map(from_helios_json).transpose()
    }

    async fn eth_get_block_by_number(
        &self,
        block: BlockTag,
        full_txs: bool,
    ) -> Result<Option<Block>, ChainError> {
        let block_id = helios_block_id(block)?;
        let block = self
            .client
            .get_block(block_id, full_txs)
            .await
            .map_err(helios_error)?;
        block.map(from_helios_json).transpose()
    }

    async fn current_head(&self) -> Result<BlockHeader, ChainError> {
        self.eth_get_block_by_number(BlockTag::Latest, false)
            .await?
            .map(|block| block.header)
            .ok_or(ChainError::BlockNotFound)
    }

    async fn execution_rpc_head(&self) -> Result<u64, ChainError> {
        #[derive(Debug, Deserialize)]
        struct RpcErrorBody {
            code: i64,
            message: String,
        }

        #[derive(Debug, Deserialize)]
        struct RpcResponse {
            result: Option<String>,
            error: Option<RpcErrorBody>,
        }

        let response = self
            .exec_rpc_client
            .post(&self.exec_rpc_url)
            .json(&json!({
                "jsonrpc": "2.0",
                "id": 1_u64,
                "method": "eth_blockNumber",
                "params": [],
            }))
            .send()
            .await
            .map_err(rpc_error)?;

        if !response.status().is_success() {
            return Err(ChainError::RpcError(format!(
                "eth_blockNumber HTTP status {}",
                response.status()
            )));
        }

        let body = response.json::<RpcResponse>().await.map_err(rpc_error)?;
        if let Some(error) = body.error {
            return Err(ChainError::RpcError(format!(
                "eth_blockNumber error {}: {}",
                error.code, error.message
            )));
        }

        parse_hex_u64(
            body.result
                .as_deref()
                .ok_or_else(|| ChainError::RpcError("eth_blockNumber missing result".into()))?,
        )
    }

    async fn current_gas_price(&self) -> Result<U256, ChainError> {
        let response = self
            .exec_rpc_client
            .post(&self.exec_rpc_url)
            .json(&json!({
                "jsonrpc": "2.0",
                "id": 1_u64,
                "method": "eth_gasPrice",
                "params": [],
            }))
            .send()
            .await
            .map_err(rpc_error)?;

        if !response.status().is_success() {
            return Err(ChainError::RpcError(format!(
                "eth_gasPrice HTTP status {}",
                response.status()
            )));
        }

        let body = response.text().await.map_err(rpc_error)?;
        parse_hex_u256_response("eth_gasPrice", &body)
    }

    async fn current_max_priority_fee_per_gas(&self) -> Result<U256, ChainError> {
        let response = self
            .exec_rpc_client
            .post(&self.exec_rpc_url)
            .json(&json!({
                "jsonrpc": "2.0",
                "id": 1_u64,
                "method": "eth_maxPriorityFeePerGas",
                "params": [],
            }))
            .send()
            .await
            .map_err(rpc_error)?;

        if !response.status().is_success() {
            return Err(ChainError::RpcError(format!(
                "eth_maxPriorityFeePerGas HTTP status {}",
                response.status()
            )));
        }

        let body = response.text().await.map_err(rpc_error)?;
        parse_hex_u256_response("eth_maxPriorityFeePerGas", &body)
    }

    async fn is_synced(&self) -> bool {
        match self.client.syncing().await {
            Ok(status) => is_helios_synced(status),
            Err(error) => {
                tracing::warn!(error = ?error, "is_synced rpc failure");
                false
            }
        }
    }

    async fn shutdown(&self) {
        self.client.shutdown().await;
    }
}

fn is_helios_synced(status: SyncStatus) -> bool {
    match status {
        SyncStatus::None => true,
        SyncStatus::Info(_) => false,
        #[allow(unreachable_patterns)]
        unknown => {
            tracing::warn!(status = ?unknown, "unknown Helios sync status");
            false
        }
    }
}

pub(crate) fn check_checkpoint_freshness(
    bundled_timestamp_unix: u64,
    on_disk_exists: bool,
    now_unix: u64,
) -> CheckpointDecision {
    if on_disk_exists {
        return CheckpointDecision::Resume;
    }

    let bundled_age = now_unix.saturating_sub(bundled_timestamp_unix);
    if bundled_age <= TWO_WEEKS_SECONDS {
        CheckpointDecision::UseBundled
    } else {
        CheckpointDecision::TooOld
    }
}

/// Fetch a bootstrappable finalized checkpoint block root from a beacon (consensus) RPC.
/// This is the weak-subjectivity anchor Helios bootstraps from; fetching it fresh at
/// startup keeps the light client syncable even when the bundled/cached checkpoint is
/// stale or absent for the active network.
async fn fetch_finalized_checkpoint(consensus_rpc: &str) -> Result<B256, ChainError> {
    let client = reqwest::Client::new();
    let mut candidates = Vec::new();
    let mut errors = Vec::new();

    match fetch_beacon_json(
        &client,
        consensus_rpc,
        "/eth/v1/beacon/states/finalized/finality_checkpoints",
    )
    .await
    {
        Ok(body) => match parse_finality_checkpoint_root(&body) {
            Ok(checkpoint) => push_checkpoint_candidate(&mut candidates, checkpoint),
            Err(error) => errors.push(format!("finality_checkpoints: {error}")),
        },
        Err(error) => errors.push(format!("finality_checkpoints: {error}")),
    }
    match fetch_beacon_json(&client, consensus_rpc, "/eth/v1/beacon/headers/finalized").await {
        Ok(body) => match parse_finalized_root(&body) {
            Ok(checkpoint) => push_checkpoint_candidate(&mut candidates, checkpoint),
            Err(error) => errors.push(format!("headers/finalized: {error}")),
        },
        Err(error) => errors.push(format!("headers/finalized: {error}")),
    }

    if candidates.is_empty() {
        return Err(ChainError::RpcError(format!(
            "no finalized checkpoint roots available: {}",
            errors.join("; ")
        )));
    }

    let mut validation_errors = Vec::new();
    for checkpoint in candidates {
        match validate_bootstrap_checkpoint(&client, consensus_rpc, checkpoint).await {
            Ok(()) => return Ok(checkpoint),
            Err(error) => {
                tracing::warn!(
                    %checkpoint,
                    error = %error,
                    "beacon finalized checkpoint is not bootstrappable"
                );
                validation_errors.push(format!("{checkpoint}: {error}"));
            }
        }
    }

    Err(ChainError::RpcError(format!(
        "no bootstrappable finalized checkpoint found: {}",
        validation_errors.join("; ")
    )))
}

async fn fetch_beacon_json(
    client: &reqwest::Client,
    consensus_rpc: &str,
    path: &str,
) -> Result<serde_json::Value, ChainError> {
    let url = format!("{}{}", consensus_rpc.trim_end_matches('/'), path);
    client
        .get(&url)
        .timeout(std::time::Duration::from_secs(10))
        .send()
        .await
        .map_err(|e| ChainError::RpcError(e.to_string()))?
        .error_for_status()
        .map_err(|e| ChainError::RpcError(e.to_string()))?
        .json()
        .await
        .map_err(|e| ChainError::RpcError(e.to_string()))
}

async fn validate_bootstrap_checkpoint(
    client: &reqwest::Client,
    consensus_rpc: &str,
    checkpoint: B256,
) -> Result<(), ChainError> {
    let url = format!(
        "{}/eth/v1/beacon/light_client/bootstrap/{checkpoint}",
        consensus_rpc.trim_end_matches('/')
    );
    let response = client
        .get(&url)
        .timeout(std::time::Duration::from_secs(10))
        .send()
        .await
        .map_err(|e| ChainError::RpcError(e.to_string()))?;
    if response.status().is_success() {
        return Ok(());
    }
    let status = response.status();
    let body = response.text().await.unwrap_or_default();
    let detail: String = body.chars().take(240).collect();
    Err(ChainError::RpcError(format!(
        "bootstrap status {status}: {detail}"
    )))
}

fn push_checkpoint_candidate(candidates: &mut Vec<B256>, checkpoint: B256) {
    if !candidates.contains(&checkpoint) {
        candidates.push(checkpoint);
    }
}

/// Extract `data.root` from a beacon `headers/finalized` response (the finalized block
/// header root, usable for light-client bootstrap), rejecting a zero root.
fn parse_finalized_root(body: &serde_json::Value) -> Result<B256, ChainError> {
    let root = body
        .get("data")
        .and_then(|data| data.get("root"))
        .and_then(|root| root.as_str())
        .ok_or_else(|| {
            ChainError::RpcError("beacon headers/finalized missing data.root".to_string())
        })?;
    let parsed = root
        .parse::<B256>()
        .map_err(|e| ChainError::RpcError(format!("invalid finalized root '{root}': {e}")))?;
    if parsed == B256::ZERO {
        return Err(ChainError::RpcError(
            "finalized checkpoint root is zero (chain not finalized yet)".to_string(),
        ));
    }
    Ok(parsed)
}

fn parse_finality_checkpoint_root(body: &serde_json::Value) -> Result<B256, ChainError> {
    parse_nonzero_root(
        body.get("data")
            .and_then(|data| data.get("finalized"))
            .and_then(|finalized| finalized.get("root"))
            .and_then(|root| root.as_str()),
        "beacon finality_checkpoints missing data.finalized.root",
    )
}

fn parse_nonzero_root(root: Option<&str>, missing_message: &str) -> Result<B256, ChainError> {
    let root = root.ok_or_else(|| ChainError::RpcError(missing_message.to_string()))?;
    let parsed = root
        .parse::<B256>()
        .map_err(|e| ChainError::RpcError(format!("invalid finalized root '{root}': {e}")))?;
    if parsed == B256::ZERO {
        return Err(ChainError::RpcError(
            "finalized checkpoint root is zero (chain not finalized yet)".to_string(),
        ));
    }
    Ok(parsed)
}

fn resolve_data_dir(data_dir: PathBuf) -> Result<PathBuf, ChainError> {
    if data_dir.is_absolute() {
        Ok(data_dir)
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(data_dir))
            .map_err(internal_error)
    }
}

fn create_private_data_dir(data_dir: &Path) -> Result<(), ChainError> {
    if data_dir.exists() {
        return Ok(());
    }

    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(data_dir)
        .map_err(internal_error)
}

fn helios_block_id(block: BlockTag) -> Result<BlockId, ChainError> {
    Ok(match block {
        BlockTag::Latest => BlockId::latest(),
        BlockTag::Finalized => BlockId::finalized(),
        BlockTag::Earliest => BlockId::earliest(),
        BlockTag::Number(number) => BlockId::number(number),
        BlockTag::Hash(hash) => BlockId::hash(hash),
    })
}

fn from_helios_json<T, S>(value: S) -> Result<T, ChainError>
where
    T: DeserializeOwned,
    S: serde::Serialize,
{
    serde_json::to_value(value)
        .and_then(serde_json::from_value)
        .map_err(internal_error)
}

fn call_request_to_helios(tx: CallRequest) -> Result<TransactionRequest, ChainError> {
    Ok(TransactionRequest {
        from: tx.from,
        to: tx.to.map(TxKind::Call),
        gas_price: tx.gas_price.map(u256_to_u128).transpose()?,
        max_fee_per_gas: tx.max_fee_per_gas.map(u256_to_u128).transpose()?,
        max_priority_fee_per_gas: tx.max_priority_fee_per_gas.map(u256_to_u128).transpose()?,
        gas: tx.gas.map(u256_to_u64).transpose()?,
        value: tx.value,
        input: TransactionInput::maybe_input(tx.data),
        nonce: tx.nonce,
        ..Default::default()
    })
}

fn state_overrides_to_helios(state_overrides: StateOverride) -> HeliosStateOverride {
    state_overrides
        .into_iter()
        .map(|(address, account)| (address, account_override_to_helios(account)))
        .collect::<AddressHashMap<_>>()
}

fn account_override_to_helios(account: AccountOverride) -> HeliosAccountOverride {
    HeliosAccountOverride {
        balance: account.balance,
        nonce: account.nonce,
        code: account.code,
        state: account.state.map(|state| state.into_iter().collect()),
        state_diff: account
            .state_diff
            .map(|state_diff| state_diff.into_iter().collect()),
        move_precompile_to: None,
    }
}

fn u256_to_u128(value: U256) -> Result<u128, ChainError> {
    value
        .try_into()
        .map_err(|_| ChainError::RpcError(format!("u256 value exceeds u128: {value:#x}")))
}

fn u256_to_u64(value: U256) -> Result<u64, ChainError> {
    value
        .try_into()
        .map_err(|_| ChainError::RpcError(format!("u256 value exceeds u64: {value:#x}")))
}

fn parse_hex_u64(value: &str) -> Result<u64, ChainError> {
    let value = value
        .strip_prefix("0x")
        .ok_or_else(|| ChainError::RpcError(format!("invalid hex quantity: {value}")))?;
    if value.is_empty() {
        return Ok(0);
    }

    u64::from_str_radix(value, 16)
        .map_err(|error| ChainError::RpcError(format!("invalid hex quantity: {error}")))
}

fn parse_hex_u256_response(method: &'static str, body: &str) -> Result<U256, ChainError> {
    #[derive(Debug, Deserialize)]
    struct RpcErrorBody {
        code: i64,
        message: String,
    }

    #[derive(Debug, Deserialize)]
    struct RpcResponse {
        result: Option<String>,
        error: Option<RpcErrorBody>,
    }

    let parsed: RpcResponse = serde_json::from_str(body)
        .map_err(|error| ChainError::RpcError(format!("{method} parse: {error}")))?;
    if let Some(error) = parsed.error {
        return Err(ChainError::RpcError(format!(
            "{method} error {}: {}",
            error.code, error.message
        )));
    }

    let raw = parsed
        .result
        .ok_or_else(|| ChainError::RpcError(format!("{method} missing result")))?;
    let stripped = raw.strip_prefix("0x").unwrap_or(raw.as_str());
    U256::from_str_radix(stripped, 16)
        .map_err(|error| ChainError::RpcError(format!("{method} hex: {error}")))
}

fn helios_error(error: impl std::fmt::Display) -> ChainError {
    let message = error.to_string();
    if let Some(data) = extract_revert_data(&message) {
        return ChainError::CallReverted(data);
    }
    if has_empty_revert_data(&message) {
        return ChainError::CallReverted(Bytes::new());
    }
    ChainError::Helios(message)
}

fn rpc_error(error: impl std::fmt::Display) -> ChainError {
    ChainError::RpcError(error.to_string())
}

fn internal_error(error: impl Into<anyhow::Error>) -> ChainError {
    ChainError::Internal(error.into())
}

// Helios currently exposes EVM revert data through Display text for this path.
// Keep this parser intentionally narrow and pinned with tests so malformed text
// falls back to ChainError::Helios instead of inventing revert bytes.
fn extract_revert_data(message: &str) -> Option<Bytes> {
    let value = extract_revert_value(message)?;
    let hex = value.strip_prefix("0x").unwrap_or(value);
    if hex.is_empty() || hex.len() % 2 != 0 || !hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    hex::decode(hex).ok().map(Bytes::from)
}

fn has_empty_revert_data(message: &str) -> bool {
    extract_revert_value(message)
        .map(|value| value.strip_prefix("0x").unwrap_or(value).is_empty())
        .unwrap_or(false)
}

fn extract_revert_value(message: &str) -> Option<&str> {
    let marker = "execution reverted: ";
    let start = message.find(marker)? + marker.len();
    message[start..]
        .split(|ch: char| ch.is_whitespace() || ch == '"' || ch == '\'' || ch == ',' || ch == ')')
        .next()
}

#[cfg(test)]
mod tests {
    use super::*;

    const _: fn() = || {
        fn assert_impl<T: ChainAdapter>() {}
        assert_impl::<HeliosChainAdapter>();
    };

    #[test]
    fn parse_finalized_root_reads_data_root() {
        let body = json!({
            "data": {
                "root": "0x19fe9abc195538e3dc8c4741ef1df983aaf867f0ef7da78ad26b32fd6fbc3492",
                "header": { "message": { "slot": "7654321" } }
            }
        });
        let root = parse_finalized_root(&body).expect("valid root");
        assert_eq!(
            root,
            "0x19fe9abc195538e3dc8c4741ef1df983aaf867f0ef7da78ad26b32fd6fbc3492"
                .parse::<B256>()
                .unwrap()
        );
    }

    #[test]
    fn parse_finalized_root_errors_when_missing() {
        assert!(parse_finalized_root(&json!({ "data": {} })).is_err());
    }

    #[test]
    fn parse_finalized_root_rejects_zero_root() {
        let body = json!({
            "data": {
                "root": "0x0000000000000000000000000000000000000000000000000000000000000000"
            }
        });
        assert!(parse_finalized_root(&body).is_err());
    }

    #[test]
    fn parse_finality_checkpoint_root_reads_finalized_root() {
        let body = json!({
            "data": {
                "previous_justified": {
                    "root": "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                },
                "current_justified": {
                    "root": "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                },
                "finalized": {
                    "epoch": "325162",
                    "root": "0x19fe9abc195538e3dc8c4741ef1df983aaf867f0ef7da78ad26b32fd6fbc3492"
                }
            }
        });
        let root = parse_finality_checkpoint_root(&body).expect("valid root");
        assert_eq!(
            root,
            "0x19fe9abc195538e3dc8c4741ef1df983aaf867f0ef7da78ad26b32fd6fbc3492"
                .parse::<B256>()
                .unwrap()
        );
    }

    #[test]
    fn push_checkpoint_candidate_dedupes_roots() {
        let root = "0x19fe9abc195538e3dc8c4741ef1df983aaf867f0ef7da78ad26b32fd6fbc3492"
            .parse::<B256>()
            .unwrap();
        let mut candidates = Vec::new();
        push_checkpoint_candidate(&mut candidates, root);
        push_checkpoint_candidate(&mut candidates, root);
        assert_eq!(candidates, vec![root]);
    }

    #[test]
    fn on_disk_with_fresh_bundle_resumes() {
        let now = 1_700_000_000;
        let bundled = now - 60;

        assert_eq!(
            check_checkpoint_freshness(bundled, true, now),
            CheckpointDecision::Resume
        );
    }

    #[test]
    fn missing_disk_with_fresh_bundle_uses_bundled() {
        let now = 1_700_000_000;
        let bundled = now - TWO_WEEKS_SECONDS;

        assert_eq!(
            check_checkpoint_freshness(bundled, false, now),
            CheckpointDecision::UseBundled
        );
    }

    #[test]
    fn missing_disk_with_stale_bundle_is_too_old() {
        let now = 1_700_000_000;
        let bundled = now - TWO_WEEKS_SECONDS - 1;

        assert_eq!(
            check_checkpoint_freshness(bundled, false, now),
            CheckpointDecision::TooOld
        );
    }

    #[test]
    fn on_disk_with_stale_bundle_resumes() {
        let now = 1_700_000_000;
        let bundled = now - TWO_WEEKS_SECONDS - 1;

        assert_eq!(
            check_checkpoint_freshness(bundled, true, now),
            CheckpointDecision::Resume
        );
    }

    #[test]
    fn helios_sync_status_none_is_synced() {
        assert!(is_helios_synced(SyncStatus::None));
    }

    #[test]
    fn helios_sync_status_info_is_not_synced() {
        assert!(!is_helios_synced(SyncStatus::Info(Box::default())));
    }

    #[test]
    fn helios_error_preserves_raw_revert_bytes_when_display_exposes_hex() {
        let error = helios_error(
            "evm error: execution reverted: 810f00230000000000000000000000000000000000000000000000000000000000000001",
        );

        match error {
            ChainError::CallReverted(data) => {
                assert_eq!(
                    format!("{data:#x}"),
                    "0x810f00230000000000000000000000000000000000000000000000000000000000000001"
                );
            }
            other => panic!("expected CallReverted, got {other:?}"),
        }
    }

    #[test]
    fn helios_error_maps_empty_execution_revert_to_call_reverted() {
        let error = helios_error("evm error: execution reverted: ");

        match error {
            ChainError::CallReverted(data) => {
                assert!(data.is_empty());
            }
            other => panic!("expected empty CallReverted, got {other:?}"),
        }
    }

    #[test]
    fn helios_error_leaves_evm_halt_text_intact_for_halt_classification() {
        // helios-core renders an EVM `Halt` as `EvmError::Revert(None)`, whose
        // Display text is "execution reverted: execution halted". The bundler's
        // gas estimator classifies a halt by looking for "execution halted" in
        // the `ChainError::Helios` message, so this parser must not consume it:
        // `extract_revert_value` splits on whitespace and yields the token
        // "execution", which is non-empty, so `has_empty_revert_data` is false
        // and the text falls through intact. If that parser is ever widened,
        // the halt silently becomes `CallReverted` and the estimator reports a
        // revert instead — this pins the boundary at the source.
        match helios_error("execution reverted: execution halted") {
            ChainError::Helios(message) => {
                assert!(
                    message.contains("execution halted"),
                    "halt text must survive for the estimator's classifier: {message:?}"
                );
            }
            other => panic!("expected Helios, got {other:?}"),
        }
    }

    #[test]
    fn helios_revert_parser_accepts_prefixed_and_quoted_revert_data() {
        let data = extract_revert_data(
            r#"provider error ("execution reverted: 0x810f00230000000000000000000000000000000000000000000000000000000000000001")"#,
        )
        .unwrap();

        assert_eq!(
            format!("{data:#x}"),
            "0x810f00230000000000000000000000000000000000000000000000000000000000000001"
        );
    }

    #[test]
    fn helios_revert_parser_accepts_comma_delimited_revert_data() {
        let data = extract_revert_data("execution reverted: 0x1234, gas used 21000").unwrap();

        assert_eq!(format!("{data:#x}"), "0x1234");
    }

    #[test]
    fn helios_revert_parser_rejects_absent_or_malformed_revert_data() {
        assert_eq!(extract_revert_data("execution reverted without data"), None);
        assert_eq!(extract_revert_data("execution reverted: "), None);
        assert_eq!(extract_revert_data("execution reverted: 0x123"), None);
        assert_eq!(extract_revert_data("execution reverted: 0xzz"), None);
    }

    #[test]
    fn parses_valid_hex_u256() {
        let body = r#"{"jsonrpc":"2.0","id":1,"result":"0x174876e800"}"#;
        let value = parse_hex_u256_response("eth_gasPrice", body).unwrap();

        assert_eq!(value.to_string(), "100000000000");
    }

    #[test]
    fn parses_zero_u256() {
        let body = r#"{"jsonrpc":"2.0","id":1,"result":"0x0"}"#;
        let value = parse_hex_u256_response("eth_gasPrice", body).unwrap();

        assert_eq!(value, U256::ZERO);
    }

    #[test]
    fn missing_result_returns_rpc_error() {
        let body = r#"{"jsonrpc":"2.0","id":1}"#;

        assert!(matches!(
            parse_hex_u256_response("eth_gasPrice", body),
            Err(ChainError::RpcError(_))
        ));
    }

    #[test]
    fn rpc_error_body_returns_rpc_error() {
        let body = r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"not found"}}"#;
        let Err(ChainError::RpcError(message)) = parse_hex_u256_response("eth_gasPrice", body)
        else {
            panic!("expected RpcError");
        };

        assert!(message.contains("-32601"));
        assert!(message.contains("not found"));
    }

    #[test]
    fn malformed_hex_returns_rpc_error() {
        let body = r#"{"jsonrpc":"2.0","id":1,"result":"not-hex"}"#;

        assert!(matches!(
            parse_hex_u256_response("eth_gasPrice", body),
            Err(ChainError::RpcError(_))
        ));
    }
}
