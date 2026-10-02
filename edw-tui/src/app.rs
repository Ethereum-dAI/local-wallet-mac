//! UI state. Pure: keys and agent events go in, state and actions come out, so it is testable
//! without a terminal.

use std::{
    collections::{BTreeMap, VecDeque},
    time::{Duration, Instant},
};

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use tokio::sync::oneshot;

use crate::{
    agent::{AgentEvent, Request, SkillOp},
    edw::EdwResult,
    skills::{SkillRow, consent::ConsentRequest},
};

pub const HELP: &str = "/models lists installed models · /model <name or number> switches (history is kept) · /profile <name or 0/1> picks who sends · /skills (or Tab) opens the Skills tab: enable, disable, add, delete · /copy [reply|log|address] copies to the clipboard · ↑↓ scroll the chat, Shift+↑↓ the command log (PgUp/PgDn too) · ←→ Home End move in the message · Tab shows one panel at a time, for selecting text · /help";

/// How long a confirmation must be on screen before y or n counts.
pub const CONFIRM_GRACE: Duration = Duration::from_millis(400);

/// `~/x` as `$HOME/x`, so a skill folder can be typed the way it is in a shell.
fn expand_home(path: &str) -> std::path::PathBuf {
    match (path.strip_prefix('~'), std::env::var("HOME")) {
        (Some(rest), Ok(home)) if rest.is_empty() || rest.starts_with('/') => {
            std::path::PathBuf::from(format!("{home}{rest}"))
        }
        _ => std::path::PathBuf::from(path),
    }
}

/// Which panels are on screen. A terminal selects whole screen rows, so text is copied
/// cleanly only when one panel fills the width.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum View {
    #[default]
    Split,
    Chat,
    Log,
    /// Installed skills: enable, disable, add, delete.
    Skills,
}

