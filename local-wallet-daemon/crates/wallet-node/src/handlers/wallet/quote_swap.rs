use alloy_primitives::{Address, Bytes, U256};
use alloy_sol_types::{sol, SolCall};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::time::Duration;
use wallet_chain::{BlockTag, CallRequest, ChainError};
use wallet_node_api::{JsonRpcError, CHAIN_MISMATCH, INTERNAL_ERROR, INVALID_REQUEST};

use crate::config::{MAINNET_CHAIN_ID, SEPOLIA_CHAIN_ID};
use crate::handlers::eth::map_chain_error;
use crate::state::DaemonState;

const MAINNET_FACTORY: Address =
    alloy_primitives::address!("1F98431c8aD98523631AE4a59f267346ea31F984");
const SEPOLIA_FACTORY: Address =
    alloy_primitives::address!("0227628f3F023bb0B980b67D528571c95c6DaC1c");
const MAINNET_ROUTER: Address =
    alloy_primitives::address!("68b3465833fb72A70ecDF485E0e4C7bD8665Fc45");
const SEPOLIA_ROUTER: Address =
    alloy_primitives::address!("3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E");
const MAINNET_QUOTER: Address =
    alloy_primitives::address!("61fFE014bA17989E743c5F6cB21bF9697530B21e");
const SEPOLIA_QUOTER: Address =
    alloy_primitives::address!("Ed1f6473345F45b75F8179591dd5bA1888cf2FB3");
const FEE_TIERS: [u32; 4] = [100, 500, 3_000, 10_000];
const DEFAULT_SLIPPAGE_BPS: u64 = 100;
const MAX_SLIPPAGE_BPS: u64 = 5_000;
const QUOTE_ROUTE_TIMEOUT: Duration = Duration::from_secs(35);

