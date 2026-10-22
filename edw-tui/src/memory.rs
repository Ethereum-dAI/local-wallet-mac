//! Working memory: keeps the chat history inside a token budget.
//!
//! The history is the agent's only memory (see [`crate::agent::run`]) and it used to grow
//! without bound, so a long session ended in a context overflow on a small Ollama model.
//! [`compact`] drops the oldest whole turns once the history is over budget and folds each
//! dropped turn into a one-line digest at the front, so the model still knows what was asked
//! and answered earlier.
//!
//! Deliberately mechanical: the digest is cut from the messages themselves, never written by
//! a model, so it cannot invent an address or an amount, and it never copies tool output
//! (large, and not the user's words). Nothing here is persisted: the `ADDR_n` aliases in the
//! history are only meaningful inside one session (see [`crate::addresses`]).

use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

use rig_agent::completion::CompletionRequest;
use rig_core::message::{AssistantContent, Message, UserContent};
use serde_json::Value;

/// Env var that pins the history budget in estimated tokens; `0` or `off` disables compaction.
/// Unset, the budget follows from the model's window (see [`Window::history_budget`]).
pub const BUDGET_ENV: &str = "EDW_TUI_HISTORY_TOKENS";

/// Env var for the context window edw-tui asks Ollama for, in tokens; never above what the
/// model supports.
pub const WINDOW_ENV: &str = "EDW_TUI_NUM_CTX";

/// The window asked for when [`WINDOW_ENV`] is unset. Ollama's own default can be 4096, which
/// the system prompt and the tool schemas alone nearly fill.
pub const DEFAULT_WINDOW: usize = 8192;

/// System prompt plus tool schemas, assumed until a real request has measured them.
const DEFAULT_FIXED: usize = 3000;

/// The history never shrinks below this, whatever the window leaves.
const MIN_BUDGET: usize = 512;

/// Digest lines kept; the oldest go first.
const MAX_DIGEST_LINES: usize = 24;
const ASKED_CHARS: usize = 120;
const ANSWERED_CHARS: usize = 160;

const DIGEST_HEADER: &str = "[Earlier in this session, shortened to fit the context. Tool output is gone; run the command again if you need it.]";
const DIGEST_ACK: &str = "Understood.";

/// How the history budget is chosen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Policy {
    Off,
    /// Exactly this many estimated tokens.
    Fixed(usize),
    /// Whatever the model's window leaves after the system prompt, tool schemas and a reply.
    Auto,
}

pub fn policy_from_env() -> Policy {
    parse_policy(std::env::var(BUDGET_ENV).ok().as_deref())
}

fn parse_policy(value: Option<&str>) -> Policy {
    match value.map(str::trim) {
        None | Some("") => Policy::Auto,
        Some(v) if v.eq_ignore_ascii_case("off") => Policy::Off,
        Some(v) => match v.parse::<usize>() {
            Ok(0) => Policy::Off,
            Ok(n) => Policy::Fixed(n),
            Err(_) => Policy::Auto,
        },
    }
}

/// The window to ask Ollama for: [`WINDOW_ENV`] or [`DEFAULT_WINDOW`].
pub fn wanted_window_from_env() -> usize {
    parse_window(std::env::var(WINDOW_ENV).ok().as_deref())
}

fn parse_window(value: Option<&str>) -> usize {
    value
        .and_then(|v| v.trim().parse::<usize>().ok())
        .filter(|&n| n > 0)
        .unwrap_or(DEFAULT_WINDOW)
}

/// The wanted window, lowered to what the model supports when that is known.
pub fn pick_window(wanted: usize, model_max: Option<usize>) -> usize {
    model_max
        .filter(|&m| m > 0)
        .map_or(wanted, |m| wanted.min(m))
}

/// A model's trained context length from an Ollama `/api/show` reply: `model_info` has one
/// `<architecture>.context_length` entry.
pub fn context_length(show: &Value) -> Option<usize> {
    show.get("model_info")?
        .as_object()?
        .iter()
        .find(|(key, _)| key.ends_with(".context_length"))
        .and_then(|(_, value)| value.as_u64())
        .map(|n| n as usize)
}

