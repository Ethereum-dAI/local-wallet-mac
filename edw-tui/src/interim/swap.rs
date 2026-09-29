//! Uniswap v3 exact-input swaps, as the SwiftUI app does them.
//!
//! Quoting is a port of the daemon's `localwallet_quoteSwap`
//! (`local-wallet-daemon/crates/wallet-node/src/handlers/wallet/quote_swap.rs`): the same
//! factory, SwapRouter02 and QuoterV2 per chain, the direct pair plus one hop through each of
//! the app's intermediates, every fee tier, pools checked for liquidity, the best
//! `quoteExactInput` wins, and the minimum output is the quote less the slippage. The router
//! calls follow the app's `SwapRouterCallEncoder` (`UserOperationBuilder.swift`): `exactInput`,
//! with `msg.value` for ETH in and `multicall(exactInput → router, unwrapWETH9 → owner)` for
//! ETH out; approvals are for exactly the amount in, reset to zero first if one is already set.
//!
//! Desktop-wallet may never ship swaps, so this module may outlive the rest of `interim` and
//! move into its own crate; nothing here depends on edw.

use alloy_primitives::{Address, Bytes, U256, address, aliases::U24};
use alloy_provider::Provider;
use alloy_rpc_types_eth::TransactionRequest;
use alloy_sol_types::{SolCall, sol};

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
    function approve(address spender, uint256 amount) returns (bool);

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams params) payable returns (uint256 amountOut);
    function multicall(bytes[] data) payable returns (bytes[] results);
    function unwrapWETH9(uint256 amountMinimum, address recipient) payable;
}

pub const FEE_TIERS: [u32; 4] = [100, 500, 3_000, 10_000];
pub const DEFAULT_SLIPPAGE_BPS: u64 = 100;
pub const MAX_SLIPPAGE_BPS: u64 = 5_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Contracts {
    pub factory: Address,
    pub router: Address,
    pub quoter: Address,
}