sol! {
    function getPool(address tokenA, address tokenB, uint24 fee) view returns (address pool);
    function liquidity() view returns (uint128);
    function quoteExactInput(bytes path, uint256 amountIn) returns (
        uint256 amountOut,
        uint160[] sqrtPriceX96AfterList,
        uint32[] initializedTicksCrossedList,
        uint256 gasEstimate
    );
    function allowance(address owner, address spender) view returns (uint256);
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct QuoteSwapRequest {
    send_chain_id: Option<u64>,
    token_in: String,
    token_out: String,
    amount_in: String,
    owner: Option<String>,
    token_in_is_native: Option<bool>,
    slippage_bps: Option<u64>,
    intermediates: Option<Vec<String>>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct QuoteSwapResponse {
    chain_id: u64,
    factory: String,
    router: String,
    quoter: String,
    token_in: String,
    token_out: String,
    amount_in: String,
    quote_amount_out: String,
    amount_out_minimum: String,
    slippage_bps: u64,
    path: String,
    hops: Vec<QuoteHop>,
    gas_estimate: String,
    allowance: Option<String>,
    requires_approval: bool,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct QuoteHop {
    token_in: String,
    token_out: String,
    fee: u32,
    pool: String,
    liquidity: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct CandidateRoute {
    tokens: Vec<Address>,
    fees: Vec<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct QuotedRoute {
    route: CandidateRoute,
    amount_out: U256,
    amount_out_minimum: U256,
    gas_estimate: U256,
    hops: Vec<QuoteHop>,
    path: Vec<u8>,
}

#[derive(Clone, Copy)]
struct UniswapContracts {
    factory: Address,
    router: Address,
    quoter: Address,
}

#[derive(Debug, thiserror::Error)]
enum QuoteSwapError {
    #[error("unsupported chain for Uniswap v3 swaps")]
    UnsupportedChain,
    #[error("invalid token address")]
    InvalidAddress,
    #[error("invalid amountIn")]
    InvalidAmount,
    #[error("slippage is outside the supported range")]
    InvalidSlippage,
    #[error("tokenIn and tokenOut must be different")]
    SameToken,
    #[error("no Uniswap v3 route found for this exact-input swap")]
    NoRoute,
    #[error("swap quote timed out")]
    TimedOut,
    #[error("failed to decode Uniswap response")]
    Decode,
    #[error(transparent)]
    Chain(#[from] ChainError),
}

impl QuoteSwapError {
    fn json_rpc(self) -> JsonRpcError {
        match self {
            Self::Chain(err) => map_chain_error(err),
            Self::InvalidAddress
            | Self::InvalidAmount
            | Self::InvalidSlippage
            | Self::SameToken
            | Self::UnsupportedChain => JsonRpcError {
                code: INVALID_REQUEST,
                message: "Invalid swap quote request".to_string(),
                data: Some(json!({ "reason": self.to_string() })),
            },
            other => JsonRpcError {
                code: INTERNAL_ERROR,
                message: "Swap quote failed".to_string(),
                data: Some(json!({ "reason": other.to_string() })),
            },
        }
    }
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
                message: "Swap quote chain must match the active wallet-node chain".to_string(),
                data: Some(json!({
                    "requestedChainId": send_chain_id,
                    "activeChainId": active_chain_id,
                })),
            });
        }
    }

    let contracts = contracts_for_chain(active_chain_id)
        .ok_or(QuoteSwapError::UnsupportedChain)
        .map_err(QuoteSwapError::json_rpc)?;
    let token_in = parse_address(&request.token_in).map_err(QuoteSwapError::json_rpc)?;
    let token_out = parse_address(&request.token_out).map_err(QuoteSwapError::json_rpc)?;
    if token_in == token_out {
        return Err(QuoteSwapError::SameToken.json_rpc());
    }
    let amount_in = parse_u256(&request.amount_in).map_err(QuoteSwapError::json_rpc)?;
    if amount_in.is_zero() {
        return Err(QuoteSwapError::InvalidAmount.json_rpc());
    }
    let slippage_bps = request.slippage_bps.unwrap_or(DEFAULT_SLIPPAGE_BPS);
    if slippage_bps > MAX_SLIPPAGE_BPS {
        return Err(QuoteSwapError::InvalidSlippage.json_rpc());
    }
    let intermediates = request
        .intermediates
        .unwrap_or_default()
        .into_iter()
        .map(|value| parse_address(&value))
        .collect::<Result<Vec<_>, _>>()
        .map_err(QuoteSwapError::json_rpc)?;

    let quote_caller = quote_eth_caller(state);
    let quoted = tokio::time::timeout(
        QUOTE_ROUTE_TIMEOUT,
        quote_best_route(
            &quote_caller,
            contracts,
            token_in,
            token_out,
            amount_in,
            slippage_bps,
            &intermediates,
        ),
    )
    .await
    .map_err(|_| QuoteSwapError::TimedOut)
    .and_then(|result| result)
    .map_err(QuoteSwapError::json_rpc)?;

    let owner = request
        .owner
        .as_deref()
        .map(parse_address)
        .transpose()
        .map_err(QuoteSwapError::json_rpc)?;
    let token_in_is_native = request.token_in_is_native.unwrap_or(false);
    let allowance = if token_in_is_native {
        None
    } else if let Some(owner) = owner {
        Some(
            read_allowance(&quote_caller, token_in, owner, contracts.router)
                .await
                .map_err(QuoteSwapError::json_rpc)?,
        )
    } else {
        None
    };
    let requires_approval = allowance.is_some_and(|value| value < amount_in);

    let response = QuoteSwapResponse {
        chain_id: active_chain_id,
        factory: address_hex(contracts.factory),
        router: address_hex(contracts.router),
        quoter: address_hex(contracts.quoter),
        token_in: address_hex(token_in),
        token_out: address_hex(token_out),
        amount_in: u256_hex(amount_in),
        quote_amount_out: u256_hex(quoted.amount_out),
        amount_out_minimum: u256_hex(quoted.amount_out_minimum),
        slippage_bps,
        path: bytes_hex(&quoted.path),
        hops: quoted.hops,
        gas_estimate: u256_hex(quoted.gas_estimate),
        allowance: allowance.map(u256_hex),
        requires_approval,
    };

    Ok(serde_json::to_value(response).expect("serialize succeeds"))
}

fn parse_params(params: serde_json::Value) -> Result<QuoteSwapRequest, JsonRpcError> {
    let mut array = params
        .as_array()
        .cloned()
        .ok_or_else(|| JsonRpcError::parse_error("expected params array"))?;
    if array.len() != 1 {
        return Err(JsonRpcError::parse_error(
            "localwallet_quoteSwap expects exactly one parameter object",
        ));
    }
    serde_json::from_value(array.remove(0)).map_err(|e| JsonRpcError::parse_error(&e.to_string()))
}

fn contracts_for_chain(chain_id: u64) -> Option<UniswapContracts> {
    match chain_id {
        MAINNET_CHAIN_ID => Some(UniswapContracts {
            factory: MAINNET_FACTORY,
            router: MAINNET_ROUTER,
            quoter: MAINNET_QUOTER,
        }),
        SEPOLIA_CHAIN_ID => Some(UniswapContracts {
            factory: SEPOLIA_FACTORY,
            router: SEPOLIA_ROUTER,
            quoter: SEPOLIA_QUOTER,
        }),
        _ => None,
    }
}

async fn quote_best_route(
    caller: &(impl QuoteEthCaller + ?Sized),
    contracts: UniswapContracts,
    token_in: Address,
    token_out: Address,
    amount_in: U256,
    slippage_bps: u64,
    intermediates: &[Address],
) -> Result<QuotedRoute, QuoteSwapError> {
    let candidates = candidate_routes(token_in, token_out, intermediates);
    let mut best: Option<QuotedRoute> = None;

    for route in candidates {
        let hops = match validate_route_pools(caller, contracts.factory, &route).await {
            Ok(hops) => hops,
            Err(error) if should_skip_route_error(&error) => continue,
            Err(error) => return Err(error),
        };
        let path = encode_path(&route);
        let (amount_out, gas_estimate) =
            match quote_exact_input(caller, contracts.quoter, path.clone(), amount_in).await {
                Ok(quote) => quote,
                Err(error) if should_skip_route_error(&error) => continue,
                Err(error) => return Err(error),
            };
        if amount_out.is_zero() {
            continue;
        }
        let amount_out_minimum = apply_output_slippage(amount_out, slippage_bps);
        if best
            .as_ref()
            .is_none_or(|current| amount_out > current.amount_out)
        {
            best = Some(QuotedRoute {
                route,
                amount_out,
                amount_out_minimum,
                gas_estimate,
                hops,
                path,
            });
        }
    }

    best.ok_or(QuoteSwapError::NoRoute)
}

fn should_skip_route_error(error: &QuoteSwapError) -> bool {
    matches!(
        error,
        QuoteSwapError::NoRoute
            | QuoteSwapError::Decode
            | QuoteSwapError::Chain(ChainError::CallReverted(_))
    )
}

fn candidate_routes(
    token_in: Address,
    token_out: Address,
    intermediates: &[Address],
) -> Vec<CandidateRoute> {
    let mut token_paths = vec![vec![token_in, token_out]];
    for intermediate in intermediates {
        if *intermediate != token_in
            && *intermediate != token_out
            && !token_paths
                .iter()
                .any(|path| path.as_slice() == [token_in, *intermediate, token_out])
        {
            token_paths.push(vec![token_in, *intermediate, token_out]);
        }
    }

    let mut routes = Vec::new();
    for tokens in token_paths {
        let hop_count = tokens.len() - 1;
        let mut fees = Vec::with_capacity(hop_count);
        push_fee_permutations(&tokens, hop_count, &mut fees, &mut routes);
    }
    routes
}

fn push_fee_permutations(
    tokens: &[Address],
    hop_count: usize,
    fees: &mut Vec<u32>,
    routes: &mut Vec<CandidateRoute>,
) {
    if fees.len() == hop_count {
        routes.push(CandidateRoute {
            tokens: tokens.to_vec(),
            fees: fees.clone(),
        });
        return;
    }

    for fee in FEE_TIERS {
        fees.push(fee);
        push_fee_permutations(tokens, hop_count, fees, routes);
        fees.pop();
    }
}

async fn validate_route_pools(
    caller: &(impl QuoteEthCaller + ?Sized),
    factory: Address,
    route: &CandidateRoute,
) -> Result<Vec<QuoteHop>, QuoteSwapError> {
    let mut hops = Vec::with_capacity(route.fees.len());
    for index in 0..route.fees.len() {
        let token_in = route.tokens[index];
        let token_out = route.tokens[index + 1];
        let fee = route.fees[index];
        let pool = get_pool(caller, factory, token_in, token_out, fee).await?;
        if pool.is_zero() {
            return Err(QuoteSwapError::NoRoute);
        }
        let liquidity = pool_liquidity(caller, pool).await?;
        if liquidity == 0 {
            return Err(QuoteSwapError::NoRoute);
        }
        hops.push(QuoteHop {
            token_in: address_hex(token_in),
            token_out: address_hex(token_out),
            fee,
            pool: address_hex(pool),
            liquidity: liquidity.to_string(),
        });
    }
    Ok(hops)
}

async fn get_pool(
    caller: &(impl QuoteEthCaller + ?Sized),
    factory: Address,
    token_a: Address,
    token_b: Address,
    fee: u32,
) -> Result<Address, QuoteSwapError> {
    let raw = caller
        .eth_call(
            factory,
            Bytes::from(
                getPoolCall {
                    tokenA: token_a,
                    tokenB: token_b,
                    fee: alloy_primitives::aliases::U24::from(fee),
                }
                .abi_encode(),
            ),
        )
        .await?;
    getPoolCall::abi_decode_returns(&raw).map_err(|_| QuoteSwapError::Decode)
}

async fn pool_liquidity(
    caller: &(impl QuoteEthCaller + ?Sized),
    pool: Address,
) -> Result<u128, QuoteSwapError> {
    let raw = caller
        .eth_call(pool, Bytes::from(liquidityCall {}.abi_encode()))
        .await?;
    liquidityCall::abi_decode_returns(&raw).map_err(|_| QuoteSwapError::Decode)
}

async fn quote_exact_input(
    caller: &(impl QuoteEthCaller + ?Sized),
    quoter: Address,
    path: Vec<u8>,
    amount_in: U256,
) -> Result<(U256, U256), QuoteSwapError> {
    let raw = caller
        .eth_call(
            quoter,
            Bytes::from(
                quoteExactInputCall {
                    path: Bytes::from(path),
                    amountIn: amount_in,
                }
                .abi_encode(),
            ),
        )
        .await?;
    let decoded =
        quoteExactInputCall::abi_decode_returns(&raw).map_err(|_| QuoteSwapError::Decode)?;
    Ok((decoded.amountOut, decoded.gasEstimate))
}

async fn read_allowance(
    caller: &(impl QuoteEthCaller + ?Sized),
    token: Address,
    owner: Address,
    spender: Address,
) -> Result<U256, QuoteSwapError> {
    let raw = caller
        .eth_call(
            token,
            Bytes::from(allowanceCall { owner, spender }.abi_encode()),
        )
        .await?;
    allowanceCall::abi_decode_returns(&raw).map_err(|_| QuoteSwapError::Decode)
}

#[allow(clippy::double_must_use)] // async_trait's generated methods; see ChainAdapter
#[async_trait]
trait QuoteEthCaller {
    async fn eth_call(&self, to: Address, data: Bytes) -> Result<Bytes, QuoteSwapError>;
}

fn quote_eth_caller(state: &DaemonState) -> ChainAdapterQuoteCaller<'_> {
    ChainAdapterQuoteCaller { state }
}

struct ChainAdapterQuoteCaller<'a> {
    state: &'a DaemonState,
}

