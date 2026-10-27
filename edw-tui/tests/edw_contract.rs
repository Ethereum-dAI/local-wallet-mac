//! The adapter held to the pinned edw: every tool, through `build_argv` and the real binary.
//!
//! These are the tests meant to break when edw changes. After bumping `EDW_PINNED_REV`, fix
//! `build_argv` (and, if a tool's meaning changed, the contract) until they pass. Assertions
//! check the facts the tool descriptions promise the model, not edw's exact wording.
//!
//! Skips when `edw` is not installed; see the README for the pinned install command.

mod common;

use std::collections::BTreeSet;

use common::{TempWallet, edw_binary};
use edw_tui::edw::{self, Backend, EdwResult, PHRASE_PLACEHOLDER, Pin, TOOLS};
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
