//! The LLM side, delegated to Rig: tools, a confirmation hook, and the chat loop.
//!
//! Rig owns the whole tool-call loop (send request, parse tool calls, dispatch, feed results
//! back, repeat until a final answer). This module only supplies:
//! - one Rig `Tool` per `edw` command, each a thin wrapper over [`crate::edw`];
//! - an `AgentHook` that holds state-changing calls until the user confirms them in the UI.

use std::{
    collections::{BTreeMap, BTreeSet},
    convert::Infallible,
    path::{Component, Path, PathBuf},
    sync::Arc,
};

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
        self as skills_mod, LOAD_SKILL, Paths, SkillRow, author, author_tools,
        catalog::Catalog,
        consent::ConsentRequest,
        facts,
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

/// Model calls per user message; each tool round-trip uses one. Writing a skill is the longest
/// job: load, two guides, three files and a check or two take about ten.
pub const MAX_TURNS: usize = 16;

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
    /// Startup finished: the skills are settled and the agent is listening. `lines` are for
    /// `/skills`, `notes` for the chat (Docker missing, a skill unavailable, …).
    SkillsReady {
        lines: Vec<String>,
        notes: Vec<String>,
        /// Every installed skill, for the Skills tab.
        rows: Vec<SkillRow>,
    },
    /// Skills to approve before the session goes on; answer with `Request::SkillsAnswered`.
    Consents(Vec<ConsentRequest>),
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
    /// A change from the Skills tab.
    Skill(SkillOp),
    /// The answers to the approval cards the session sent (`AgentEvent::Consents`).
    SkillsAnswered(BTreeMap<String, bool>),
}