#[async_trait]
impl QuoteEthCaller for ChainAdapterQuoteCaller<'_> {
    async fn eth_call(&self, to: Address, data: Bytes) -> Result<Bytes, QuoteSwapError> {
        self.state
            .chain
            .eth_call(
                CallRequest {
                    to: Some(to),
                    data: Some(data),
                    ..CallRequest::default()
                },
                BlockTag::Latest,
                None,
            )
            .await
            .map_err(QuoteSwapError::Chain)
    }
}

fn encode_path(route: &CandidateRoute) -> Vec<u8> {
    let mut path = Vec::with_capacity(20 * route.tokens.len() + 3 * route.fees.len());
    path.extend_from_slice(route.tokens[0].as_slice());
    for (index, fee) in route.fees.iter().enumerate() {
        let fee_bytes = fee.to_be_bytes();
        path.extend_from_slice(&fee_bytes[1..4]);
        path.extend_from_slice(route.tokens[index + 1].as_slice());
    }
    path
}

fn apply_output_slippage(amount_out: U256, slippage_bps: u64) -> U256 {
    amount_out * U256::from(10_000 - slippage_bps) / U256::from(10_000)
}

fn parse_address(value: &str) -> Result<Address, QuoteSwapError> {
    value
        .parse::<Address>()
        .map_err(|_| QuoteSwapError::InvalidAddress)
}

