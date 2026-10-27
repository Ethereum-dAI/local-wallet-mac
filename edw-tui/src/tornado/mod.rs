//! Tornado Cash through edw's CLI: shield, unshield, a prepared shield, the next fresh address,
//! and the private side of the balance.
//!
//! The model names a token and an amount. Both are checked against the unlocked network's pools
//! with edw-core's own catalog, at the rev the edw binary is pinned to, so a call edw would refuse
//! is refused before anything runs, with the pool sizes that would work. `--tail-calls` and
//! `--expected-fresh-address` are the harness's alone: no tool argument reaches them.

pub mod prepared;

use std::{fmt, time::Duration};

use alloy_primitives::Address;
use edw_core::{
    network::NetworkPreset,
    vault::tornadocash::{
        Pool, deposit_pools_for_asset, format_amount, parse_amount, resolve_asset,
    },
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::{
    edw::{self, EdwResult, text},
    interim::guards::{self, Amount},
};

/// Pool sync, proving and waiting for the bundler's receipt can take minutes, and a broadcast
/// stopped half way is worse than a slow one.
pub const TIMEOUT: Duration = Duration::from_secs(600);

/// The tokens edw can shield. Which of them a network has pools for is up to edw-core's catalog.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum Token {
    Eth,
    Dai,
    Usdc,
    Usdt,
    Wbtc,
}

impl Token {
    pub const ALL: [Token; 5] = [
        Token::Eth,
        Token::Dai,
        Token::Usdc,
        Token::Usdt,
        Token::Wbtc,
    ];

    pub fn symbol(self) -> &'static str {
        match self {
            Token::Eth => "ETH",
            Token::Dai => "DAI",
            Token::Usdc => "USDC",
            Token::Usdt => "USDT",
            Token::Wbtc => "WBTC",
        }
    }

    fn parse(text: &str) -> Result<Self, String> {
        Self::ALL
            .into_iter()
            .find(|token| token.symbol().eq_ignore_ascii_case(text))
            .ok_or_else(|| {
                format!(
                    "`{text}` cannot be shielded; the token must be one of {}",
                    list(&Self::ALL)
                )
            })
    }
}

impl fmt::Display for Token {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.symbol())
    }
}

fn list<T: fmt::Display>(items: &[T]) -> String {
    items
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(", ")
}

/// `network`'s pools for `token`, largest first.
fn pools(network: NetworkPreset, token: Token) -> Vec<&'static Pool> {
    let mut pools: Vec<&Pool> = Pool::POOLS
        .iter()
        .filter(|pool| {
            pool.chain_id == network.network_id().0
                && pool.symbol().eq_ignore_ascii_case(token.symbol())
        })
        .collect();
    pools.sort_by_key(|pool| std::cmp::Reverse(pool.amount_wei));
    pools
}

pub fn tokens_on(network: NetworkPreset) -> Vec<Token> {
    Token::ALL
        .into_iter()
        .filter(|token| !pools(network, *token).is_empty())
        .collect()
}

/// An amount of `token` that `network`'s pools can hold.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PoolAmount {
    pub network: NetworkPreset,
    pub token: Token,
    /// As edw writes it: `100`, `1.1`.
    pub amount: String,
    /// How a shield splits it into notes, largest first, as edw does: `1.1` ETH is `1` and `0.1`.
    pub notes: Vec<String>,
}

impl PoolAmount {
    pub fn new(network: NetworkPreset, token: Token, amount: &str) -> Result<Self, String> {
        let here = tokens_on(network);
        if here.is_empty() {
            return Err(format!(
                "{network} has no Tornado pools; shield and unshield work on sepolia ({}) and mainnet ({})",
                list(&tokens_on(NetworkPreset::Sepolia)),
                list(&tokens_on(NetworkPreset::Mainnet))
            ));
        }
        if !here.contains(&token) {
            return Err(format!(
                "{network} has no {token} pool; its Tornado pools are for {}",
                list(&here)
            ));
        }
        let text = match guards::amount(amount)? {
            Amount::Exact(text) => text,
            Amount::All => {
                return Err("a Tornado amount is an exact sum of pool sizes, not \"all\"".into());
            }
        };
        let chain = network.network_id().0;
        let asset = resolve_asset(token.symbol(), chain)?;
        let base = parse_amount(&text, asset.decimals()).map_err(|e| e.to_string())?;
        let notes = deposit_pools_for_asset(base, chain, &asset).map_err(|_| {
            let sizes: Vec<String> = pools(network, token).iter().map(|p| p.amount()).collect();
            format!(
                "{text} {token} is not a sum of the {network} {token} pool sizes ({} {token})",
                sizes.join(", ")
            )
        })?;
        Ok(Self {
            network,
            token,
            amount: format_amount(base, asset.decimals()),
            notes: notes.iter().map(Pool::amount).collect(),
        })
    }

