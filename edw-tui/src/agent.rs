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
    tool::{DynamicTool, Tool, ToolContext, ToolOutput},
};
use rig_core::{
    client::{CompletionClient, Nothing},
    message::{AssistantContent, EMPTY_RESPONSE_ERROR, Message},
    providers::ollama,
};
use serde_json::Value;
use tokio::sync::{mpsc, oneshot};

use crate::{
    addresses::AddressBook,
    app_contract::SAFETY_CLAUSE,
    edw::{self, Backend, EdwConfig, EdwResult, TOOLS},
    interim::{self, Interim, InterimConfig},
    scripted::ScriptedModel,
    skills::{
        LOAD_SKILL,
        catalog::Catalog,
        host::Log,
        plan,
        sandbox::{self, Output},
        tools::{self as skill_tools, SkillGate, SkillSet},
    },
};

const RULES: &str = "You are the chat interface of edw, a privacy-first Ethereum desktop wallet.
You act only through the provided tools; each one runs one real wallet command.

Rules:
- When the user asks for something a tool does, call the tool. Do not describe the command instead.
- One request may need several commands (for example: unlock a network, then add profiles, then list them). Call the tools one after another until the whole request is done, then answer once.
- A new wallet for a network is created by the first `unlock` of that network; `local` is a local dev chain at 127.0.0.1:8545.
- Only use arguments the user gave or that a previous tool result showed. If a required value is missing or ambiguous, ask one short question.
- Addresses appear as ADDR_1, ADDR_2 and so on. Pass them to tools exactly as written; they stand for full 0x addresses the harness holds. Never ask the user to retype one.
- Transfers and swaps are sent from the wallet's selected profile. When the user names a sender (\"from bob\"), call use_profile first, then the transfer; otherwise never ask which profile to use. The user reviews every transfer before it is sent, so call the tool rather than asking for confirmation. Only say funds were sent when the tool result says the transaction succeeded.
- edw cannot yet shield, unshield, or show history. If asked, say so plainly and do not call any tool or invent a result.
- Never ask for, repeat, or accept a recovery phrase or password. Importing a phrase must be done in a terminal with `edw profile import`.
- If a tool fails, explain the error in one sentence and suggest the next step (for example, \"the wallet is locked, unlock it first\").
- Keep answers short.";

/// The system turn without skills: edw-tui's rules, then the app's safety clause unchanged.
pub fn preamble() -> String {
    preamble_with(&Catalog::default())
}

/// The system turn: edw-tui's rules, the skills the model may load (if any), then the app's
/// safety clause unchanged, so it stays last and overrides everything above it.
pub fn preamble_with(catalog: &Catalog) -> String {
    let block = catalog.preamble_block();
    if block.is_empty() {
        format!("{RULES}\n\n{SAFETY_CLAUSE}")
    } else {
        format!("{RULES}\n\n{block}\n\n{SAFETY_CLAUSE}")
    }
}

/// The most of a read tool's result the model is given.
pub const MAX_SKILL_RESULT: usize = 8 * 1024;

/// Model calls per user message; each tool round-trip uses one.
pub const MAX_TURNS: usize = 10;

/// Everything the agent tells the UI.
#[derive(Debug)]
pub enum AgentEvent {
    ToolStarted {
        command: String,
    },
    ToolFinished(EdwResult),
    /// A state-changing command waits for the user's yes/no. A transfer carries the dry run's
    /// `preview`, written by the executor, never by the model.
    Confirm {
        command: String,
        preview: Option<String>,
        reply: oneshot::Sender<bool>,
    },
    Reply(String),
    Error(String),
    /// Models available to switch to, as listed by Ollama (plus the scripted stand-in).
    Models(Vec<String>),
    ModelChanged(String),
    /// The sending profile changed: its selector and address. `by_model` when the model's
    /// `use_profile` did it mid-turn (the turn goes on), not the user's `/profile`.
    ProfileChanged {
        selector: String,
        address: String,
        by_model: bool,
    },
}

/// What the UI asks the agent task to do. Handled one at a time, in order.
#[derive(Debug, PartialEq, Eq)]
pub enum Request {
    Prompt(String),
    ListModels,
    SetModel(String),
    /// Send from this profile (a name or `mnemonic/profile`), after checking it exists.
    SetProfile(String),
}

pub type Events = mpsc::UnboundedSender<AgentEvent>;

struct Shared {
    config: EdwConfig,
    interim: Interim,
    addresses: AddressBook,
    events: Events,
    skills: Arc<SkillSet>,
}

impl Shared {
    fn log(&self, event: AgentEvent) {
        let _ = self.events.send(event);
    }

    /// Asks the user and waits; `false` if they decline or the UI is gone.
    async fn confirm(&self, command: &str, preview: Option<String>) -> bool {
        let (reply, answer) = oneshot::channel();
        let asked = self.events.send(AgentEvent::Confirm {
            command: command.to_owned(),
            preview,
            reply,
        });
        asked.is_ok() && answer.await.unwrap_or(false)
    }

    async fn interim_call(&self, tool: &str, args: &Value) -> String {
        match tool {
            "use_profile" => {
                let selector = args
                    .get("profile")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .trim()
                    .to_owned();
                let command = format!("interim use-profile {selector}");
                let result = match self.interim.address(Some(&selector)).await {
                    Err(error) => EdwResult {
                        command,
                        exit_code: 1,
                        output: format!("{error}; the sender is still {}", self.interim.profile()),
                    },
                    Ok(address) => {
                        self.interim.set_profile(&selector);
                        self.log(AgentEvent::ProfileChanged {
                            selector: selector.clone(),
                            address: address.to_string(),
                            by_model: true,
                        });
                        EdwResult {
                            command,
                            exit_code: 0,
                            output: format!(
                                "Transfers, swaps and balances now use profile {selector} ({address}) until changed."
                            ),
                        }
                    }
                };
                self.log(AgentEvent::ToolFinished(result.clone()));
                result.to_model_json()
            }
            "profile_addresses" => {
                let result = self.interim.profile_addresses().await;
                self.log(AgentEvent::ToolFinished(result.clone()));
                result.to_model_json()
            }
            "balance" => {
                let command = interim::display_command(tool, args, &self.interim.profile());
                self.log(AgentEvent::ToolStarted { command });
                let result = self.interim.balance(args).await;
                self.log(AgentEvent::ToolFinished(result.clone()));
                result.to_model_json()
            }
            "transfer" | "swap" => {
                let prepared = if tool == "swap" {
                    self.interim.prepare_swap(args).await
                } else {
                    self.interim.prepare_transfer(args).await
                };
                let prepared = match prepared {
                    Ok(prepared) => prepared,
                    Err(result) => {
                        self.log(AgentEvent::ToolFinished(result.clone()));
                        return result.to_model_json();
                    }
                };
                self.log(AgentEvent::ToolFinished(EdwResult {
                    command: format!("{} (dry run)", prepared.command),
                    exit_code: 0,
                    output: prepared.preview.clone(),
                }));
                let command = prepared.command.clone();
                if !self.confirm(&command, Some(prepared.preview.clone())).await {
                    return format!("The user declined `{command}`; nothing was sent.");
                }
                self.log(AgentEvent::ToolStarted {
                    command: command.clone(),
                });
                let result = self.interim.broadcast(prepared).await;
                self.log(AgentEvent::ToolFinished(result.clone()));
                result.to_model_json()
            }
            other => {
                let result = EdwResult {
                    command: interim::display_command(other, args, &self.interim.profile()),
                    exit_code: 1,
                    output: format!("`{other}` is not an interim tool; nothing was done."),
                };
                self.log(AgentEvent::ToolFinished(result.clone()));
                result.to_model_json()
            }
        }
    }
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

    /// Arguments arrive with address aliases and are resolved first; the result goes back to
    /// the model with addresses aliased again. The UI always sees real addresses.
    async fn call(&self, _context: &mut ToolContext, args: Value) -> Result<String, Infallible> {
        if TOOLS[I].moves_value
            && let Some(to) = args.get("to").and_then(Value::as_str)
            && let Some(invented) = self.0.addresses.invented(to)
        {
            let result = EdwResult {
                command: interim::display_command(Self::NAME, &args, &self.0.interim.profile()),
                exit_code: 1,
                output: format!(
                    "Refused: {invented} came from neither the user nor a tool, so it may be made up. Ask the user for the address; nothing was sent."
                ),
            };
            self.0.log(AgentEvent::ToolFinished(result.clone()));
            return Ok(result.to_model_json());
        }
        let args = self.0.addresses.reveal_json(args);
        let output = self.0.run_tool::<I>(Self::NAME, &args).await;
        Ok(self.0.addresses.hide(&output))
    }
}

impl Shared {
    fn load_skill(&self, args: &Value) -> String {
        let name = args.get("name").and_then(Value::as_str).unwrap_or_default();
        let text = self.skills.load(name);
        let loaded = self.skills.is_loaded(name);
        self.log(AgentEvent::ToolFinished(EdwResult {
            command: format!("{LOAD_SKILL} {name}"),
            exit_code: if loaded { 0 } else { 1 },
            output: text.clone(),
        }));
        text
    }

    /// Runs one skill tool: a read tool's result goes back to the model; an action's plan is
    /// checked, simulated, reviewed and only then sent.
    async fn skill_call(&self, tool: &str, args: Value) -> String {
        let Some(skill) = self.skills.catalog.skill_of_tool(tool).cloned() else {
            return format!("`{tool}` is not a tool of any loaded skill; nothing was run.");
        };
        let fail = |command: &str, output: String| {
            let result = EdwResult {
                command: command.to_owned(),
                exit_code: 1,
                output,
            };
            self.log(AgentEvent::ToolFinished(result.clone()));
            result.to_model_json()
        };
        let short = format!("skill {}/{tool}", skill.name);
        if !self.skills.is_loaded(&skill.name) {
            return fail(
                &short,
                format!("call load_skill {} first; nothing was run.", skill.name),
            );
        }
        if let Some(invented) = first_invented(&self.addresses, &args) {
            // Worded like the transfer guard for actions; a read tool never sends anything.
            let nothing = if skill.action(tool).is_some() {
                "sent"
            } else {
                "run"
            };
            return fail(
                &short,
                format!(
                    "Refused: {invented} came from neither the user nor a tool, so it may be made up. Ask the user for the address; nothing was {nothing}."
                ),
            );
        }
        let args = self.addresses.reveal_json(args);
        let command = format!("{short} {args}");
        self.log(AgentEvent::ToolStarted {
            command: command.clone(),
        });
        let at = match self.interim.skill_context().await {
            Ok(at) => at,
            Err(error) => return fail(&command, error),
        };
        let events = self.events.clone();
        let log: Log = Arc::new(move |line| {
            let _ = events.send(AgentEvent::ToolFinished(EdwResult {
                command: line,
                exit_code: 0,
                output: String::new(),
            }));
        });
        let host = self.skills.host(&skill, Some(at.rpc.clone()), log);
        let action = skill.action(tool);
        let run = match (action, skill.read_tool(tool)) {
            (Some(action), _) => action.tool.run.clone(),
            (None, Some(read)) => read.run.clone(),
            (None, None) => return fail(&command, format!("`{tool}` is not in {}", skill.name)),
        };
        let invoke = sandbox::invoke_message(tool, &args, self.skills.context(&skill, &at));
        // Runs from a snapshot whose hash must still be the one the user agreed to.
        let (snapshot, _run_dir) = match self.skills.prepare_run(&skill) {
            Ok(prepared) => prepared,
            Err(error) => return fail(&command, error),
        };
        let output = match self.skills.runner.run(&snapshot, &run, invoke, &host).await {
            Ok(output) => output,
            Err(error) => return fail(&command, format!("{short} failed: {error}")),
        };
        let plan = match (output, action) {
            (Output::Result(value), None) => {
                let mut text = value.to_string();
                if text.len() > MAX_SKILL_RESULT {
                    let mut end = MAX_SKILL_RESULT;
                    while !text.is_char_boundary(end) {
                        end -= 1;
                    }
                    text.truncate(end);
                    text.push_str(" …(truncated at 8 KiB)");
                }
                let result = EdwResult {
                    command,
                    exit_code: 0,
                    output: text,
                };
                self.log(AgentEvent::ToolFinished(result.clone()));
                return result.to_model_json();
            }
            (Output::Plan(plan), Some(action)) => (plan, action),
            (Output::Result(_), Some(_)) => {
                return fail(
                    &command,
                    format!("{short} returned no plan; nothing was sent."),
                );
            }
            (Output::Plan(_), None) => {
                return fail(
                    &command,
                    format!(
                        "{short} is a read tool and may not propose transactions; nothing was sent."
                    ),
                );
            }
        };
        let (plan, action) = plan;
        let checked = match plan::check(&plan, &skill, action, at.chain_id, at.me) {
            Ok(checked) => checked,
            Err(error) => {
                return fail(
                    &command,
                    format!("the plan was refused ({error}); nothing was sent."),
                );
            }
        };
        let hash = self.skills.hash(&skill.name);
        let header = vec![format!(
            "Skill    {} {} (sha256 {})",
            skill.name,
            skill.manifest.version,
            &hash[..hash.len().min(12)]
        )];
        let names = self.skills.names(&skill, at.chain_id);
        let prepared = match self
            .interim
            .prepare_plan(command.clone(), header, checked, &names, &at)
            .await
        {
            Ok(prepared) => prepared,
            Err(error) => return fail(&command, error),
        };
        self.log(AgentEvent::ToolFinished(EdwResult {
            command: format!("{command} (dry run)"),
            exit_code: 0,
            output: prepared.preview.clone(),
        }));
        if !self.confirm(&command, Some(prepared.preview.clone())).await {
            return format!("The user declined `{short}`; nothing was sent.");
        }
        self.log(AgentEvent::ToolStarted {
            command: command.clone(),
        });
        let result = self.interim.broadcast(prepared).await;
        self.log(AgentEvent::ToolFinished(result.clone()));
        result.to_model_json()
    }

    async fn run_tool<const I: usize>(&self, name: &str, args: &Value) -> String {
        if TOOLS[I].backend == Backend::Interim {
            return self.interim_call(name, args).await;
        }
        let argv = match edw::build_argv(name, args) {
            Ok(argv) => argv,
            Err(error) => return format!("Rejected before running edw: {error}"),
        };
        self.log(AgentEvent::ToolStarted {
            command: edw::display_command(&argv),
        });
        let result = edw::run(&self.config, &argv).await;
        self.log(AgentEvent::ToolFinished(result.clone()));
        result.to_model_json()
    }
}

/// The first address in any string of `args` that neither the user nor a tool produced.
fn first_invented(addresses: &AddressBook, args: &Value) -> Option<String> {
    match args {
        Value::String(text) => addresses.invented(text).map(str::to_owned),
        Value::Array(items) => items.iter().find_map(|v| first_invented(addresses, v)),
        Value::Object(map) => map.values().find_map(|v| first_invented(addresses, v)),
        _ => None,
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
        // Value-moving tools confirm inside the tool, after the dry run, with its preview.
        if !spec.mutating || spec.moves_value {
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
                preview: None,
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

pub fn build_agent(
    model: ModelHandle,
    config: EdwConfig,
    interim: InterimConfig,
    events: Events,
    skills: Arc<SkillSet>,
) -> Agent {
    let shared = Arc::new(Shared {
        config,
        addresses: interim.addresses.clone(),
        interim: Interim::new(interim),
        events: events.clone(),
        skills: skills.clone(),
    });
    let dynamic = dynamic_tools(&shared);
    let builder = AgentBuilder::from_model_handle(model)
        .preamble(&preamble_with(&skills.catalog))
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
        .tool(EdwTool::<7>(shared.clone()))
        .tool(EdwTool::<8>(shared.clone()))
        .tool(EdwTool::<9>(shared.clone()))
        .tool(EdwTool::<10>(shared.clone()))
        .tool(EdwTool::<11>(shared.clone()))
        .tool(EdwTool::<12>(shared));
    if skills.is_empty() {
        return builder.build();
    }
    builder
        .dynamic_tools(dynamic)
        .add_hook(SkillGate {
            builtin: skill_tools::builtin_tools(&skills),
            set: skills,
        })
        .build()
}

/// `load_skill`, and one tool per read tool and action of every ready skill. They are all
/// registered; [`SkillGate`] decides which ones a request offers.
fn dynamic_tools(shared: &Arc<Shared>) -> Vec<DynamicTool> {
    let mut tools = Vec::new();
    if shared.skills.is_empty() {
        return tools;
    }
    let s = shared.clone();
    tools.push(DynamicTool::new(
        LOAD_SKILL,
        skill_tools::LOAD_SKILL_DESCRIPTION,
        skill_tools::load_skill_parameters(),
        move |_context, args| {
            let s = s.clone();
            Box::pin(async move { Ok(ToolOutput::text(s.load_skill(&args))) })
        },
    ));
    for skill in &shared.skills.catalog.skills {
        let m = &skill.manifest;
        for tool in m.read_tools.iter().chain(m.actions.iter().map(|a| &a.tool)) {
            let s = shared.clone();
            let name = tool.name.clone();
            tools.push(DynamicTool::new(
                tool.name.clone(),
                tool.description.clone(),
                tool.schema.clone(),
                move |_context, args| {
                    let s = s.clone();
                    let name = name.clone();
                    Box::pin(async move {
                        let output = s.skill_call(&name, args).await;
                        Ok(ToolOutput::text(s.addresses.hide(&output)))
                    })
                },
            ));
        }
    }
    tools
}

/// An Ollama model behind [`OllamaReplies`]. `nudge` turns on the empty-reply retry that
/// gemma4 needs; the cut-off handling is always on.
pub fn ollama_model(base_url: &str, model: &str, nudge: bool) -> anyhow::Result<ModelHandle> {
    let client = ollama::Client::builder()
        .api_key(Nothing)
        .base_url(base_url)
        .build()?;
    Ok(ModelHandle::named(
        "ollama",
        OllamaReplies {
            inner: client.completion_model(model),
            nudge,
        },
    ))
}

const SUMMARY_NUDGE: &str = "If my request still needs more commands, call the next tool now. Otherwise tell me the result in one short sentence.";
const NO_SUMMARY: &str = "(The model gave no summary; the command and its output are in the log.)";
const CUT_OFF_NUDGE: &str = "Your previous reply was cut off before it finished. Try again: if my request needs a tool, call it, copying any address from my message character by character.";
pub const CUT_OFF_REPLY: &str = "(The model's reply was cut off before it finished, so nothing was run. Ollama does this with some long runs of repeated characters, such as an address full of zeros. Try again, rephrase, or switch model with /models.)";

/// Two ways an Ollama reply can fail without the request being at fault.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Hiccup {
    /// gemma4 ends the turn right after a tool result with an empty message.
    Empty,
    /// Ollama 0.31 aborts some generations and answers with a placeholder
    /// (`{"message":{"role":"",...},"done":false}`) that Rig cannot parse. Seen with qwen3:8b
    /// writing `0x000…000bEEF`: generation stops inside the run of zeros.
    CutOff,
}

fn hiccup(error: &CompletionError) -> Option<Hiccup> {
    match error {
        CompletionError::ResponseError(message) if message == EMPTY_RESPONSE_ERROR => {
            Some(Hiccup::Empty)
        }
        CompletionError::JsonError(error) if error.to_string().contains("unknown variant ``") => {
            Some(Hiccup::CutOff)
        }
        _ => None,
    }
}

/// Retries a hiccup once with a one-line nudge, then falls back to a short explanation, so a
/// model or Ollama quirk never surfaces as a raw parse error.
#[derive(Clone)]
struct OllamaReplies<M> {
    inner: M,
    nudge: bool,
}

impl<M: CompletionModel> CompletionModel for OllamaReplies<M> {
    async fn completion(
        &self,
        request: CompletionRequest,
    ) -> Result<CompletionResponse, CompletionError> {
        let kind = match self.inner.completion(request.clone()).await {
            Err(error) => match hiccup(&error) {
                Some(Hiccup::Empty) if !self.nudge => return Err(error),
                Some(kind) => kind,
                None => return Err(error),
            },
            ok => return ok,
        };
        let (nudge, fallback) = match kind {
            Hiccup::Empty => (SUMMARY_NUDGE, NO_SUMMARY),
            Hiccup::CutOff => (CUT_OFF_NUDGE, CUT_OFF_REPLY),
        };
        let mut nudged = request;
        nudged.chat_history.push(Message::user(nudge));
        match self.inner.completion(nudged).await {
            Err(error) if hiccup(&error).is_some() => Ok(CompletionResponse::new(
                vec![AssistantContent::text(fallback)],
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
        self.inner.stream(request).await
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
    interim: InterimConfig,
) {
    let mut history: Vec<Message> = Vec::new();
    while let Some(request) = requests.recv().await {
        let event = match request {
            Request::Prompt(prompt) => {
                let addresses = &interim.addresses;
                match agent.chat(addresses.hide(&prompt), &mut history).await {
                    Ok(answer) => {
                        AgentEvent::Reply(addresses.reveal(&addresses.flag_invented(&answer)))
                    }
                    Err(error) => AgentEvent::Error(addresses.reveal(&error.to_string())),
                }
            }
            Request::ListModels => match source.list().await {
                Ok(names) => AgentEvent::Models(names),
                Err(error) => AgentEvent::Error(format!("cannot list Ollama models: {error}")),
            },
            Request::SetModel(name) => match switch_model(&mut agent, &source, &name).await {
                Ok(()) => AgentEvent::ModelChanged(name),
                Err(error) => AgentEvent::Error(error.to_string()),
            },
            // Checked against the unlocked wallet first, so a typo never becomes the sender.
            Request::SetProfile(selector) => {
                match Interim::new(interim.clone()).address(Some(&selector)).await {
                    Ok(address) => {
                        interim.profile.set(&selector);
                        AgentEvent::ProfileChanged {
                            selector,
                            address: address.to_string(),
                            by_model: false,
                        }
                    }
                    Err(error) => AgentEvent::Error(error),
                }
            }
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
const _: () = assert!(TOOLS.len() == 13);

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    /// The error Rig raises for Ollama's cut-off placeholder (`"role": ""`).
    fn cut_off() -> CompletionError {
        #[derive(Debug, serde::Deserialize)]
        #[serde(rename_all = "lowercase")]
        #[allow(dead_code)]
        enum Role {
            User,
            Assistant,
            System,
            Tool,
        }
        CompletionError::JsonError(serde_json::from_str::<Role>("\"\"").unwrap_err())
    }

    fn empty() -> CompletionError {
        CompletionError::ResponseError(EMPTY_RESPONSE_ERROR.into())
    }

    /// Fails the first `failures` calls with `error`, then answers "ok".
    #[derive(Clone)]
    struct Flaky {
        failures: usize,
        error: fn() -> CompletionError,
        calls: Arc<AtomicUsize>,
    }

    impl CompletionModel for Flaky {
        async fn completion(
            &self,
            _request: CompletionRequest,
        ) -> Result<CompletionResponse, CompletionError> {
            if self.calls.fetch_add(1, Ordering::SeqCst) < self.failures {
                return Err((self.error)());
            }
            Ok(CompletionResponse::new(
                vec![AssistantContent::text("ok")],
                Usage::new(),
                "flaky",
            ))
        }

        async fn stream(
            &self,
            _request: CompletionRequest,
        ) -> Result<StreamingCompletionResponse, CompletionError> {
            Err(CompletionError::ResponseError("no streaming".into()))
        }
    }

    async fn ask(
        failures: usize,
        error: fn() -> CompletionError,
        nudge: bool,
    ) -> (Result<String, String>, usize) {
        let calls = Arc::new(AtomicUsize::new(0));
        let model = OllamaReplies {
            inner: Flaky {
                failures,
                error,
                calls: calls.clone(),
            },
            nudge,
        };
        let agent = AgentBuilder::from_model_handle(ModelHandle::named("flaky", model)).build();
        let answer = agent
            .chat("hi", &mut Vec::new())
            .await
            .map_err(|e| e.to_string());
        (answer, calls.load(Ordering::SeqCst))
    }

    #[tokio::test]
    async fn a_cut_off_reply_is_retried_once_then_explained() {
        assert!(hiccup(&cut_off()) == Some(Hiccup::CutOff));
        assert_eq!(ask(1, cut_off, false).await, (Ok("ok".into()), 2));
        assert_eq!(ask(2, cut_off, false).await, (Ok(CUT_OFF_REPLY.into()), 2));
    }

    #[tokio::test]
    async fn an_empty_reply_is_nudged_only_when_asked() {
        assert_eq!(ask(1, empty, true).await, (Ok("ok".into()), 2));
        assert_eq!(ask(2, empty, true).await, (Ok(NO_SUMMARY.into()), 2));
        let (answer, calls) = ask(1, empty, false).await;
        assert!(answer.is_err() && calls == 1);
    }

    #[tokio::test]
    async fn other_errors_pass_through_untouched() {
        let (answer, calls) = ask(1, || CompletionError::ResponseError("boom".into()), true).await;
        assert!(answer.unwrap_err().contains("boom") && calls == 1);
    }
}
