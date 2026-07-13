use std::net::{IpAddr, ToSocketAddrs};
use std::time::Duration;

use alloy_primitives::{keccak256, Address, Bytes, B256, U256};
use alloy_sol_types::{sol, SolCall, SolError, SolValue};
use async_trait::async_trait;
use reqwest::Url;
use serde::{Deserialize, Serialize};
use serde_json::json;
use wallet_chain::{BlockTag, CallRequest, ChainError};
use wallet_node_api::{JsonRpcError, CHAIN_MISMATCH, INTERNAL_ERROR};

use crate::config::{MAINNET_CHAIN_ID, SEPOLIA_CHAIN_ID};
use crate::handlers::eth::map_chain_error;
use crate::state::DaemonState;

const UNIVERSAL_RESOLVER: Address =
    alloy_primitives::address!("0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe");
const ETH_COIN_TYPE: u64 = 60;
const DEFAULT_EVM_COIN_TYPE: u64 = 0;
const MAX_CCIP_READ_DEPTH: usize = 4;
const CCIP_GATEWAY_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_CCIP_RESPONSE_BYTES: u64 = 256 * 1024;
const MAINNET_FALLBACK_EXECUTION_RPC: &str = "https://ethereum-rpc.publicnode.com";

sol! {
    function resolve(bytes name, bytes data) view returns (bytes result, address resolver);
    error OffchainLookup(address sender, string[] urls, bytes callData, bytes4 callbackFunction, bytes extraData);
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResolveNameRequest {
    name: String,
    send_chain_id: Option<u64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ResolveNameResponse {
    input: String,
    normalized_name: String,
    address: String,
    resolver: String,
    resolution_chain_id: u64,
    resolution_chain_name: &'static str,
    address_record: &'static str,
    coin_type: u64,
    ccip_read_used: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AddressRecord {
    ChainSpecific(u64),
    DefaultEvm,
    Ethereum,
}

impl AddressRecord {
    fn coin_type(self) -> u64 {
        match self {
            Self::ChainSpecific(chain_id) => evm_coin_type(chain_id),
            Self::DefaultEvm => DEFAULT_EVM_COIN_TYPE,
            Self::Ethereum => ETH_COIN_TYPE,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::ChainSpecific(_) => "chain_specific_evm",
            Self::DefaultEvm => "default_evm",
            Self::Ethereum => "ethereum",
        }
    }
}

#[derive(Debug, thiserror::Error)]
enum ResolveNameError {
    #[error("invalid ENS name: {0}")]
    InvalidName(String),
    #[error("ENS name does not have an EVM address record")]
    NoAddressRecord,
    #[error("ENS address record was not a 20-byte EVM address")]
    NonEvmAddressRecord,
    #[error("CCIP Read exceeded maximum continuation depth")]
    CcipReadDepth,
    #[error("CCIP Read gateway URL is not allowed")]
    CcipGatewayNotAllowed,
    #[error("CCIP Read gateway returned an invalid response")]
    CcipGatewayInvalidResponse,
    #[error("CCIP Read gateway request failed: {0}")]
    CcipGatewayRequest(String),
    #[error(transparent)]
    Chain(#[from] ChainError),
    #[error("failed to decode ENS resolver response")]
    Decode,
}

impl ResolveNameError {
    fn json_rpc(self) -> JsonRpcError {
        match self {
            Self::Chain(err) => map_chain_error(err),
            other => JsonRpcError {
                code: INTERNAL_ERROR,
                message: "ENS resolution failed".to_string(),
                data: Some(json!({ "reason": other.to_string() })),
            },
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Resolution {
    address: Address,
    resolver: Address,
    chain_id: u64,
    record: AddressRecord,
    ccip_read_used: bool,
}

pub async fn handle(
    state: &DaemonState,
    params: serde_json::Value,
) -> Result<serde_json::Value, JsonRpcError> {
    let request = parse_params(params)?;

    let active_chain_id = state.config.network.chain_id;
    if let Some(send_chain_id) = request.send_chain_id {
        if send_chain_id != active_chain_id {
            return Err(JsonRpcError {
                code: CHAIN_MISMATCH,
                message: "ENS resolution chain must match the active wallet-node chain".to_string(),
                data: Some(json!({
                    "requestedChainId": send_chain_id,
                    "activeChainId": active_chain_id,
                })),
            });
        }
    }

    let normalized_name = normalize_name(&request.name).map_err(ResolveNameError::json_rpc)?;
    let dns_name = dns_encode_name(&normalized_name).map_err(ResolveNameError::json_rpc)?;
    let node = namehash(&normalized_name).map_err(ResolveNameError::json_rpc)?;
    let client = CcipGatewayClient::default();

    let resolution = resolve_with_policy(state, &client, active_chain_id, dns_name, node)
        .await
        .map_err(ResolveNameError::json_rpc)?;

    let response = ResolveNameResponse {
        input: request.name,
        normalized_name,
        address: format!("{:#x}", resolution.address),
        resolver: format!("{:#x}", resolution.resolver),
        resolution_chain_id: resolution.chain_id,
        resolution_chain_name: chain_name(resolution.chain_id),
        address_record: resolution.record.label(),
        coin_type: resolution.record.coin_type(),
        ccip_read_used: resolution.ccip_read_used,
    };

    Ok(serde_json::to_value(response).expect("serialize succeeds"))
}

fn parse_params(params: serde_json::Value) -> Result<ResolveNameRequest, JsonRpcError> {
    let mut array = params
        .as_array()
        .cloned()
        .ok_or_else(|| JsonRpcError::parse_error("expected params array"))?;
    if array.len() != 1 {
        return Err(JsonRpcError::parse_error(
            "localwallet_resolveName expects exactly one parameter object",
        ));
    }
    serde_json::from_value(array.remove(0)).map_err(|e| JsonRpcError::parse_error(&e.to_string()))
}

async fn resolve_with_policy(
    state: &DaemonState,
    client: &CcipGatewayClient,
    active_chain_id: u64,
    dns_name: Vec<u8>,
    node: B256,
) -> Result<Resolution, ResolveNameError> {
    let active_caller = ChainAdapterEnsCaller { state };
    match resolve_evm_address(
        &active_caller,
        client,
        active_chain_id,
        dns_name.clone(),
        node,
    )
    .await
    {
        Ok(resolution) => Ok(resolution),
        Err(ResolveNameError::NoAddressRecord) if active_chain_id == SEPOLIA_CHAIN_ID => {
            let mainnet_caller = JsonRpcEnsCaller::new(MAINNET_FALLBACK_EXECUTION_RPC);
            resolve_evm_address(&mainnet_caller, client, MAINNET_CHAIN_ID, dns_name, node).await
        }
        Err(err) => Err(err),
    }
}

async fn resolve_evm_address(
    caller: &(impl EnsCaller + ?Sized),
    client: &CcipGatewayClient,
    chain_id: u64,
    dns_name: Vec<u8>,
    node: B256,
) -> Result<Resolution, ResolveNameError> {
    let records = [
        AddressRecord::ChainSpecific(chain_id),
        AddressRecord::DefaultEvm,
        AddressRecord::Ethereum,
    ];

    for record in records {
        if chain_id == MAINNET_CHAIN_ID && matches!(record, AddressRecord::ChainSpecific(_)) {
            continue;
        }

        let resolver_call_data = match record {
            AddressRecord::Ethereum => legacy_addr_call_data(node),
            AddressRecord::DefaultEvm | AddressRecord::ChainSpecific(_) => {
                multicoin_addr_call_data(node, record.coin_type())
            }
        };
        let resolved =
            match universal_resolve(caller, client, dns_name.clone(), resolver_call_data).await {
                Ok(value) => value,
                Err(ResolveNameError::NoAddressRecord) => continue,
                Err(err) => return Err(err),
            };

        let Some(address) = decode_record_address(record, &resolved.result)? else {
            continue;
        };
        return Ok(Resolution {
            address,
            resolver: resolved.resolver,
            chain_id,
            record,
            ccip_read_used: resolved.ccip_read_used,
        });
    }

    Err(ResolveNameError::NoAddressRecord)
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct UniversalResolveOutput {
    result: Bytes,
    resolver: Address,
    ccip_read_used: bool,
}

async fn universal_resolve(
    caller: &(impl EnsCaller + ?Sized),
    client: &CcipGatewayClient,
    dns_name: Vec<u8>,
    resolver_call_data: Vec<u8>,
) -> Result<UniversalResolveOutput, ResolveNameError> {
    let call = resolveCall {
        name: Bytes::from(dns_name),
        data: Bytes::from(resolver_call_data),
    };
    let mut tx = CallRequest {
        to: Some(UNIVERSAL_RESOLVER),
        data: Some(Bytes::from(call.abi_encode())),
        ..CallRequest::default()
    };
    let mut ccip_read_used = false;

    for _ in 0..=MAX_CCIP_READ_DEPTH {
        match caller.eth_call(tx.clone()).await {
            Ok(raw) => {
                let decoded =
                    resolveCall::abi_decode_returns(&raw).map_err(|_| ResolveNameError::Decode)?;
                if decoded.result.is_empty() {
                    return Err(ResolveNameError::NoAddressRecord);
                }
                return Ok(UniversalResolveOutput {
                    result: decoded.result,
                    resolver: decoded.resolver,
                    ccip_read_used,
                });
            }
            Err(ChainError::CallReverted(revert_data)) => {
                let lookup = OffchainLookup::abi_decode(&revert_data)
                    .map_err(|_| ResolveNameError::Chain(ChainError::CallReverted(revert_data)))?;
                let gateway_response = client.fetch(&lookup).await?;
                let mut callback =
                    Vec::with_capacity(4 + gateway_response.len() + lookup.extraData.len() + 128);
                callback.extend_from_slice(lookup.callbackFunction.as_slice());
                callback.extend_from_slice(
                    &(Bytes::from(gateway_response), lookup.extraData).abi_encode(),
                );
                tx = CallRequest {
                    to: Some(lookup.sender),
                    data: Some(Bytes::from(callback)),
                    ..CallRequest::default()
                };
                ccip_read_used = true;
            }
            Err(err) => return Err(ResolveNameError::Chain(err)),
        }
    }

    Err(ResolveNameError::CcipReadDepth)
}

#[async_trait]
trait EnsCaller: Send + Sync {
    async fn eth_call(&self, tx: CallRequest) -> Result<Bytes, ChainError>;
}

struct ChainAdapterEnsCaller<'a> {
    state: &'a DaemonState,
}

#[async_trait]
impl EnsCaller for ChainAdapterEnsCaller<'_> {
    async fn eth_call(&self, tx: CallRequest) -> Result<Bytes, ChainError> {
        self.state.chain.eth_call(tx, BlockTag::Latest, None).await
    }
}

struct JsonRpcEnsCaller {
    client: reqwest::Client,
    rpc_url: &'static str,
}

impl JsonRpcEnsCaller {
    fn new(rpc_url: &'static str) -> Self {
        Self {
            client: reqwest::Client::new(),
            rpc_url,
        }
    }
}

#[async_trait]
impl EnsCaller for JsonRpcEnsCaller {
    async fn eth_call(&self, tx: CallRequest) -> Result<Bytes, ChainError> {
        let response = self
            .client
            .post(self.rpc_url)
            .json(&json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "eth_call",
                "params": [tx, "latest"],
            }))
            .send()
            .await
            .map_err(|err| ChainError::RpcError(err.to_string()))?
            .error_for_status()
            .map_err(|err| ChainError::RpcError(err.to_string()))?;

        let value: serde_json::Value = response
            .json()
            .await
            .map_err(|err| ChainError::RpcError(err.to_string()))?;
        if let Some(error) = value.get("error") {
            if let Some(data) = rpc_error_revert_data(error) {
                if let Ok(bytes) = data.parse::<Bytes>() {
                    return Err(ChainError::CallReverted(bytes));
                }
            }
            return Err(ChainError::RpcError(error.to_string()));
        }

        let result = value
            .get("result")
            .and_then(|result| result.as_str())
            .ok_or_else(|| ChainError::RpcError("missing eth_call result".to_string()))?;
        result
            .parse::<Bytes>()
            .map_err(|err| ChainError::RpcError(err.to_string()))
    }
}

fn rpc_error_revert_data(error: &serde_json::Value) -> Option<&str> {
    error.get("data").and_then(|data| {
        data.as_str()
            .or_else(|| data.get("data").and_then(|nested| nested.as_str()))
    })
}

#[derive(Clone)]
struct CcipGatewayClient {
    http: reqwest::Client,
    allow_private_gateways: bool,
}

impl Default for CcipGatewayClient {
    fn default() -> Self {
        Self {
            http: reqwest::Client::builder()
                .timeout(CCIP_GATEWAY_TIMEOUT)
                .build()
                .expect("static reqwest client config is valid"),
            allow_private_gateways: false,
        }
    }
}

impl CcipGatewayClient {
    async fn fetch(&self, lookup: &OffchainLookup) -> Result<Vec<u8>, ResolveNameError> {
        for template in &lookup.urls {
            let Ok(request) = self.build_request(template, lookup) else {
                continue;
            };
            if let Ok(bytes) = self.fetch_once(request).await {
                return Ok(bytes);
            }
        }
        Err(ResolveNameError::CcipGatewayRequest(
            "all gateways failed".to_string(),
        ))
    }

    fn build_request(
        &self,
        template: &str,
        lookup: &OffchainLookup,
    ) -> Result<GatewayRequest, ResolveNameError> {
        let sender = format!("{:#x}", lookup.sender);
        let data = format!("{:#x}", lookup.callData);
        if template.contains("{sender}") || template.contains("{data}") {
            let url = template
                .replace("{sender}", &sender)
                .replace("{data}", &data);
            let url = parse_gateway_url(&url, self.allow_private_gateways)?;
            return Ok(GatewayRequest::Get(url));
        }

        let url = parse_gateway_url(template, self.allow_private_gateways)?;
        Ok(GatewayRequest::Post { url, sender, data })
    }

    async fn fetch_once(&self, request: GatewayRequest) -> Result<Vec<u8>, ResolveNameError> {
        let response = match request {
            GatewayRequest::Get(url) => self.http.get(url).send().await,
            GatewayRequest::Post { url, sender, data } => {
                self.http
                    .post(url)
                    .json(&json!({
                        "sender": sender,
                        "data": data,
                    }))
                    .send()
                    .await
            }
        }
        .map_err(|err| ResolveNameError::CcipGatewayRequest(err.to_string()))?
        .error_for_status()
        .map_err(|err| ResolveNameError::CcipGatewayRequest(err.to_string()))?;

        let body = response
            .bytes()
            .await
            .map_err(|err| ResolveNameError::CcipGatewayRequest(err.to_string()))?;
        if body.len() as u64 > MAX_CCIP_RESPONSE_BYTES {
            return Err(ResolveNameError::CcipGatewayInvalidResponse);
        }
        decode_gateway_body(&body)
    }
}

enum GatewayRequest {
    Get(Url),
    Post {
        url: Url,
        sender: String,
        data: String,
    },
}

fn decode_gateway_body(body: &[u8]) -> Result<Vec<u8>, ResolveNameError> {
    let value: serde_json::Value =
        serde_json::from_slice(body).map_err(|_| ResolveNameError::CcipGatewayInvalidResponse)?;
    let data = value
        .get("data")
        .and_then(|value| value.as_str())
        .ok_or(ResolveNameError::CcipGatewayInvalidResponse)?;
    decode_hex_bytes(data).map_err(|_| ResolveNameError::CcipGatewayInvalidResponse)
}

fn parse_gateway_url(raw: &str, allow_private: bool) -> Result<Url, ResolveNameError> {
    let url = Url::parse(raw).map_err(|_| ResolveNameError::CcipGatewayNotAllowed)?;
    if url.scheme() != "https" && !(cfg!(test) && allow_private && url.scheme() == "http") {
        return Err(ResolveNameError::CcipGatewayNotAllowed);
    }
    let Some(host) = url.host_str() else {
        return Err(ResolveNameError::CcipGatewayNotAllowed);
    };
    if !allow_private && is_private_gateway_host(host) {
        return Err(ResolveNameError::CcipGatewayNotAllowed);
    }
    Ok(url)
}

fn is_private_gateway_host(host: &str) -> bool {
    if host.eq_ignore_ascii_case("localhost") {
        return true;
    }
    if let Ok(ip) = host.parse::<IpAddr>() {
        return is_private_ip(ip);
    }
    let port = 443;
    match (host, port).to_socket_addrs() {
        Ok(addrs) => addrs.into_iter().any(|addr| is_private_ip(addr.ip())),
        Err(_) => false,
    }
}

fn is_private_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            ip.is_private()
                || ip.is_loopback()
                || ip.is_link_local()
                || ip.is_broadcast()
                || ip.is_documentation()
                || ip.octets()[0] == 0
        }
        IpAddr::V6(ip) => {
            ip.is_loopback()
                || ip.is_unspecified()
                || ip.is_unique_local()
                || ip.is_unicast_link_local()
        }
    }
}

fn normalize_name(input: &str) -> Result<String, ResolveNameError> {
    let trimmed = input.trim().trim_end_matches('.');
    if trimmed.is_empty() || !trimmed.contains('.') {
        return Err(ResolveNameError::InvalidName(
            "name must include at least one dot".to_string(),
        ));
    }
    ens_normalize::normalize(trimmed).map_err(|err| ResolveNameError::InvalidName(err.to_string()))
}

fn dns_encode_name(name: &str) -> Result<Vec<u8>, ResolveNameError> {
    let mut out = Vec::with_capacity(name.len() + 2);
    for label in name.split('.') {
        let bytes = label.as_bytes();
        if bytes.is_empty() || bytes.len() > 63 {
            return Err(ResolveNameError::InvalidName(
                "label length is outside DNS limits".to_string(),
            ));
        }
        out.push(bytes.len() as u8);
        out.extend_from_slice(bytes);
    }
    out.push(0);
    if out.len() > 255 {
        return Err(ResolveNameError::InvalidName(
            "name length is outside DNS limits".to_string(),
        ));
    }
    Ok(out)
}

fn namehash(name: &str) -> Result<B256, ResolveNameError> {
    let mut node = [0u8; 32];
    for label in name.rsplit('.') {
        if label.is_empty() {
            return Err(ResolveNameError::InvalidName(
                "empty labels are not valid".to_string(),
            ));
        }
        let label_hash = keccak256(label.as_bytes());
        let mut data = [0u8; 64];
        data[..32].copy_from_slice(&node);
        data[32..].copy_from_slice(label_hash.as_slice());
        node.copy_from_slice(keccak256(data).as_slice());
    }
    Ok(B256::from(node))
}

fn evm_coin_type(chain_id: u64) -> u64 {
    0x8000_0000u64 | chain_id
}

fn legacy_addr_call_data(node: B256) -> Vec<u8> {
    let mut out = Vec::with_capacity(36);
    out.extend_from_slice(&keccak256("addr(bytes32)").as_slice()[..4]);
    out.extend_from_slice(node.as_slice());
    out
}

fn multicoin_addr_call_data(node: B256, coin_type: u64) -> Vec<u8> {
    let mut out = Vec::with_capacity(68);
    out.extend_from_slice(&keccak256("addr(bytes32,uint256)").as_slice()[..4]);
    out.extend_from_slice(node.as_slice());
    out.extend_from_slice(U256::from(coin_type).to_be_bytes::<32>().as_slice());
    out
}

fn decode_record_address(
    record: AddressRecord,
    data: &[u8],
) -> Result<Option<Address>, ResolveNameError> {
    match record {
        AddressRecord::Ethereum => {
            if data.len() != 32 {
                return Err(ResolveNameError::Decode);
            }
            if data.iter().all(|byte| *byte == 0) {
                return Ok(None);
            }
            Ok(Some(Address::from_slice(&data[12..32])))
        }
        AddressRecord::DefaultEvm | AddressRecord::ChainSpecific(_) => {
            let bytes = decode_abi_bytes(data)?;
            if bytes.is_empty() {
                return Ok(None);
            }
            if bytes.len() != 20 {
                return Err(ResolveNameError::NonEvmAddressRecord);
            }
            Ok(Some(Address::from_slice(&bytes)))
        }
    }
}

fn decode_abi_bytes(data: &[u8]) -> Result<Vec<u8>, ResolveNameError> {
    if data.len() < 64 {
        return Err(ResolveNameError::Decode);
    }
    let offset = U256::from_be_slice(&data[..32])
        .try_into()
        .map_err(|_| ResolveNameError::Decode)?;
    if offset + 32 > data.len() {
        return Err(ResolveNameError::Decode);
    }
    let len: usize = U256::from_be_slice(&data[offset..offset + 32])
        .try_into()
        .map_err(|_| ResolveNameError::Decode)?;
    let start = offset + 32;
    let end = start.checked_add(len).ok_or(ResolveNameError::Decode)?;
    if end > data.len() {
        return Err(ResolveNameError::Decode);
    }
    Ok(data[start..end].to_vec())
}

fn decode_hex_bytes(value: &str) -> Result<Vec<u8>, hex::FromHexError> {
    hex::decode(value.strip_prefix("0x").unwrap_or(value))
}

fn chain_name(chain_id: u64) -> &'static str {
    match chain_id {
        MAINNET_CHAIN_ID => "Ethereum Mainnet",
        SEPOLIA_CHAIN_ID => "Ethereum Sepolia",
        _ => "Unknown Chain",
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::Arc;

    use alloy_primitives::FixedBytes;
    use serde_json::json;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;
    use tokio::sync::watch;

    use super::*;
    use crate::auth::Token;
    use crate::config::Config;
    use crate::paths::Paths;
    use crate::state::TransportInfo;

    #[test]
    fn normalizes_and_dns_encodes_subdomains() {
        let normalized = normalize_name("Pay.Vitalik.eth.").expect("normalizes");
        assert_eq!(normalized, "pay.vitalik.eth");
        assert_eq!(
            dns_encode_name(&normalized).expect("dns encode"),
            b"\x03pay\x07vitalik\x03eth\0".to_vec()
        );
    }

    #[test]
    fn namehash_matches_known_eth_vector() {
        assert_eq!(
            format!("{:#x}", namehash("eth").expect("namehash")),
            "0x93cdeb708b7545dc668eb9280176169d1c33cfd8".to_string() + "ed6f04690a0bcc88a93fc4ae"
        );
    }

    #[test]
    fn evm_coin_type_uses_ensip_11_formula() {
        assert_eq!(evm_coin_type(1), 0x8000_0001);
        assert_eq!(evm_coin_type(11_155_111), 0x80aa_36a7);
    }

    #[test]
    fn rejects_private_gateway_hosts() {
        assert!(parse_gateway_url("https://localhost/a", false).is_err());
        assert!(parse_gateway_url("https://127.0.0.1/a", false).is_err());
        assert!(parse_gateway_url("https://10.0.0.1/a", false).is_err());
        assert!(parse_gateway_url("https://ccip-v3.ens.xyz/a", false).is_ok());
    }

    #[test]
    fn decodes_gateway_json_response() {
        assert_eq!(
            decode_gateway_body(br#"{"data":"0x1234"}"#).expect("gateway body"),
            vec![0x12, 0x34]
        );
    }

    #[test]
    fn decodes_legacy_and_multicoin_address_records() {
        let address = Address::repeat_byte(0x42);
        let mut legacy = [0u8; 32];
        legacy[12..].copy_from_slice(address.as_slice());
        assert_eq!(
            decode_record_address(AddressRecord::Ethereum, &legacy)
                .expect("legacy")
                .expect("address"),
            address
        );

        let encoded = Bytes::from(address.as_slice().to_vec()).abi_encode();
        assert_eq!(
            decode_record_address(AddressRecord::DefaultEvm, &encoded)
                .expect("multicoin")
                .expect("address"),
            address
        );
    }

    #[tokio::test]
    async fn handler_resolves_chain_specific_record() {
        let chain = Arc::new(wallet_chain::MockChainAdapter::new());
        let state = test_state(chain.clone(), SEPOLIA_CHAIN_ID);
        let normalized = "sub.example.eth";
        let dns_name = dns_encode_name(normalized).expect("dns");
        let node = namehash(normalized).expect("node");
        let recipient = Address::repeat_byte(0x55);
        let resolver = Address::repeat_byte(0x77);
        let call_data = multicoin_addr_call_data(node, evm_coin_type(SEPOLIA_CHAIN_ID));
        let universal_call = resolveCall {
            name: Bytes::from(dns_name),
            data: Bytes::from(call_data),
        };
        let tx = CallRequest {
            to: Some(UNIVERSAL_RESOLVER),
            data: Some(Bytes::from(universal_call.abi_encode())),
            ..CallRequest::default()
        };
        let encoded_record = Bytes::from(recipient.as_slice().to_vec()).abi_encode();
        let response = resolveCall::abi_encode_returns(&resolveReturn {
            result: Bytes::from(encoded_record),
            resolver,
        });
        chain.set_call_response(tx, BlockTag::Latest, None, Bytes::from(response));

        let result = handle(
            &state,
            json!([{
                "name": "Sub.Example.eth",
                "sendChainId": SEPOLIA_CHAIN_ID
            }]),
        )
        .await
        .expect("resolve succeeds");

        assert_eq!(result["normalizedName"], "sub.example.eth");
        assert_eq!(result["address"], format!("{recipient:#x}"));
        assert_eq!(result["resolver"], format!("{resolver:#x}"));
        assert_eq!(result["addressRecord"], "chain_specific_evm");
        assert_eq!(result["ccipReadUsed"], false);
    }

    #[tokio::test]
    async fn handler_falls_back_to_ethereum_record_on_mainnet() {
        let chain = Arc::new(wallet_chain::MockChainAdapter::new());
        let state = test_state(chain.clone(), MAINNET_CHAIN_ID);
        let normalized = "example.eth";
        let dns_name = dns_encode_name(normalized).expect("dns");
        let node = namehash(normalized).expect("node");
        let recipient = Address::repeat_byte(0x66);
        let resolver = Address::repeat_byte(0x88);
        let call_data = multicoin_addr_call_data(node, DEFAULT_EVM_COIN_TYPE);
        let default_call = resolveCall {
            name: Bytes::from(dns_name.clone()),
            data: Bytes::from(call_data),
        };
        let default_tx = CallRequest {
            to: Some(UNIVERSAL_RESOLVER),
            data: Some(Bytes::from(default_call.abi_encode())),
            ..CallRequest::default()
        };
        chain.set_call_response(
            default_tx,
            BlockTag::Latest,
            None,
            Bytes::from(resolveCall::abi_encode_returns(&resolveReturn {
                result: Bytes::new(),
                resolver,
            })),
        );

        let legacy_call = resolveCall {
            name: Bytes::from(dns_name),
            data: Bytes::from(legacy_addr_call_data(node)),
        };
        let legacy_tx = CallRequest {
            to: Some(UNIVERSAL_RESOLVER),
            data: Some(Bytes::from(legacy_call.abi_encode())),
            ..CallRequest::default()
        };
        let mut legacy_record = [0u8; 32];
        legacy_record[12..].copy_from_slice(recipient.as_slice());
        chain.set_call_response(
            legacy_tx,
            BlockTag::Latest,
            None,
            Bytes::from(resolveCall::abi_encode_returns(&resolveReturn {
                result: Bytes::from(legacy_record.to_vec()),
                resolver,
            })),
        );

        let result = handle(&state, json!([{ "name": "example.eth" }]))
            .await
            .expect("resolve succeeds");

        assert_eq!(result["address"], format!("{recipient:#x}"));
        assert_eq!(result["addressRecord"], "ethereum");
        assert_eq!(result["coinType"], ETH_COIN_TYPE);
    }

    #[tokio::test]
    async fn handler_rejects_cross_chain_resolution_request() {
        let state = test_state(
            Arc::new(wallet_chain::MockChainAdapter::new()),
            SEPOLIA_CHAIN_ID,
        );
        let err = handle(
            &state,
            json!([{ "name": "example.eth", "sendChainId": MAINNET_CHAIN_ID }]),
        )
        .await
        .expect_err("chain mismatch");

        assert_eq!(err.code, CHAIN_MISMATCH);
    }

    #[tokio::test]
    async fn universal_resolve_follows_ccip_read_continuation() {
        let chain = Arc::new(wallet_chain::MockChainAdapter::new());
        let state = test_state(chain.clone(), MAINNET_CHAIN_ID);
        let gateway_payload = spawn_one_shot_gateway(br#"{"data":"0xfeed"}"#).await;
        let dns_name = dns_encode_name("example.eth").expect("dns");
        let resolver_data = legacy_addr_call_data(namehash("example.eth").expect("node"));
        let initial_call = resolveCall {
            name: Bytes::from(dns_name.clone()),
            data: Bytes::from(resolver_data.clone()),
        };
        let initial_tx = CallRequest {
            to: Some(UNIVERSAL_RESOLVER),
            data: Some(Bytes::from(initial_call.abi_encode())),
            ..CallRequest::default()
        };
        let ccip_sender = Address::repeat_byte(0x99);
        let callback_selector = FixedBytes::<4>::from([0x12, 0x34, 0x56, 0x78]);
        let extra_data = Bytes::from(vec![0xee, 0xee]);
        let lookup = OffchainLookup {
            sender: ccip_sender,
            urls: vec![format!("{}/{{sender}}/{{data}}", gateway_payload.url)],
            callData: Bytes::from(vec![0xab, 0xcd]),
            callbackFunction: callback_selector,
            extraData: extra_data.clone(),
        };
        chain.set_call_revert(
            initial_tx,
            BlockTag::Latest,
            None,
            Bytes::from(lookup.abi_encode()),
        );

        let mut callback_data = Vec::new();
        callback_data.extend_from_slice(callback_selector.as_slice());
        callback_data.extend_from_slice(&(Bytes::from(vec![0xfe, 0xed]), extra_data).abi_encode());
        let callback_tx = CallRequest {
            to: Some(ccip_sender),
            data: Some(Bytes::from(callback_data)),
            ..CallRequest::default()
        };
        let resolver = Address::repeat_byte(0x77);
        let mut record = [0u8; 32];
        record[12..].copy_from_slice(Address::repeat_byte(0x42).as_slice());
        chain.set_call_response(
            callback_tx,
            BlockTag::Latest,
            None,
            Bytes::from(resolveCall::abi_encode_returns(&resolveReturn {
                result: Bytes::from(record.to_vec()),
                resolver,
            })),
        );

        let client = CcipGatewayClient {
            allow_private_gateways: true,
            ..CcipGatewayClient::default()
        };
        let caller = ChainAdapterEnsCaller { state: &state };
        let resolved = universal_resolve(&caller, &client, dns_name, resolver_data)
            .await
            .expect("ccip resolve");

        assert!(resolved.ccip_read_used);
        assert_eq!(resolved.resolver, resolver);
        assert_eq!(resolved.result, Bytes::from(record.to_vec()));
        gateway_payload.done.await.expect("gateway task");
    }

    struct OneShotGateway {
        url: String,
        done: tokio::task::JoinHandle<()>,
    }

    async fn spawn_one_shot_gateway(body: &'static [u8]) -> OneShotGateway {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind test gateway");
        let addr = listener.local_addr().expect("gateway addr");
        let done = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept gateway request");
            let mut buffer = [0u8; 2048];
            let _ = socket
                .read(&mut buffer)
                .await
                .expect("read gateway request");
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            socket
                .write_all(response.as_bytes())
                .await
                .expect("write response head");
            socket.write_all(body).await.expect("write response body");
        });
        OneShotGateway {
            url: format!("http://{}", addr),
            done,
        }
    }

    fn test_state(chain: Arc<dyn wallet_chain::ChainAdapter>, chain_id: u64) -> DaemonState {
        let (shutdown_tx, _shutdown_rx) = watch::channel(false);
        let mut config = Config::default();
        config.network.chain_id = chain_id;

        DaemonState::new(
            Arc::new(Token::generate()),
            Arc::new(config),
            Arc::new(Paths {
                app_support_dir: PathBuf::from("/tmp/wallet-node-test"),
                socket_path: PathBuf::from("/tmp/wallet-node-test/wallet-node.sock"),
                db_path: PathBuf::from("/tmp/wallet-node-test/node.sqlite"),
                helios_dir: PathBuf::from("/tmp/wallet-node-test/helios"),
                logs_dir: PathBuf::from("/tmp/wallet-node-test/logs"),
                config_path: PathBuf::from("/tmp/wallet-node-test/config.toml"),
            }),
            shutdown_tx,
            (TransportInfo::http(), chain),
        )
    }
}
