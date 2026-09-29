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
use edw_tui::edw::{self, EdwResult, PHRASE_PLACEHOLDER, Pin, TOOLS};
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
        edw::run(&self.wallet.config, &argv).await
    }

    async fn ok(&mut self, tool: &'static str, args: Value, expect: &[&str]) -> EdwResult {
        let result = self.call(tool, args).await;
        assert!(result.ok(), "{} failed: {result:?}", result.command);
        for needle in expect {
            assert!(
                result.output.contains(needle),
                "{}: missing {needle:?} in {:?}",
                result.command,
                result.output
            );
        }
        result
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
    s.ok("wallet_status", json!({}), &["session=(locked)"])
        .await;

    // The first unlock of a network creates its wallet: mnemonic 0, profile 0, and a phrase
    // that must never reach the model.
    let unlocked = s
        .ok(
            "unlock",
            json!({"network": "local"}),
            &["Unlocked local", PHRASE_PLACEHOLDER],
        )
        .await;
    // edw printed exactly one phrase line, and redaction caught it.
    assert_eq!(unlocked.output.matches(PHRASE_PLACEHOLDER).count(), 1);
    s.ok("wallet_status", json!({}), &["session=local"]).await;
    s.ok("list_profiles", json!({}), &["Mnemonic 0", "default"])
        .await;
    s.ok("list_networks", json!({}), &["chain 31337"]).await;

    // add_profile uses the next unused index on the existing mnemonic.
    s.ok("add_profile", json!({"name": "bob"}), &["0/1", "bob"])
        .await;
    s.ok(
        "rename_profile",
        json!({"profile": "0/1", "new_name": "robert"}),
        &["0/1", "robert"],
    )
    .await;
    // An empty new name clears it.
    s.ok(
        "rename_profile",
        json!({"profile": "robert", "new_name": ""}),
        &["0/1"],
    )
    .await;

    // new_mnemonic is a separate seed; its phrase is withheld too.
    s.ok(
        "new_mnemonic",
        json!({"name": "carol"}),
        &["mnemonic 1", "1/0", "carol", PHRASE_PLACEHOLDER],
    )
    .await;
    // With two mnemonics, add_profile needs `mnemonic`, as its schema tells the model.
    s.fails("add_profile", json!({"name": "dave"}), "mnemonic")
        .await;
    s.ok(
        "add_profile",
        json!({"name": "dave", "mnemonic": 1}),
        &["1/1", "dave"],
    )
    .await;
    s.ok(
        "list_profiles",
        json!({}),
        &["Mnemonic 0", "Mnemonic 1", "carol", "dave"],
    )
    .await;

    s.ok("lock", json!({}), &[]).await;
    s.fails("list_profiles", json!({}), "locked").await;

    let all: BTreeSet<&str> = TOOLS.iter().map(|tool| tool.name).collect();
    assert_eq!(s.used, all, "every tool needs a contract check here");
}
