//! The profile's unspent Tornado ETH notes, as `edw balance --detailed` lists them, and whether
//! they can pay for an unshield the way edw picks notes, with edw-core's own `withdrawal_notes` at
//! the rev the edw binary is pinned to. Only mined notes count, each is spent whole, together they
//! must make the amount exactly, and one of those picked must be in a pool with a paymaster to
//! sponsor the gas.

use std::fmt;

use alloy_primitives::U256;
use edw_core::{
    network::NetworkPreset,
    vault::tornadocash::{
        AmountError, Asset, Pool, TornadoNote, exact_notes_for_asset, format_amount,
        withdrawal_notes,
    },
};
use serde::Deserialize;

use super::{Token, pools};
use crate::edw::EdwResult;

/// One unspent Tornado ETH note: its pool in edw-core's catalog, and whether its deposit is mined.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HeldNote {
    pub pool: Pool,
    pub mined: bool,
}

/// A profile's unspent Tornado ETH notes on `network`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HeldEth {
    pub network: NetworkPreset,
    pub notes: Vec<HeldNote>,
}

/// Why edw would refuse an unshield before signing anything.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// The mined notes cannot make the amount exactly, even with the pending ones mined.
    CannotMake,
    /// They could once notes still pending are mined.
    NotMined,
    /// The notes edw picks for the amount are all in pools without a paymaster.
    NoSponsor,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refused {
    pub reason: Refusal,
    pub message: String,
}

impl fmt::Display for Refused {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

/// A row of the balance document's `tornado_notes`.
#[derive(Deserialize)]
struct Row {
    pool: String,
    #[serde(default)]
    pending: bool,
}

impl HeldEth {
    /// What `edw balance --detailed` returned on `network`. A failed command, or a balance without
    /// `tornado_notes` (edw could not read them, and says why on stderr), is an error, since the
    /// notes are then unknown, not absent.
    pub fn read(result: &EdwResult, network: NetworkPreset) -> Result<Self, String> {
        let document = result.document();
        if !result.ok() {
            return Err(document
                .as_ref()
                .and_then(|document| document["message"].as_str())
                .map_or_else(|| result.output.clone(), str::to_owned));
        }
        let Some(document) = document.filter(|document| document["kind"] == "edw/balance") else {
            return Err(format!("edw printed no balance ({})", result.output));
        };
        let Some(rows) = document.get("tornado_notes") else {
            let why = result
                .output
                .lines()
                .find(|line| line.starts_with("Could not read Tornado notes"))
                .unwrap_or("edw left them out of its balance");
            return Err(why.to_owned());
        };
        let rows: Vec<Row> = serde_json::from_value(rows.clone())
            .map_err(|e| format!("edw's tornado_notes are not a list of notes ({e})"))?;
        let mut notes = Vec::new();
        for row in rows {
            let pool = Pool::POOLS
                .iter()
                .find(|pool| pool.id() == row.pool)
                .ok_or_else(|| {
                    format!(
                        "edw listed a note in pool {}, which edw-core at the pinned rev does not know",
                        row.pool
                    )
                })?;
            // `edw balance` lists a token's notes only while the profile shows that token; ETH's
            // are always listed.
            if pool.asset == Asset::ETH {
                notes.push(HeldNote {
                    pool: pool.clone(),
                    mined: !row.pending,
                });
            }
        }
        Ok(Self { network, notes })
    }

    /// Whether these notes can pay for unshielding `amount` wei of ETH as `profile`, picked as edw
    /// picks them. `Err` is why edw would refuse it.
    pub fn unshield(&self, amount: U256, profile: &str) -> Result<(), Refused> {
        let chain = self.network.network_id().0;
        let pick = |with_pending| {
            withdrawal_notes(amount, &self.tornado(with_pending), &Asset::ETH, chain)
        };
        let error = match pick(false) {
            Ok(_) => return Ok(()),
            Err(error) => error,
        };
        let needed = eth(amount);
        let pending = describe(self.notes.iter().filter(|n| !n.mined).map(|n| &n.pool));
        let (reason, message) = match error {
            AmountError::Sponsor(_) => {
                let picked = exact_notes_for_asset(amount, &self.tornado(false), &Asset::ETH)
                    .unwrap_or_default();
                let sponsors: Vec<String> = pools(self.network, Token::Eth)
                    .into_iter()
                    .filter(|pool| pool.paymaster.is_some())
                    .map(|pool| format!("{} ETH", pool.amount()))
                    .collect();
                (
                    Refusal::NoSponsor,
                    format!(
                        "the mined Tornado ETH notes edw picks to make {needed} ({}) are all in pools without a paymaster, so none can sponsor the gas; on {} only the {} pools have one",
                        describe(picked.iter().map(|n| &n.pool)).unwrap_or_default(),
                        self.network,
                        sponsors.join(" and ")
                    ),
                )
            }
            _ if pick(true).is_ok() => (
                Refusal::NotMined,
                format!(
                    "profile {profile}'s Tornado ETH notes make {needed} only with notes that are not mined yet ({}); only mined notes can be unshielded, so try again once those deposits are mined",
                    pending.unwrap_or_default()
                ),
            ),
            _ => {
                let unmined = pending.map_or_else(String::new, |p| format!(" ({p} not mined yet)"));
                let mined = describe(self.notes.iter().filter(|n| n.mined).map(|n| &n.pool));
                (
                    Refusal::CannotMake,
                    match mined {
                        None => format!(
                            "profile {profile} holds no mined Tornado ETH notes{unmined}, but unshielding {needed} needs mined notes that make exactly {needed}; notes are only unshielded whole"
                        ),
                        Some(held) => format!(
                            "profile {profile} holds mined Tornado ETH notes of {held}{unmined}, which cannot make the {needed} needed exactly; notes are only unshielded whole"
                        ),
                    },
                )
            }
        };
        Err(Refused { reason, message })
    }

