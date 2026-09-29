//! The LLM side, delegated to Rig: tools, a confirmation hook, and the chat loop.
//!
//! Rig owns the whole tool-call loop (send request, parse tool calls, dispatch, feed results
//! back, repeat until a final answer). This module only supplies:
//! - one Rig `Tool` per `edw` command, each a thin wrapper over [`crate::edw`];
//! - an `AgentHook` that holds state-changing calls until the user confirms them in the UI.

use std::{convert::Infallible, sync::Arc};

use rig_agent::{
    Agent, AgentBuilder, ModelHandle,
    agent::{AgentHook, HookContext, ToolCall, ToolCallAction},
    completion::{
        Chat, CompletionError, CompletionModel, CompletionRequest, CompletionResponse, Usage,
    },
    streaming::StreamingCompletionResponse,
    tool::{Tool, ToolContext},
};
use rig_core::{
    client::{CompletionClient, Nothing},
    message::{AssistantContent, EMPTY_RESPONSE_ERROR, Message},
    providers::ollama,
};
use serde_json::Value;
use tokio::sync::{mpsc, oneshot};

use crate::{
    edw::{self, EdwConfig, EdwResult, TOOLS},
    scripted::ScriptedModel,
};

pub const PREAMBLE: &str = "You are the chat interface of edw, a privacy-first Ethereum desktop wallet.
You act only through the provided tools; each one runs one real `edw` CLI command.