    fn header(&self) -> String {
        format!(
            "{} {} on {} (chain {})",
            self.amount,
            self.token,
            self.network,
            self.network.network_id().0
        )
    }

    fn args(&self) -> [String; 4] {
        [
            "--token".into(),
            self.token.symbol().into(),
            "--amount-formatted".into(),
            self.amount.clone(),
        ]
    }
}

/// Calls the fresh account runs after an unshield's withdrawal, in edw's `--tail-calls` form
/// (`TARGET:0xCALLDATA[:WEI],…`). Only the harness makes one, from a stored preparation or a
/// reviewed plan; no tool argument becomes one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TailCalls(String);

impl TailCalls {
    fn count(&self) -> usize {
        self.0.split(',').count()
    }
}

/// What an unshield does with what it withdraws.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Destination {
    /// It stays on the fresh address.
    Fresh,
    /// What is left after the fee goes on to this address (`--to`).
    To(Address),
    /// The fresh account runs these calls (`--tail-calls`).
    Calls(TailCalls),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Unshield {
    pub amount: PoolAmount,
    pub destination: Destination,
    /// The fresh address the user reviewed, or that a plan's calls were built for. edw aborts
    /// before proving or signing when its next fresh address is another one.
    pub expected_fresh_address: Option<Address>,
}

/// One edw command a Tornado tool runs, checked against the unlocked network. [`Command::argv`]
/// runs it as a profile: the harness's sending profile, never one the model names.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Command {
    /// Deposits from the profile's first address, which pays the amount and the gas.
    Shield(PoolAmount),
    /// Reserves notes and returns their deposit calls; broadcasts nothing.
    Prepare(PoolAmount),
    Unshield(Unshield),
    /// The address the next unshield withdraws to. Stores nothing.
    PeekFreshAddress,
    /// Public and private holdings, with each unspent note.
    PrivateBalance,
}

/// `shield --from`: the profile's first address, the one transfers and balances use.
const PAYER_INDEX: &str = "0";

impl Command {
    /// The model's call, checked against `network`. Every argument a tool takes is read here.
    pub fn from_call(tool: &str, args: &Value, network: NetworkPreset) -> Result<Self, String> {
        let empty = Map::new();
        let args = match args {
            Value::Object(map) => map,
            Value::Null => &empty,
            _ => return Err("arguments must be a JSON object".into()),
        };
        let amount = || {
            let token = Token::parse(&text(args, "token", false)?.unwrap_or_else(|| "ETH".into()))?;
            let amount = match args.get("amount") {
                // Some models send a number even though the schema says string.
                Some(Value::Number(n)) => n.to_string(),
                _ => text(args, "amount", true)?.unwrap_or_default(),
            };
            PoolAmount::new(network, token, &amount)
        };
        Ok(match tool {
            "shield" => Command::Shield(amount()?),
            "prepare_shield" => Command::Prepare(amount()?),
            "unshield" => Command::Unshield(Unshield {
                amount: amount()?,
                destination: match text(args, "to", false)? {
                    None => Destination::Fresh,
                    Some(to) => Destination::To(guards::recipient(&to)?),
                },
                expected_fresh_address: None,
            }),
            "next_fresh_address" => Command::PeekFreshAddress,
            "balance" => Command::PrivateBalance,
            other => return Err(format!("`{other}` is not a Tornado tool")),
        })
    }

    /// The edw arguments (without the binary) that run this command as `profile`.
    pub fn argv(&self, profile: &str) -> Vec<String> {
        let owned = |parts: &[&str]| parts.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        let mut argv = match self {
            Command::Shield(amount) => {
                let mut argv = owned(&["shield"]);
                argv.extend(amount.args());
                argv.extend(owned(&["--from", PAYER_INDEX]));
                argv
            }
            Command::Prepare(amount) => {
                let mut argv = owned(&["shield", "--prepare"]);
                argv.extend(amount.args());
                argv
            }
            Command::Unshield(unshield) => {
                let mut argv = owned(&["unshield"]);
                argv.extend(unshield.amount.args());
                match &unshield.destination {
                    Destination::Fresh => {}
                    Destination::To(to) => argv.extend(["--to".into(), to.to_string()]),
                    Destination::Calls(calls) => {
                        argv.extend(["--tail-calls".into(), calls.0.clone()]);
                    }
                }
                if let Some(fresh) = unshield.expected_fresh_address {
                    argv.extend(["--expected-fresh-address".into(), fresh.to_string()]);
                }
                argv
            }
            Command::PeekFreshAddress => owned(&["next-fresh-address", "--peek"]),
            // `--` keeps a profile name that starts with a dash from being read as a flag.
            Command::PrivateBalance => return owned(&["balance", "--detailed", "--", profile]),
        };
        argv.extend(["--profile".into(), profile.to_owned()]);
        argv
    }