/// Room kept for the model's reply and the tool results of the turn in progress.
fn reserve(window: usize) -> usize {
    (window / 4).max(1024)
}

/// The history budget a window leaves once `fixed` tokens of prompt and schemas are paid for.
pub fn derived_budget(window: usize, fixed: usize) -> usize {
    window
        .saturating_sub(fixed + reserve(window))
        .max(MIN_BUDGET)
}

/// The context window of the current model, shared by every handle for it. Switching models
/// sets a new value; requests already built read it when they are sent.
#[derive(Clone, Debug, Default)]
pub struct Window(Arc<Sizes>);

#[derive(Debug, Default)]
struct Sizes {
    /// The window sent as `num_ctx`; 0 until known.
    window: AtomicUsize,
    /// System prompt plus tool schemas, as measured on the last request; 0 until then.
    fixed: AtomicUsize,
}

impl Window {
    pub fn set(&self, window: usize) {
        self.0.window.store(window, Ordering::Relaxed);
    }

    pub fn get(&self) -> Option<usize> {
        Some(self.0.window.load(Ordering::Relaxed)).filter(|&n| n > 0)
    }

    /// The budget for the history alone, or `None` when compaction is off.
    pub fn history_budget(&self) -> Option<usize> {
        match policy_from_env() {
            Policy::Off => None,
            Policy::Fixed(n) => Some(n),
            Policy::Auto => {
                let fixed = match self.0.fixed.load(Ordering::Relaxed) {
                    0 => DEFAULT_FIXED,
                    n => n,
                };
                Some(derived_budget(self.get().unwrap_or(DEFAULT_WINDOW), fixed))
            }
        }
    }

    /// Last step before a request leaves: pins Ollama's window to the one the budget is
    /// computed from, measures what the prompt and schemas cost, and compacts the request's
    /// copy of the history. This also covers the tool loop inside one chat turn, where the
    /// history grows between model calls.
    pub fn prepare(&self, request: &mut CompletionRequest) {
        let system = request
            .chat_history
            .iter()
            .take_while(|m| matches!(m, Message::System { .. }))
            .count();
        let fixed = request.preamble.as_deref().map_or(0, |p| p.len() / 4)
            + serde_json::to_string(&request.tools).map_or(0, |t| t.len() / 4)
            + estimate_all(&request.chat_history[..system]);
        self.0.fixed.store(fixed, Ordering::Relaxed);
        if let Some(window) = self.get() {
            let params = request
                .additional_params
                .get_or_insert_with(|| serde_json::json!({}));
            if let Some(params) = params.as_object_mut() {
                params.insert("num_ctx".into(), window.into());
            }
        }
        if let Some(budget) = self.history_budget() {
            compact(&mut request.chat_history, budget);
        }
    }
}

/// Rough token count: a quarter of the serialized size. Over-counts JSON framing on purpose,
/// so the real prompt lands under the budget.
pub fn estimate(message: &Message) -> usize {
    serde_json::to_string(message).map_or(0, |json| json.len() / 4 + 4)
}

pub fn estimate_all(history: &[Message]) -> usize {
    history.iter().map(estimate).sum()
}

/// Folds the oldest whole turns into the digest until `history` fits `budget`; returns how
/// many turns were folded. The latest turn is always kept, even when it alone is over budget.
///
/// A turn runs from a user prompt to the next one, so a tool call and its result are never
/// split.
pub fn compact(history: &mut Vec<Message>, budget: usize) -> usize {
    // Leading system messages are the prompt, not the conversation: never counted or dropped.
    let system = history
        .iter()
        .take_while(|m| matches!(m, Message::System { .. }))
        .count();
    if estimate_all(&history[system..]) <= budget {
        return 0;
    }
    let (mut lines, body_start) = split_digest(history, system);
    let starts = turn_starts(history, body_start);
    if starts.len() < 2 {
        return 0;
    }
    let mut folded = 0;
    let mut cut = starts[starts.len() - 1];
    for k in 1..starts.len() {
        let candidate = digest_with(&lines, &history[body_start..starts[k]]);
        if estimate_all(&digest_messages(&candidate)) + estimate_all(&history[starts[k]..])
            <= budget
        {
            folded = k;
            cut = starts[k];
            lines = candidate;
            break;
        }
    }
    if folded == 0 {
        folded = starts.len() - 1;
        lines = digest_with(&lines, &history[body_start..cut]);
    }
    let mut compacted = history[..system].to_vec();
    compacted.extend(digest_messages(&lines));
    compacted.extend(history.drain(cut..));
    *history = compacted;
    folded
}

