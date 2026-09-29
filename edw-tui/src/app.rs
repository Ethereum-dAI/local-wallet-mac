//! UI state. Pure: keys and agent events go in, state and actions come out, so it is testable
//! without a terminal.

use std::collections::VecDeque;

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use tokio::sync::oneshot;

use crate::{
    agent::{AgentEvent, Request},
    edw::EdwResult,
};

pub const HELP: &str =
    "/models lists installed models · /model <name or number> switches (history is kept) · /help";

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
    reply: oneshot::Sender<bool>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Action {
    None,
    Send(Request),
    Quit,
}

pub struct App {
    pub model: String,
    pub data_dir: String,
    pub chat: Vec<ChatLine>,
    pub log: Vec<LogEntry>,
    pub input: String,
    pub busy: bool,
    /// The last `/models` listing, so `/model 2` can pick by number.
    pub models: Vec<String>,
    /// Confirmations in arrival order; the model may emit several state changes in one turn.
    pub pending: VecDeque<PendingConfirm>,
}

impl App {
    pub fn new(model: impl Into<String>, data_dir: impl Into<String>) -> Self {
        Self {
            model: model.into(),
            data_dir: data_dir.into(),
            chat: Vec::new(),
            log: Vec::new(),
            input: String::new(),
            busy: false,
            models: Vec::new(),
            pending: VecDeque::new(),
        }
    }

    pub fn on_key(&mut self, key: KeyEvent) -> Action {
        if key.modifiers.contains(KeyModifiers::CONTROL)
            && matches!(key.code, KeyCode::Char('c' | 'd'))
        {
            return Action::Quit;
        }
        if !self.pending.is_empty() {
            match key.code {
                KeyCode::Char('y' | 'Y') | KeyCode::Enter => self.answer(true),
                KeyCode::Char('n' | 'N') | KeyCode::Esc => self.answer(false),
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
    }

    pub fn on_agent(&mut self, event: AgentEvent) {
        match event {
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
            AgentEvent::Confirm { command, reply } => {
                self.pending.push_back(PendingConfirm { command, reply })
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

    #[test]
    fn confirm_prompt_takes_y_or_n_and_logs_a_decline() {
        let mut app = App::new("m", "d");
        let (reply, mut answer) = oneshot::channel();
        app.on_agent(AgentEvent::Confirm {
            command: "edw lock".into(),
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
            reply,
        });
        app.on_key(key(KeyCode::Char('y')));
        assert_eq!(answer.try_recv(), Ok(true));
    }

    #[test]
    fn confirmations_queue_instead_of_replacing_each_other() {
        let mut app = App::new("m", "d");
        let (first, mut first_answer) = oneshot::channel();
        let (second, mut second_answer) = oneshot::channel();
        app.on_agent(AgentEvent::Confirm {
            command: "edw unlock --network local".into(),
            reply: first,
        });
        app.on_agent(AgentEvent::Confirm {
            command: "edw profile add --next".into(),
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
}