/// The daemon's `contracts_for_chain`.
pub fn contracts(chain_id: u64) -> Option<Contracts> {
    match chain_id {
        1 => Some(Contracts {
            factory: address!("0x1F98431c8aD98523631AE4a59f267346ea31F984"),
            router: address!("0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45"),
            quoter: address!("0x61fFE014bA17989E743c5F6cB21bF9697530B21e"),
        }),
        11_155_111 => Some(Contracts {
            factory: address!("0x0227628f3F023bb0B980b67D528571c95c6DaC1c"),
            router: address!("0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E"),
            quoter: address!("0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3"),
        }),
        _ => None,
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Route {
    pub tokens: Vec<Address>,
    pub fees: Vec<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Quote {
    pub route: Route,
    pub amount_out: U256,
    pub amount_out_minimum: U256,
    pub gas_estimate: U256,
    pub path: Vec<u8>,
}

/// The direct pair and one hop through each intermediate, under every fee tier.
pub fn candidate_routes(
    token_in: Address,
    token_out: Address,
    intermediates: &[Address],
) -> Vec<Route> {
    let mut token_paths = vec![vec![token_in, token_out]];
    for intermediate in intermediates {
        let path = vec![token_in, *intermediate, token_out];
        if *intermediate != token_in && *intermediate != token_out && !token_paths.contains(&path) {
            token_paths.push(path);
        }
    }
    let mut routes = Vec::new();
    for tokens in token_paths {
        let mut fee_lists: Vec<Vec<u32>> = vec![Vec::new()];
        for _ in 1..tokens.len() {
            fee_lists = fee_lists
                .into_iter()
                .flat_map(|fees| {
                    FEE_TIERS.iter().map(move |fee| {
                        let mut next = fees.clone();
                        next.push(*fee);
                        next
                    })
                })
                .collect();
        }
        routes.extend(fee_lists.into_iter().map(|fees| Route {
            tokens: tokens.clone(),
            fees,
        }));
    }
    routes
}

/// Uniswap v3's packed path: token (20 bytes), fee (3 bytes), token, …
pub fn encode_path(route: &Route) -> Vec<u8> {
    let mut path = Vec::with_capacity(20 * route.tokens.len() + 3 * route.fees.len());
    path.extend_from_slice(route.tokens[0].as_slice());
    for (index, fee) in route.fees.iter().enumerate() {
        path.extend_from_slice(&fee.to_be_bytes()[1..4]);
        path.extend_from_slice(route.tokens[index + 1].as_slice());
    }
    path
}

/// Rounds down, like the daemon's `apply_output_slippage`.
pub fn minimum_out(amount_out: U256, slippage_bps: u64) -> U256 {
    amount_out * U256::from(10_000 - slippage_bps) / U256::from(10_000)
}

async fn eth_call(provider: &impl Provider, to: Address, data: Vec<u8>) -> Option<Bytes> {
    let tx = TransactionRequest {
        to: Some(to.into()),
        input: Bytes::from(data).into(),
        ..Default::default()
    };
    provider.call(tx).await.ok()
}

/// Whether the pool for this pair and fee exists and holds liquidity. Unordered: Uniswap's
/// factory returns the same pool for (a, b) and (b, a).
async fn pool_is_live(
    provider: &impl Provider,
    factory: Address,
    pair: (Address, Address, u32),
) -> Result<bool, String> {
    let (a, b, fee) = pair;
    let call = getPoolCall {
        tokenA: a,
        tokenB: b,
        fee: U24::from(fee),
    };
    let raw = provider
        .call(TransactionRequest {
            to: Some(factory.into()),
            input: Bytes::from(call.abi_encode()).into(),
            ..Default::default()
        })
        .await
        .map_err(|e| format!("cannot read the Uniswap factory: {e}"))?;
    let pool = getPoolCall::abi_decode_returns(&raw)
        .map_err(|_| "unexpected factory answer".to_string())?;
    if pool.is_zero() {
        return Ok(false);
    }
    let liquidity = eth_call(provider, pool, liquidityCall {}.abi_encode())
        .await
        .and_then(|raw| liquidityCall::abi_decode_returns(&raw).ok())
        .unwrap_or(0);
    Ok(liquidity > 0)
}

fn pair_key(a: Address, b: Address, fee: u32) -> (Address, Address, u32) {
    if a < b { (a, b, fee) } else { (b, a, fee) }
}

/// The best exact-input quote over every candidate route, or `None` if no route has pools
/// with liquidity. Routes whose quote reverts are skipped, as in the daemon. Each distinct
/// pool is looked up once and the lookups and quotes run concurrently, since a fork answers
/// every call over the network.
pub async fn quote_best_route(
    provider: &impl Provider,
    contracts: Contracts,
    token_in: Address,
    token_out: Address,
    amount_in: U256,
    slippage_bps: u64,
    intermediates: &[Address],
) -> Result<Option<Quote>, String> {
    let routes = candidate_routes(token_in, token_out, intermediates);
    let mut pairs: Vec<(Address, Address, u32)> = routes
        .iter()
        .flat_map(|route| {
            route
                .fees
                .iter()
                .enumerate()
                .map(|(i, fee)| pair_key(route.tokens[i], route.tokens[i + 1], *fee))
        })
        .collect();
    pairs.sort();
    pairs.dedup();
    let live = futures::future::try_join_all(
        pairs
            .iter()
            .map(|pair| pool_is_live(provider, contracts.factory, *pair)),
    )
    .await?;
    let is_live = |a, b, fee| {
        pairs
            .iter()
            .position(|p| *p == pair_key(a, b, fee))
            .is_some_and(|i| live[i])
    };
    let usable: Vec<Route> = routes
        .into_iter()
        .filter(|route| {
            route
                .fees
                .iter()
                .enumerate()
                .all(|(i, fee)| is_live(route.tokens[i], route.tokens[i + 1], *fee))
        })
        .collect();

    let quotes = futures::future::join_all(usable.into_iter().map(|route| async move {
        let path = encode_path(&route);
        let call = quoteExactInputCall {
            path: Bytes::from(path.clone()),
            amountIn: amount_in,
        };
        let decoded = eth_call(provider, contracts.quoter, call.abi_encode())
            .await
            .and_then(|raw| quoteExactInputCall::abi_decode_returns(&raw).ok())?;
        (!decoded.amountOut.is_zero()).then(|| Quote {
            amount_out_minimum: minimum_out(decoded.amountOut, slippage_bps),
            amount_out: decoded.amountOut,
            gas_estimate: decoded.gasEstimate,
            route,
            path,
        })
    }))
    .await;
    Ok(quotes
        .into_iter()
        .flatten()
        .max_by(|a, b| a.amount_out.cmp(&b.amount_out)))
}

pub async fn allowance(
    provider: &impl Provider,
    token: Address,
    owner: Address,
    spender: Address,
) -> Result<U256, String> {
    let raw = eth_call(
        provider,
        token,
        allowanceCall { owner, spender }.abi_encode(),
    )
    .await
    .ok_or_else(|| format!("cannot read the allowance on {token}"))?;
    allowanceCall::abi_decode_returns(&raw)
        .map_err(|_| format!("{token} did not answer allowance()"))
}

pub fn approve_calldata(spender: Address, amount: U256) -> Bytes {
    Bytes::from(approveCall { spender, amount }.abi_encode())
}

/// The router call for `quote`: `exactInput` to the owner, or, when the output is ETH,
/// `multicall(exactInput → router, unwrapWETH9(min, owner))`.
pub fn router_calldata(
    quote: &Quote,
    amount_in: U256,
    owner: Address,
    router: Address,
    token_out_is_native: bool,
) -> Bytes {
    let exact_input = |recipient: Address| {
        exactInputCall {
            params: ExactInputParams {
                path: Bytes::from(quote.path.clone()),
                recipient,
                amountIn: amount_in,
                amountOutMinimum: quote.amount_out_minimum,
            },
        }
        .abi_encode()
    };
    if token_out_is_native {
        let unwrap = unwrapWETH9Call {
            amountMinimum: quote.amount_out_minimum,
            recipient: owner,
        }
        .abi_encode();
        Bytes::from(
            multicallCall {
                data: vec![Bytes::from(exact_input(router)), Bytes::from(unwrap)],
            }
            .abi_encode(),
        )
    } else {
        Bytes::from(exact_input(owner))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: Address = address!("0x1000000000000000000000000000000000000001");
    const B: Address = address!("0x2000000000000000000000000000000000000002");
    const C: Address = address!("0x3000000000000000000000000000000000000003");

    #[test]
    fn encodes_the_path_like_the_daemon() {
        let route = Route {
            tokens: vec![A, C, B],
            fees: vec![500, 3_000],
        };
        assert_eq!(
            alloy_primitives::hex::encode(encode_path(&route)),
            concat!(
                "1000000000000000000000000000000000000001",
                "0001f4",
                "3000000000000000000000000000000000000003",
                "000bb8",
                "2000000000000000000000000000000000000002",
            )
        );
    }

    #[test]
    fn routes_are_direct_plus_one_hop_without_cycles() {
        let routes = candidate_routes(A, B, &[A, C, B, C]);
        assert_eq!(
            routes.len(),
            4 + 16,
            "4 direct fee tiers, 16 two-hop combinations"
        );
        assert!(
            routes
                .iter()
                .all(|r| r.tokens == [A, B] || r.tokens == [A, C, B])
        );
    }

    #[test]
    fn slippage_rounds_down_like_the_daemon() {
        assert_eq!(minimum_out(U256::from(1_001u64), 100), U256::from(990u64));
    }

    #[test]
    fn selectors_match_the_apps_encoder() {
        // SwapRouterCallEncoder and ERC20ApprovalCallEncoder in UserOperationBuilder.swift.
        assert_eq!(exactInputCall::SELECTOR, [0xb8, 0x58, 0x18, 0x3f]);
        assert_eq!(multicallCall::SELECTOR, [0xac, 0x96, 0x50, 0xd8]);
        assert_eq!(unwrapWETH9Call::SELECTOR, [0x49, 0x40, 0x4b, 0x7c]);
        assert_eq!(approveCall::SELECTOR, [0x09, 0x5e, 0xa7, 0xb3]);
    }

    #[test]
    fn eth_out_unwraps_to_the_owner_through_the_router() {
        let quote = Quote {
            route: Route {
                tokens: vec![A, B],
                fees: vec![500],
            },
            amount_out: U256::from(100u64),
            amount_out_minimum: U256::from(99u64),
            gas_estimate: U256::ZERO,
            path: encode_path(&Route {
                tokens: vec![A, B],
                fees: vec![500],
            }),
        };
        let data = router_calldata(&quote, U256::from(7u64), C, A, true);
        assert_eq!(data[..4], multicallCall::SELECTOR);
        let data = router_calldata(&quote, U256::from(7u64), C, A, false);
        assert_eq!(data[..4], exactInputCall::SELECTOR);
    }
}
