//! Rig's tool loop + the confirmation hook + the real `edw` binary, driven by the scripted model.
//!
//! Skips when `edw` is not installed (`cargo install --git https://github.com/ethereum/desktop-wallet edw`).

mod common;

use std::{path::PathBuf, time::Duration};

use common::{TempWallet, edw_binary};
use edw_tui::{
    agent::{self, AgentEvent, ModelSource, Request},
    scripted::ScriptedModel,
};
use rig_agent::ModelHandle;
use tokio::sync::mpsc;

fn ollama_url() -> String {
    std::env::var("OLLAMA_HOST").unwrap_or("http://127.0.0.1:11434".into())
}

struct Harness {
    prompts: mpsc::UnboundedSender<Request>,
    events: mpsc::UnboundedReceiver<AgentEvent>,
    _wallet: TempWallet,
}

impl Harness {
    async fn switch(&mut self, model: &str) -> Result<(), String> {
        self.prompts.send(Request::SetModel(model.into())).unwrap();
        match self.next().await {
            AgentEvent::ModelChanged(name) => {
                assert_eq!(name, model);
                Ok(())
            }
            AgentEvent::Error(error) => Err(error),
            other => panic!("unexpected {other:?}"),
        }
    }

    fn start(binary: PathBuf, name: &str) -> Self {
        Self::start_with(
            binary,
            name,
            ModelHandle::named("scripted", ScriptedModel::default()),
        )
    }

    fn start_with(binary: PathBuf, name: &str, model: ModelHandle) -> Self {
        let wallet = TempWallet::new(binary, name);
        let (event_tx, events) = mpsc::unbounded_channel();
        let (prompts, prompt_rx) = mpsc::unbounded_channel();
        let agent = agent::build_agent(model, wallet.config.clone(), event_tx.clone());
        let source = ModelSource {
            ollama_url: ollama_url(),
            nudge: true,
        };
        tokio::spawn(agent::run(agent, prompt_rx, event_tx, source));
        Self {
            prompts,
            events,
            _wallet: wallet,
        }
    }

    async fn next(&mut self) -> AgentEvent {
        tokio::time::timeout(Duration::from_secs(60), self.events.recv())
            .await
            .expect("timed out")
            .expect("agent gone")
    }

    /// Sends a prompt and collects events until the reply, answering any confirmation with `approve`.
    async fn turn(&mut self, prompt: &str, approve: bool) -> (Vec<String>, Vec<String>, String) {
        self.prompts.send(Request::Prompt(prompt.into())).unwrap();
        let (mut confirms, mut outputs) = (Vec::new(), Vec::new());
        loop {
            match self.next().await {
                AgentEvent::Confirm { command, reply } => {
                    confirms.push(command);
                    reply.send(approve).unwrap();
                }
                AgentEvent::ToolStarted { .. } => {}
                AgentEvent::ToolFinished(result) => outputs.push(format!(
                    "{} => {}: {}",
                    result.command, result.exit_code, result.output
                )),
                AgentEvent::Reply(reply) => return (confirms, outputs, reply),
                other @ (AgentEvent::Models(_) | AgentEvent::ModelChanged(_)) => {
                    panic!("unexpected {other:?}")
                }
                AgentEvent::Error(error) => {
                    return (confirms, outputs, format!("AGENT ERROR: {error}"));
                }
            }
        }
    }
}

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
        binary,
        "ollama",
        agent::ollama_model(&ollama_url(), &model, nudge).unwrap(),
    );
    let log = |prompt: &str, (confirms, outputs, reply): (Vec<String>, Vec<String>, String)| {
        let commands: Vec<&str> = outputs
            .iter()
            .map(|o| o.split(" => ").next().unwrap_or(""))
            .collect();
        eprintln!("> {prompt}\n  confirms={confirms:?}\n  ran={commands:?}\n  reply={reply}");
    };
    for prompt in [
        "unlock sepolia",
        "show my profiles",
        "send 1 ETH to vitalik.eth",
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
    let (_, outputs, _) = h.turn("show profiles", true).await;
    assert!(outputs[0].contains("default"), "{outputs:?}");
    // An unknown Ollama model is refused (or Ollama is unreachable); either way the model stays.
    assert!(h.switch("definitely-not-a-model:1b").await.is_err());
    let (_, outputs, _) = h.turn("show profiles", true).await;
    assert!(outputs[0].contains("default"), "{outputs:?}");
}

#[tokio::test]
async fn confirmed_commands_run_and_declined_ones_do_not() {
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return;
    };
    let mut h = Harness::start(binary, "loop");

    // Locked wallet: a read-only call runs without confirmation and reports edw's error.
    let (confirms, outputs, _) = h.turn("list my profiles", true).await;
    assert!(confirms.is_empty());
    assert!(outputs[0].contains("wallet is locked"), "{outputs:?}");

    // Declining a state change: nothing runs.
    let (confirms, outputs, _) = h.turn("unlock sepolia", false).await;
    assert_eq!(confirms, ["edw unlock --network sepolia"]);
    assert!(outputs.is_empty(), "{outputs:?}");

    // Approving it: the store is created, and the recovery phrase never leaves the harness.
    let (_, outputs, reply) = h.turn("unlock sepolia", true).await;
    assert!(
        outputs[0].contains("=> 0:") && outputs[0].contains("Unlocked sepolia"),
        "{outputs:?}"
    );
    assert!(
        outputs[0].contains(edw_tui::edw::PHRASE_PLACEHOLDER),
        "{outputs:?}"
    );
    assert!(reply.starts_with("Done"));

    let (confirms, outputs, _) = h.turn("add a profile named bob", true).await;
    assert_eq!(confirms, ["edw profile add --next --name bob"]);
    assert!(
        outputs[0].contains("Created profile 0/1 (bob)"),
        "{outputs:?}"
    );

    let (_, outputs, _) = h.turn("show profiles", true).await;
    assert!(
        outputs[0].contains("default") && outputs[0].contains("bob"),
        "{outputs:?}"
    );

    // Out of scope: no tool call at all.
    let (confirms, outputs, reply) = h.turn("send 1 ETH to vitalik.eth", true).await;
    assert!(confirms.is_empty() && outputs.is_empty());
    assert!(reply.contains("cannot transfer"));
}
