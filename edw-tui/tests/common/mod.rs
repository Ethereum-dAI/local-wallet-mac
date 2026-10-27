//! Shared by the integration tests: find `edw` and `anvil`, give each test a throwaway
//! wallet, and drive the real agent loop.
#![allow(dead_code)] // each test binary uses a different part

pub mod pty;
pub mod recorder;
pub mod safe_fork;
pub mod scenario;

use std::{path::PathBuf, sync::Arc, time::Duration};

use alloy_node_bindings::{Anvil, AnvilInstance};
use edw_tui::{
    addresses::AddressBook,
    agent::{self, AgentEvent, ModelSource, Request},
    edw::{self, EdwConfig, EdwResult},
    flow::FlowEvent,
    interim::{InterimConfig, SendingProfile},
    scripted::ScriptedModel,
    skills::tools::SkillSet,
};
use rig_agent::ModelHandle;
use tokio::sync::mpsc;

/// `EDW_BIN`, or `edw` on PATH; `None` when it does not run.
pub fn edw_binary() -> Option<PathBuf> {
    let binary = PathBuf::from(std::env::var_os("EDW_BIN").unwrap_or_else(|| "edw".into()));
    std::process::Command::new(&binary)
        .arg("--help")
        .output()
        .ok()?
        .status
        .success()
        .then_some(binary)
}

pub fn ollama_url() -> String {
    std::env::var("OLLAMA_HOST").unwrap_or("http://127.0.0.1:11434".into())
}

/// The before and after values a review read shows for `name`, as numbers (∞ as infinity): the
/// row `debt           0.00 → 999.83 USD` gives (0.0, 999.83). Works on the review text and on
/// a screen showing it.
pub fn read_values(review: &str, name: &str) -> (f64, f64) {
    let key = format!("{name}  ");
    let rest = review
        .lines()
        .filter_map(|line| line.split_once(&key).map(|(_, rest)| rest))
        .find(|rest| rest.contains('→'))
        .unwrap_or_else(|| panic!("no `{name}` row in\n{review}"));
    let number = |text: &str| {
        let word = text.split_whitespace().next().unwrap_or_default();
        if word == "∞" {
            f64::INFINITY
        } else {
            word.parse()
                .unwrap_or_else(|_| panic!("`{word}` is not a number in {rest:?}"))
        }
    };
    let (before, after) = rest.split_once('→').unwrap();
    (number(before), number(after))
}

/// A data and runtime dir that is removed when the test ends.
pub struct TempWallet {
    pub config: EdwConfig,
    dir: PathBuf,
}

impl TempWallet {
    pub fn new(binary: PathBuf, name: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("edw-tui-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let config = EdwConfig {
            binary,
            data_dir: dir.join("data"),
            runtime_dir: dir.join("runtime"),
            password: "test-password".into(),
        };
        Self { config, dir }
    }

    /// Runs one edw command in this wallet, panicking if it fails.
    pub async fn edw(&self, args: &[&str]) -> EdwResult {
        let argv: Vec<String> = args.iter().map(|s| (*s).to_owned()).collect();
        let result = edw::run(&self.config, &argv).await;
        assert!(result.ok(), "{result:?}");
        result
    }

    /// Unlocks `network` as the `unlock` tool does, so a first unlock creates profile 0/0.
    pub async fn unlock(&self, network: &str) -> EdwResult {
        let args = serde_json::json!({ "network": network });
        let argv = edw::build_argv("unlock", &args).unwrap();
        let result = edw::run_tool(&self.config, "unlock", &args, &argv).await;
        assert!(result.ok(), "{result:?}");
        result
    }

    pub fn interim(&self, rpc_url: Option<String>, allow_sepolia: bool) -> InterimConfig {
        InterimConfig {
            edw: self.config.clone(),
            rpc_url,
            allow_sepolia,
            profile: SendingProfile::default(),
            addresses: AddressBook::default(),
            swap_slippage_bps: edw_tui::interim::swap::DEFAULT_SLIPPAGE_BPS,
            mainnet_fork: false,
        }
    }
}

/// A Sepolia wallet whose RPC is a fresh anvil answering with Sepolia's chain id, with edw's pool
/// indexer off, so Tornado commands run without the network. The pools have no code there: a
/// shield is a plain value transfer to the pool's address, and there are no notes to unshield.
/// `None` (with a message) when anvil cannot start.
pub async fn fake_sepolia(binary: PathBuf, name: &str) -> Option<(TempWallet, AnvilInstance)> {
    let chain = match Anvil::new().chain_id(11_155_111).try_spawn() {
        Ok(chain) => chain,
        Err(error) => {
            eprintln!("skipping: cannot start anvil ({error})");
            return None;
        }
    };
    let wallet = TempWallet::new(binary, name);
    let rpc = chain.endpoint();
    // The RPC is switched before the first profile exists, so nothing reaches the real Sepolia.
    for step in [
        &["unlock", "--network", "sepolia"][..],
        &[
            "network",
            "rpc-config",
            "add",
            "anvil",
            "--url",
            &rpc,
            "--use",
        ],
        &["network", "indexer-config", "--disable"],
        &["profile", "new", "--new-phrase"],
    ] {
        wallet.edw(step).await;
    }
    Some((wallet, chain))
}