/// What the Skills tab can do. Each one re-runs the startup steps (cards for anything new,
/// Docker, dependencies) and rebuilds the agent; the conversation is kept.
#[derive(Debug, PartialEq, Eq)]
pub enum SkillOp {
    /// Copy this folder into the user's skills folder; its approval card comes next.
    Add(PathBuf),
    Disable(String),
    /// Approval is asked for again.
    Enable(String),
    /// Only skills the user added.
    Delete(String),
    /// The user's own command: copy the model's draft into their skills; its approval card
    /// comes next.
    InstallDraft(String),
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
        // The SKILL.md text is for the model; the log only says what was loaded, so the
        // results that follow stay in view.
        let output = if loaded {
            match self.skills.catalog.closure(name) {
                Some(skills) => {
                    let parts: Vec<String> = skills
                        .iter()
                        .map(|s| {
                            let tools = s.tool_names();
                            if tools.is_empty() {
                                format!("{} (instructions only)", s.name)
                            } else {
                                format!("{} (tools: {})", s.name, tools.join(", "))
                            }
                        })
                        .collect();
                    format!("Loaded {}", parts.join(", "))
                }
                None => text.clone(),
            }
        } else {
            text.clone()
        };
        self.log(AgentEvent::ToolFinished(EdwResult {
            command: format!("{LOAD_SKILL} {name}"),
            exit_code: if loaded { 0 } else { 1 },
            output,
        }));
        text
    }

    /// Runs one authoring tool against the drafts folder. It needs `skill-creator` loaded.
    /// Addresses the model writes must have come from the user or a tool, and an `ADDR_n`
    /// alias is resolved only inside `skill.toml`: a script or SKILL.md is written as typed.
    async fn author_call(&self, tool: &str, mut args: Value) -> String {
        let Some(store) = self.skills.drafts() else {
            return "skill authoring is not available".into();
        };
        let name = args
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let command = format!("{tool} {name}");
        let fail = |output: String| {
            self.log(AgentEvent::ToolFinished(EdwResult {
                command: command.clone(),
                exit_code: 1,
                output: output.clone(),
            }));
            output
        };
        if !self.skills.is_loaded(author::CREATOR) {
            return fail(format!(
                "load the {} skill first (call load_skill); nothing was written.",
                author::CREATOR
            ));
        }
        // Every text the model supplied is echoed somewhere in the reply (a path, a name, a
        // topic), and the reply goes through `hide`, which would register an invented address.
        // So all of it is scanned, and a refusal names only the argument.
        if let Some((key, _)) = args.as_object().and_then(|o| {
            o.iter().find(|(_, v)| {
                v.as_str()
                    .is_some_and(|t| self.addresses.invented(t).is_some())
            })
        }) {
            return fail(format!(
                "Refused: `{key}` holds an address that came from neither the user nor a tool, so it may be made up. Ask the user for the address; nothing was written."
            ));
        }
        if matches!(tool, author::WRITE | author::INSTALL) && !store.confirmed() {
            return fail(
                "Not yet, nothing was written. First tell the user in a few lines what you plan to build (what it reads or sends, which chain, which contracts or web hosts, when it is used), ask about anything missing, and wait for their reply."
                    .into(),
            );
        }
        if tool == author::WRITE {
            let path = args.get("path").and_then(Value::as_str).unwrap_or_default();
            // `allowed_path` refuses every other spelling, so this is the manifest or nothing.
            let is_manifest = Path::new(path)
                .components()
                .eq([Component::Normal("skill.toml".as_ref())]);
            if is_manifest && let Some(content) = args.get("content").and_then(Value::as_str) {
                let revealed = self.addresses.reveal_uppercase(content);
                args["content"] = Value::String(revealed);
            }
        }
        self.log(AgentEvent::ToolStarted {
            command: command.clone(),
        });
        let (exit_code, mut output) =
            author_tools::call(store, &facts::Sourcify::new(), tool, &args).await;
        if output.len() > MAX_SKILL_RESULT {
            let mut end = MAX_SKILL_RESULT;
            while !output.is_char_boundary(end) {
                end -= 1;
            }
            output.truncate(end);
        }
        self.log(AgentEvent::ToolFinished(EdwResult {
            command,
            exit_code,
            output: output.clone(),
        }));
        output
    }

    /// What the model reads after an authoring call: [`Self::author_call`]'s text with every
    /// address hidden. Refusals never contain the address they refuse (see `author_call`).
    async fn author_reply(&self, tool: &str, args: Value) -> String {
        let output = self.author_call(tool, args).await;
        self.addresses.hide(&output)
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
        // Read tools need no wallet: with it locked they run without a sender or RPC (a
        // lookup such as defi-data's needs neither). Actions build transactions, so they do.
        let at = match self.interim.skill_context().await {
            Ok(at) => Some(at),
            Err(_) if skill.action(tool).is_none() => None,
            Err(error) => return fail(&command, format!("{error}; skill actions need the wallet")),
        };
        let events = self.events.clone();
        let log: Log = Arc::new(move |line| {
            let _ = events.send(AgentEvent::ToolFinished(EdwResult {
                command: line,
                exit_code: 0,
                output: String::new(),
            }));
        });
        let host = self
            .skills
            .host(&skill, at.as_ref().map(|at| at.rpc.clone()), log);
        let action = skill.action(tool);
        let run = match (action, skill.read_tool(tool)) {
            (Some(action), _) => action.tool.run.clone(),
            (None, Some(read)) => read.run.clone(),
            (None, None) => return fail(&command, format!("`{tool}` is not in {}", skill.name)),
        };
        let invoke = sandbox::invoke_message(tool, &args, self.skills.context(&skill, at.as_ref()));
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
        let Some(at) = at else {
            return fail(
                &command,
                "the wallet is locked; unlock a network first".into(),
            );
        };
        let checked = match plan::check(&plan, &skill, action, at.chain_id, at.me, &args) {
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
    if shared.skills.authoring_enabled() {
        for (name, description, schema) in author_tools::specs() {
            let s = shared.clone();
            tools.push(DynamicTool::new(
                name,
                description,
                schema,
                move |_context, args| {
                    let s = s.clone();
                    Box::pin(async move { Ok(ToolOutput::text(s.author_reply(name, args).await)) })
                },
            ));
        }
    }
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
        let event = answer(&mut agent, &mut history, request, &source, &interim).await;
        if events.send(event).is_err() {
            return;
        }
    }
}