/// The digest lines already at the front of `history` and where the real turns begin.
fn split_digest(history: &[Message], from: usize) -> (Vec<String>, usize) {
    match history.get(from).and_then(prompt_text) {
        Some(text) if text.starts_with(DIGEST_HEADER) => (
            text.lines()
                .filter(|line| line.starts_with("- "))
                .map(str::to_owned)
                .collect(),
            (from + 2).min(history.len()),
        ),
        _ => (Vec::new(), from),
    }
}

fn digest_messages(lines: &[String]) -> Vec<Message> {
    vec![
        Message::user(format!("{DIGEST_HEADER}\n{}", lines.join("\n"))),
        Message::assistant(DIGEST_ACK),
    ]
}

fn digest_with(existing: &[String], dropped: &[Message]) -> Vec<String> {
    let mut lines = existing.to_vec();
    let mut asked: Option<String> = None;
    let mut answered: Option<String> = None;
    let mut flush = |asked: &mut Option<String>, answered: &mut Option<String>| {
        if let Some(question) = asked.take() {
            lines.push(match answered.take() {
                Some(answer) => format!("- you: {question} | me: {answer}"),
                None => format!("- you: {question}"),
            });
        }
    };
    for message in dropped {
        if let Some(text) = prompt_text(message) {
            flush(&mut asked, &mut answered);
            asked = Some(clip(&text, ASKED_CHARS));
        } else if let Some(text) = assistant_text(message) {
            answered = Some(clip(&text, ANSWERED_CHARS));
        }
    }
    flush(&mut asked, &mut answered);
    let extra = lines.len().saturating_sub(MAX_DIGEST_LINES);
    lines.drain(..extra);
    lines
}

/// Indices of the user prompts (user messages carrying text, not tool results).
fn turn_starts(history: &[Message], from: usize) -> Vec<usize> {
    (from..history.len())
        .filter(|&i| prompt_text(&history[i]).is_some())
        .collect()
}

fn prompt_text(message: &Message) -> Option<String> {
    let Message::User { content } = message else {
        return None;
    };
    if content
        .iter()
        .any(|part| matches!(part, UserContent::ToolResult(_)))
    {
        return None;
    }
    let text: Vec<&str> = content
        .iter()
        .filter_map(|part| match part {
            UserContent::Text(text) => Some(text.text.as_str()),
            _ => None,
        })
        .collect();
    (!text.is_empty()).then(|| text.join(" "))
}

fn assistant_text(message: &Message) -> Option<String> {
    let Message::Assistant { content, .. } = message else {
        return None;
    };
    let text: Vec<&str> = content
        .iter()
        .filter_map(|part| match part {
            AssistantContent::Text(text) => Some(text.text.as_str()),
            _ => None,
        })
        .collect();
    let joined = text.join(" ");
    (!joined.trim().is_empty()).then_some(joined)
}

/// One line, at most `max` characters.
fn clip(text: &str, max: usize) -> String {
    let one_line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if one_line.chars().count() <= max {
        return one_line;
    }
    let mut clipped: String = one_line.chars().take(max).collect();
    clipped.push('…');
    clipped
}

#[cfg(test)]
mod tests {
    use rig_core::message::{ToolCall, ToolCallId, ToolFunction, ToolResult};

    use super::*;

    fn turn(history: &mut Vec<Message>, prompt: &str, reply: &str) {
        history.push(Message::user(prompt));
        history.push(Message::assistant(reply));
    }

    fn tool_turn(history: &mut Vec<Message>, prompt: &str, output: &str) {
        history.push(Message::user(prompt));
        history.push(Message::Assistant {
            id: None,
            content: vec![AssistantContent::ToolCall(ToolCall::new(
                ToolCallId::new("call-1").unwrap(),
                ToolFunction::new("balance".into(), serde_json::json!({})),
            ))],
        });
        history.push(Message::tool_result("call-1", "balance", output));
        history.push(Message::assistant("done"));
    }