impl View {
    fn next(self) -> Self {
        match self {
            View::Split => View::Chat,
            View::Chat => View::Log,
            View::Log => View::Skills,
            View::Skills => View::Split,
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

/// One panel's scroll position. `None` follows the newest lines; `Some(row)` pins the first
/// visible wrapped row, so lines arriving below never move what is on screen.
#[derive(Debug, Default)]
pub struct PanelScroll {
    top: Option<usize>,
    /// (total wrapped rows, visible rows) as the last render saw them; keys page by these.
    seen: std::cell::Cell<(usize, usize)>,
}

impl PanelScroll {
    pub fn top(&self) -> Option<usize> {
        self.top
    }

    pub fn following(&self) -> bool {
        self.top.is_none()
    }

    /// Called by the renderer with the panel's size; returns the first row to show.
    pub fn observe(&self, total: usize, height: usize) -> usize {
        self.seen.set((total, height));
        let last_top = total.saturating_sub(height);
        self.top.map_or(last_top, |top| top.min(last_top))
    }

    fn page(&self) -> (usize, usize) {
        let (total, height) = self.seen.get();
        (
            total.saturating_sub(height),
            height.saturating_sub(1).max(1),
        )
    }

    pub fn up(&mut self) {
        let (last_top, page) = self.page();
        if last_top == 0 {
            return;
        }
        let from = self.top.unwrap_or(last_top).min(last_top);
        self.top = Some(from.saturating_sub(page));
    }

    pub fn down(&mut self) {
        let (last_top, page) = self.page();
        if let Some(top) = self.top {
            let next = top + page;
            self.top = (next < last_top).then_some(next);
        }
    }

    pub fn follow(&mut self) {
        self.top = None;
    }

    /// `rows` up (negative) or down; reaching the bottom follows the newest lines again.
    pub fn by(&mut self, rows: isize) {
        let (last_top, _) = self.page();
        if last_top == 0 {
            return;
        }
        let from = self.top.unwrap_or(last_top).min(last_top);
        let to = from.saturating_add_signed(rows).min(last_top);
        self.top = (to < last_top).then_some(to);
    }
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
    /// ↑↓ (or PgUp/PgDn) scroll the chat, Shift+↑↓ the command log; scrolling to the bottom,
    /// or sending a message, follows the newest lines again.
    pub chat_scroll: PanelScroll,
    /// Where typing goes in `input`, in characters.
    pub cursor: usize,
    pub log_scroll: PanelScroll,
    /// Skills waiting for the user's approval, shown one card at a time before chatting.
    pub consents: VecDeque<ConsentRequest>,
    pub consent_scroll: u16,
    /// How many cards this round had, for "(2 of 3)".
    pub consent_total: usize,
    consent_answers: BTreeMap<String, bool>,
    consent_shown: Option<Instant>,
    /// `/skills`: one line per installed skill and its state, from startup.
    pub skills: Vec<String>,
    /// The Skills tab: every installed skill, and which one is selected.
    pub skill_rows: Vec<SkillRow>,
    pub skill_selected: usize,
    /// One line under the list: what is happening, or what went wrong.
    pub skill_notice: Option<String>,
    /// A delete waiting for y or n.
    pub skill_delete: Option<String>,
    /// The folder path being typed after `a`.
    pub skill_add: Option<String>,
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
            chat_scroll: PanelScroll::default(),
            cursor: 0,
            log_scroll: PanelScroll::default(),
            consents: VecDeque::new(),
            consent_scroll: 0,
            consent_total: 0,
            consent_answers: BTreeMap::new(),
            consent_shown: None,
            skills: Vec::new(),
            skill_rows: Vec::new(),
            skill_selected: 0,
            skill_notice: None,
            skill_delete: None,
            skill_add: None,
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
        if self.view == View::Skills {
            return self.on_skills_key(key.code);
        }
        match key.code {
            KeyCode::Enter if !self.busy => {
                let prompt = self.input.trim().to_owned();
                self.input.clear();
                self.cursor = 0;
                // A new message: both panels show the newest lines again.
                self.chat_scroll.follow();
                self.log_scroll.follow();
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
            // Scrolling. Mac terminals keep PageUp/PageDown for their own scrollback, so the
            // arrows do it too: ↑↓ the chat, Shift+↑↓ the command log; a single-panel view
            // scrolls the panel on screen.
            KeyCode::Up | KeyCode::Down | KeyCode::PageUp | KeyCode::PageDown => {
                let log = match self.view {
                    View::Log => true,
                    View::Chat | View::Skills => false,
                    View::Split => key.modifiers.contains(KeyModifiers::SHIFT),
                };
                let panel = if log {
                    &mut self.log_scroll
                } else {
                    &mut self.chat_scroll
                };
                match key.code {
                    KeyCode::Up => panel.by(-1),
                    KeyCode::Down => panel.by(1),
                    KeyCode::PageUp => panel.up(),
                    _ => panel.down(),
                }
                Action::None
            }
            // Editing the message at the cursor.
            KeyCode::Char('a') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                self.cursor = 0;
                Action::None
            }
            KeyCode::Char('e') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                self.cursor = self.input.chars().count();
                Action::None
            }
            KeyCode::Home => {
                self.cursor = 0;
                Action::None
            }
            KeyCode::End => {
                self.cursor = self.input.chars().count();
                Action::None
            }
            KeyCode::Left => {
                self.cursor = self.cursor.saturating_sub(1);
                Action::None
            }
            KeyCode::Right => {
                self.cursor = (self.cursor + 1).min(self.input.chars().count());
                Action::None
            }
            KeyCode::Char(c) => {
                self.insert(&c.to_string());
                Action::None
            }
            KeyCode::Backspace => {
                if self.cursor > 0 {
                    self.cursor -= 1;
                    let at = self.byte_at(self.cursor);
                    self.input.remove(at);
                }
                Action::None
            }
            KeyCode::Delete => {
                if self.cursor < self.input.chars().count() {
                    let at = self.byte_at(self.cursor);
                    self.input.remove(at);
                }
                Action::None
            }
            KeyCode::Esc => {
                self.input.clear();
                self.cursor = 0;
                Action::None
            }
            _ => Action::None,
        }
    }

    /// The Skills tab: letters are commands here, the message box is not typed into.
    fn on_skills_key(&mut self, code: KeyCode) -> Action {
        let send = |op: SkillOp| Action::Send(Request::Skill(op));
        // Typing a folder path after `a`.
        if let Some(path) = &mut self.skill_add {
            match code {
                KeyCode::Enter => {
                    let typed = self.skill_add.take().unwrap_or_default();
                    let typed = typed.trim();
                    if typed.is_empty() {
                        return Action::None;
                    }
                    let folder = expand_home(typed);
                    self.skill_notice = Some(format!("Checking {}…", folder.display()));
                    return send(SkillOp::Add(folder));
                }
                KeyCode::Esc => self.skill_add = None,
                KeyCode::Backspace => {
                    path.pop();
                }
                KeyCode::Char(c) => path.push(c),
                _ => {}
            }
            return Action::None;
        }
        // A delete waiting for its answer.
        if let Some(name) = self.skill_delete.clone() {
            return match code {
                KeyCode::Char('y' | 'Y') => {
                    self.skill_delete = None;
                    self.skill_notice = Some(format!("Deleting {name}…"));
                    send(SkillOp::Delete(name))
                }
                KeyCode::Char('n' | 'N') | KeyCode::Esc => {
                    self.skill_delete = None;
                    Action::None
                }
                _ => Action::None,
            };
        }
        let selected = self.skill_rows.get(self.skill_selected).cloned();
        match code {
            KeyCode::Tab => self.view = self.view.next(),
            KeyCode::Up => self.skill_selected = self.skill_selected.saturating_sub(1),
            KeyCode::Down => {
                self.skill_selected =
                    (self.skill_selected + 1).min(self.skill_rows.len().saturating_sub(1));
            }
            KeyCode::Char('a') => {
                self.skill_add = Some(String::new());
                self.skill_notice = None;
            }
            KeyCode::Char('d') => {
                if let Some(row) = selected
                    && row.state != "disabled"
                {
                    self.skill_notice = Some(format!("Disabling {}…", row.name));
                    return send(SkillOp::Disable(row.name));
                }
            }
            KeyCode::Char('e') => {
                if let Some(row) = selected
                    && matches!(row.state.as_str(), "disabled" | "declined")
                {
                    self.skill_notice = Some(format!("Enabling {}…", row.name));
                    return send(SkillOp::Enable(row.name));
                }
            }
            KeyCode::Char('x') => {
                if let Some(row) = selected {
                    if row.origin == crate::skills::Origin::Added {
                        self.skill_delete = Some(row.name);
                    } else {
                        self.skill_notice = Some(format!(
                            "{} is shipped with edw-tui, so it cannot be deleted; disable it instead (d).",
                            row.name
                        ));
                    }
                }
            }
            _ => {}
        }
        Action::None
    }

    /// Pasted text goes into the input as typed text; line breaks become spaces, so a paste
    /// never submits half a message.
    pub fn on_paste(&mut self, text: &str) {
        if let Some(path) = &mut self.skill_add {
            path.push_str(text.trim());
            return;
        }
        if self.pending.is_empty() && self.consents.is_empty() && self.view != View::Skills {
            self.insert(&text.replace(['\r', '\n'], " ").replace('\t', " "));
        }
    }

    /// The byte offset of character `index` in the input (its end when past the last).
    fn byte_at(&self, index: usize) -> usize {
        self.input
            .char_indices()
            .nth(index)
            .map_or(self.input.len(), |(at, _)| at)
    }

    fn insert(&mut self, text: &str) {
        let at = self.byte_at(self.cursor);
        self.input.insert_str(at, text);
        self.cursor += text.chars().count();
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
                self.view = View::Skills;
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
            AgentEvent::Consents(requests) => {
                self.skill_notice = None;
                self.ask_consents(requests);
            }
            AgentEvent::SkillsReady { lines, notes, rows } => {
                self.skills = lines;
                self.skill_rows = rows;
                self.skill_notice = (!notes.is_empty()).then(|| notes.join(" "));
                self.skill_selected = self
                    .skill_selected
                    .min(self.skill_rows.len().saturating_sub(1));
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
                // A failed Skills-tab change is shown where it was made, too.
                if self.view == View::Skills {
                    self.skill_notice = Some(error.clone());
                }
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
            rows: vec![],
        });
        assert!(!app.busy);
        assert_eq!(app.skills, ["alpha (ready)"]);
        assert!(matches!(app.chat.last(), Some(ChatLine::Info(t)) if t.contains("Docker")));
    }