    /// The command line the log, the review and the model see: tail calls are counted, never
    /// spelled out, so no calldata reaches the model.
    pub fn display(&self, profile: &str) -> String {
        let mut argv = self.argv(profile);
        if let Command::Unshield(Unshield {
            destination: Destination::Calls(calls),
            ..
        }) = self
            && let Some(at) = argv.iter().position(|arg| arg == "--tail-calls")
        {
            argv[at + 1] = format!("<{} calls>", calls.count());
        }
        edw::display_command(&argv)
    }

    /// What the review card says under the command line. `fresh` is the address an unshield
    /// withdraws to, as `next_fresh_address` reported it.
    pub fn preview(&self, profile: &str, fresh: Option<&FreshAddress>) -> String {
        match self {
            Command::Shield(amount) | Command::Prepare(amount) => {
                let notes = amount
                    .notes
                    .iter()
                    .map(|note| format!("{note} {}", amount.token))
                    .collect::<Vec<_>>()
                    .join(" + ");
                let mut lines = vec![
                    format!("Shield   {}", amount.header()),
                    format!("Notes    {notes}"),
                ];
                if let Command::Prepare(_) = self {
                    lines.push(format!(
                        "Reserve  these notes for profile {profile}; nothing is sent now"
                    ));
                } else {
                    lines.push(format!(
                        "Pays     profile {profile}, address index {PAYER_INDEX} (the amount and the gas)"
                    ));
                    // edw batches several notes, or a token's approval and deposit, into one
                    // user operation, which delegates the paying address with EIP-7702.
                    if amount.notes.len() > 1 || amount.token != Token::Eth {
                        lines.push("Batch    one user operation; it installs edw's EIP-7702 delegation on that address if missing".into());
                    }
                    lines.push("Signed and sent by edw".into());
                }
                lines.join("\n")
            }
            Command::Unshield(unshield) => {
                let token = unshield.amount.token;
                let mut lines = vec![format!(
                    "Unshield {} from profile {profile}'s shielded notes",
                    unshield.amount.header()
                )];
                if let Some(fresh) = fresh {
                    lines.push(format!(
                        "Fresh    {} (address index {}): one user operation from there",
                        fresh.address, fresh.index
                    ));
                }
                lines.push(if token == Token::Eth {
                    "Fee      comes out of the ETH note".into()
                } else {
                    "Fee      one of your shielded ETH notes pays it; its rest stays on the fresh address".into()
                });
                lines.push(match &unshield.destination {
                    Destination::Fresh => {
                        format!("Result   the {token} stays on the fresh address")
                    }
                    Destination::To(to) => format!("To       {to}"),
                    Destination::Calls(calls) => {
                        format!("Then     {} calls from the fresh address", calls.count())
                    }
                });
                lines.push("Signed and sent by edw".into());
                lines.join("\n")
            }
            Command::PeekFreshAddress | Command::PrivateBalance => String::new(),
        }
    }
}

/// Whether a `balance` call asks for the shielded side, which edw reads.
pub fn wants_private(args: &Value) -> bool {
    match args.get("private") {
        Some(Value::Bool(private)) => *private,
        // Models often send booleans as strings.
        Some(Value::String(text)) => text.trim().eq_ignore_ascii_case("true"),
        _ => false,
    }
}

/// edw's `edw/next-fresh-address` answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FreshAddress {
    pub index: u32,
    pub address: Address,
}

impl FreshAddress {
    pub fn from_document(document: &Value) -> Option<Self> {
        if document["kind"] != "edw/next-fresh-address" {
            return None;
        }
        Some(Self {
            index: u32::try_from(document["index"].as_u64()?).ok()?,
            address: document["address"].as_str()?.parse().ok()?,
        })
    }
}

