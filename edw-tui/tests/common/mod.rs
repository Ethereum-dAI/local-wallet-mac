//! Shared by the integration tests: find `edw` and `anvil`, give each test a throwaway
//! wallet, and drive the real agent loop.
#![allow(dead_code)] // each test binary uses a different part

pub mod pty;
pub mod recorder;
pub mod safe_fork;
pub mod scenario;

use std::{path::PathBuf, sync::Arc, time::Duration};

use edw_tui::{
    addresses::AddressBook,
    agent::{self, AgentEvent, ModelSource, Request},
    edw::{self, EdwConfig, EdwResult},
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
