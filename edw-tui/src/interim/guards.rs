//! Checks that run before the interim executor opens the store or touches the chain.
//!
//! They back up the model's safety clause; they do not replace it. Everything here is pure,
//! so it is unit-tested without a wallet or a node.

use alloy_primitives::{Address, U256};
use serde_json::{Map, Value};

use crate::edw::text;

/// Destinations no transfer may go to. Compared case-insensitively.
pub const BURN_ADDRESSES: [&str; 3] = [
    "0x0000000000000000000000000000000000000000",
    "0x000000000000000000000000000000000000dEaD",
    "0xdEAD000000000000000042069420694206942069",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Amount {
    /// A positive decimal in human units, as the user said it.
    Exact(String),
    All,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TokenRef {
    Native,
    Symbol(String),
    Address(Address),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransferArgs {
    pub to: Address,
    pub amount: Amount,
    pub token: TokenRef,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BalanceArgs {
    pub token: Option<TokenRef>,
}

fn object(args: &Value) -> Result<Map<String, Value>, String> {
    match args {
        Value::Object(map) => Ok(map.clone()),
        Value::Null => Ok(Map::new()),
        _ => Err("arguments must be a JSON object".into()),
    }
}

fn is_hex_address(value: &str) -> bool {
    value.len() == 42
        && value.starts_with("0x")
        && value[2..].chars().all(|c| c.is_ascii_hexdigit())
}

pub fn is_burn(address: &Address) -> bool {
    BURN_ADDRESSES
        .iter()
        .any(|burn| burn.eq_ignore_ascii_case(&address.to_string()))
}

pub fn recipient(value: &str) -> Result<Address, String> {
    if !is_hex_address(value) {
        return Err(
            if value.to_uppercase().starts_with(crate::addresses::PREFIX) {
                format!(
                    "`{value}` is not an address from this conversation; ask the user for the address"
                )
            } else if value.to_lowercase().ends_with(".eth") {
                format!(
                    "`{value}` is an ENS name, and edw-tui cannot resolve names yet; ask the user for the 0x address"
                )
            } else if value.starts_with("0x") {
                format!(
                    "`{value}` is not a valid address: it must be 0x followed by 40 hex characters"
                )
            } else {
                format!(
                    "`{value}` is not a 0x address; edw-tui can only send to 0x addresses for now (no contacts or other chains)"
                )
            },
        );
    }
    let address: Address = value
        .parse()
        .map_err(|_| format!("`{value}` is not a valid address"))?;
    if is_burn(&address) {
        return Err(format!(
            "`{value}` is a burn or zero address; funds sent there are lost, so edw-tui refuses to send to it"
        ));
    }
    Ok(address)
}

pub fn amount(value: &str) -> Result<Amount, String> {
    if value == "all" {
        return Ok(Amount::All);
    }
    let (whole, fraction) = value.split_once('.').unwrap_or((value, ""));
    let digits = |s: &str| s.chars().all(|c| c.is_ascii_digit());
    if whole.is_empty() || !digits(whole) || !digits(fraction) || value.ends_with('.') {
        return Err(format!(
            "`{value}` is not a plain positive number (for example 0.1), or \"all\""
        ));
    }
    if value.chars().all(|c| c == '0' || c == '.') {
        return Err("the amount must be greater than zero".into());
    }
    Ok(Amount::Exact(value.to_owned()))
}

pub fn token(value: Option<&str>) -> Result<TokenRef, String> {
    let Some(value) = value else {
        return Ok(TokenRef::Native);
    };
    if value.eq_ignore_ascii_case("eth") {
        return Ok(TokenRef::Native);
    }
    if value.starts_with("0x") {
        if !is_hex_address(value) {
            return Err(format!("`{value}` is not a valid token address"));
        }
        let address: Address = value
            .parse()
            .map_err(|_| format!("`{value}` is not a valid token address"))?;
        if is_burn(&address) {
            return Err(format!("`{value}` is not a token"));
        }
        return Ok(TokenRef::Address(address));
    }
    let mut chars = value.chars();
    let valid = chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric())
        && value.len() <= 11;
    if !valid {
        return Err(format!("`{value}` is not a token symbol or 0x address"));
    }
    Ok(TokenRef::Symbol(value.to_uppercase()))
}

pub fn transfer_args(args: &Value) -> Result<TransferArgs, String> {
    let args = object(args)?;
    let to = text(&args, "to", true)?.unwrap_or_default();
    let amount_text = match args.get("amount") {
        // Some models send a number even though the schema says string.
        Some(Value::Number(n)) => n.to_string(),
        _ => text(&args, "amount", true)?.unwrap_or_default(),
    };
    Ok(TransferArgs {
        to: recipient(&to)?,
        amount: amount(&amount_text)?,
        token: token(text(&args, "token", false)?.as_deref())?,
    })
}

pub fn balance_args(args: &Value) -> Result<BalanceArgs, String> {
    let args = object(args)?;
    let token_text = text(&args, "token", false)?;
    Ok(BalanceArgs {
        token: match token_text.as_deref() {
            // Models ask for "all" (or similar) when they mean every token.
            None | Some("*") => None,
            Some(t)
                if ["all", "any", "every", "everything"].contains(&t.to_lowercase().as_str()) =>
            {
                None
            }
            Some(t) => Some(token(Some(t))?),
        },
    })
}

/// `"1.5"` with 18 decimals → 1.5 × 10¹⁸. More fraction digits than the token has is an error,
/// never a silent rounding.
pub fn parse_units(value: &str, decimals: u8) -> Result<U256, String> {
    let (whole, fraction) = value.split_once('.').unwrap_or((value, ""));
    if fraction.len() > decimals as usize {
        return Err(format!(
            "`{value}` has more decimal places than the token supports ({decimals})"
        ));
    }
    let padded = format!("{whole}{fraction:0<width$}", width = decimals as usize);
    U256::from_str_radix(&padded, 10).map_err(|_| format!("`{value}` is too large"))
}

/// Base units back to a trimmed decimal: 1.5 × 10¹⁸ with 18 decimals → `"1.5"`.
pub fn format_units(value: U256, decimals: u8) -> String {
    let digits = value.to_string();
    let decimals = decimals as usize;
    if decimals == 0 {
        return digits;
    }
    let padded = format!("{digits:0>width$}", width = decimals + 1);
    let (whole, fraction) = padded.split_at(padded.len() - decimals);
    let fraction = fraction.trim_end_matches('0');
    if fraction.is_empty() {
        whole.to_owned()
    } else {
        format!("{whole}.{fraction}")
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn refuses_burn_zero_and_malformed_recipients() {
        for bad in [
            "0x0000000000000000000000000000000000000000",
            "0x000000000000000000000000000000000000dead",
            "0x000000000000000000000000000000000000DEAD",
            "0xdead000000000000000042069420694206942069",
            "0x1234",
            "0x000000000000000000000000000000000000beeg",
            "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh",
            "vitalik.eth",
            "alice",
        ] {
            assert!(recipient(bad).is_err(), "{bad}");
        }
        assert!(recipient("vitalik.eth").unwrap_err().contains("ENS"));
        // Real addresses may begin with zeros; only the listed ones are refused.
        assert!(recipient("0x0000000000000000000000000000000000000001").is_ok());
        assert!(recipient("0x000000000000000000000000000000000000bEEF").is_ok());
    }

    #[test]
    fn accepts_plain_positive_amounts_or_all() {
        assert_eq!(amount("0.1"), Ok(Amount::Exact("0.1".into())));
        assert_eq!(amount("100"), Ok(Amount::Exact("100".into())));
        assert_eq!(amount("all"), Ok(Amount::All));
        for bad in [
            "-1", "0", "0.00", "1e18", "1,5", "abc", ".5", "5.", "", "ALL", "0x10",
        ] {
            assert!(amount(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn reads_tokens() {
        assert_eq!(token(None), Ok(TokenRef::Native));
        assert_eq!(token(Some("eth")), Ok(TokenRef::Native));
        assert_eq!(token(Some("usdc")), Ok(TokenRef::Symbol("USDC".into())));
        assert!(matches!(
            token(Some("0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238")),
            Ok(TokenRef::Address(_))
        ));
        for bad in ["0x12", "U$DC", "1INCH", "averyveryverylongsymbol"] {
            assert!(token(Some(bad)).is_err(), "{bad}");
        }
    }

    #[test]
    fn maps_transfer_arguments() {
        let args = transfer_args(&json!({
            "to": "0x000000000000000000000000000000000000bEEF",
            "amount": 0.25
        }))
        .unwrap();
        assert_eq!(args.amount, Amount::Exact("0.25".into()));
        assert_eq!(args.token, TokenRef::Native);
        assert!(transfer_args(&json!({"amount": "1"})).is_err());
        assert!(
            transfer_args(&json!({"to": "0x000000000000000000000000000000000000bEEF"})).is_err()
        );
    }

    #[test]
    fn a_balance_for_all_tokens_lists_everything() {
        for all in [
            json!({}),
            json!({"token": "all"}),
            json!({"token": "ALL"}),
            json!({"token": "*"}),
        ] {
            assert_eq!(balance_args(&all).unwrap().token, None, "{all}");
        }
        assert_eq!(
            balance_args(&json!({"token": "usdc"})).unwrap().token,
            Some(TokenRef::Symbol("USDC".into()))
        );
    }

    #[test]
    fn converts_units_exactly() {
        assert_eq!(
            parse_units("1.5", 18).unwrap(),
            U256::from(15u64) * U256::from(10u64).pow(U256::from(17))
        );
        assert_eq!(parse_units("100", 6).unwrap(), U256::from(100_000_000u64));
        assert!(parse_units("0.0000001", 6).is_err());
        assert_eq!(format_units(U256::from(1_500_000u64), 6), "1.5");
        assert_eq!(format_units(U256::from(10u64).pow(U256::from(18)), 18), "1");
        assert_eq!(format_units(U256::from(21000u64), 18), "0.000000000000021");
        assert_eq!(format_units(U256::ZERO, 18), "0");
    }
}
