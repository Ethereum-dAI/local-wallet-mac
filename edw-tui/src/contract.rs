//! The model-facing contract: everything the LLM is given, in the bytes the harness sends.
//!
//! `edw-tui tools-dump` prints it. Evals read that output instead of keeping their own copy,
//! and `contract.json` next to `Cargo.toml` is the committed snapshot a test holds it to, so
//! any change to what the model sees shows up as a diff in review.
//!
//! What is in the contract is what evals depend on: tool names, descriptions, parameter
//! schemas, the preamble and the request settings. How a call maps onto edw's argv is not;
//! that is the adapter in [`crate::edw`], held to the pinned edw by its own tests. The edw
//! revision is deliberately left out too: bumping the pin must not look like a contract change.

use rig_core::{completion::ToolDefinition, providers::ollama};
use serde_json::{Value, json};

use crate::{
    agent::{MAX_TURNS, additional_params, preamble},
    edw::TOOLS,
};

/// Bump when a change alters what a correct answer is (a tool's meaning, or a removed or
/// renamed tool), so eval results from before and after are never compared as equals.
/// Rewording a description or adding a tool does not need a bump; the diff shows it.
///
/// 2: `transfer`/`swap` (the app's schemas) and `balance` added, and the app's safety clause
/// appended. "send 1 ETH to 0x…" is now a call, where under 1 it was a refusal.
pub const CONTRACT_VERSION: u32 = 2;

pub fn dump() -> Value {
    // Rig's own conversion, so the tool list is exactly what the Ollama request carries.
    let tools: Vec<ollama::ToolDefinition> = TOOLS
        .iter()
        .map(|tool| {
            ToolDefinition {
                name: tool.name.to_owned(),
                description: tool.description.to_owned(),
                parameters: (tool.parameters)(),
            }
            .into()
        })
        .collect();
    json!({
        "contract_version": CONTRACT_VERSION,
        "preamble": preamble(),
        "tools": tools,
        "confirmation_required": TOOLS.iter().filter(|t| t.mutating || t.moves_value).map(|t| t.name).collect::<Vec<_>>(),
        "reviewed_dry_run": TOOLS.iter().filter(|t| t.moves_value).map(|t| t.name).collect::<Vec<_>>(),
        "request": {"max_turns": MAX_TURNS, "additional_params": additional_params()},
    })
}

pub fn dump_pretty() -> String {
    let mut text = serde_json::to_string_pretty(&dump()).expect("serializable");
    text.push('\n');
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_the_committed_snapshot() {
        let committed = include_str!("../contract.json");
        assert!(
            committed == dump_pretty(),
            "the model-facing contract changed; if intended, run \
             `cargo run -- tools-dump > contract.json` and review the diff \
             (bump CONTRACT_VERSION if a correct answer changed)"
        );
    }

    #[test]
    fn lists_every_tool_in_rigs_wire_format() {
        let dump = dump();
        let tools = dump["tools"].as_array().unwrap();
        assert_eq!(tools.len(), TOOLS.len());
        for (tool, spec) in tools.iter().zip(&TOOLS) {
            assert_eq!(tool["type"], "function");
            assert_eq!(tool["function"]["name"], spec.name);
            assert_eq!(tool["function"]["parameters"], (spec.parameters)());
        }
    }
}
