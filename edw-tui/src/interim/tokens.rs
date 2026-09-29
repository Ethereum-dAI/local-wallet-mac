//! Tokens the interim executor knows by symbol, per chain. Stored locally rather than
//! fetched, as edw's own EDW-010 plans to do. Any other ERC-20 works by its 0x address.

use alloy_primitives::{Address, address};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Token {
    pub symbol: &'static str,
    pub address: Address,
    pub decimals: u8,
}

const SEPOLIA: &[Token] = &[
    Token {
        symbol: "USDC",
        address: address!("0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"),
        decimals: 6,
    },
    Token {
        symbol: "WETH",
        address: address!("0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14"),
        decimals: 18,
    },
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