/// One chat-loop request against `agent`; skill requests are the session's (see
/// [`run_session`]).
async fn answer(
    agent: &mut Agent,
    history: &mut Vec<Message>,
    request: Request,
    source: &ModelSource,
    interim: &InterimConfig,
) -> AgentEvent {
    match request {
        Request::Prompt(prompt) => {
            let addresses = &interim.addresses;
            match agent.chat(addresses.hide(&prompt), history).await {
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
        Request::SetModel(name) => match switch_model(agent, source, &name).await {
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
        Request::Skill(_) | Request::SkillsAnswered(_) => {
            AgentEvent::Error("skills cannot be changed in this session".into())
        }
    }
}

/// Everything the session needs to (re)build the agent.
pub struct Session {
    pub model_name: String,
    /// The model to start with; `None` builds it from `model_name` through `source`.
    pub model: Option<ModelHandle>,
    pub source: ModelSource,
    pub config: EdwConfig,
    pub interim: InterimConfig,
    /// `None`: skills are off.
    pub paths: Option<Paths>,
}

/// The TUI's agent task: settles the skills (approval cards through the TUI, then Docker and
/// dependencies), builds the agent, answers chat requests, and on every change from the Skills
/// tab settles the skills again and rebuilds the agent with the same conversation.
pub async fn run_session(
    session: Session,
    mut requests: mpsc::UnboundedReceiver<Request>,
    events: Events,
) {
    let model = match session.model.clone() {
        Some(model) => model,
        None => match session.source.handle(&session.model_name) {
            Ok(model) => model,
            Err(error) => {
                let _ = events.send(AgentEvent::Error(error.to_string()));
                return;
            }
        },
    };
    let mut state = SessionState {
        session,
        events,
        model,
        agent: None,
        set: Arc::new(SkillSet::empty()),
        pending: None,
        declined: BTreeSet::new(),
        history: Vec::new(),
    };
    state.begin(None).await;
    while let Some(request) = requests.recv().await {
        match request {
            Request::SkillsAnswered(answers) => {
                if let Some((discovery, added)) = state.pending.take() {
                    state.settle(discovery, &answers, added).await;
                }
            }
            Request::Skill(op) => state.change(op).await,
            other => {
                if let Request::Prompt(text) = &other
                    && let Some(drafts) = state.set.drafts()
                {
                    drafts.user_message(text);
                }
                let event = match state.agent.as_mut() {
                    Some(agent) => {
                        answer(
                            agent,
                            &mut state.history,
                            other,
                            &state.session.source,
                            &state.session.interim,
                        )
                        .await
                    }
                    None => AgentEvent::Error("the skills are still being set up".into()),
                };
                if state.events.send(event).is_err() {
                    return;
                }
                // The model offered a finished draft: the user's approval card follows its
                // reply. Only the user's answer to that card installs anything.
                if let Some(name) = state.set.drafts().and_then(|d| d.take_install_request()) {
                    state.change(SkillOp::InstallDraft(name)).await;
                }
            }
        }
    }
}

struct SessionState {
    session: Session,
    events: Events,
    /// The model the first agent is built with; later rebuilds keep the current one.
    model: ModelHandle,
    agent: Option<Agent>,
    set: Arc<SkillSet>,
    /// Cards sent to the TUI and not answered yet, and a skill just added (deleted again if
    /// it is not approved).
    pending: Option<(skills_mod::Discovery, Option<String>)>,
    /// (name, folder hash) of cards declined this session: not shown again on every change,
    /// only when the user enables the skill (or its folder changes).
    declined: BTreeSet<(String, String)>,
    history: Vec<Message>,
}

impl SessionState {
    /// Finds the skills; asks the TUI about any that need approval, or settles right away.
    async fn begin(&mut self, added: Option<String>) {
        let Some(paths) = &self.session.paths else {
            self.rebuild(Arc::new(SkillSet::empty()));
            let _ = self.events.send(AgentEvent::SkillsReady {
                lines: vec!["Skills are off (EDW_TUI_SKILLS=off).".into()],
                notes: Vec::new(),
                rows: Vec::new(),
            });
            return;
        };
        let mut discovery = skills_mod::discover(paths);
        discovery
            .requests
            .retain(|r| !self.declined.contains(&(r.name.clone(), r.hash.clone())));
        if discovery.requests.is_empty() {
            self.settle(discovery, &BTreeMap::new(), added).await;
        } else {
            let _ = self
                .events
                .send(AgentEvent::Consents(discovery.requests.clone()));
            self.pending = Some((discovery, added));
        }
    }

    async fn change(&mut self, op: SkillOp) {
        let Some(paths) = self.session.paths.clone() else {
            let _ = self.events.send(AgentEvent::Error(
                "skills are off (EDW_TUI_SKILLS=off)".into(),
            ));
            return;
        };
        if self.pending.is_some() {
            let _ = self.events.send(AgentEvent::Error(
                "answer the open approval cards first".into(),
            ));
            return;
        }
        let done = match op {
            SkillOp::Add(source) => skills_mod::add(&paths, &source).map(Some),
            SkillOp::Disable(name) => skills_mod::disable(&paths, &name).map(|()| None),
            SkillOp::Enable(name) => {
                self.declined.retain(|(declined, _)| *declined != name);
                skills_mod::enable(&paths, &name).map(|()| None)
            }
            SkillOp::Delete(name) => skills_mod::delete(&paths, &name).map(|()| None),
            SkillOp::InstallDraft(name) => skills_mod::install_draft(&paths, &name).map(Some),
        };
        match done {
            Ok(added) => {
                // Adding a skill again is asking for its card again.
                if let Some(name) = &added {
                    self.declined.retain(|(declined, _)| declined != name);
                }
                self.begin(added).await
            }
            Err(error) => {
                let _ = self.events.send(AgentEvent::Error(error));
            }
        }
    }

    async fn settle(
        &mut self,
        discovery: skills_mod::Discovery,
        answers: &BTreeMap<String, bool>,
        added: Option<String>,
    ) {
        let Some(paths) = self.session.paths.clone() else {
            return;
        };
        for request in &discovery.requests {
            if answers.get(&request.name) != Some(&true) {
                self.declined
                    .insert((request.name.clone(), request.hash.clone()));
            }
        }
        let startup = skills_mod::finish(discovery, answers).await;
        let mut notes = startup.notes;
        let mut installed = startup.installed;
        if let Some(name) = added
            && answers.get(&name) != Some(&true)
        {
            // Never approved, so never kept.
            let _ = skills_mod::delete(&paths, &name);
            installed.retain(|i| i.name != name);
            notes.push(format!("{name} was not added: it was not approved."));
        }
        startup.set.carry_loaded(&self.set);
        self.set = startup.set;
        self.rebuild(self.set.clone());
        let _ = self.events.send(AgentEvent::SkillsReady {
            lines: skills_mod::describe(&installed),
            notes,
            rows: skills_mod::rows(&installed, &paths),
        });
    }

    fn rebuild(&mut self, set: Arc<SkillSet>) {
        let model = self
            .agent
            .as_ref()
            .map_or_else(|| self.model.clone(), |agent| agent.model_handle().clone());
        self.agent = Some(build_agent(
            model,
            self.session.config.clone(),
            self.session.interim.clone(),
            self.events.clone(),
            set,
        ));
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

    fn creator_set(root: &std::path::Path, with_drafts: bool) -> Arc<SkillSet> {
        use crate::skills::{
            author::DraftStore,
            catalog::{self, Catalog, SkillState},
            sandbox::Runner,
        };
        let dir = root.join("skills/skill-creator");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("SKILL.md"),
            "---\nname: skill-creator\ndescription: Create a new skill.\n---\nbody\n",
        )
        .unwrap();
        let mut installed = catalog::discover(&[root.join("skills")]);
        installed[0].state = SkillState::Ready;
        let mut set = SkillSet::new(
            Catalog::from_installed(&installed),
            &installed,
            Runner::from_env(),
        );
        if with_drafts {
            set = set.with_drafts(DraftStore::new(root.join("drafts")));
        }
        Arc::new(set)
    }

    fn shared_with(skills: Arc<SkillSet>, root: &std::path::Path) -> Arc<Shared> {
        let edw = EdwConfig {
            binary: "edw".into(),
            data_dir: root.join("data"),
            runtime_dir: root.join("run"),
            password: String::new(),
        };
        let mut interim = InterimConfig::from_env(edw.clone());
        interim.addresses = AddressBook::new(true);
        let (events, _rx) = mpsc::unbounded_channel();
        Arc::new(Shared {
            config: edw,
            addresses: interim.addresses.clone(),
            interim: Interim::new(interim),
            events,
            skills,
        })
    }

    const KNOWN: &str = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
    const MADE_UP: &str = "0x1111111111111111111111111111111111111111";

    async fn write_draft(s: &Shared, path: &str, content: &str) -> String {
        s.author_call(
            author::WRITE,
            serde_json::json!({"name": "demo", "path": path, "content": content}),
        )
        .await
    }

    fn authoring_tool_names(shared: &Arc<Shared>) -> usize {
        dynamic_tools(shared)
            .iter()
            .filter(|t| author::TOOL_NAMES.contains(&t.name()))
            .count()
    }

    #[test]
    fn authoring_tools_are_registered_only_with_skill_creator_and_a_drafts_folder() {
        let root = tempfile::tempdir().unwrap();
        let with = shared_with(creator_set(root.path(), true), root.path());
        assert_eq!(authoring_tool_names(&with), 4);
        let root = tempfile::tempdir().unwrap();
        let no_drafts = shared_with(creator_set(root.path(), false), root.path());
        assert_eq!(authoring_tool_names(&no_drafts), 0);
        let root = tempfile::tempdir().unwrap();
        let empty = SkillSet::empty().with_drafts(crate::skills::author::DraftStore::new(
            root.path().join("drafts"),
        ));
        let no_creator = shared_with(Arc::new(empty), root.path());
        assert_eq!(authoring_tool_names(&no_creator), 0);
    }

    #[tokio::test]
    async fn an_authoring_call_is_refused_until_skill_creator_is_loaded() {
        let root = tempfile::tempdir().unwrap();
        let s = shared_with(creator_set(root.path(), true), root.path());
        let out = write_draft(&s, "SKILL.md", "x").await;
        assert!(out.contains("load the skill-creator skill first"), "{out}");
        assert!(!root.path().join("drafts/demo").exists());
        s.skills.load("skill-creator");
        let out = write_draft(&s, "SKILL.md", "x").await;
        assert!(out.starts_with("wrote SKILL.md"), "{out}");
    }

    #[tokio::test]
    async fn nothing_is_written_or_offered_until_the_user_has_answered() {
        let root = tempfile::tempdir().unwrap();
        let s = shared_with(creator_set(root.path(), true), root.path());
        s.skills.load("skill-creator");
        let drafts = s.skills.drafts().unwrap();
        drafts.user_message(&format!("{} and help me: a skill", author::START));
        let refused = write_draft(&s, "SKILL.md", "x").await;
        assert!(
            refused.contains("Not yet") && refused.contains("wait for their reply"),
            "{refused}"
        );
        assert!(!root.path().join("drafts/demo").exists());
        let offered = s
            .author_call(author::INSTALL, serde_json::json!({"name": "demo"}))
            .await;
        assert!(offered.contains("Not yet"), "{offered}");
        // Reading the guides is allowed meanwhile, and the user's next message is the answer.
        let guide = s
            .author_call(author::GUIDE, serde_json::json!({"topic": "example"}))
            .await;
        assert!(!guide.contains("Not yet"));
        drafts.user_message("yes, mainnet only");
        assert!(write_draft(&s, "SKILL.md", "x").await.starts_with("wrote"));
    }

    #[tokio::test]
    async fn a_draft_write_refuses_addresses_from_neither_user_nor_tool() {
        let root = tempfile::tempdir().unwrap();
        let s = shared_with(creator_set(root.path(), true), root.path());
        s.skills.load("skill-creator");
        s.addresses.hide(KNOWN);
        let ok = write_draft(&s, "skill.toml", &format!("a = \"{KNOWN}\"\n")).await;
        assert!(ok.starts_with("wrote"), "{ok}");
        let refused = write_draft(&s, "scripts/a.py", &format!("A = \"{MADE_UP}\"\n")).await;
        assert!(
            refused.contains("Refused")
                && refused.contains("`content`")
                && refused.contains("nothing was written"),
            "{refused}"
        );
        assert!(!root.path().join("drafts/demo/scripts/a.py").exists());
    }

    #[tokio::test]
    async fn a_refusal_does_not_launder_the_invented_address() {
        let root = tempfile::tempdir().unwrap();
        let s = shared_with(creator_set(root.path(), true), root.path());
        s.skills.load("skill-creator");
        let args = |content: &str| serde_json::json!({"name": "demo", "path": "skill.toml", "content": content});
        let bad = format!("a = \"{MADE_UP}\"\n");
        let first = s.author_reply(author::WRITE, args(&bad)).await;
        assert!(
            first.contains("Refused") && !first.contains(MADE_UP),
            "{first}"
        );
        assert!(!first.contains("ADDR_"), "{first}");
        let retry = s.author_reply(author::WRITE, args(&bad)).await;
        assert!(retry.contains("Refused"), "{retry}");
        s.author_reply(author::WRITE, args("a = \"ADDR_1\"\n"))
            .await;
        let written = std::fs::read_to_string(root.path().join("drafts/demo/skill.toml")).unwrap();
        assert!(!written.contains(MADE_UP), "{written}");
    }

    #[tokio::test]
    async fn a_path_or_name_holding_an_invented_address_is_refused_not_echoed() {
        let root = tempfile::tempdir().unwrap();
        let s = shared_with(creator_set(root.path(), true), root.path());
        s.skills.load("skill-creator");
        let path = format!("scripts/{MADE_UP}.py");
        let reply = s
            .author_reply(
                author::WRITE,
                serde_json::json!({"name": "demo", "path": path, "content": "x = 1\n"}),
            )
            .await;
        assert!(
            reply.contains("Refused") && !reply.contains("ADDR_"),
            "{reply}"
        );
        // No alias was handed out, so the model cannot write one into skill.toml.
        assert!(!s.addresses.reveal_uppercase("ADDR_1").contains(MADE_UP));
        let guide = s
            .author_reply(author::GUIDE, serde_json::json!({"topic": MADE_UP}))
            .await;
        assert!(
            guide.contains("Refused") && !guide.contains("ADDR_"),
            "{guide}"
        );
    }

    #[tokio::test]
    async fn aliases_resolve_only_in_skill_toml() {
        let root = tempfile::tempdir().unwrap();
        let s = shared_with(creator_set(root.path(), true), root.path());
        s.skills.load("skill-creator");
        s.addresses.hide(KNOWN);
        let script = "addr_1 = ctx['to']\nprint(addr_1)\n";
        write_draft(&s, "scripts/run.py", script).await;
        write_draft(&s, "skill.toml", "to = \"ADDR_1\"\n").await;
        write_draft(&s, "SKILL.md", "use ADDR_1\n").await;
        let dir = root.path().join("drafts/demo");
        assert_eq!(
            std::fs::read_to_string(dir.join("scripts/run.py")).unwrap(),
            script
        );
        assert_eq!(
            std::fs::read_to_string(dir.join("skill.toml")).unwrap(),
            format!("to = \"{KNOWN}\"\n")
        );
        assert_eq!(
            std::fs::read_to_string(dir.join("SKILL.md")).unwrap(),
            "use ADDR_1\n"
        );
    }
}
