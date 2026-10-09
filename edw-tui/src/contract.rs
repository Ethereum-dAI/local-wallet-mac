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
    agent::{MAX_TURNS, additional_params, preamble_with},
    edw::{self, TOOLS},
    skills::{
        LOAD_SKILL, author, author_tools,
        catalog::{self, Catalog, Installed, SkillState},
        tools::{LOAD_SKILL_DESCRIPTION, load_skill_parameters},
    },
};

/// Bump when a change alters what a correct answer is (a tool's meaning, or a removed or
/// renamed tool), so eval results from before and after are never compared as equals.
/// Rewording a description or adding a tool does not need a bump; the diff shows it.
///
/// 2: `transfer`/`swap` (the app's schemas) and `balance` added, and the app's safety clause
/// appended. "send 1 ETH to 0x…" is now a call, where under 1 it was a refusal.
/// 3: skills. The preamble lists them, `load_skill` loads one, and its tools (in `skills`)
/// are offered only after that, so a correct answer may now start with `load_skill`.
pub const CONTRACT_VERSION: u32 = 3;

/// The skills shipped in this crate's `skills/` folder, as if the user had agreed to all of
/// them and Docker were running: what the model sees in the full setup.
fn shipped_skills() -> (Catalog, Vec<Installed>) {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("skills");
    let mut installed = catalog::discover(&[dir]);
    for i in &mut installed {
        if i.state == SkillState::NeedsConsent {
            i.state = SkillState::Ready;
        }
    }
    catalog::resolve(&mut installed, &edw::tool_names(), true);
    (Catalog::from_installed(&installed), installed)
}

pub fn dump() -> Value {
    // Rig's own conversion, so the tool list is exactly what the Ollama request carries.
    let wire = |name: &str, description: &str, parameters: Value| -> ollama::ToolDefinition {
        ToolDefinition {
            name: name.to_owned(),
            description: description.to_owned(),
            parameters,
        }
        .into()
    };
    let (catalog, installed) = shipped_skills();
    let mut tools: Vec<ollama::ToolDefinition> = TOOLS
        .iter()
        .map(|tool| wire(tool.name, tool.description, (tool.parameters)()))
        .collect();
    if !catalog.skills.is_empty() {
        tools.push(wire(
            LOAD_SKILL,
            LOAD_SKILL_DESCRIPTION,
            load_skill_parameters(),
        ));
    }
    let skills: Vec<Value> = catalog
        .skills
        .iter()
        .map(|skill| {
            let m = &skill.manifest;
            let hash = installed
                .iter()
                .find(|i| i.name == skill.name)
                .map_or("", |i| i.hash.as_str());
            let mut tools: Vec<ollama::ToolDefinition> = m
                .read_tools
                .iter()
                .chain(m.actions.iter().map(|a| &a.tool))
                .map(|t| wire(&t.name, &t.description, t.schema.clone()))
                .collect();
            // The authoring tools come from the harness, not a manifest: loading
            // skill-creator is what offers them.
            if skill.name == author::CREATOR {
                tools.extend(
                    author_tools::specs()
                        .into_iter()
                        .map(|(name, description, schema)| wire(name, description, schema)),
                );
            }
            json!({
                "name": skill.name,
                "version": m.version,
                "sha256": hash,
                "requires": m.requires,
                "body": skill.body,
                "tools": tools,
                "actions": m.actions.iter().map(|a| &a.tool.name).collect::<Vec<_>>(),
            })
        })
        .collect();
    json!({
        "contract_version": CONTRACT_VERSION,
        "preamble": preamble_with(&catalog),
        "tools": tools,
        "skills": skills,
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
        let skills = !dump["skills"].as_array().unwrap().is_empty();
        assert_eq!(tools.len(), TOOLS.len() + usize::from(skills));
        for (tool, spec) in tools.iter().zip(&TOOLS) {
            assert_eq!(tool["type"], "function");
            assert_eq!(tool["function"]["name"], spec.name);
            assert_eq!(tool["function"]["parameters"], (spec.parameters)());
        }
    }
}
