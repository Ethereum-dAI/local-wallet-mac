//! The adapter held to the pinned edw: every tool, through `build_argv` (or `tornado::Command`)
//! and the real binary.
//!
//! These are the tests meant to break when edw changes. After bumping `EDW_PINNED_REV`, fix
//! `build_argv` (and, if a tool's meaning changed, the contract) until they pass. Assertions
//! check the facts the tool descriptions promise the model, not edw's exact wording.
//!
//! Skips when `edw` is not installed; see the README for the pinned install command. The
//! Tornado checks also skip without anvil.

mod common;

use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
};

use alloy_node_bindings::Anvil;
use alloy_primitives::{Address, address};
use common::{TempWallet, edw_binary, fake_sepolia};
use edw_core::network::NetworkPreset;
use edw_tui::{
    edw::{self, Backend, EdwConfig, EdwResult, PHRASE_PLACEHOLDER, Pin, TOOLS},
    tornado::{self, Command, Destination, FreshAddress, Token, prepared::Store},
};
use serde_json::{Value, json};

#[test]
fn installed_edw_is_the_pinned_rev() {
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return;
    };
    match edw::check_pin(&binary) {
        Pin::Matches => {}
        Pin::Unverified(reason) if std::env::var_os("EDW_BIN").is_some() => {
            eprintln!("skipping: EDW_BIN points at an unpinned build ({reason})");
        }
        pin => panic!("{}", pin.warning().unwrap()),
    }
}

struct Session {
    wallet: TempWallet,
    used: BTreeSet<&'static str>,
}

impl Session {
    /// Runs one tool call the way `EdwTool::call` does: map, then run.
    async fn call(&mut self, tool: &'static str, args: Value) -> EdwResult {
        self.used.insert(tool);
        let argv = edw::build_argv(tool, &args).unwrap_or_else(|e| panic!("{tool} {args}: {e}"));
        edw::run_tool(&self.wallet.config, tool, &args, &argv).await
    }

    /// Runs a call that must succeed, and returns the JSON documents edw printed, in order.
    async fn ok(&mut self, tool: &'static str, args: Value) -> Vec<Value> {
        let result = self.call(tool, args).await;
        assert!(result.ok(), "{} failed: {result:?}", result.command);
        assert!(
            !result.output.contains(PHRASE_PLACEHOLDER),
            "edw printed a recovery phrase off a terminal: {result:?}"
        );
        result
            .output
            .lines()
            .filter_map(|line| serde_json::from_str(line).ok())
            .collect()
    }

    async fn fails(&mut self, tool: &'static str, args: Value, expect: &str) {
        let result = self.call(tool, args).await;
        assert!(!result.ok(), "{} should fail: {result:?}", result.command);
        assert!(result.output.contains(expect), "{result:?}");
    }
}

#[tokio::test]
async fn every_tool_maps_onto_the_pinned_edw() {
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return;
    };
    let mut s = Session {
        wallet: TempWallet::new(binary, "contract"),
        used: BTreeSet::new(),
    };

    // A locked wallet refuses reads and says how to fix it (the preamble tells the model so).
    s.fails("list_profiles", json!({}), "locked").await;
    assert_eq!(s.ok("wallet_status", json!({})).await[0]["locked"], true);

    // The first unlock of a network creates its wallet: mnemonic 0 and profile 0.
    let unlocked = s.ok("unlock", json!({"network": "local"})).await;
    assert_eq!(unlocked[0]["network"], "local");
    assert_eq!(profile(&unlocked[1]["profile"]), (0, 0, None));
    let status = s.ok("wallet_status", json!({})).await;
    assert_eq!(status[0]["session"]["network"], "local");
    let listed = s.ok("list_profiles", json!({})).await;
    assert_eq!(profiles(&listed[0]), [(0, 0, None)]);
    let network = s.ok("list_networks", json!({})).await;
    assert_eq!(network[0]["network_id"], 31337);

    // add_profile uses the next unused index on the existing mnemonic.
    let bob = s.ok("add_profile", json!({"name": "bob"})).await;
    assert_eq!(profile(&bob[0]["profile"]), (0, 1, Some("bob")));
    let renamed = s
        .ok(
            "rename_profile",
            json!({"profile": "0/1", "new_name": "robert"}),
        )
        .await;
    assert_eq!(profile(&renamed[0]["profile"]), (0, 1, Some("robert")));
    // An empty new name clears it.
    let cleared = s
        .ok(
            "rename_profile",
            json!({"profile": "robert", "new_name": ""}),
        )
        .await;
    assert_eq!(profile(&cleared[0]["profile"]), (0, 1, None));

    // new_mnemonic is a separate seed.
    let carol = s.ok("new_mnemonic", json!({"name": "carol"})).await;
    assert_eq!(profile(&carol[0]["profile"]), (1, 0, Some("carol")));
    // With two mnemonics, add_profile needs `mnemonic`, as its schema tells the model.
    s.fails("add_profile", json!({"name": "dave"}), "mnemonic")
        .await;
    let dave = s
        .ok("add_profile", json!({"name": "dave", "mnemonic": 1}))
        .await;
    assert_eq!(profile(&dave[0]["profile"]), (1, 1, Some("dave")));
    let listed = s.ok("list_profiles", json!({})).await;
    assert_eq!(
        profiles(&listed[0]),
        [
            (0, 0, None),
            (0, 1, None),
            (1, 0, Some("carol")),
            (1, 1, Some("dave"))
        ]
    );

    s.ok("lock", json!({})).await;
    s.fails("list_profiles", json!({}), "locked").await;

    // Interim tools have their own tests (tests/interim.rs).
    let all: BTreeSet<&str> = TOOLS
        .iter()
        .filter(|tool| tool.backend == Backend::Cli)
        .map(|tool| tool.name)
        .collect();
    assert_eq!(s.used, all, "every tool needs a contract check here");
}

