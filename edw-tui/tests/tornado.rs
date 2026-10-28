//! The Tornado tools through the agent, the review and the real `edw`, on an anvil that answers
//! as Sepolia (`common::fake_sepolia`). It has no pool contracts, so a shield is a plain transfer
//! to the pool's address and an unshield finds no notes. What is checked is what the harness
//! promises: nothing is sent without a yes, a prepared shield is saved and reused, and the model
//! never sees calldata. Skips when edw or anvil is missing.
//!
//! `live_sepolia_shield_then_unshield` is the real thing, ignored by default.

mod common;

use std::os::unix::fs::PermissionsExt;

use alloy_node_bindings::{Anvil, AnvilInstance};
use alloy_primitives::{Address, U256, address};
use alloy_provider::{Provider, ProviderBuilder};
use common::{Harness, TempWallet, Turn, edw_binary, fake_sepolia};
use edw_core::instance::{DataDir, Instance};
use edw_tui::{
    flow::{FlowEvent, Stage, StepState},
    scripted::ScriptedModel,
};
use rig_agent::ModelHandle;
use serde_json::Value;

const ETHER: u128 = 1_000_000_000_000_000_000;
const SEPOLIA_ETH_POOL_01: Address = address!("0x8C4A04d872a6C1BE37964A21ba3a138525dFF50b");
/// Tornado's `deposit(bytes32)`: every deposit call starts with it.
const DEPOSIT: &str = "0xb214faa5";
const TO: &str = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";

fn scripted(wallet: TempWallet) -> Harness {
    Harness::start_with(
        wallet,
        ModelHandle::named("scripted", ScriptedModel::default()),
        None,
    )
}

async fn start(name: &str) -> Option<(Harness, AnvilInstance)> {
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return None;
    };
    let (wallet, chain) = fake_sepolia(binary, name).await?;
    Some((scripted(wallet), chain))
}

/// The JSON a tool printed for `command`, from the log.
fn output_of(turn: &Turn, command: &str) -> Value {
    let line = turn
        .outputs
        .iter()
        .find(|o| o.starts_with(command))
        .unwrap_or_else(|| panic!("no `{command}` in {turn:?}"));
    let (_, json) = line.split_once(" => ").unwrap().1.split_once(": ").unwrap();
    serde_json::from_str(json).unwrap_or_else(|e| panic!("{e}: {line}"))
}

fn stage(turn: &Turn, stage: Stage, state: StepState) -> bool {
    turn.flow.iter().any(|event| {
        matches!(event, FlowEvent::Step { stage: s, state: t, .. } if *s == stage && *t == state)
    })
}

async fn fresh_address(wallet: &TempWallet) -> Address {
    let peek = wallet
        .edw(&["next-fresh-address", "--peek", "--profile", "0/0"])
        .await;
    peek.document().unwrap()["address"]
        .as_str()
        .unwrap()
        .parse()
        .unwrap()
}