Rules:
- When the user asks for something a tool does, call the tool. Do not describe the command instead.
- One request may need several commands (for example: unlock a network, then add profiles, then list them). Call the tools one after another until the whole request is done, then answer once.
- A new wallet for a network is created by the first `unlock` of that network; `local` is a local dev chain at 127.0.0.1:8545.
- Only use arguments the user gave or that a previous tool result showed. If a required value is missing or ambiguous, ask one short question.
- edw cannot yet transfer, send, swap, shield, or show balances or history. If asked, say so plainly and do not call any tool or invent a result.
- Never ask for, repeat, or accept a recovery phrase or password. Importing a phrase must be done in a terminal with `edw profile import`.
- If a tool fails, explain the error in one sentence and suggest the next step (for example, \"the wallet is locked, unlock it first\").
- Keep answers short.";

/// Model calls per user message; each tool round-trip uses one.
pub const MAX_TURNS: usize = 10;

/// Everything the agent tells the UI.
#[derive(Debug)]
pub enum AgentEvent {
    ToolStarted {
        command: String,
    },
    ToolFinished(EdwResult),
    /// A state-changing command waits for the user's yes/no.
    Confirm {
        command: String,
        reply: oneshot::Sender<bool>,
    },
    Reply(String),
    Error(String),
    /// Models available to switch to, as listed by Ollama (plus the scripted stand-in).
    Models(Vec<String>),
    ModelChanged(String),
}

/// What the UI asks the agent task to do. Handled one at a time, in order.
#[derive(Debug, PartialEq, Eq)]
pub enum Request {
    Prompt(String),
    ListModels,
    SetModel(String),
}

pub type Events = mpsc::UnboundedSender<AgentEvent>;

struct Shared {
    config: EdwConfig,
    events: Events,
}

/// `TOOLS[I]` as a Rig tool. The const index gives each command its own type and `NAME`.
#[derive(Clone)]
struct EdwTool<const I: usize>(Arc<Shared>);

impl<const I: usize> Tool for EdwTool<I> {
    const NAME: &'static str = TOOLS[I].name;
    type Args = Value;
    type Output = String;
    type Error = Infallible;

    fn description(&self) -> String {
        TOOLS[I].description.to_owned()
    }

    fn parameters(&self) -> Value {
        (TOOLS[I].parameters)()
    }

    async fn call(&self, _context: &mut ToolContext, args: Value) -> Result<String, Infallible> {
        let argv = match edw::build_argv(Self::NAME, &args) {
            Ok(argv) => argv,
            Err(error) => return Ok(format!("Rejected before running edw: {error}")),
        };
        let _ = self.0.events.send(AgentEvent::ToolStarted {
            command: edw::display_command(&argv),
        });
        let result = edw::run(&self.0.config, &argv).await;
        let _ = self.0.events.send(AgentEvent::ToolFinished(result.clone()));
        Ok(result.to_model_json())
    }
}

/// Holds every state-changing tool call until the user answers in the UI.
#[derive(Clone)]
struct ConfirmHook {
    events: Events,
}

impl AgentHook for ConfirmHook {
    async fn on_tool_call(&self, _ctx: &HookContext, event: ToolCall<'_>) -> ToolCallAction {
        let Some(spec) = edw::spec(event.tool_name) else {
            return ToolCallAction::Run;
        };
        if !spec.mutating {
            return ToolCallAction::Run;
        }
        let args: Value = serde_json::from_str(event.args).unwrap_or(Value::Null);
        // An invalid call is rejected by the tool itself, with the reason, before anything runs.
        let Ok(argv) = edw::build_argv(spec.name, &args) else {
            return ToolCallAction::Run;
        };
        let command = edw::display_command(&argv);

        let (reply, answer) = oneshot::channel();
        if self
            .events
            .send(AgentEvent::Confirm {
                command: command.clone(),
                reply,
            })
            .is_err()
        {
            return ToolCallAction::skip(
                "No one is there to confirm the command; nothing was run.",
            );
        }
        match answer.await {
            Ok(true) => ToolCallAction::Run,
            _ => ToolCallAction::skip(format!("The user declined `{command}`; nothing was run.")),
        }
    }
}

/// Extra request fields sent with every model call. Ollama: skip gemma4's thinking phase, a
/// tool call does not need it.
pub fn additional_params() -> Value {
    serde_json::json!({"think": false})
}

pub fn build_agent(model: ModelHandle, config: EdwConfig, events: Events) -> Agent {
    let shared = Arc::new(Shared {
        config,
        events: events.clone(),
    });
    AgentBuilder::from_model_handle(model)
        .preamble(PREAMBLE)
        .default_max_turns(MAX_TURNS)
        .additional_params(additional_params())
        .add_hook(ConfirmHook { events })
        .tool(EdwTool::<0>(shared.clone()))
        .tool(EdwTool::<1>(shared.clone()))
        .tool(EdwTool::<2>(shared.clone()))
        .tool(EdwTool::<3>(shared.clone()))
        .tool(EdwTool::<4>(shared.clone()))
        .tool(EdwTool::<5>(shared.clone()))
        .tool(EdwTool::<6>(shared.clone()))
        .tool(EdwTool::<7>(shared))
        .build()
}

/// `nudge` wraps the model in [`AnswerAfterTools`]; models that answer after a tool result on
/// their own do not need it.
pub fn ollama_model(base_url: &str, model: &str, nudge: bool) -> anyhow::Result<ModelHandle> {
    let client = ollama::Client::builder()
        .api_key(Nothing)
        .base_url(base_url)
        .build()?;
    let model = client.completion_model(model);
    Ok(if nudge {
        ModelHandle::named("ollama", AnswerAfterTools(model))
    } else {
        ModelHandle::named("ollama", model)
    })
}

const SUMMARY_NUDGE: &str = "If my request still needs more commands, call the next tool now. Otherwise tell me the result in one short sentence.";
const NO_SUMMARY: &str = "(The model gave no summary; the command and its output are in the log.)";

/// gemma4 on Ollama usually ends the turn right after a tool result with an empty message,
/// which Rig reports as an error. Retry once with a one-line nudge, then fall back to a
/// pointer at the command log, so a successful command never surfaces as a failure.
#[derive(Clone)]
struct AnswerAfterTools<M>(M);

fn is_empty_response(error: &CompletionError) -> bool {
    matches!(error, CompletionError::ResponseError(message) if message == EMPTY_RESPONSE_ERROR)
}

impl<M: CompletionModel> CompletionModel for AnswerAfterTools<M> {
    async fn completion(
        &self,
        request: CompletionRequest,
    ) -> Result<CompletionResponse, CompletionError> {
        match self.0.completion(request.clone()).await {
            Err(error) if is_empty_response(&error) => {}
            other => return other,
        }
        let mut nudged = request;
        nudged.chat_history.push(Message::user(SUMMARY_NUDGE));
        match self.0.completion(nudged).await {
            Err(error) if is_empty_response(&error) => Ok(CompletionResponse::new(
                vec![AssistantContent::text(NO_SUMMARY)],
                Usage::new(),
                "ollama",
            )),
            other => other,
        }
    }

    async fn stream(
        &self,
        request: CompletionRequest,
    ) -> Result<StreamingCompletionResponse, CompletionError> {
        self.0.stream(request).await
    }
}

pub const SCRIPTED: &str = "scripted";

/// Where models come from: the local Ollama daemon, or the scripted stand-in.
#[derive(Clone, Debug)]
pub struct ModelSource {
    pub ollama_url: String,
    pub nudge: bool,
}

impl ModelSource {
    pub fn handle(&self, name: &str) -> anyhow::Result<ModelHandle> {
        if name == SCRIPTED {
            return Ok(ModelHandle::named(SCRIPTED, ScriptedModel::default()));
        }
        ollama_model(&self.ollama_url, name, self.nudge)
    }

    /// Installed Ollama models (`GET /api/tags`), then the scripted stand-in.
    pub async fn list(&self) -> anyhow::Result<Vec<String>> {
        #[derive(serde::Deserialize)]
        struct Tags {
            models: Vec<Tag>,
        }
        #[derive(serde::Deserialize)]
        struct Tag {
            name: String,
        }
        let url = format!("{}/api/tags", self.ollama_url.trim_end_matches('/'));
        let tags: Tags = reqwest::get(&url).await?.error_for_status()?.json().await?;
        let mut names: Vec<String> = tags.models.into_iter().map(|tag| tag.name).collect();
        names.sort();
        names.push(SCRIPTED.into());
        Ok(names)
    }
}

/// Handles requests in order: one chat turn per prompt, keeping the history between turns.
///
/// The history is Rig's provider-neutral `Message` list, so it survives a model switch.
pub async fn run(
    mut agent: Agent,
    mut requests: mpsc::UnboundedReceiver<Request>,
    events: Events,
    source: ModelSource,
) {
    let mut history: Vec<Message> = Vec::new();
    while let Some(request) = requests.recv().await {
        let event = match request {
            Request::Prompt(prompt) => match agent.chat(prompt, &mut history).await {
                Ok(answer) => AgentEvent::Reply(answer),
                Err(error) => AgentEvent::Error(error.to_string()),
            },
            Request::ListModels => match source.list().await {
                Ok(names) => AgentEvent::Models(names),
                Err(error) => AgentEvent::Error(format!("cannot list Ollama models: {error}")),
            },
            Request::SetModel(name) => match switch_model(&mut agent, &source, &name).await {
                Ok(()) => AgentEvent::ModelChanged(name),
                Err(error) => AgentEvent::Error(error.to_string()),
            },
        };
        if events.send(event).is_err() {
            return;
        }
    }
}

async fn switch_model(agent: &mut Agent, source: &ModelSource, name: &str) -> anyhow::Result<()> {
    if name != SCRIPTED
        && !source
            .list()
            .await?
            .iter()
            .any(|installed| installed == name)
    {
        anyhow::bail!(
            "`{name}` is not installed in Ollama; run `ollama pull {name}`, or /models to list what is"
        );
    }
    agent.set_model_handle(source.handle(name)?);
    Ok(())
}

// Every `TOOLS` entry must be registered above; this fails to compile if one is added without it.
const _: () = assert!(TOOLS.len() == 8);