    /// The notes as edw-core's selection takes them, the pending ones counted as mined or not.
    fn tornado(&self, with_pending: bool) -> Vec<TornadoNote> {
        self.notes
            .iter()
            .zip(0..)
            .map(|(note, nonce)| TornadoNote {
                pool: note.pool.clone(),
                nonce,
                // The selection only asks whether a note has a leaf, not which one.
                leaf_index: (note.mined || with_pending).then_some(0),
                spent: false,
            })
            .collect()
    }
}

fn eth(wei: U256) -> String {
    format!("{} ETH", format_amount(wei, 18))
}

/// `10 ETH + 2 × 0.1 ETH`, largest first; `None` for no notes.
fn describe<'a>(pools: impl IntoIterator<Item = &'a Pool>) -> Option<String> {
    let mut pools: Vec<&Pool> = pools.into_iter().collect();
    pools.sort_by_key(|pool| std::cmp::Reverse(pool.amount_wei));
    let parts: Vec<String> = pools
        .chunk_by(|a, b| a.amount_wei == b.amount_wei)
        .map(|same| {
            let note = eth(U256::from(same[0].amount_wei));
            match same.len() {
                1 => note,
                n => format!("{n} × {note}"),
            }
        })
        .collect();
    (!parts.is_empty()).then(|| parts.join(" + "))
}

#[cfg(test)]
mod tests {
    use edw_core::vault::tornadocash::parse_amount;
    use serde_json::{Value, json};

    use super::*;

    /// `edw balance --detailed` from the pinned edw on the fake Sepolia (`tests/held_notes.rs`
    /// checks it still is), with mined 10 and 1 ETH notes and a 0.1 ETH note not mined yet.
    const BALANCE: &str = include_str!("../../tests/fixtures/balance_detailed_tornado_notes.json");

    fn balance() -> Value {
        serde_json::from_str(BALANCE).unwrap()
    }

    fn ran(document: &Value, stderr: &str) -> EdwResult {
        EdwResult {
            command: "edw balance --detailed -- 0/0".into(),
            exit_code: 0,
            output: format!("{document}\n{stderr}"),
        }
    }

    /// The real document with `rows` as its notes.
    fn holding(rows: Value) -> HeldEth {
        let mut document = balance();
        document["tornado_notes"] = rows;
        HeldEth::read(&ran(&document, ""), NetworkPreset::Sepolia).unwrap()
    }

    fn mined(pools: &[&str]) -> Value {
        pools.iter().map(|pool| json!({"pool": pool})).collect()
    }

    fn wei(eth: &str) -> U256 {
        parse_amount(eth, 18).unwrap()
    }

    fn refusal(held: &HeldEth, eth: &str) -> Option<Refusal> {
        held.unshield(wei(eth), "0/0")
            .err()
            .map(|refused| refused.reason)
    }

    #[test]
    fn reads_each_unspent_eth_note_from_the_pinned_edws_balance() {
        let held = HeldEth::read(&ran(&balance(), ""), NetworkPreset::Sepolia).unwrap();
        let note = |pool: &Pool, mined| HeldNote {
            pool: pool.clone(),
            mined,
        };
        assert_eq!(
            held.notes,
            [
                note(&Pool::SEPOLIA_ETHER_10, true),
                note(&Pool::SEPOLIA_ETHER_1, true),
                note(&Pool::SEPOLIA_ETHER_01, false),
            ]
        );
        let with_dai = holding(json!([{"pool": "dai-100-11155111", "amount": "100 dai"}]));
        assert!(with_dai.notes.is_empty(), "{with_dai:?}");
    }

