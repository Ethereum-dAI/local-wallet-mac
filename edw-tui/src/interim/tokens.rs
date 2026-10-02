//! Tokens the interim executor knows by symbol, per chain: the SwiftUI app's
//! `WalletTokenRegistry` (`wallet-macos/.../UserOperationModels.swift`), stored locally rather
//! than fetched, as edw's own EDW-010 plans to do. Transfers accept any other ERC-20 by its 0x
//! address; swaps trade only these (the safety clause refuses unknown token addresses).

use alloy_primitives::{Address, address};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Token {
    pub symbol: &'static str,
    pub address: Address,
    pub decimals: u8,
}

const fn token(symbol: &'static str, address: Address, decimals: u8) -> Token {
    Token {
        symbol,
        address,
        decimals,
    }
}

const SEPOLIA: &[Token] = &[
    token(
        "WETH",
        address!("0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14"),
        18,
    ),
    token(
        "USDC",
        address!("0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"),
        6,
    ),
    token(
        "USDT",
        address!("0xaa8E23Fb1079EA71e0a56F48a2aA51851D8433D0"),
        6,
    ),
    token(
        "DAI",
        address!("0x776b6FC2eD15d6bB5fC32e0c89DE68683118c62a"),
        18,
    ),
    token(
        "AAVE",
        address!("0x5Bb220aFc6e2E008cB2302A83536A019ed245Aa2"),
        18,
    ),
    token(
        "UNI",
        address!("0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"),
        18,
    ),
];

pub const SEPOLIA_CHAIN_ID: u64 = 11_155_111;

pub fn known(chain_id: u64) -> &'static [Token] {
    match chain_id {
        SEPOLIA_CHAIN_ID => SEPOLIA,
        _ => &[],
    }
}

pub fn by_symbol(chain_id: u64, symbol: &str) -> Option<Token> {
    known(chain_id)
        .iter()
        .find(|token| token.symbol.eq_ignore_ascii_case(symbol))
        .copied()
}

pub fn by_address(chain_id: u64, address: Address) -> Option<Token> {
    known(chain_id)
        .iter()
        .find(|token| token.address == address)
        .copied()
}

/// What ETH is swapped as: the app's `wrappedNativeToken`.
pub fn wrapped_native(chain_id: u64) -> Option<Token> {
    by_symbol(chain_id, "WETH")
}

/// One-hop candidates a swap route may pass through: the app's `swapIntermediates`.
pub fn swap_intermediates(chain_id: u64) -> Vec<Token> {
    ["WETH", "USDC", "USDT", "DAI"]
        .iter()
        .filter_map(|symbol| by_symbol(chain_id, symbol))
        .collect()
}
