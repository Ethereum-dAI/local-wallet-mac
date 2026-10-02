//! The skills one session may use, which of them the model has loaded, and the hook that
//! offers a skill's tools only once it is loaded.
//!
//! Every ready skill's tools are registered with Rig up front. [`SkillGate`] narrows each
//! request's tool list to the built-ins plus the tools of loaded skills; Rig takes a fresh
//! tool snapshot for every model call, so a `load_skill` in one turn takes effect in the next.

use std::{
    collections::{BTreeMap, BTreeSet},
    path::PathBuf,
    sync::{Arc, Mutex},
};

use alloy_primitives::Address;
use reqwest::Url;
use rig_agent::agent::{
    AgentHook, CompletionCallAction, CompletionCallEvent, HookContext, RequestPatch,
};
use serde_json::{Value, json};

use super::{
    LOAD_SKILL,
    catalog::{Catalog, Installed},
    host::{Host, HostConfig, Log, SharedCache},
    manifest::Skill,
    sandbox::Runner,
};
use crate::interim::SkillContext;

pub struct SkillSet {
    pub catalog: Catalog,
    pub runner: Runner,
    pub cache: SharedCache,
    hashes: BTreeMap<String, String>,
    loaded: Mutex<BTreeSet<String>>,
}

impl SkillSet {
    pub fn new(catalog: Catalog, installed: &[Installed], runner: Runner) -> Self {
        Self {
            hashes: installed
                .iter()
                .map(|i| (i.name.clone(), i.hash.clone()))
                .collect(),
            catalog,
            runner,
            cache: SharedCache::default(),
            loaded: Mutex::default(),
        }
    }

    /// No skills: the agent behaves exactly as it did before skills existed.
    pub fn empty() -> Self {
        Self::new(
            Catalog::default(),
            &[],
            Runner::from_env(PathBuf::from("skills/_sdk")),
        )
    }

    pub fn is_empty(&self) -> bool {
        self.catalog.skills.is_empty()
    }

    pub fn hash(&self, skill: &str) -> &str {
        self.hashes.get(skill).map_or("", String::as_str)
    }

    pub fn is_loaded(&self, skill: &str) -> bool {
        self.loaded.lock().expect("not poisoned").contains(skill)
    }

    /// Loads `name` and everything it requires; returns what the model reads next.
    pub fn load(&self, name: &str) -> String {
        let Some(closure) = self.catalog.closure(name) else {
            let names: Vec<&str> = self
                .catalog
                .skills
                .iter()
                .map(|s| s.name.as_str())
                .collect();
            return format!(
                "There is no skill named `{name}`. Available skills: {}.",
                if names.is_empty() {
                    "none".into()
                } else {
                    names.join(", ")
                }
            );
        };
        let mut loaded = self.loaded.lock().expect("not poisoned");
        let mut parts = Vec::new();
        for skill in closure {
            loaded.insert(skill.name.clone());
            let tools = skill.tool_names();
            parts.push(format!(
                "# Skill {}\n{}\nTools now available: {}",
                skill.name,
                skill.body.trim(),
                if tools.is_empty() {
                    "none (instructions only)".into()
                } else {
                    tools.join(", ")
                }
            ));
        }
        parts.join("\n\n")
    }

    /// Forgets which skills were loaded, with the conversation they were loaded in.
    pub fn reset(&self) {
        self.loaded.lock().expect("not poisoned").clear();
    }

    /// The tool names a request may offer: `builtin` and the tools of loaded skills.
    pub fn active_tools(&self, builtin: &[String]) -> Vec<String> {
        let loaded = self.loaded.lock().expect("not poisoned");
        let mut names = builtin.to_vec();
        for skill in self
            .catalog
            .skills
            .iter()
            .filter(|s| loaded.contains(&s.name))
        {
            names.extend(skill.tool_names().into_iter().map(str::to_owned));
        }
        names
    }

    /// What a script is told besides its arguments: where it runs, and the manifest's
    /// addresses for this chain so it can read them without hard-coding any.
    pub fn context(&self, skill: &Skill, at: &SkillContext) -> Value {
        let m = &skill.manifest;
        let contracts: serde_json::Map<String, Value> = m
            .contracts
            .iter()
            .filter_map(|c| {
                let address = c.address.get(&at.chain_id)?;
                Some((c.id.clone(), json!(address.to_string())))
            })
            .collect();
        let tokens: serde_json::Map<String, Value> = m
            .tokens
            .iter()
            .filter_map(|t| {
                let address = t.address.get(&at.chain_id)?;
                Some((
                    t.id.clone(),
                    json!({"address": address.to_string(), "symbol": t.symbol, "decimals": t.decimals, "movable": t.movable}),
                ))
            })
            .collect();
        json!({
            "chain_id": at.chain_id,
            "me": at.me.to_string(),
            "network": at.network,
            "contracts": contracts,
            "tokens": tokens,
        })
    }

    /// The host calls one run of `skill` may make.
    pub fn host(&self, skill: &Skill, rpc: Option<Url>, log: Log) -> Host {
        let m = &skill.manifest;
        let cache = m
            .read_tools
            .iter()
            .chain(m.actions.iter().map(|a| &a.tool))
            .flat_map(|t| t.cache.clone())
            .collect();
        Host::new(
            HostConfig {
                skill: skill.name.clone(),
                hosts: m.hosts.clone(),
                cache,
                rpc,
                fixtures: None,
                log,
            },
            self.cache.clone(),
        )
    }

    /// Token names for the review's simulated changes, from the manifest.
    pub fn names(&self, skill: &Skill, chain_id: u64) -> BTreeMap<Address, (String, u8)> {
        skill
            .manifest
            .tokens
            .iter()
            .filter_map(|t| Some((*t.address.get(&chain_id)?, (t.symbol.clone(), t.decimals))))
            .collect()
    }
}

/// Offers a skill's tools only after `load_skill`.
pub struct SkillGate {
    pub builtin: Vec<String>,
    pub set: Arc<SkillSet>,
}

impl AgentHook for SkillGate {
    async fn on_completion_call(
        &self,
        _ctx: &HookContext,
        _event: CompletionCallEvent<'_>,
    ) -> CompletionCallAction {
        CompletionCallAction::Patch(
            RequestPatch::new().active_tools(self.set.active_tools(&self.builtin)),
        )
    }
}

/// `load_skill`'s schema, as the model sees it.
pub fn load_skill_parameters() -> Value {
    json!({"type": "object", "required": ["name"], "properties": {
        "name": {"type": "string", "description": "A skill name from the Skills list."}
    }})
}

pub const LOAD_SKILL_DESCRIPTION: &str =
    "Load a skill by name: returns its instructions and makes its tools available.";

/// The built-in tool names plus `load_skill`, which the gate always offers.
pub fn builtin_tools(skills: &SkillSet) -> Vec<String> {
    let mut names: Vec<String> = crate::edw::tool_names()
        .into_iter()
        .map(str::to_owned)
        .collect();
    if !skills.is_empty() {
        names.push(LOAD_SKILL.to_owned());
    }
    names
}