impl Drop for TempWallet {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// One user turn: what was asked for confirmation (with any dry-run preview), what ran, and
/// the final reply.
#[derive(Debug, Default)]
pub struct Turn {
    pub confirms: Vec<String>,
    pub previews: Vec<String>,
    pub outputs: Vec<String>,
    /// Sending-profile switches the model made with `use_profile`.
    pub switched: Vec<String>,
    /// The action card's events, in order.
    pub flow: Vec<FlowEvent>,
    pub reply: String,
}

pub struct Harness {
    prompts: mpsc::UnboundedSender<Request>,
    events: mpsc::UnboundedReceiver<AgentEvent>,
    pub wallet: TempWallet,
}

impl Harness {
    pub fn start(binary: PathBuf, name: &str) -> Self {
        Self::start_with(
            TempWallet::new(binary, name),
            ModelHandle::named("scripted", ScriptedModel::default()),
            None,
        )
    }

    pub fn start_with(
        wallet: TempWallet,
        model: ModelHandle,
        interim: Option<InterimConfig>,
    ) -> Self {
        Self::start_with_skills(wallet, model, interim, Arc::new(SkillSet::empty()))
    }

    pub fn start_with_skills(
        wallet: TempWallet,
        model: ModelHandle,
        interim: Option<InterimConfig>,
        skills: Arc<SkillSet>,
    ) -> Self {
        let interim = interim.unwrap_or_else(|| wallet.interim(None, false));
        let (event_tx, events) = mpsc::unbounded_channel();
        let (prompts, prompt_rx) = mpsc::unbounded_channel();
        let agent = agent::build_agent(
            model,
            wallet.config.clone(),
            interim.clone(),
            event_tx.clone(),
            skills,
        );
        let source = ModelSource {
            ollama_url: ollama_url(),
            nudge: true,
        };
        tokio::spawn(agent::run(agent, prompt_rx, event_tx, source, interim));
        Self {
            prompts,
            events,
            wallet,
        }
    }

    pub async fn next(&mut self) -> AgentEvent {
        tokio::time::timeout(Duration::from_secs(120), self.events.recv())
            .await
            .expect("timed out")
            .expect("agent gone")
    }

    pub async fn switch(&mut self, model: &str) -> Result<(), String> {
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

    pub async fn set_profile(&mut self, selector: &str) -> Result<String, String> {
        self.prompts
            .send(Request::SetProfile(selector.into()))
            .unwrap();
        match self.next().await {
            AgentEvent::ProfileChanged { address, .. } => Ok(address),
            AgentEvent::Error(error) => Err(error),
            other => panic!("unexpected {other:?}"),
        }
    }

    /// Sends a prompt without waiting; read what follows with [`Self::next`].
    pub fn prompt(&self, prompt: &str) {
        self.prompts.send(Request::Prompt(prompt.into())).unwrap();
    }

    /// Sends a prompt and collects events until the reply, answering every confirmation
    /// with `approve`.
    pub async fn turn(&mut self, prompt: &str, approve: bool) -> Turn {
        self.prompts.send(Request::Prompt(prompt.into())).unwrap();
        let mut turn = Turn::default();
        loop {
            match self.next().await {
                AgentEvent::Confirm {
                    command,
                    preview,
                    reply,
                } => {
                    turn.confirms.push(command);
                    turn.previews.extend(preview);
                    reply.send(approve).unwrap();
                }
                AgentEvent::ToolStarted { .. } => {}
                AgentEvent::ToolFinished(result) => turn.outputs.push(format!(
                    "{} => {}: {}",
                    result.command, result.exit_code, result.output
                )),
                AgentEvent::ProfileChanged { selector, .. } => turn.switched.push(selector),
                AgentEvent::Flow(event) => turn.flow.push(event),
                AgentEvent::Reply(reply) => {
                    turn.reply = reply;
                    return turn;
                }
                AgentEvent::Error(error) => {
                    turn.reply = format!("AGENT ERROR: {error}");
                    return turn;
                }
                other => panic!("unexpected {other:?}"),
            }
        }
    }
}
