//! A deterministic stand-in for the LLM, for tests and end-to-end UI runs.
//!
//! Selected with `EDW_TUI_MODEL=scripted`. It maps a few keywords onto tool calls, so the UI,
//! the Rig loop, the confirmation hook and the real `edw` binary can all be exercised without
//! Ollama and without model nondeterminism.

use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

use rig_agent::completion::{
    CompletionError, CompletionModel, CompletionRequest, CompletionResponse, Usage,
};
use rig_agent::streaming::StreamingCompletionResponse;
use rig_core::message::{AssistantContent, Message, ToolCall, ToolFunction, UserContent};
use serde_json::{Value, json};

#[derive(Clone, Default)]
pub struct ScriptedModel {
    calls: Arc<AtomicUsize>,
}

/// What the script does with one user message.
#[derive(Debug, PartialEq)]
pub enum Script {
    Call(&'static str, Value),
    Say(String),
}

pub fn script(prompt: &str) -> Script {
    let text = prompt.to_lowercase();
    let has = |word: &str| {
        text.split(|c: char| !c.is_alphanumeric())
            .any(|w| w == word)
    };
    let named = || {
        let words: Vec<&str> = prompt.split_whitespace().collect();
        words
            .iter()
            .position(|w| w.eq_ignore_ascii_case("named"))
            .and_then(|i| words.get(i + 1))
            .map(|w| w.to_string())
    };

    if has("shield") {
        Script::Say("edw cannot shield yet, so there is nothing I can run for that.".into())
    } else if has("transfer") || has("send") {
        // "send <amount> <token> to <recipient>"
        let words: Vec<&str> = prompt.split_whitespace().collect();
        let at = words.iter().position(|w| w.eq_ignore_ascii_case("to"));
        match (
            at,
            words.iter().position(|w| w.eq_ignore_ascii_case("send")),
        ) {
            (Some(to), Some(send)) if to == send + 3 && to + 1 < words.len() => Script::Call(
                "transfer",
                json!({"to": words[to + 1], "amount": words[send + 1], "token": words[send + 2]}),
            ),
            _ => Script::Say("Say it as: send <amount> <token> to <0x address>.".into()),
        }
    } else if has("swap") {
        // "swap <amount> <token> for|to|into <token>"
        let words: Vec<&str> = prompt.split_whitespace().collect();
        match words.iter().position(|w| w.eq_ignore_ascii_case("swap")) {
            Some(at) if words.len() > at + 4 => Script::Call(
                "swap",
                json!({"from_token": words[at + 2], "to_token": words[at + 4], "amount": words[at + 1], "amount_side": "input"}),
            ),
            _ => Script::Say("Say it as: swap <amount> <token> for <token>.".into()),
        }
    } else if has("use") || has("switch") {
        // "use bob", "switch to profile 1/0": the last word names the profile.
        let profile = prompt.split_whitespace().last().unwrap_or_default();
        Script::Call("use_profile", json!({ "profile": profile }))
    } else if has("address") || has("addresses") {
        Script::Call("profile_addresses", json!({}))
    } else if has("balance") {
        Script::Call("balance", json!({}))
    } else if has("unlock") {
        let network = if has("mainnet") {
            "mainnet"
        } else if has("local") {
            "local"
        } else {
            "sepolia"
        };
        Script::Call("unlock", json!({ "network": network }))
    } else if has("lock") {
        Script::Call("lock", json!({}))
    } else if has("add") && has("profile") {
        Script::Call(
            "add_profile",
            named().map_or(json!({}), |name| json!({ "name": name })),
        )
    } else if (has("create") || has("new")) && (has("profile") || has("seed") || has("mnemonic")) {
        Script::Call(
            "new_mnemonic",
            named().map_or(json!({}), |name| json!({ "name": name })),
        )
    } else if has("profiles") || has("profile") {
        Script::Call("list_profiles", json!({}))
    } else if has("network") || has("networks") {
        Script::Call("list_networks", json!({}))
    } else if has("status") {
        Script::Call("wallet_status", json!({}))
    } else {
        Script::Say(
            "I can unlock or lock the wallet, and list, create, add or rename profiles.".into(),
        )
    }
}

fn response(choice: AssistantContent) -> CompletionResponse {
    CompletionResponse::new(vec![choice], Usage::new(), "scripted")
}

impl CompletionModel for ScriptedModel {
    async fn completion(
        &self,
        request: CompletionRequest,
    ) -> Result<CompletionResponse, CompletionError> {
        let Some(Message::User { content }) = request.chat_history.last() else {
            return Ok(response(AssistantContent::text(
                "(scripted model: no user message)",
            )));
        };
        if content
            .iter()
            .any(|part| matches!(part, UserContent::ToolResult(_)))
        {
            return Ok(response(AssistantContent::text(
                "Done. The command and its output are in the log.",
            )));
        }
        let prompt: String = content
            .iter()
            .filter_map(|part| match part {
                UserContent::Text(text) => Some(text.text.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join(" ");
        Ok(response(match script(&prompt) {
            Script::Say(text) => AssistantContent::text(text),
            Script::Call(name, args) => {
                let id = format!("scripted-{}", self.calls.fetch_add(1, Ordering::Relaxed));
                AssistantContent::ToolCall(ToolCall::from_wire(
                    id,
                    ToolFunction::new(name.to_owned(), args),
                ))
            }
        }))
    }

    async fn stream(
        &self,
        _request: CompletionRequest,
    ) -> Result<StreamingCompletionResponse, CompletionError> {
        Err(CompletionError::ResponseError(
            "the scripted model does not stream".into(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scripts_intents() {
        assert_eq!(
            script("unlock sepolia please"),
            Script::Call("unlock", json!({"network": "sepolia"}))
        );
        assert_eq!(
            script("Unlock mainnet"),
            Script::Call("unlock", json!({"network": "mainnet"}))
        );
        assert_eq!(script("lock it"), Script::Call("lock", json!({})));
        assert_eq!(
            script("show my profiles"),
            Script::Call("list_profiles", json!({}))
        );
        assert_eq!(
            script("add a profile named bob"),
            Script::Call("add_profile", json!({"name": "bob"}))
        );
        assert_eq!(
            script("send 0.1 ETH to 0x000000000000000000000000000000000000bEEF"),
            Script::Call(
                "transfer",
                json!({"to": "0x000000000000000000000000000000000000bEEF", "amount": "0.1", "token": "ETH"})
            )
        );
        assert_eq!(
            script("what is my balance"),
            Script::Call("balance", json!({}))
        );
        assert!(matches!(script("shield 1 ETH"), Script::Say(_)));
        assert_eq!(
            script("swap 0.01 ETH for USDC"),
            Script::Call(
                "swap",
                json!({"from_token": "ETH", "to_token": "USDC", "amount": "0.01", "amount_side": "input"})
            )
        );
    }
}
