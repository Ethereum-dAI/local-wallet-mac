//! UI state. Pure: keys and agent events go in, state and actions come out, so it is testable
//! without a terminal.

use std::{
    collections::{BTreeMap, VecDeque},
    time::{Duration, Instant},
};

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use tokio::sync::oneshot;

use crate::{
    agent::{AgentEvent, Request},
    edw::EdwResult,
    skills::consent::ConsentRequest,
};

pub const HELP: &str = "/models lists installed models · /model <name or number> switches (history is kept) · /profile <name or 0/1> picks who sends · /skills lists skills · /copy [reply|log|address] copies to the clipboard · Tab shows one panel at a time, for selecting text · /help";

/// How long a confirmation must be on screen before y or n counts.
pub const CONFIRM_GRACE: Duration = Duration::from_millis(400);

/// Which panels are on screen. A terminal selects whole screen rows, so text is copied
/// cleanly only when one panel fills the width.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum View {
    #[default]
    Split,
    Chat,
    Log,
}

impl View {
    fn next(self) -> Self {
        match self {
            View::Split => View::Chat,
            View::Chat => View::Log,
            View::Log => View::Split,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChatLine {
    User(String),
    Assistant(String),
    Error(String),
    /// Harness messages: help, model lists, model switches.
    Info(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LogEntry {
    Running(String),
    Finished(EdwResult),
    Declined(String),
}

pub struct PendingConfirm {
    pub command: String,
    /// A transfer's dry run, shown above the command.
    pub preview: Option<String>,
    reply: oneshot::Sender<bool>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Action {
    None,
    Send(Request),
    /// Put this text on the system clipboard.
    Copy(String),
    /// Every skill approval is answered: skill name → allowed. Unlisted means no.
    SkillsAnswered(BTreeMap<String, bool>),
    Quit,
}

pub struct App {
    pub model: String,
    pub data_dir: String,
    /// The profile transfers are sent from (a selector such as `0/0` or `bob`).
    pub profile: String,
    /// Its address, once `/profile` has looked it up.
    pub profile_address: Option<String>,
    pub view: View,
    pub chat: Vec<ChatLine>,
    pub log: Vec<LogEntry>,
    pub input: String,
    pub busy: bool,
    /// The last `/models` listing, so `/model 2` can pick by number.
    pub models: Vec<String>,
    /// Skills waiting for the user's approval, shown one card at a time before chatting.
    pub consents: VecDeque<ConsentRequest>,
    pub consent_scroll: u16,
    /// How many cards this round had, for "(2 of 3)".
    pub consent_total: usize,
    consent_answers: BTreeMap<String, bool>,
    consent_shown: Option<Instant>,
    /// `/skills`: one line per installed skill and its state, from startup.
    pub skills: Vec<String>,
    /// Confirmations in arrival order; the model may emit several state changes in one turn.
    pub pending: VecDeque<PendingConfirm>,
    /// When the front confirmation appeared; keys are ignored until `confirm_grace` has passed.
    confirm_shown: Option<Instant>,
    pub confirm_grace: Duration,
}

impl App {
    pub fn new(model: impl Into<String>, data_dir: impl Into<String>) -> Self {
        Self {
            model: model.into(),
            data_dir: data_dir.into(),
            profile: crate::interim::DEFAULT_PROFILE.into(),
            profile_address: None,
            view: View::default(),
            chat: Vec::new(),
            log: Vec::new(),
            input: String::new(),
            busy: false,
            models: Vec::new(),
            consents: VecDeque::new(),
            consent_scroll: 0,
            consent_total: 0,
            consent_answers: BTreeMap::new(),
            consent_shown: None,
            skills: Vec::new(),
            pending: VecDeque::new(),
            confirm_shown: None,
            confirm_grace: CONFIRM_GRACE,
        }
    }

    /// Shows these approval cards before anything else; chat waits until the skills are ready
    /// (see `AgentEvent::SkillsReady`).
    pub fn ask_consents(&mut self, requests: Vec<ConsentRequest>) {
        self.consent_total = requests.len();
        self.consents = requests.into();
        self.consent_scroll = 0;
        self.consent_answers.clear();
        self.consent_shown = (!self.consents.is_empty()).then(Instant::now);
        self.busy = true;
    }

    fn on_consent_key(&mut self, code: KeyCode) -> Action {
        // Same rule as a send: only a deliberate y or n, once the card has been up a moment.
        let settled = self
            .consent_shown
            .is_none_or(|shown| shown.elapsed() >= self.confirm_grace);
        let allow = match code {
            KeyCode::Char('y' | 'Y') if settled => true,
            KeyCode::Char('n' | 'N') | KeyCode::Esc if settled => false,
            KeyCode::Up | KeyCode::Char('k') => {
                self.consent_scroll = self.consent_scroll.saturating_sub(1);
                return Action::None;
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.consent_scroll = self.consent_scroll.saturating_add(1);
                return Action::None;
            }
            _ => return Action::None,
        };
        if let Some(request) = self.consents.pop_front() {
            self.consent_answers.insert(request.name, allow);
        }
        self.consent_scroll = 0;
        self.consent_shown = (!self.consents.is_empty()).then(Instant::now);
        if self.consents.is_empty() {
            Action::SkillsAnswered(std::mem::take(&mut self.consent_answers))
        } else {
            Action::None
        }
    }

    pub fn on_key(&mut self, key: KeyEvent) -> Action {
        if key.modifiers.contains(KeyModifiers::CONTROL)
            && matches!(key.code, KeyCode::Char('c' | 'd'))
        {
            return Action::Quit;
        }
        if !self.consents.is_empty() {
            return self.on_consent_key(key.code);
        }
        if !self.pending.is_empty() {
            // Only an explicit y or n answers, and only once the modal has been on screen for a
            // moment: an Enter or a "y" typed for the next message must never approve a send.
            let settled = self
                .confirm_shown
                .is_none_or(|shown| shown.elapsed() >= self.confirm_grace);
            match key.code {
                KeyCode::Char('y' | 'Y') if settled => self.answer(true),
                KeyCode::Char('n' | 'N') | KeyCode::Esc if settled => self.answer(false),
                _ => {}
            }
            return Action::None;
        }
        match key.code {
            KeyCode::Enter if !self.busy => {
                let prompt = self.input.trim().to_owned();
                self.input.clear();
                if prompt.is_empty() {
                    return Action::None;
                }
                self.chat.push(ChatLine::User(prompt.clone()));
                if prompt.starts_with("/copy") {
                    return self.copy(prompt.split_whitespace().nth(1));
                }
                let request = if prompt.starts_with('/') {
                    match self.command(&prompt) {
                        Some(request) => request,
                        None => return Action::None,
                    }
                } else {
                    Request::Prompt(prompt)
                };
                self.busy = true;
                Action::Send(request)
            }
            KeyCode::Tab => {
                self.view = self.view.next();
                Action::None
            }
            KeyCode::Char(c) => {
                self.input.push(c);
                Action::None
            }
            KeyCode::Backspace => {
                self.input.pop();
                Action::None
            }
            KeyCode::Esc => {
                self.input.clear();
                Action::None
            }
            _ => Action::None,
        }
    }

    /// Pasted text goes into the input as typed text; line breaks become spaces, so a paste
    /// never submits half a message.
    pub fn on_paste(&mut self, text: &str) {
        if self.pending.is_empty() {
            self.input
                .push_str(&text.replace(['\r', '\n'], " ").replace('\t', " "));
        }
    }

    /// `/copy` (the last reply), `/copy log` (the last command and its output), `/copy address`
    /// (the sending profile's address).
    fn copy(&mut self, what: Option<&str>) -> Action {
        let text = match what.unwrap_or("reply") {
            "reply" => self.chat.iter().rev().find_map(|line| match line {
                ChatLine::Assistant(text) => Some(text.clone()),
                _ => None,
            }),
            "log" => self.log.iter().rev().find_map(|entry| match entry {
                LogEntry::Finished(result) => {
                    Some(format!("$ {}\n{}", result.command, result.output))
                }
                _ => None,
            }),
            "address" => self.profile_address.clone(),
            other => {
                self.chat.push(ChatLine::Error(format!(
                    "cannot copy `{other}`; use /copy, /copy log or /copy address"
                )));
                return Action::None;
            }
        };
        match text {
            Some(text) => Action::Copy(text),
            None => {
                let hint = if what == Some("address") {
                    "no address yet; run /profile <name or 0/0> first"
                } else {
                    "nothing to copy yet"
                };
                self.chat.push(ChatLine::Error(hint.into()));
                Action::None
            }
        }
    }

    /// Parses a slash command; `None` when it was handled locally or is invalid.
    fn command(&mut self, input: &str) -> Option<Request> {
        let mut words = input.split_whitespace();
        match (words.next(), words.next()) {
            (Some("/models") | Some("/model"), None) => Some(Request::ListModels),
            (Some("/model"), Some(choice)) => {
                let by_number = choice
                    .parse::<usize>()
                    .ok()
                    .and_then(|n| n.checked_sub(1))
                    .and_then(|i| self.models.get(i));
                match (by_number, choice.parse::<usize>()) {
                    (Some(name), _) => Some(Request::SetModel(name.clone())),
                    (None, Ok(_)) => {
                        self.chat.push(ChatLine::Error(
                            "no model with that number; run /models first".into(),
                        ));
                        None
                    }
                    (None, Err(_)) => Some(Request::SetModel(choice.to_owned())),
                }
            }
            (Some("/profile"), None) => {
                self.chat.push(ChatLine::Info(format!(
                    "Transfers are sent from profile {}. Change it with /profile <name or 0/1>.",
                    self.profile
                )));
                None
            }
            (Some("/profile"), Some(selector)) => Some(Request::SetProfile(selector.to_owned())),
            (Some("/skills"), None) => {
                let mut text = vec!["Skills:".to_owned()];
                text.extend(self.skills.iter().map(|line| format!("  {line}")));
                self.chat.push(ChatLine::Info(text.join("\n")));
                None
            }
            (Some("/help"), _) => {
                self.chat.push(ChatLine::Info(HELP.into()));
                None
            }
            _ => {
                self.chat
                    .push(ChatLine::Error(format!("unknown command. {HELP}")));
                None
            }
        }
    }

    fn answer(&mut self, run: bool) {
        if let Some(pending) = self.pending.pop_front() {
            if !run {
                self.log.push(LogEntry::Declined(pending.command));
            }
            let _ = pending.reply.send(run);
        }
        // The next queued confirmation gets its own grace period.
        self.confirm_shown = (!self.pending.is_empty()).then(Instant::now);
    }

    pub fn on_agent(&mut self, event: AgentEvent) {
        match event {
            AgentEvent::SkillsReady { lines, notes } => {
                self.skills = lines;
                self.chat.extend(notes.into_iter().map(ChatLine::Info));
                self.busy = false;
            }
            AgentEvent::ToolStarted { command } => self.log.push(LogEntry::Running(command)),
            AgentEvent::ToolFinished(result) => {
                let running = self
                    .log
                    .iter()
                    .rposition(|e| matches!(e, LogEntry::Running(c) if *c == result.command));
                match running {
                    Some(i) => self.log[i] = LogEntry::Finished(result),
                    None => self.log.push(LogEntry::Finished(result)),
                }
            }
            AgentEvent::Confirm {
                command,
                preview,
                reply,
            } => {
                if self.pending.is_empty() {
                    self.confirm_shown = Some(Instant::now());
                }
                self.pending.push_back(PendingConfirm {
                    command,
                    preview,
                    reply,
                });
            }
            AgentEvent::ProfileChanged {
                selector,
                address,
                by_model,
            } => {
                // The model's switch happens mid-turn; only the user's /profile ends a request.
                if !by_model {
                    self.busy = false;
                }
                self.chat.push(ChatLine::Info(format!(
                    "Transfers are now sent from profile {selector} ({address}). /copy address copies it."
                )));
                self.profile = selector;
                self.profile_address = Some(address);
            }
            AgentEvent::Reply(text) => {
                self.busy = false;
                self.chat
                    .push(ChatLine::Assistant(if text.trim().is_empty() {
                        "(no answer)".into()
                    } else {
                        text
                    }));
            }
            AgentEvent::Error(error) => {
                self.busy = false;
                self.chat.push(ChatLine::Error(error));
            }
            AgentEvent::Models(names) => {
                self.busy = false;
                let list = names
                    .iter()
                    .enumerate()
                    .map(|(i, name)| {
                        let current = if *name == self.model {
                            "  (current)"
                        } else {
                            ""
                        };
                        format!("{}. {name}{current}", i + 1)
                    })
                    .collect::<Vec<_>>()
                    .join("\n");
                self.chat.push(ChatLine::Info(format!(
                    "{list}\nSwitch with /model <number or name>."
                )));
                self.models = names;
            }
            AgentEvent::ModelChanged(name) => {
                self.busy = false;
                self.chat.push(ChatLine::Info(format!(
                    "Switched to {name}. The conversation so far is kept."
                )));
                self.model = name;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::skills::consent::Reason;

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn type_text(app: &mut App, text: &str) {
        for c in text.chars() {
            app.on_key(key(KeyCode::Char(c)));
        }
    }

    #[test]
    fn enter_submits_once_and_blocks_until_the_reply() {
        let mut app = App::new("m", "d");
        type_text(&mut app, "  list profiles ");
        assert_eq!(
            app.on_key(key(KeyCode::Enter)),
            Action::Send(Request::Prompt("list profiles".into()))
        );
        assert!(app.busy && app.input.is_empty());
        type_text(&mut app, "again");
        assert_eq!(app.on_key(key(KeyCode::Enter)), Action::None);
        app.on_agent(AgentEvent::Reply("ok".into()));
        assert!(!app.busy);
        assert_eq!(
            app.on_key(key(KeyCode::Enter)),
            Action::Send(Request::Prompt("again".into()))
        );
    }

    fn consent(name: &str) -> ConsentRequest {
        ConsentRequest {
            name: name.into(),
            version: "1".into(),
            short_hash: "abc".into(),
            hash: "abc".into(),
            description: "d".into(),
            reason: Reason::New,
            requires: vec![],
            hosts: vec![],
            tools: vec![],
            chains: vec![],
        }
    }

    #[test]
    fn skill_approvals_are_answered_one_by_one_and_then_handed_over() {
        let mut app = App::new("m", "d");
        app.confirm_grace = Duration::ZERO;
        app.ask_consents(vec![consent("alpha"), consent("beta")]);
        assert!(app.busy, "no chatting until the skills are settled");

        // Typing does not leak into the message box, and Enter approves nothing.
        type_text(&mut app, "hello");
        assert!(app.input.is_empty());
        assert_eq!(app.on_key(key(KeyCode::Enter)), Action::None);
        assert_eq!(app.consents.len(), 2);

        app.on_key(key(KeyCode::Down));
        assert_eq!(app.consent_scroll, 1);
        app.on_key(key(KeyCode::Up));
        app.on_key(key(KeyCode::Up));
        assert_eq!(app.consent_scroll, 0);

        assert_eq!(app.on_key(key(KeyCode::Char('y'))), Action::None);
        assert_eq!(app.consents.front().unwrap().name, "beta");
        let done = app.on_key(key(KeyCode::Char('n')));
        assert_eq!(
            done,
            Action::SkillsAnswered(BTreeMap::from([
                ("alpha".to_owned(), true),
                ("beta".to_owned(), false),
            ]))
        );
        assert!(app.consents.is_empty());
        assert!(
            app.busy,
            "still preparing until the agent says the skills are ready"
        );

        app.on_agent(AgentEvent::SkillsReady {
            lines: vec!["alpha (ready)".into()],
            notes: vec!["Docker is not running".into()],
        });
        assert!(!app.busy);
        assert_eq!(app.skills, ["alpha (ready)"]);
        assert!(matches!(app.chat.last(), Some(ChatLine::Info(t)) if t.contains("Docker")));
    }

    #[test]
    fn a_skill_approval_waits_out_the_grace_period() {
        let mut app = App::new("m", "d");
        app.confirm_grace = Duration::from_secs(60);
        app.ask_consents(vec![consent("alpha")]);
        app.on_key(key(KeyCode::Char('y')));
        assert_eq!(app.consents.len(), 1, "a y typed too early does not count");
    }

    #[test]
    fn confirm_prompt_takes_y_or_n_and_logs_a_decline() {
        let mut app = App::new("m", "d");
        app.confirm_grace = Duration::ZERO;
        let (reply, mut answer) = oneshot::channel();
        app.on_agent(AgentEvent::Confirm {
            command: "edw lock".into(),
            preview: None,
            reply,
        });
        app.on_key(key(KeyCode::Char('x')));
        assert!(
            !app.pending.is_empty() && app.input.is_empty(),
            "other keys are ignored while confirming"
        );
        app.on_key(key(KeyCode::Char('n')));
        assert_eq!(answer.try_recv(), Ok(false));
        assert_eq!(app.log, [LogEntry::Declined("edw lock".into())]);

        let (reply, mut answer) = oneshot::channel();
        app.on_agent(AgentEvent::Confirm {
            command: "edw lock".into(),
            preview: None,
            reply,
        });
        app.on_key(key(KeyCode::Char('y')));
        assert_eq!(answer.try_recv(), Ok(true));
    }

    #[test]
    fn only_a_deliberate_y_sends() {
        let mut app = App::new("m", "d");
        let (reply, mut answer) = oneshot::channel();
        app.on_agent(AgentEvent::Confirm {
            command: "interim transfer --to 0xabc --amount 0.5 --token ETH --from 0/0".into(),
            preview: Some("Send     0.5 ETH".into()),
            reply,
        });
        // Typed for the next message as the modal appeared: neither Enter nor a "y" answers.
        app.on_key(key(KeyCode::Enter));
        app.on_key(key(KeyCode::Char('y')));
        assert!(answer.try_recv().is_err() && app.pending.len() == 1);

        // Once the modal has settled, Enter still does not send; y does.
        app.confirm_grace = Duration::ZERO;
        app.on_key(key(KeyCode::Enter));
        assert!(answer.try_recv().is_err(), "Enter never approves");
        app.on_key(key(KeyCode::Char('y')));
        assert_eq!(answer.try_recv(), Ok(true));
    }

    #[test]
    fn confirmations_queue_instead_of_replacing_each_other() {
        let mut app = App::new("m", "d");
        app.confirm_grace = Duration::ZERO;
        let (first, mut first_answer) = oneshot::channel();
        let (second, mut second_answer) = oneshot::channel();
        app.on_agent(AgentEvent::Confirm {
            command: "edw unlock --network local".into(),
            preview: None,
            reply: first,
        });
        app.on_agent(AgentEvent::Confirm {
            command: "edw profile add --next".into(),
            preview: None,
            reply: second,
        });
        assert_eq!(
            app.pending.front().unwrap().command,
            "edw unlock --network local"
        );
        app.on_key(key(KeyCode::Char('y')));
        assert_eq!(first_answer.try_recv(), Ok(true));
        assert_eq!(
            app.pending.front().unwrap().command,
            "edw profile add --next"
        );
        app.on_key(key(KeyCode::Char('n')));
        assert_eq!(second_answer.try_recv(), Ok(false));
        assert!(app.pending.is_empty());
    }

    fn submit(app: &mut App, text: &str) -> Action {
        type_text(app, text);
        app.on_key(key(KeyCode::Enter))
    }

    #[test]
    fn slash_commands_list_and_switch_models() {
        let mut app = App::new("gemma4:latest", "d");
        assert_eq!(
            submit(&mut app, "/models"),
            Action::Send(Request::ListModels)
        );
        app.on_agent(AgentEvent::Models(vec![
            "gemma4:latest".into(),
            "qwen3:8b".into(),
            "scripted".into(),
        ]));
        let Some(ChatLine::Info(list)) = app.chat.last() else {
            panic!("no list")
        };
        assert!(list.contains("1. gemma4:latest  (current)") && list.contains("2. qwen3:8b"));

        assert_eq!(
            submit(&mut app, "/model 2"),
            Action::Send(Request::SetModel("qwen3:8b".into()))
        );
        app.on_agent(AgentEvent::ModelChanged("qwen3:8b".into()));
        assert_eq!(app.model, "qwen3:8b");
        assert!(!app.busy);

        assert_eq!(
            submit(&mut app, "/model llama3.2:3b"),
            Action::Send(Request::SetModel("llama3.2:3b".into()))
        );
        app.on_agent(AgentEvent::Error("not installed".into()));

        assert_eq!(submit(&mut app, "/model 9"), Action::None);
        assert_eq!(submit(&mut app, "/bogus"), Action::None);
        assert!(matches!(app.chat.last(), Some(ChatLine::Error(e)) if e.contains("/models")));
        assert!(!app.busy);
    }

    #[test]
    fn finished_tool_replaces_its_running_entry() {
        let mut app = App::new("m", "d");
        app.on_agent(AgentEvent::ToolStarted {
            command: "edw profile list".into(),
        });
        let result = EdwResult {
            command: "edw profile list".into(),
            exit_code: 0,
            output: "Mnemonic 0".into(),
        };
        app.on_agent(AgentEvent::ToolFinished(result.clone()));
        assert_eq!(app.log, [LogEntry::Finished(result)]);
    }

    #[test]
    fn tab_cycles_views_for_clean_selection() {
        let mut app = App::new("m", "d");
        assert_eq!(app.view, View::Split);
        app.on_key(key(KeyCode::Tab));
        assert_eq!(app.view, View::Chat);
        app.on_key(key(KeyCode::Tab));
        assert_eq!(app.view, View::Log);
        app.on_key(key(KeyCode::Tab));
        assert_eq!(app.view, View::Split);
    }

    #[test]
    fn copy_puts_the_reply_log_or_address_on_the_clipboard() {
        let mut app = App::new("m", "d");
        assert_eq!(submit(&mut app, "/copy"), Action::None, "nothing yet");
        app.on_agent(AgentEvent::Reply("You have 10 ETH.".into()));
        app.on_agent(AgentEvent::ToolFinished(EdwResult {
            command: "interim balance --from 0/0".into(),
            exit_code: 0,
            output: "10 ETH".into(),
        }));
        assert_eq!(
            submit(&mut app, "/copy"),
            Action::Copy("You have 10 ETH.".into())
        );
        assert_eq!(
            submit(&mut app, "/copy log"),
            Action::Copy("$ interim balance --from 0/0\n10 ETH".into())
        );
        assert_eq!(submit(&mut app, "/copy address"), Action::None);
        app.on_agent(AgentEvent::ProfileChanged {
            selector: "0/0".into(),
            address: "0xabc".into(),
            by_model: false,
        });
        assert_eq!(
            submit(&mut app, "/copy address"),
            Action::Copy("0xabc".into())
        );
        assert!(!app.busy, "copying never waits on the agent");
    }

    #[test]
    fn a_paste_is_typed_text_and_never_submits() {
        let mut app = App::new("m", "d");
        app.on_paste("send 1 ETH to\n0xabc\r\n");
        assert_eq!(app.input, "send 1 ETH to 0xabc  ");
        assert!(!app.busy && app.chat.is_empty());
    }
}