/// `result` as the model and the log get it: edw's JSON document alone when it printed one, so
/// progress lines on stderr (which echo tail calls) never reach the model.
pub fn for_model(result: EdwResult, command: &str) -> EdwResult {
    let output = result
        .document()
        .map_or(result.output, |document| document.to_string());
    EdwResult {
        command: command.to_owned(),
        exit_code: result.exit_code,
        output,
    }
}

fn amount_properties() -> Map<String, Value> {
    let symbols: Vec<&str> = Token::ALL.iter().map(|t| t.symbol()).collect();
    json!({
        "token": {"type": "string", "enum": symbols, "description": "Defaults to ETH."},
        "amount": {"type": "string", "description": "Decimal amount in token units, e.g. \"0.1\" or \"100\". It must be a sum of the network's pool sizes."}
    })
    .as_object()
    .cloned()
    .expect("an object")
}

pub fn shield_parameters() -> Value {
    json!({"type": "object", "properties": amount_properties(), "required": ["amount"]})
}

pub fn unshield_parameters() -> Value {
    let mut properties = amount_properties();
    properties.insert(
        "to".into(),
        json!({"type": "string", "description": "Optional 0x address to forward it to. Omit to keep it on the fresh address."}),
    );
    json!({"type": "object", "properties": properties, "required": ["amount"]})
}

#[cfg(test)]
mod tests {
    use super::*;
    use NetworkPreset::{Local, Mainnet, Sepolia};

    const PROFILE: &str = "0/0";
    const TO: &str = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";

    fn command(tool: &str, args: Value, network: NetworkPreset) -> Result<Command, String> {
        Command::from_call(tool, &args, network)
    }

    fn argv(tool: &str, args: Value, network: NetworkPreset) -> String {
        command(tool, args, network)
            .unwrap_or_else(|e| panic!("{tool}: {e}"))
            .argv(PROFILE)
            .join(" ")
    }

    #[test]
    fn maps_every_tornado_call_onto_edw_argv() {
        let cases = [
            (
                "shield",
                json!({"token": "dai", "amount": "200"}),
                "shield --token DAI --amount-formatted 200 --from 0 --profile 0/0",
            ),
            (
                "shield",
                json!({"amount": 1.1}),
                "shield --token ETH --amount-formatted 1.1 --from 0 --profile 0/0",
            ),
            (
                "prepare_shield",
                json!({"token": "DAI", "amount": "100.0"}),
                "shield --prepare --token DAI --amount-formatted 100 --profile 0/0",
            ),
            (
                "unshield",
                json!({"token": "ETH", "amount": "0.1"}),
                "unshield --token ETH --amount-formatted 0.1 --profile 0/0",
            ),
            (
                "unshield",
                json!({"amount": "0.1", "to": TO}),
                "unshield --token ETH --amount-formatted 0.1 --to 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --profile 0/0",
            ),
            (
                "next_fresh_address",
                json!({}),
                "next-fresh-address --peek --profile 0/0",
            ),
            (
                "balance",
                json!({"private": true}),
                "balance --detailed -- 0/0",
            ),
        ];
        for (tool, args, expected) in cases {
            assert_eq!(argv(tool, args, Sepolia), expected, "{tool}");
        }
    }

    #[test]
    fn a_network_without_the_tokens_pool_is_refused_with_what_it_has() {
        let usdc = command("shield", json!({"token": "USDC", "amount": "100"}), Sepolia);
        let why = usdc.unwrap_err();
        assert!(why.contains("ETH, DAI"), "{why}");
        assert!(command("shield", json!({"token": "USDC", "amount": "100"}), Mainnet).is_ok());
        for token in ["ETH", "DAI"] {
            let local = command("unshield", json!({"token": token, "amount": "100"}), Local);
            assert!(local.unwrap_err().contains("no Tornado pools"), "{token}");
        }
        for token in ["DOGE", "WETH", "0x6B175474E89094C44Da98b954EedeAC495271d0F"] {
            let why = command("shield", json!({"token": token, "amount": "1"}), Mainnet);
            assert!(why.unwrap_err().contains("must be one of"), "{token}");
        }
    }