    fn texts(history: &[Message]) -> Vec<String> {
        history
            .iter()
            .filter_map(|m| prompt_text(m).or_else(|| assistant_text(m)))
            .collect()
    }

    #[test]
    fn under_budget_is_untouched() {
        let mut history = Vec::new();
        turn(&mut history, "hi", "hello");
        let before = history.clone();
        assert_eq!(compact(&mut history, 10_000), 0);
        assert_eq!(history, before);
    }

    #[test]
    fn drops_oldest_turns_and_keeps_a_digest() {
        let mut history = Vec::new();
        for i in 0..10 {
            turn(
                &mut history,
                &format!("question {i} {}", "x".repeat(1200)),
                &format!("answer {i}"),
            );
        }
        let budget = estimate_all(&history) / 2;
        let folded = compact(&mut history, budget);
        assert!(folded > 0);
        assert!(estimate_all(&history) <= budget);
        let all = texts(&history);
        assert!(all[0].starts_with(DIGEST_HEADER));
        assert!(all[0].contains("- you: question 0"));
        assert!(all[0].contains("me: answer 0"));
        // The newest turn survives verbatim.
        assert!(all.iter().any(|t| t.starts_with("question 9")));
        assert!(all.last().unwrap() == "answer 9");
    }

    #[test]
    fn never_splits_a_tool_call_from_its_result() {
        let mut history = Vec::new();
        for i in 0..6 {
            tool_turn(&mut history, &format!("balance {i}"), &"o".repeat(400));
        }
        let budget = estimate_all(&history) / 3;
        compact(&mut history, budget);
        // Every remaining tool result is preceded by the assistant message that called it.
        for (i, message) in history.iter().enumerate() {
            if let Message::User { content } = message
                && content
                    .iter()
                    .any(|part| matches!(part, UserContent::ToolResult(ToolResult { .. })))
            {
                assert!(matches!(&history[i - 1], Message::Assistant { content, .. }
                    if content.iter().any(|c| matches!(c, AssistantContent::ToolCall(_)))));
            }
        }
        // The first real message after the digest is a user prompt.
        assert!(prompt_text(&history[2]).is_some());
    }

    #[test]
    fn digest_never_carries_tool_output() {
        let mut history = Vec::new();
        for i in 0..6 {
            tool_turn(&mut history, &format!("balance {i}"), "SECRET-TOOL-OUTPUT");
        }
        let budget = estimate_all(&history) / 3;
        compact(&mut history, budget);
        assert!(!texts(&history)[0].contains("SECRET-TOOL-OUTPUT"));
    }

    #[test]
    fn keeps_the_last_turn_even_when_it_alone_is_over_budget() {
        let mut history = Vec::new();
        turn(&mut history, "old", "old reply");
        turn(&mut history, &"big ".repeat(2000), "ok");
        assert_eq!(compact(&mut history, 50), 1);
        assert!(texts(&history).iter().any(|t| t.starts_with("big ")));
        // A single turn cannot be shortened further.
        let mut single = Vec::new();
        turn(&mut single, &"big ".repeat(2000), "ok");
        assert_eq!(compact(&mut single, 50), 0);
    }

    #[test]
    fn compacting_twice_extends_one_digest() {
        let mut history = Vec::new();
        for i in 0..8 {
            turn(&mut history, &format!("first {i} {}", "x".repeat(300)), "r");
        }
        let budget = estimate_all(&history) / 2;
        compact(&mut history, budget);
        for i in 0..8 {
            turn(
                &mut history,
                &format!("second {i} {}", "x".repeat(300)),
                "r",
            );
        }
        let budget = estimate_all(&history) / 3;
        compact(&mut history, budget);
        let all = texts(&history);
        let digests = all.iter().filter(|t| t.starts_with(DIGEST_HEADER)).count();
        assert_eq!(digests, 1);
        assert!(all[0].contains("first 0"));
        assert!(all[0].contains("second 0"));
    }