    #[test]
    fn notes_edw_could_not_list_are_an_error_not_an_empty_list() {
        let mut unread = balance();
        unread.as_object_mut().unwrap().remove("tornado_notes");
        let why = HeldEth::read(
            &ran(
                &unread,
                "Could not read Tornado notes: provider error: connection refused",
            ),
            NetworkPreset::Sepolia,
        )
        .unwrap_err();
        assert!(why.contains("connection refused"), "{why}");

        let failed = EdwResult {
            command: "edw balance --detailed -- 0/0".into(),
            exit_code: 1,
            output: r#"{"kind":"edw/error","version":1,"class":"other","message":"RPC config `anvil` cannot be used for sepolia: tcp connect error"}"#.into(),
        };
        let why = HeldEth::read(&failed, NetworkPreset::Sepolia).unwrap_err();
        assert!(
            why.starts_with("RPC config `anvil` cannot be used"),
            "{why}"
        );

        let mut unknown = balance();
        unknown["tornado_notes"] = json!([{"pool": "eth-0.5-11155111"}]);
        let why = HeldEth::read(&ran(&unknown, ""), NetworkPreset::Sepolia).unwrap_err();
        assert!(why.contains("eth-0.5-11155111"), "{why}");

        let other = ran(&json!({"kind": "edw/next-fresh-address"}), "");
        assert!(HeldEth::read(&other, NetworkPreset::Sepolia).is_err());
    }

    /// What the pinned edw answered `unshield --token ETH --amount-formatted N` holding these very
    /// notes (`tests/held_notes.rs` asks it again). It went past note selection for 1 and 11,
    /// said "the selected ETH notes have no paymaster" for 10, and "held notes cannot make" for
    /// the rest.
    #[test]
    fn picks_notes_as_edw_does() {
        let held = HeldEth::read(&ran(&balance(), ""), NetworkPreset::Sepolia).unwrap();
        for (eth, expected) in [
            ("1", None),
            ("11", None),
            ("10", Some(Refusal::NoSponsor)),
            ("0.1", Some(Refusal::NotMined)),
            ("1.1", Some(Refusal::NotMined)),
            ("11.1", Some(Refusal::NotMined)),
            ("2", Some(Refusal::CannotMake)),
            ("0.2", Some(Refusal::CannotMake)),
        ] {
            assert_eq!(refusal(&held, eth), expected, "{eth} ETH");
        }
    }

    /// edw takes the largest notes first and only then looks for a sponsor, so a 10 ETH note is
    /// picked over ten 1 ETH notes that would have had one.
    #[test]
    fn the_largest_notes_are_picked_first_even_when_smaller_ones_could_sponsor() {
        let mut pools = vec!["eth-10-11155111"];
        pools.extend(["eth-1-11155111"; 10]);
        let held = holding(mined(&pools));
        assert_eq!(refusal(&held, "10"), Some(Refusal::NoSponsor));
        assert_eq!(refusal(&held, "11"), None);
        assert_eq!(refusal(&held, "9"), None);
    }

    #[test]
    fn the_refusal_says_what_is_held_and_what_is_needed() {
        let none = holding(json!([]));
        let refused = none.unshield(wei("1"), "0/0").unwrap_err();
        assert_eq!(refused.reason, Refusal::CannotMake);
        assert!(
            refused
                .message
                .contains("profile 0/0 holds no mined Tornado ETH notes")
                && refused.message.contains("exactly 1 ETH")
                && refused.message.contains("only unshielded whole"),
            "{refused}"
        );

        let small = holding(mined(&[
            "eth-1-11155111",
            "eth-0.1-11155111",
            "eth-0.1-11155111",
        ]));
        let refused = small.unshield(wei("0.3"), "0/0").unwrap_err();
        assert!(
            refused.message.contains("notes of 1 ETH + 2 × 0.1 ETH")
                && refused.message.contains("the 0.3 ETH needed")
                && refused.message.contains("only unshielded whole"),
            "{refused}"
        );

        let pending = holding(json!([{"pool": "eth-1-11155111", "pending": true}]));
        let refused = pending.unshield(wei("1"), "0/0").unwrap_err();
        assert_eq!(refused.reason, Refusal::NotMined);
        assert!(
            refused.message.contains("not mined yet (1 ETH)"),
            "{refused}"
        );

        let big = holding(mined(&["eth-10-11155111"]));
        let refused = big.unshield(wei("10"), "0/0").unwrap_err();
        assert!(
            refused.message.contains("(10 ETH)")
                && refused
                    .message
                    .contains("on sepolia only the 1 ETH and 0.1 ETH pools have one"),
            "{refused}"
        );
    }
}