    #[test]
    fn only_sums_of_the_networks_pool_sizes_are_accepted() {
        let ok = |token: &str, amount: &str, network| {
            command("shield", json!({"token": token, "amount": amount}), network).is_ok()
        };
        for amount in ["0.1", "1.1", "12.3", "0.3"] {
            assert!(ok("ETH", amount, Sepolia), "{amount} ETH");
        }
        for amount in ["1.15", "0.05", "0.000000000000000001"] {
            assert!(!ok("ETH", amount, Sepolia), "{amount} ETH");
        }
        assert!(ok("DAI", "300", Sepolia) && !ok("DAI", "150", Sepolia));
        assert!(ok("ETH", "100", Mainnet) && ok("WBTC", "1.1", Mainnet));
        assert!(ok("USDC", "1100", Mainnet) && !ok("USDC", "50", Mainnet));
        let why = command("shield", json!({"amount": "1.15"}), Sepolia).unwrap_err();
        assert!(why.contains("10, 1, 0.1 ETH"), "{why}");
        for bad in ["all", "-1", "0", "1e18", "abc", ""] {
            assert!(!ok("ETH", bad, Sepolia), "{bad}");
        }
    }

    #[test]
    fn a_shield_splits_into_notes_as_edw_does() {
        let Ok(Command::Shield(amount)) = command("shield", json!({"amount": "12.3"}), Sepolia)
        else {
            panic!("a valid shield");
        };
        assert_eq!(amount.notes, ["10", "1", "1", "0.1", "0.1", "0.1"]);
        let preview = Command::Shield(amount).preview(PROFILE, None);
        assert!(preview.contains("10 ETH + 1 ETH + 1 ETH"), "{preview}");
        assert!(preview.contains("sepolia (chain 11155111)") && preview.contains("Batch"));
    }

    #[test]
    fn an_unshield_destination_must_be_a_real_address() {
        for to in [
            "0x0000000000000000000000000000000000000000",
            "0x000000000000000000000000000000000000dEaD",
            "vitalik.eth",
            "0x1234",
            "ADDR_7",
        ] {
            let call = command("unshield", json!({"amount": "0.1", "to": to}), Sepolia);
            assert!(call.is_err(), "{to}");
        }
    }

    #[test]
    fn tail_calls_and_the_expected_fresh_address_come_only_from_the_harness() {
        let model = command(
            "unshield",
            json!({"amount": "1", "tail_calls": format!("{TO}:0xdeadbeef"), "expected_fresh_address": TO}),
            Sepolia,
        )
        .unwrap();
        let line = model.argv(PROFILE).join(" ");
        assert!(!line.contains("--tail-calls") && !line.contains("--expected-fresh-address"));

        let calls = format!("{TO}:0xdeadbeef:0,{TO}:0x");
        let Command::Unshield(mut harness) = model else {
            panic!("an unshield");
        };
        harness.destination = Destination::Calls(TailCalls(calls.clone()));
        harness.expected_fresh_address = Some(TO.parse().unwrap());
        let harness = Command::Unshield(harness);
        let argv = harness.argv(PROFILE);
        assert!(
            argv.windows(2)
                .any(|w| w == ["--tail-calls", calls.as_str()])
        );
        assert!(
            argv.windows(2)
                .any(|w| w[0] == "--expected-fresh-address" && w[1] == TO)
        );
        let shown = harness.display(PROFILE);
        assert!(
            !shown.contains("deadbeef") && shown.contains("<2 calls>"),
            "{shown}"
        );
    }

    #[test]
    fn edw_json_alone_reaches_the_model() {
        let result = EdwResult {
            command: "edw unshield".into(),
            exit_code: 1,
            output: format!(
                "{{\"kind\":\"edw/error\",\"message\":\"no notes\"}}\ntail {TO}:0xdeadbeef:0"
            ),
        };
        let shown = for_model(result, "edw unshield --token ETH");
        assert!(!shown.output.contains("deadbeef"), "{shown:?}");
        assert!(shown.output.contains("no notes") && shown.exit_code == 1);
    }

    #[test]
    fn reads_the_next_fresh_address() {
        let document = json!({"kind": "edw/next-fresh-address", "version": 1, "index": 3, "path": "m/44'/60'/0'/0/3", "address": TO, "stored": false});
        let fresh = FreshAddress::from_document(&document).unwrap();
        assert_eq!((fresh.index, fresh.address.to_string()), (3, TO.to_owned()));
        assert!(FreshAddress::from_document(&json!({"kind": "edw/error"})).is_none());
    }

    #[test]
    fn schemas_offer_the_token_enum_and_no_harness_fields() {
        for schema in [shield_parameters(), unshield_parameters()] {
            assert_eq!(
                schema["properties"]["token"]["enum"],
                json!(["ETH", "DAI", "USDC", "USDT", "WBTC"])
            );
            for harness_only in ["tail_calls", "expected_fresh_address", "profile", "from"] {
                assert!(
                    schema["properties"].get(harness_only).is_none(),
                    "{harness_only}"
                );
            }
        }
    }
}