    #[test]
    fn digest_is_capped() {
        let mut history = Vec::new();
        for i in 0..100 {
            turn(&mut history, &format!("q{i}"), "a");
        }
        compact(&mut history, 200);
        let digest = &texts(&history)[0];
        assert!(digest.lines().filter(|l| l.starts_with("- ")).count() <= MAX_DIGEST_LINES);
        assert!(digest.contains("q95") || digest.contains("q9"));
    }

    #[test]
    fn policy_env_values() {
        assert_eq!(parse_policy(None), Policy::Auto);
        assert_eq!(parse_policy(Some("")), Policy::Auto);
        assert_eq!(parse_policy(Some("3000")), Policy::Fixed(3000));
        assert_eq!(parse_policy(Some("0")), Policy::Off);
        assert_eq!(parse_policy(Some("OFF")), Policy::Off);
        assert_eq!(parse_policy(Some("nonsense")), Policy::Auto);
    }

    #[test]
    fn window_is_capped_by_the_model() {
        assert_eq!(parse_window(None), DEFAULT_WINDOW);
        assert_eq!(parse_window(Some("16384")), 16384);
        assert_eq!(parse_window(Some("0")), DEFAULT_WINDOW);
        assert_eq!(pick_window(8192, Some(4096)), 4096);
        assert_eq!(pick_window(8192, Some(131_072)), 8192);
        assert_eq!(pick_window(8192, None), 8192);
        assert_eq!(pick_window(8192, Some(0)), 8192);
    }

    #[test]
    fn reads_the_context_length_whatever_the_architecture() {
        let qwen = serde_json::json!({"model_info": {
            "general.architecture": "qwen3",
            "qwen3.block_count": 36,
            "qwen3.context_length": 40960
        }});
        assert_eq!(context_length(&qwen), Some(40960));
        let gemma = serde_json::json!({"model_info": {"gemma4.context_length": 131072}});
        assert_eq!(context_length(&gemma), Some(131_072));
        assert_eq!(context_length(&serde_json::json!({})), None);
    }

    #[test]
    fn budget_leaves_room_for_the_prompt_and_a_reply() {
        // 8192 window, 3000 of prompt and schemas, a quarter (2048) for the reply.
        assert_eq!(derived_budget(8192, 3000), 8192 - 3000 - 2048);
        // The reply reserve has a floor of 1024.
        assert_eq!(derived_budget(2048, 500), 2048 - 500 - 1024);
        // A window the prompt alone fills still leaves the minimum.
        assert_eq!(derived_budget(4096, 6000), MIN_BUDGET);
    }

    fn request(history: Vec<Message>) -> CompletionRequest {
        let mut request: CompletionRequest = serde_json::from_value(serde_json::json!({
            "model": null, "preamble": "p".repeat(400), "chat_history": [], "documents": [],
            "tools": [], "temperature": null, "max_tokens": null, "tool_choice": null,
            "additional_params": null, "output_schema": null
        }))
        .expect("request");
        request.chat_history = history;
        request
    }

    #[test]
    fn prepare_pins_the_window_and_measures_the_prompt() {
        let window = Window::default();
        window.set(4096);
        let mut req = request(vec![Message::user("hi")]);
        window.prepare(&mut req);
        assert_eq!(req.additional_params.unwrap()["num_ctx"], 4096);
        assert!(window.0.fixed.load(Ordering::Relaxed) >= 100);
    }

    #[test]
    fn prepare_keeps_a_leading_system_message_and_the_newest_turn() {
        let window = Window::default();
        window.set(4096);
        let mut history = vec![Message::System {
            content: "SYSTEM RULES".into(),
        }];
        for i in 0..30 {
            turn(&mut history, &format!("q{i} {}", "x".repeat(600)), "a");
        }
        let mut req = request(history);
        window.prepare(&mut req);
        let history = req.chat_history;
        assert!(matches!(&history[0], Message::System { content } if content == "SYSTEM RULES"));
        assert!(texts(&history).iter().any(|t| t.starts_with("q29")));
        let budget = window.history_budget().unwrap();
        assert!(estimate_all(&history[1..]) <= budget);
    }
}
