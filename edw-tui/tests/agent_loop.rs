//! Rig's tool loop + the confirmation hook + the real `edw` binary, driven by the scripted model.
//!
//! Skips when `edw` is not installed (`cargo install --git https://github.com/ethereum/desktop-wallet edw`).

mod common;

use common::{Harness, TempWallet, Turn, edw_binary, ollama_url};
use edw_tui::agent;

/// Real models through Ollama: `cargo test --test agent_loop -- --ignored --nocapture`.
/// `EDW_TUI_MODEL` picks the model, `EDW_TUI_NUDGE=0` turns the empty-reply nudge off, and
/// `EDW_TUI_SWITCH_TO` switches to a second model mid-conversation.
#[tokio::test]
#[ignore = "needs a running Ollama"]
async fn real_ollama_calls_tools() {
    let Some(binary) = edw_binary() else { return };
    let model = std::env::var("EDW_TUI_MODEL").unwrap_or("qwen3:8b".into());
    let nudge = std::env::var("EDW_TUI_NUDGE").map_or(true, |v| v != "0");
    eprintln!("model={model} nudge={nudge}");
    let mut h = Harness::start_with(
        TempWallet::new(binary, "ollama"),
        agent::ollama_model(&ollama_url(), &model, nudge).unwrap(),
        None,
    );
    let log = |prompt: &str, turn: Turn| {
        let commands: Vec<&str> = turn
            .outputs
            .iter()
            .map(|o| o.split(" => ").next().unwrap_or(""))
            .collect();
        eprintln!(
            "> {prompt}\n  confirms={:?}\n  ran={commands:?}\n  reply={}",
            turn.confirms, turn.reply
        );
    };
    for prompt in [
        "unlock sepolia",
        "show my profiles",
        "shield 1 ETH",
        "lock the wallet, then create a new wallet on the local chain, add two profiles named alice and bob to it, and list the profiles",
    ] {
        log(prompt, h.turn(prompt, true).await);
    }
    if let Ok(second) = std::env::var("EDW_TUI_SWITCH_TO") {
        h.switch(&second).await.unwrap();
        eprintln!("-- switched to {second}");
        let prompt = "which profiles did we just create? rename bob to robert";
        log(prompt, h.turn(prompt, true).await);
    }
}

#[tokio::test]
async fn switching_models_keeps_the_conversation() {
    let Some(binary) = edw_binary() else { return };
    let mut h = Harness::start(binary, "switch");
    h.turn("unlock sepolia", true).await;
    h.switch("scripted").await.unwrap();
    let turn = h.turn("show profiles", true).await;
    assert!(turn.outputs[0].contains(DEFAULT_PROFILE), "{turn:?}");
    // An unknown Ollama model is refused (or Ollama is unreachable); either way the model stays.
    assert!(h.switch("definitely-not-a-model:1b").await.is_err());
    let turn = h.turn("show profiles", true).await;
    assert!(turn.outputs[0].contains(DEFAULT_PROFILE), "{turn:?}");
}

/// Profile 0/0, unnamed, as edw's JSON lists it.
const DEFAULT_PROFILE: &str = r#"{"mnemonic_index":0,"profile_index":0,"name":null}"#;

#[tokio::test]
async fn confirmed_commands_run_and_declined_ones_do_not() {
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return;
    };
    let mut h = Harness::start(binary, "loop");

    // Locked wallet: a read-only call runs without confirmation and reports edw's error.
    let turn = h.turn("list my profiles", true).await;
    assert!(turn.confirms.is_empty());
    assert!(turn.outputs[0].contains("wallet is locked"), "{turn:?}");

    // Declining a state change: nothing runs. `local`, because on a network with an RPC edw
    // scans the chain when a profile is added.
    let turn = h.turn("unlock local", false).await;
    assert_eq!(turn.confirms, ["edw unlock --network local"]);
    assert!(turn.outputs.is_empty(), "{turn:?}");

    let turn = h.turn("unlock local", true).await;
    assert!(
        turn.outputs[0].contains("=> 0:")
            && turn.outputs[0].contains(r#""network":"local""#)
            && turn.outputs[0].contains(DEFAULT_PROFILE),
        "{turn:?}"
    );
    assert!(
        !turn.outputs[0].contains(edw_tui::edw::PHRASE_PLACEHOLDER),
        "{turn:?}"
    );
    assert!(turn.reply.starts_with("Done"));

    let bob = r#"{"mnemonic_index":0,"profile_index":1,"name":"bob"}"#;
    let turn = h.turn("add a profile named bob", true).await;
    assert_eq!(
        turn.confirms,
        ["edw profile new --phrase-of 0/0 --name bob"]
    );
    assert!(turn.outputs[0].contains(bob), "{turn:?}");

    let turn = h.turn("show profiles", true).await;
    assert!(
        turn.outputs[0].contains(DEFAULT_PROFILE) && turn.outputs[0].contains(bob),
        "{turn:?}"
    );

    // The local chain has no Tornado pools: the call is refused before any review or edw run.
    let turn = h.turn("shield 1 ETH", true).await;
    assert!(turn.confirms.is_empty() && turn.flow.is_empty(), "{turn:?}");
    assert!(
        turn.outputs[0].contains("Rejected before running edw")
            && turn.outputs[0].contains("no Tornado pools"),
        "{turn:?}"
    );
}
