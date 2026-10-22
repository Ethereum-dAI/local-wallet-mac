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

use rig_core::message::{AssistantContent, Message, UserContent};

/// Env var for the history budget in estimated tokens; `0` or `off` disables compaction.
pub const BUDGET_ENV: &str = "EDW_TUI_HISTORY_TOKENS";

/// Room left for the system prompt, the tool schemas and one reply on a 8k-context model.
pub const DEFAULT_BUDGET: usize = 5000;

/// Digest lines kept; the oldest go first.
const MAX_DIGEST_LINES: usize = 24;
const ASKED_CHARS: usize = 120;
const ANSWERED_CHARS: usize = 160;

const DIGEST_HEADER: &str = "[Earlier in this session, shortened to fit the context. Tool output is gone; run the command again if you need it.]";
const DIGEST_ACK: &str = "Understood.";

/// The budget from [`BUDGET_ENV`]; `None` when compaction is off.
pub fn budget_from_env() -> Option<usize> {
    parse_budget(std::env::var(BUDGET_ENV).ok().as_deref())
}

fn parse_budget(value: Option<&str>) -> Option<usize> {
    match value.map(str::trim) {
        None | Some("") => Some(DEFAULT_BUDGET),
        Some(v) if v.eq_ignore_ascii_case("off") => None,
        Some(v) => match v.parse::<usize>() {
            Ok(0) => None,
            Ok(n) => Some(n),
            Err(_) => Some(DEFAULT_BUDGET),
        },
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
    if estimate_all(history) <= budget {
        return 0;
    }
    let (mut lines, body_start) = split_digest(history);
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
    let mut compacted = digest_messages(&lines);
    compacted.extend(history.drain(cut..));
    *history = compacted;
    folded
}

/// The digest lines already at the front of `history` and where the real turns begin.
fn split_digest(history: &[Message]) -> (Vec<String>, usize) {
    match history.first().and_then(prompt_text) {
        Some(text) if text.starts_with(DIGEST_HEADER) => (
            text.lines()
                .filter(|line| line.starts_with("- "))
                .map(str::to_owned)
                .collect(),
            2.min(history.len()),
        ),
        _ => (Vec::new(), 0),
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
    fn budget_env_values() {
        assert_eq!(parse_budget(None), Some(DEFAULT_BUDGET));
        assert_eq!(parse_budget(Some("")), Some(DEFAULT_BUDGET));
        assert_eq!(parse_budget(Some("3000")), Some(3000));
        assert_eq!(parse_budget(Some("0")), None);
        assert_eq!(parse_budget(Some("OFF")), None);
        assert_eq!(parse_budget(Some("nonsense")), Some(DEFAULT_BUDGET));
    }
}