    fn shifted(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::SHIFT)
    }

    #[test]
    fn page_keys_scroll_chat_and_shift_page_keys_scroll_the_log() {
        let mut app = App::new("m", "d");
        // As the last render saw them: 100 rows of chat, 50 of log, 20 visible each.
        app.chat_scroll.observe(100, 20);
        app.log_scroll.observe(50, 20);
        assert!(app.chat_scroll.following() && app.log_scroll.following());

        app.on_key(key(KeyCode::PageUp));
        assert_eq!(
            app.chat_scroll.top(),
            Some(80 - 19),
            "one page up from the bottom"
        );
        assert!(app.log_scroll.following(), "the log does not move");

        app.on_key(shifted(KeyCode::PageUp));
        app.on_key(shifted(KeyCode::PageUp));
        assert_eq!(
            app.log_scroll.top(),
            Some(0),
            "two pages up from row 30 stop at the top"
        );

        app.on_key(key(KeyCode::PageDown));
        assert!(
            app.chat_scroll.following(),
            "paging down to the end follows again"
        );

        app.on_key(shifted(KeyCode::PageDown));
        app.on_key(shifted(KeyCode::PageDown));
        assert!(app.chat_scroll.following() && app.log_scroll.following());
        assert!(app.input.is_empty(), "scroll keys type nothing");
    }

    #[test]
    fn the_cursor_moves_and_edits_in_the_middle_of_a_message() {
        let mut app = App::new("m", "d");
        type_text(&mut app, "helo");
        app.on_key(key(KeyCode::Left));
        type_text(&mut app, "l");
        assert_eq!((app.input.as_str(), app.cursor), ("hello", 4));
        app.on_key(key(KeyCode::Home));
        type_text(&mut app, "é ");
        assert_eq!(app.input, "é hello");
        app.on_key(key(KeyCode::Delete));
        assert_eq!(app.input, "é ello");
        app.on_key(key(KeyCode::Backspace));
        assert_eq!((app.input.as_str(), app.cursor), ("éello", 1));
        app.on_key(key(KeyCode::Right));
        app.on_key(key(KeyCode::Right));
        assert_eq!(app.cursor, 3);
        app.on_key(KeyEvent::new(KeyCode::Char('e'), KeyModifiers::CONTROL));
        assert_eq!(app.cursor, 5, "Ctrl+E goes to the end");
        app.on_key(key(KeyCode::Right));
        assert_eq!(app.cursor, 5, "not past the end");
        app.on_key(KeyEvent::new(KeyCode::Char('a'), KeyModifiers::CONTROL));
        assert_eq!(app.cursor, 0, "Ctrl+A goes to the start");
        app.on_paste("pasted ");
        assert_eq!((app.input.as_str(), app.cursor), ("pasted éello", 7));
        app.on_key(key(KeyCode::End));
        assert_eq!(app.cursor, 12);
        app.on_key(key(KeyCode::Esc));
        assert_eq!((app.input.as_str(), app.cursor), ("", 0));
    }

    /// Mac terminals keep PageUp/PageDown (and Shift+PageUp) for their own scrollback, so the
    /// arrows scroll: ↑↓ the chat, Shift+↑↓ the command log.
    #[test]
    fn arrows_scroll_chat_and_shift_arrows_scroll_the_log() {
        let mut app = App::new("m", "d");
        app.chat_scroll.observe(100, 20);
        app.log_scroll.observe(100, 20);
        app.on_key(key(KeyCode::Up));
        assert_eq!(app.chat_scroll.top(), Some(79), "one row at a time");
        assert!(app.log_scroll.following());
        app.on_key(shifted(KeyCode::Up));
        app.on_key(shifted(KeyCode::Up));
        assert_eq!(app.log_scroll.top(), Some(78));
        app.on_key(key(KeyCode::Down));
        assert!(
            app.chat_scroll.following(),
            "down to the bottom follows again"
        );
        // In a single-panel view the arrows scroll the panel on screen.
        app.view = View::Log;
        app.on_key(key(KeyCode::Up));
        assert_eq!(app.log_scroll.top(), Some(77));
        assert!(app.chat_scroll.following());
    }

    #[test]
    fn sending_a_message_shows_the_newest_lines_again() {
        let mut app = App::new("m", "d");
        app.chat_scroll.observe(100, 20);
        app.log_scroll.observe(100, 20);
        app.on_key(key(KeyCode::Up));
        app.on_key(shifted(KeyCode::Up));
        type_text(&mut app, "hi");
        app.on_key(key(KeyCode::Enter));
        assert!(app.chat_scroll.following() && app.log_scroll.following());
    }

    fn row(name: &str, state: &str, origin: crate::skills::Origin) -> SkillRow {
        SkillRow {
            name: name.into(),
            version: "1".into(),
            state: state.into(),
            note: None,
            description: format!("about {name}"),
            origin,
            dir: std::path::PathBuf::from(format!("/skills/{name}")),
            details: None,
        }
    }

    fn skills_tab() -> App {
        use crate::skills::Origin::*;
        let mut app = App::new("m", "d");
        app.on_agent(AgentEvent::SkillsReady {
            lines: vec![],
            notes: vec![],
            rows: vec![
                row("aave", "ready", Shipped),
                row("lp", "disabled", Added),
                row("data", "ready", Added),
            ],
        });
        app.view = View::Skills;
        app
    }

    fn skill_op(action: Action) -> Option<SkillOp> {
        match action {
            Action::Send(Request::Skill(op)) => Some(op),
            _ => None,
        }
    }

    #[test]
    fn tab_and_slash_skills_reach_the_skills_tab() {
        let mut app = App::new("m", "d");
        for expected in [View::Chat, View::Log, View::Skills, View::Split] {
            app.on_key(key(KeyCode::Tab));
            assert_eq!(app.view, expected);
        }
        type_text(&mut app, "/skills");
        app.on_key(key(KeyCode::Enter));
        assert_eq!(app.view, View::Skills);
        assert!(!app.busy, "opening the tab sends nothing");
    }

    #[test]
    fn the_skills_tab_selects_and_disables_or_enables() {
        let mut app = skills_tab();
        type_text(&mut app, "q");
        assert!(
            app.input.is_empty(),
            "letters are commands here, not typing"
        );
        assert_eq!(
            skill_op(app.on_key(key(KeyCode::Char('d')))),
            Some(SkillOp::Disable("aave".into()))
        );
        app.on_key(key(KeyCode::Down));
        assert_eq!(app.skill_selected, 1);
        assert_eq!(
            skill_op(app.on_key(key(KeyCode::Char('e')))),
            Some(SkillOp::Enable("lp".into()))
        );
        assert_eq!(
            skill_op(app.on_key(key(KeyCode::Char('d')))),
            None,
            "already disabled"
        );
        app.on_key(key(KeyCode::Down));
        app.on_key(key(KeyCode::Down));
        assert_eq!(app.skill_selected, 2, "stops at the last skill");
        app.on_key(key(KeyCode::Up));
        app.on_key(key(KeyCode::Up));
        app.on_key(key(KeyCode::Up));
        assert_eq!(app.skill_selected, 0);
        assert!(!app.busy, "skill changes do not block the chat");
    }

    #[test]
    fn deleting_asks_first_and_only_added_skills() {
        let mut app = skills_tab();
        assert_eq!(skill_op(app.on_key(key(KeyCode::Char('x')))), None);
        assert!(
            app.skill_notice
                .as_deref()
                .unwrap()
                .contains("disable it instead")
        );

        app.on_key(key(KeyCode::Down));
        assert_eq!(
            skill_op(app.on_key(key(KeyCode::Char('x')))),
            None,
            "asks first"
        );
        assert_eq!(app.skill_delete.as_deref(), Some("lp"));
        assert_eq!(skill_op(app.on_key(key(KeyCode::Char('n')))), None);
        assert!(app.skill_delete.is_none(), "n cancels");
        app.on_key(key(KeyCode::Char('x')));
        assert_eq!(
            skill_op(app.on_key(key(KeyCode::Char('y')))),
            Some(SkillOp::Delete("lp".into()))
        );
    }

    #[test]
    fn adding_takes_a_folder_path_with_a_home_shortcut() {
        let mut app = skills_tab();
        app.on_key(key(KeyCode::Char('a')));
        assert_eq!(app.skill_add.as_deref(), Some(""));
        type_text(&mut app, "~/Downloads/lpx");
        app.on_key(key(KeyCode::Backspace));
        let home = std::env::var("HOME").unwrap();
        assert_eq!(
            skill_op(app.on_key(key(KeyCode::Enter))),
            Some(SkillOp::Add(std::path::PathBuf::from(format!(
                "{home}/Downloads/lp"
            ))))
        );
        assert!(app.skill_add.is_none());

        app.on_key(key(KeyCode::Char('a')));
        type_text(&mut app, "x");
        app.on_key(key(KeyCode::Esc));
        assert!(app.skill_add.is_none(), "Esc cancels");
        assert_eq!(skill_op(app.on_key(key(KeyCode::Enter))), None);
    }

    #[test]
    fn a_skills_tab_error_shows_in_the_tab() {
        let mut app = skills_tab();
        app.on_agent(AgentEvent::Error("lp is shipped with edw-tui".into()));
        assert_eq!(
            app.skill_notice.as_deref(),
            Some("lp is shipped with edw-tui")
        );
    }

    #[test]
    fn a_short_panel_does_not_scroll() {
        let mut app = App::new("m", "d");
        app.chat_scroll.observe(5, 20);
        app.on_key(key(KeyCode::PageUp));
        assert!(app.chat_scroll.following());
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
        assert_eq!(app.view, View::Skills);
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