/// A profile in edw's JSON as `(mnemonic, profile, name)`.
fn profile(document: &Value) -> (u64, u64, Option<&str>) {
    (
        document["mnemonic_index"].as_u64().expect("mnemonic_index"),
        document["profile_index"].as_u64().expect("profile_index"),
        document["name"].as_str(),
    )
}

fn profiles(list: &Value) -> Vec<(u64, u64, Option<&str>)> {
    list["profiles"]
        .as_array()
        .expect("profiles")
        .iter()
        .map(profile)
        .collect()
}

const PROFILE: &str = "0/0";
const TO: Address = address!("0x70997970C51812dc3A010C7d01b50e0d17dc79C8");

fn owned(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|s| (*s).to_owned()).collect()
}

async fn run(config: &EdwConfig, argv: &[String]) -> EdwResult {
    edw::run_with_timeout(config, argv, tornado::TIMEOUT).await
}

/// edw's exit code and error class: `(2, "usage")` is a flag or value its CLI refused itself,
/// `(1, "other")` one its wallet core refused after reading every flag.
fn refusal(result: &EdwResult) -> (i32, String) {
    let class = result
        .document()
        .and_then(|d| d["class"].as_str().map(str::to_owned))
        .unwrap_or_default();
    (result.exit_code, class)
}

fn usage() -> (i32, String) {
    (2, "usage".into())
}

fn other() -> (i32, String) {
    (1, "other".into())
}

/// Every file under `dir`, with its bytes.
fn snapshot(dir: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    let mut files = BTreeMap::new();
    let mut pending = vec![dir.to_owned()];
    while let Some(dir) = pending.pop() {
        for entry in std::fs::read_dir(&dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                pending.push(path);
            } else {
                files.insert(path.clone(), std::fs::read(&path).unwrap());
            }
        }
    }
    files
}

#[tokio::test]
async fn tornado_on_the_local_network() {
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return;
    };
    let Ok(chain) = Anvil::new().try_spawn() else {
        eprintln!("skipping: cannot start anvil");
        return;
    };
    let wallet = TempWallet::new(binary, "contract-tornado-local");
    wallet.unlock("local").await;
    let config = &wallet.config;

    // edw gives a new local wallet no RPC, and every Tornado command needs one.
    let peek = run(config, &Command::PeekFreshAddress.argv(PROFILE)).await;
    assert_eq!(refusal(&peek), other(), "{peek:?}");

    let rpc = chain.endpoint();
    wallet
        .edw(&[
            "network",
            "rpc-config",
            "add",
            "anvil",
            "--url",
            &rpc,
            "--use",
        ])
        .await;
    let network = edw::unlocked_network(config).await.unwrap();
    assert_eq!(network, NetworkPreset::Local);

    // Peeking writes nothing; storing the address does, so the comparison can see a write.
    let before = snapshot(&config.data_dir);
    let peek = run(config, &Command::PeekFreshAddress.argv(PROFILE)).await;
    let document = peek.document().unwrap();
    assert!(peek.ok() && document["stored"] == false, "{peek:?}");
    assert!(FreshAddress::from_document(&document).is_some(), "{peek:?}");
    assert_eq!(
        snapshot(&config.data_dir),
        before,
        "--peek wrote to the data dir"
    );
    wallet
        .edw(&["next-fresh-address", "--profile", PROFILE])
        .await;
    assert_ne!(snapshot(&config.data_dir), before);

    // No pools on the local chain: the harness refuses every token, and so does edw, as usage.
    for token in Token::ALL {
        let args = json!({"token": token.symbol(), "amount": "100"});
        let refused = Command::from_call("prepare_shield", &args, network).unwrap_err();
        assert!(refused.contains("no Tornado pools"), "{refused}");
        let argv = owned(&[
            "shield",
            "--prepare",
            "--token",
            token.symbol(),
            "--amount-formatted",
            "100",
            "--profile",
            PROFILE,
        ]);
        let prepared = run(config, &argv).await;
        assert_eq!(refusal(&prepared), usage(), "{token}: {prepared:?}");
    }
}