fn parse_u256(value: &str) -> Result<U256, QuoteSwapError> {
    let trimmed = value.trim();
    if let Some(hex) = trimmed.strip_prefix("0x") {
        U256::from_str_radix(hex, 16).map_err(|_| QuoteSwapError::InvalidAmount)
    } else {
        U256::from_str_radix(trimmed, 10).map_err(|_| QuoteSwapError::InvalidAmount)
    }
}

fn address_hex(address: Address) -> String {
    format!("{address:#x}")
}

fn u256_hex(value: U256) -> String {
    format!("{value:#x}")
}

fn bytes_hex(bytes: &[u8]) -> String {
    format!("0x{}", hex::encode(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::DaemonState;
    use std::sync::Arc;

    const TOKEN_A: Address = alloy_primitives::address!("1000000000000000000000000000000000000001");
    const TOKEN_B: Address = alloy_primitives::address!("2000000000000000000000000000000000000002");
    const TOKEN_C: Address = alloy_primitives::address!("3000000000000000000000000000000000000003");
    const OWNER: Address = alloy_primitives::address!("4000000000000000000000000000000000000004");
    const POOL_AB_500: Address =
        alloy_primitives::address!("5000000000000000000000000000000000000005");
    const POOL_AC_500: Address =
        alloy_primitives::address!("6000000000000000000000000000000000000006");
    const POOL_CB_3000: Address =
        alloy_primitives::address!("7000000000000000000000000000000000000007");

    #[test]
    fn encodes_uniswap_v3_path_with_uint24_fees() {
        let route = CandidateRoute {
            tokens: vec![TOKEN_A, TOKEN_C, TOKEN_B],
            fees: vec![500, 3_000],
        };

        assert_eq!(
            bytes_hex(&encode_path(&route)),
            concat!(
                "0x",
                "1000000000000000000000000000000000000001",
                "0001f4",
                "3000000000000000000000000000000000000003",
                "000bb8",
                "2000000000000000000000000000000000000002",
            )
        );
    }

    #[test]
    fn candidate_routes_include_direct_and_one_hop_without_cycles() {
        let routes = candidate_routes(TOKEN_A, TOKEN_B, &[TOKEN_A, TOKEN_C, TOKEN_B, TOKEN_C]);
        assert_eq!(routes.len(), 20);
        assert!(routes
            .iter()
            .any(|route| route.tokens == [TOKEN_A, TOKEN_B]));
        assert!(routes
            .iter()
            .any(|route| route.tokens == [TOKEN_A, TOKEN_C, TOKEN_B]));
        assert!(!routes
            .iter()
            .any(|route| route.tokens == [TOKEN_A, TOKEN_A, TOKEN_B]));
    }

    #[test]
    fn output_slippage_rounds_down() {
        assert_eq!(
            apply_output_slippage(U256::from(1_001_u64), 100),
            U256::from(990_u64)
        );
    }

    #[tokio::test]
    async fn handler_selects_best_quoted_route_and_reports_allowance() {
        let chain = Arc::new(wallet_chain::MockChainAdapter::new());
        let state = test_state(chain.clone());
        let amount_in = U256::from(1_000_u64);
        let direct_quote = U256::from(2_000_u64);
        let better_quote = U256::from(2_500_u64);

        mock_zero_pools_for_routes(
            chain.as_ref(),
            MAINNET_FACTORY,
            TOKEN_A,
            TOKEN_B,
            &[TOKEN_C],
        );
        mock_pool(
            chain.as_ref(),
            MAINNET_FACTORY,
            TOKEN_A,
            TOKEN_B,
            500,
            POOL_AB_500,
            10,
        );
        mock_pool(
            chain.as_ref(),
            MAINNET_FACTORY,
            TOKEN_A,
            TOKEN_C,
            500,
            POOL_AC_500,
            10,
        );
        mock_pool(
            chain.as_ref(),
            MAINNET_FACTORY,
            TOKEN_C,
            TOKEN_B,
            3_000,
            POOL_CB_3000,
            10,
        );
        mock_quote(
            chain.as_ref(),
            MAINNET_QUOTER,
            vec![TOKEN_A, TOKEN_B],
            vec![500],
            amount_in,
            direct_quote,
        );
        mock_quote(
            chain.as_ref(),
            MAINNET_QUOTER,
            vec![TOKEN_A, TOKEN_C, TOKEN_B],
            vec![500, 3_000],
            amount_in,
            better_quote,
        );
        mock_allowance(
            chain.as_ref(),
            TOKEN_A,
            OWNER,
            MAINNET_ROUTER,
            U256::from(999_u64),
        );

        let value = handle(
            &state,
            json!([{
                "sendChainId": MAINNET_CHAIN_ID,
                "tokenIn": address_hex(TOKEN_A),
                "tokenOut": address_hex(TOKEN_B),
                "amountIn": u256_hex(amount_in),
                "owner": address_hex(OWNER),
                "intermediates": [address_hex(TOKEN_C)],
                "slippageBps": 100
            }]),
        )
        .await
        .unwrap();

        assert_eq!(value["quoteAmountOut"], u256_hex(better_quote));
        assert_eq!(value["amountOutMinimum"], u256_hex(U256::from(2_475_u64)));
        assert_eq!(value["requiresApproval"], true);
        assert_eq!(value["hops"].as_array().unwrap().len(), 2);
        assert_eq!(value["hops"][0]["fee"], 500);
        assert_eq!(value["hops"][1]["fee"], 3_000);
    }

    #[tokio::test]
    async fn handler_rejects_chain_mismatch() {
        let state = test_state(Arc::new(wallet_chain::MockChainAdapter::new()));

        let error = handle(
            &state,
            json!([{
                "sendChainId": SEPOLIA_CHAIN_ID,
                "tokenIn": address_hex(TOKEN_A),
                "tokenOut": address_hex(TOKEN_B),
                "amountIn": "0x1"
            }]),
        )
        .await
        .unwrap_err();

        assert_eq!(error.code, CHAIN_MISMATCH);
    }

    #[tokio::test]
    async fn handler_returns_no_route_when_pool_checks_find_no_pool() {
        let chain = Arc::new(wallet_chain::MockChainAdapter::new());
        let state = test_state(chain.clone());
        mock_zero_pools_for_routes(chain.as_ref(), MAINNET_FACTORY, TOKEN_A, TOKEN_B, &[]);

        let error = handle(
            &state,
            json!([{
                "sendChainId": MAINNET_CHAIN_ID,
                "tokenIn": address_hex(TOKEN_A),
                "tokenOut": address_hex(TOKEN_B),
                "amountIn": "0x1"
            }]),
        )
        .await
        .unwrap_err();

        assert_eq!(error.code, INTERNAL_ERROR);
        assert_eq!(
            error.data.unwrap()["reason"],
            "no Uniswap v3 route found for this exact-input swap"
        );
    }

    #[tokio::test]
    async fn handler_propagates_chain_readiness_errors_while_quoting() {
        let chain = Arc::new(wallet_chain::MockChainAdapter::new());
        chain.inject_error(Box::new(|| {
            ChainError::Helios("out of sync: 1780568656 seconds behind".to_string())
        }));
        let state = test_state(chain);

        let error = handle(
            &state,
            json!([{
                "sendChainId": MAINNET_CHAIN_ID,
                "tokenIn": address_hex(TOKEN_A),
                "tokenOut": address_hex(TOKEN_B),
                "amountIn": "0x1"
            }]),
        )
        .await
        .unwrap_err();

        assert_eq!(error.code, wallet_node_api::NOT_READY);
        let data = error.data.unwrap();
        assert_eq!(data["reason"], "helios_error");
        assert_eq!(data["detail"], "out of sync: 1780568656 seconds behind");
    }

    #[tokio::test]
    async fn quote_caller_uses_shared_chain_adapter() {
        let chain = Arc::new(wallet_chain::MockChainAdapter::new());
        let state = test_state(chain.clone());
        let data = Bytes::from(vec![0xab, 0xcd]);
        chain.set_call_response(
            CallRequest {
                to: Some(TOKEN_A),
                data: Some(data.clone()),
                ..CallRequest::default()
            },
            BlockTag::Latest,
            None,
            Bytes::from(vec![0x12, 0x34]),
        );

        let caller = quote_eth_caller(&state);
        let output = caller.eth_call(TOKEN_A, data).await.unwrap();

        assert_eq!(output, Bytes::from(vec![0x12, 0x34]));
        assert_eq!(chain.call_call_count(), 1);
    }

    fn test_state(chain: Arc<dyn wallet_chain::ChainAdapter>) -> DaemonState {
        DaemonState::for_tests(chain)
    }

    fn mock_zero_pools_for_routes(
        chain: &wallet_chain::MockChainAdapter,
        factory: Address,
        token_in: Address,
        token_out: Address,
        intermediates: &[Address],
    ) {
        for route in candidate_routes(token_in, token_out, intermediates) {
            for index in 0..route.fees.len() {
                mock_pool_address(
                    chain,
                    factory,
                    route.tokens[index],
                    route.tokens[index + 1],
                    route.fees[index],
                    Address::ZERO,
                );
            }
        }
    }

    fn mock_pool(
        chain: &wallet_chain::MockChainAdapter,
        factory: Address,
        token_a: Address,
        token_b: Address,
        fee: u32,
        pool: Address,
        liquidity: u128,
    ) {
        mock_pool_address(chain, factory, token_a, token_b, fee, pool);
        chain.set_call_response(
            CallRequest {
                to: Some(pool),
                data: Some(Bytes::from(liquidityCall {}.abi_encode())),
                ..CallRequest::default()
            },
            BlockTag::Latest,
            None,
            Bytes::from(liquidityCall::abi_encode_returns(&liquidity)),
        );
    }

    fn mock_pool_address(
        chain: &wallet_chain::MockChainAdapter,
        factory: Address,
        token_a: Address,
        token_b: Address,
        fee: u32,
        pool: Address,
    ) {
        chain.set_call_response(
            CallRequest {
                to: Some(factory),
                data: Some(Bytes::from(
                    getPoolCall {
                        tokenA: token_a,
                        tokenB: token_b,
                        fee: alloy_primitives::aliases::U24::from(fee),
                    }
                    .abi_encode(),
                )),
                ..CallRequest::default()
            },
            BlockTag::Latest,
            None,
            Bytes::from(getPoolCall::abi_encode_returns(&pool)),
        );
    }

    fn mock_quote(
        chain: &wallet_chain::MockChainAdapter,
        quoter: Address,
        tokens: Vec<Address>,
        fees: Vec<u32>,
        amount_in: U256,
        amount_out: U256,
    ) {
        let route = CandidateRoute { tokens, fees };
        let path = encode_path(&route);
        chain.set_call_response(
            CallRequest {
                to: Some(quoter),
                data: Some(Bytes::from(
                    quoteExactInputCall {
                        path: Bytes::from(path),
                        amountIn: amount_in,
                    }
                    .abi_encode(),
                )),
                ..CallRequest::default()
            },
            BlockTag::Latest,
            None,
            Bytes::from(quoteExactInputCall::abi_encode_returns(
                &quoteExactInputReturn {
                    amountOut: amount_out,
                    sqrtPriceX96AfterList: Vec::new(),
                    initializedTicksCrossedList: Vec::new(),
                    gasEstimate: U256::from(123_456_u64),
                },
            )),
        );
    }

    fn mock_allowance(
        chain: &wallet_chain::MockChainAdapter,
        token: Address,
        owner: Address,
        spender: Address,
        value: U256,
    ) {
        chain.set_call_response(
            CallRequest {
                to: Some(token),
                data: Some(Bytes::from(allowanceCall { owner, spender }.abi_encode())),
                ..CallRequest::default()
            },
            BlockTag::Latest,
            None,
            Bytes::from(allowanceCall::abi_encode_returns(&value)),
        );
    }
}
