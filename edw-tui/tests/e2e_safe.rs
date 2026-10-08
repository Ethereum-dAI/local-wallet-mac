//! The `safe-multisig` skill end to end through the real terminal, on an anvil fork of Ethereum
//! mainnet: approve the shipped skills on their cards, then ask about a real Safe (one that
//! pays out COW tokens): who controls it, what is waiting for signatures, what it recently paid out.
//! A second question reaches a Gnosis Chain Safe by name. Uses the scripted model, the pinned
//! edw, and Docker; sends nothing, and the test checks no block was mined.
//!
//! Needs the network (the fork, the Safe Transaction Service):
//! `cargo test --test e2e_safe -- --ignored`.
//! `EDW_TUI_E2E_RECORD=1` also records `target/e2e-screenshots/safe.mp4`.

mod common;

use alloy_provider::{Provider, ProviderBuilder};
use common::scenario::{Chain, Scenario};
use edw_tui::skills::sandbox;

/// A 4-of-11 mainnet Safe with a standing queue and many executed payouts.
const MAINNET_SAFE: &str = "0xA03be496e67Ec29bC62F01a428683D7F9c204930";
/// A 3-of-5 Safe on Gnosis Chain.
const GNOSIS_SAFE: &str = "0x9cFA3e01d3E093D5ADAcf08f9A391EFF42C40D86";

#[tokio::test(flavor = "multi_thread")]
#[ignore = "forks mainnet and calls the Safe service over the network; needs anvil, edw and Docker"]
async fn safe_questions_are_answered_from_the_chain_and_the_service() {
    if !sandbox::docker_available().await {
        eprintln!("skipping: Docker is not running");
        return;
    }
    let Some(mut s) = Scenario::start_with_skills("safe", Chain::MainnetFork).await else {
        return;
    };
    s.confirmed("unlock mainnet", "Unlocked");
    let provider = ProviderBuilder::new().connect_http(s.rpc.parse().unwrap());
    let before = provider.get_block_number().await.unwrap();

    // Who controls it: read from the Safe service and checked against the chain's own getOwners.
    s.ask(
        &format!("who controls safe {MAINNET_SAFE}?"),
        "match the chain",
    );
    s.screenshot("safe_info");
    let screen = s.tui.screen();
    assert!(screen.contains("4 of 11 owners must sign"), "{screen}");

    // What is waiting: plain English, signatures so far, and warnings.
    s.ask(
        &format!("what is waiting for signatures on safe {MAINNET_SAFE}?"),
        "waiting",
    );
    s.screenshot("safe_queue");

    // What it did: executed batches, summarised as payouts.
    s.ask(
        &format!("what did safe {MAINNET_SAFE} do recently?"),
        "Recently executed",
    );
    s.screenshot("safe_activity");
    assert!(s.tui.screen().contains("Pays"), "{}", s.tui.screen());

    // Another chain by name: the wallet is on Ethereum, so there is no on-chain cross-check.
    s.ask(
        &format!("who controls safe {GNOSIS_SAFE} on gnosis?"),
        "not checked: the wallet is not on Gnosis Chain",
    );
    s.screenshot("safe_gnosis");

    // Every question was a read: the fork did not mine a block.
    assert_eq!(provider.get_block_number().await.unwrap(), before);
    s.finish("safe");
}