/// edw's own count of the profile's pending private ETH: notes reserved or not yet mined.
async fn pending_private_eth(wallet: &TempWallet) -> String {
    let balance = wallet.edw(&["balance", "--detailed", "--", "0/0"]).await;
    let document = balance.document().unwrap();
    let eth = document["assets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|asset| asset["address"].is_null())
        .unwrap();
    eth["private"]["pending"]["formatted"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[tokio::test]
async fn a_prepared_shield_is_saved_and_a_retry_reuses_it() {
    let Some((mut h, _chain)) = start("tornado-prepare").await else {
        return;
    };
    const PREPARE: &str = "edw shield --prepare --token ETH --amount-formatted 1.1 --profile 0/0";

    let declined = h.turn("prepare a shield of 1.1 ETH", false).await;
    assert_eq!(declined.confirms, [PREPARE]);
    assert!(
        declined.previews[0].contains("1 ETH + 0.1 ETH"),
        "{declined:?}"
    );
    assert!(declined.outputs.is_empty(), "{declined:?}");
    assert_eq!(pending_private_eth(&h.wallet).await, "0");

    let first = h.turn("prepare a shield of 1.1 ETH", true).await;
    let summary = output_of(&first, PREPARE);
    assert_eq!(summary["reused"], false);
    assert_eq!(summary["notes"].as_array().unwrap().len(), 2);
    assert!(
        !first.outputs.iter().any(|o| o.contains(DEPOSIT)),
        "calldata in {first:?}"
    );
    let id = summary["id"].as_str().unwrap().to_owned();
    let record = h
        .wallet
        .config
        .data_dir
        .join(format!("edw-tui/prepared-shields/{id}.json"));
    let mode = std::fs::metadata(&record).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);

    let retry = h.turn("prepare a shield of 1.1 ETH", true).await;
    assert!(retry.confirms.is_empty(), "{retry:?}");
    let again = output_of(&retry, PREPARE);
    assert_eq!(
        (again["id"].as_str(), &again["reused"]),
        (Some(id.as_str()), &Value::Bool(true))
    );
    // edw reserved notes once: 1.1 ETH pending, not 2.2.
    assert_eq!(pending_private_eth(&h.wallet).await, "1.1");
}

#[tokio::test]
async fn a_shield_is_sent_only_after_the_user_says_yes() {
    let Some((mut h, chain)) = start("tornado-shield").await else {
        return;
    };
    const SHIELD: &str = "edw shield --token ETH --amount-formatted 0.1 --from 0 --profile 0/0";
    let payer = fresh_address(&h.wallet).await;
    let provider = ProviderBuilder::new().connect_http(chain.endpoint().parse().unwrap());
    let _: () = provider
        .raw_request("anvil_setBalance".into(), (payer, U256::from(ETHER)))
        .await
        .unwrap();
    let balance = |address| {
        let provider = provider.clone();
        async move { provider.get_balance(address).await.unwrap() }
    };

    let declined = h.turn("shield 0.1 ETH", false).await;
    assert_eq!(declined.confirms, [SHIELD]);
    assert!(
        declined.previews[0].contains("0.1 ETH on sepolia (chain 11155111)")
            && declined.previews[0].contains("profile 0/0"),
        "{declined:?}"
    );
    assert!(stage(&declined, Stage::Review, StepState::Declined));
    assert_eq!(balance(payer).await, U256::from(ETHER));
    assert_eq!(balance(SEPOLIA_ETH_POOL_01).await, U256::ZERO);

    let sent = h.turn("shield 0.1 ETH", true).await;
    assert_eq!(output_of(&sent, SHIELD)["kind"], "edw/shield");
    assert!(stage(&sent, Stage::Send, StepState::Done), "{sent:?}");
    assert_eq!(balance(SEPOLIA_ETH_POOL_01).await, U256::from(ETHER / 10));
    assert!(balance(payer).await < U256::from(ETHER - ETHER / 10));
}

#[tokio::test]
async fn an_unshield_is_reviewed_with_its_fresh_address_and_held_to_it() {
    let Some((mut h, _chain)) = start("tornado-unshield").await else {
        return;
    };
    let fresh = fresh_address(&h.wallet).await;
    let prompt = format!("unshield 0.1 ETH to {TO}");

    let declined = h.turn(&prompt, false).await;
    let command = format!(
        "edw unshield --token ETH --amount-formatted 0.1 --to {TO} --expected-fresh-address {fresh} --profile 0/0"
    );
    assert_eq!(declined.confirms, [command.as_str()]);
    assert!(
        declined.previews[0].contains(&format!("Fresh    {fresh}")),
        "{declined:?}"
    );
    assert!(!declined.outputs.iter().any(|o| o.starts_with(&command)));

    // No notes on this chain: edw stops after the review, before proving, and the send fails.
    let sent = h.turn(&prompt, true).await;
    assert_eq!(output_of(&sent, &command)["kind"], "edw/error");
    assert!(!stage(&sent, Stage::Send, StepState::Done), "{sent:?}");
}

#[tokio::test]
async fn calls_edw_would_refuse_never_reach_a_review() {
    let Some((mut h, _chain)) = start("tornado-refused").await else {
        return;
    };
    for prompt in [
        "shield 100 USDC",
        "shield 1.15 ETH",
        "unshield 0.1 ETH to 0x0000000000000000000000000000000000000000",
    ] {
        let turn = h.turn(prompt, true).await;
        assert!(turn.confirms.is_empty() && turn.flow.is_empty(), "{turn:?}");
        assert!(
            turn.outputs[0].contains("Rejected before running edw"),
            "{turn:?}"
        );
    }

    let fresh = h.turn("what is my fresh address", true).await;
    let peek = output_of(&fresh, "edw next-fresh-address --peek");
    assert!(
        fresh.confirms.is_empty() && peek["stored"] == false,
        "{fresh:?}"
    );
    let private = h.turn("show my private balance", true).await;
    let balance = output_of(&private, "edw balance --detailed");
    assert!(private.confirms.is_empty() && balance["tornado_notes"].is_array());
}

/// A mainnet wallet whose edw RPC is `rpc`, with the indexer off.
async fn mainnet_wallet(binary: std::path::PathBuf, name: &str, rpc: &str) -> TempWallet {
    let wallet = TempWallet::new(binary, name);
    for step in [
        &["unlock", "--network", "mainnet"][..],
        &[
            "network",
            "rpc-config",
            "add",
            "anvil",
            "--url",
            rpc,
            "--use",
        ],
        &["network", "indexer-config", "--disable"],
        &["profile", "new", "--new-phrase"],
    ] {
        wallet.edw(step).await;
    }
    wallet
}

#[tokio::test]
async fn mainnet_is_refused_unless_edw_sends_through_a_loopback_anvil_fork() {
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return;
    };
    let Ok(upstream) = Anvil::new().chain_id(1).try_spawn() else {
        eprintln!("skipping: cannot start anvil");
        return;
    };
    let fork = Anvil::new().fork(upstream.endpoint()).spawn();
    let cases = [
        (
            "plain-off",
            upstream.endpoint(),
            false,
            Some("EDW_TUI_MAINNET_FORK"),
        ),
        (
            "plain-on",
            upstream.endpoint(),
            true,
            Some("not an anvil fork"),
        ),
        (
            "fork-off",
            fork.endpoint(),
            false,
            Some("EDW_TUI_MAINNET_FORK"),
        ),
        ("fork-on", fork.endpoint(), true, None),
    ];
    for (name, rpc, flag, refusal) in cases {
        let wallet = mainnet_wallet(binary.clone(), &format!("tornado-mainnet-{name}"), &rpc).await;
        let mut interim = wallet.interim(None, false);
        interim.mainnet_fork = flag;
        let mut h = Harness::start_with(
            wallet,
            ModelHandle::named("scripted", ScriptedModel::default()),
            Some(interim),
        );
        let shield = h.turn("shield 0.1 ETH", false).await;
        let peek = h.turn("what is my fresh address", false).await;
        match refusal {
            Some(why) => {
                for turn in [shield, peek] {
                    assert!(turn.confirms.is_empty(), "{name}: {turn:?}");
                    assert!(
                        turn.outputs[0].contains("Rejected before running edw")
                            && turn.outputs[0].contains(why),
                        "{name}: {turn:?}"
                    );
                }
            }
            None => {
                assert_eq!(shield.confirms.len(), 1, "{name}: {shield:?}");
                assert!(
                    shield.previews[0].contains("on mainnet (chain 1)"),
                    "{shield:?}"
                );
                let peeked = output_of(&peek, "edw next-fresh-address --peek");
                assert_eq!(peeked["kind"], "edw/next-fresh-address", "{peek:?}");
            }
        }
    }
}

/// The real thing on Sepolia: shield 0.1 ETH, see it among the notes, unshield it to the fresh
/// address. Moves real Sepolia ETH and takes minutes. Needs:
/// - `EDW_TUI_LIVE_PHRASE`: a throwaway mnemonic whose profile 0, address index 0, holds at least
///   0.11 Sepolia ETH;
/// - optionally `EDW_TUI_LIVE_RPC`, a Sepolia RPC that supports state overrides (else edw's
///   public default), and the network, for edw's indexer and the public Pimlico bundler.
///
/// `cargo test --test tornado live -- --ignored --nocapture`
#[tokio::test]
#[ignore = "moves real Sepolia ETH; needs EDW_TUI_LIVE_PHRASE, edw and the network"]
async fn live_sepolia_shield_then_unshield() {
    let Ok(phrase) = std::env::var("EDW_TUI_LIVE_PHRASE") else {
        eprintln!("skipping: EDW_TUI_LIVE_PHRASE is not set");
        return;
    };
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return;
    };
    let wallet = TempWallet::new(binary, "live-tornado");
    Instance::open_or_create(
        &DataDir::new(&wallet.config.data_dir),
        "sepolia".parse().unwrap(),
        wallet.config.password.as_bytes(),
    )
    .await
    .unwrap()
    .import_profile(phrase.into(), 0, None)
    .await
    .unwrap();
    wallet.unlock("sepolia").await;
    if let Ok(rpc) = std::env::var("EDW_TUI_LIVE_RPC") {
        wallet
            .edw(&[
                "network",
                "rpc-config",
                "add",
                "live",
                "--url",
                &rpc,
                "--use",
            ])
            .await;
    }
    let mut h = scripted(wallet);

    let shield = h.turn("shield 0.1 ETH", true).await;
    eprintln!("{shield:#?}");
    assert!(stage(&shield, Stage::Send, StepState::Done), "{shield:?}");

    let private = h.turn("show my private balance", true).await;
    eprintln!("{private:#?}");
    let balance = output_of(&private, "edw balance --detailed");
    let notes = balance["tornado_notes"].as_array().unwrap();
    assert!(
        notes.iter().any(|note| note["pool"] == "eth-0.1-11155111"),
        "{balance}"
    );

    let unshield = h.turn("unshield 0.1 ETH", true).await;
    eprintln!("{unshield:#?}");
    assert!(
        stage(&unshield, Stage::Send, StepState::Done),
        "{unshield:?}"
    );
}
