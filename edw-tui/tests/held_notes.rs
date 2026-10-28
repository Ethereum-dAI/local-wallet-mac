//! The held-notes check against the pinned `edw`, on the anvil that answers as Sepolia
//! (`common::fake_sepolia`) with notes mined there by `common::mine_eth_notes`. For every amount,
//! the check passes exactly when edw's own `unshield` gets past picking notes and goes on to
//! prove; when it refuses, edw refused for the same rule. Skips without edw or anvil.

mod common;

use std::time::Duration;

use common::{edw_binary, fake_sepolia, mine_eth_notes};
use edw_core::{network::NetworkPreset, vault::tornadocash::parse_amount};
use edw_tui::{
    edw::{self, EdwConfig, EdwResult},
    tornado::{
        Command,
        held::{HeldEth, Refusal},
    },
};
use serde_json::Value;

const BALANCE: &str = include_str!("fixtures/balance_detailed_tornado_notes.json");

async fn run(config: &EdwConfig, argv: Vec<String>) -> EdwResult {
    edw::run_with_timeout(config, &argv, Duration::from_secs(120)).await
}

async fn held(config: &EdwConfig) -> (Value, HeldEth) {
    let balance = run(config, Command::PrivateBalance.argv("0/0")).await;
    let held = HeldEth::read(&balance, NetworkPreset::Sepolia).unwrap();
    (balance.document().unwrap(), held)
}

/// The rule edw refused `eth` for while picking notes, or `None` when it went on to prove.
async fn edw_refusal(config: &EdwConfig, eth: &str) -> Option<Refusal> {
    let argv = [
        "unshield",
        "--token",
        "ETH",
        "--amount-formatted",
        eth,
        "--profile",
        "0/0",
    ];
    let result = run(config, argv.map(str::to_owned).to_vec()).await;
    assert!(
        !result.ok(),
        "this chain has no EntryPoint, so nothing can be sent: {result:?}"
    );
    if result.output.contains("Proving sponsoring") {
        return None;
    }
    let message = result.document().unwrap()["message"].clone();
    match message.as_str().unwrap_or_default() {
        m if m.starts_with("held notes cannot make") => Some(Refusal::CannotMake),
        "the selected ETH notes have no paymaster" => Some(Refusal::NoSponsor),
        _ => panic!("{eth} ETH failed before picking notes: {result:?}"),
    }
}

async fn compare(config: &EdwConfig, held: &HeldEth, amounts: &[&str]) {
    for &eth in amounts {
        let ours = held
            .unshield(parse_amount(eth, 18).unwrap(), "0/0")
            .err()
            .map(|refused| refused.reason);
        // edw has no word for "not mined yet": it says the held notes cannot make the amount.
        let ours = ours.map(|reason| match reason {
            Refusal::NotMined => Refusal::CannotMake,
            other => other,
        });
        assert_eq!(ours, edw_refusal(config, eth).await, "{eth} ETH");
    }
}

#[tokio::test]
async fn the_check_refuses_exactly_what_edw_refuses() {
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return;
    };
    let Some((wallet, chain)) = fake_sepolia(binary, "held-notes").await else {
        return;
    };
    let config = &wallet.config;
    let (_, none) = held(config).await;
    assert!(none.notes.is_empty(), "{none:?}");
    compare(config, &none, &["1"]).await;

    mine_eth_notes(&wallet, &chain, "11").await;
    wallet
        .edw(&[
            "shield",
            "--prepare",
            "--token",
            "ETH",
            "--amount-formatted",
            "0.1",
            "--profile",
            "0/0",
        ])
        .await;
    let (document, notes) = held(config).await;
    let fixture: Value = serde_json::from_str(BALANCE).unwrap();
    assert_eq!(
        document["tornado_notes"], fixture["tornado_notes"],
        "the fixture is what the pinned edw lists for these notes"
    );
    compare(
        config,
        &notes,
        &["0.1", "1", "1.1", "2", "10", "11", "11.1"],
    )
    .await;

    // Ten 1 ETH notes could make 10 ETH with a paymaster, but edw takes the 10 ETH note first.
    mine_eth_notes(&wallet, &chain, "9").await;
    let (_, more) = held(config).await;
    compare(config, &more, &["9", "10", "20"]).await;
}