#[tokio::test]
async fn tornado_tools_map_onto_the_pinned_edw() {
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return;
    };
    let Some((wallet, _chain)) = fake_sepolia(binary, "contract-tornado").await else {
        return;
    };
    let config = &wallet.config;
    let network = edw::unlocked_network(config).await.unwrap();
    assert_eq!(network, NetworkPreset::Sepolia);
    let mut used = BTreeSet::new();
    let mut command = |tool: &'static str, args: Value| {
        used.insert(tool);
        Command::from_call(tool, &args, network)
    };
    let prepare = |token: &str, amount: &str| {
        owned(&[
            "shield",
            "--prepare",
            "--token",
            token,
            "--amount-formatted",
            amount,
            "--profile",
            PROFILE,
        ])
    };

    // The harness's tokens are edw's, and on Sepolia it refuses exactly the ones edw does.
    for token in Token::ALL {
        let size = if token == Token::Eth { "0.1" } else { "100" };
        let harness = command(
            "prepare_shield",
            json!({"token": token.symbol(), "amount": size}),
        );
        let edw = run(config, &prepare(token.symbol(), size)).await;
        assert_eq!(harness.is_ok(), edw.ok(), "{token}: {harness:?} {edw:?}");
        if !edw.ok() {
            assert_eq!(refusal(&edw), usage(), "{token}: {edw:?}");
        }
    }
    let unsupported = run(config, &prepare("DOGE", "1")).await;
    assert_eq!(refusal(&unsupported), usage(), "{unsupported:?}");
    assert!(command("prepare_shield", json!({"token": "DOGE", "amount": "1"})).is_err());

    // An amount that is not a sum of pool sizes: refused by both.
    let odd = run(config, &prepare("ETH", "1.15")).await;
    assert_eq!(refusal(&odd), other(), "{odd:?}");
    assert!(command("prepare_shield", json!({"amount": "1.15"})).is_err());

    // A preparation reserves the notes the harness predicted, and broadcasts nothing.
    let prepared = command("prepare_shield", json!({"amount": "1.1"})).unwrap();
    let Command::Prepare(amount) = &prepared else {
        panic!("a preparation");
    };
    let result = run(config, &prepared.argv(PROFILE)).await;
    let document = result.document().unwrap();
    assert!(
        result.ok() && document["kind"] == "edw/shield-prepared" && document["broadcast"] == false,
        "{result:?}"
    );
    let notes: Vec<&str> = document["notes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|note| note["amount"].as_str().unwrap())
        .collect();
    assert_eq!(notes, amount.notes);
    let store = Store::in_data_dir(&config.data_dir);
    let (record, _) = store
        .reuse_or(amount, PROFILE, || async { Ok::<_, String>(document) })
        .await
        .expect("the store reads edw's document");

    // A shield's flags are all accepted: edw gets as far as the unfunded payer's balance.
    let shield = command("shield", json!({"amount": "0.1"})).unwrap();
    let shield = run(config, &shield.argv(PROFILE)).await;
    assert_eq!(refusal(&shield), other(), "{shield:?}");

    let peek = command("next_fresh_address", json!({})).unwrap();
    let peek = run(config, &peek.argv(PROFILE)).await;
    let fresh = FreshAddress::from_document(&peek.document().unwrap()).unwrap();

    // So are an unshield's, with `--to` or the harness's tail calls, held to the peeked address:
    // edw reads them all and stops at having no notes to spend.
    for destination in [Destination::To(TO), Destination::Calls(record.tail_calls())] {
        let Ok(Command::Unshield(mut unshield)) = command("unshield", json!({"amount": "0.1"}))
        else {
            panic!("an unshield");
        };
        unshield.destination = destination;
        unshield.expected_fresh_address = Some(fresh.address);
        let result = run(config, &Command::Unshield(unshield).argv(PROFILE)).await;
        assert_eq!(refusal(&result), other(), "{result:?}");
    }

    let balance = command("balance", json!({"private": true})).unwrap();
    let balance = run(config, &balance.argv(PROFILE)).await;
    let document = balance.document().unwrap();
    assert!(
        balance.ok() && document["kind"] == "edw/balance" && document["tornado_notes"].is_array(),
        "{balance:?}"
    );

    let all: BTreeSet<&str> = TOOLS
        .iter()
        .filter(|tool| tool.backend == Backend::Tornado)
        .map(|tool| tool.name)
        .chain(["balance"])
        .collect();
    assert_eq!(used, all, "every Tornado tool needs a contract check here");
}
