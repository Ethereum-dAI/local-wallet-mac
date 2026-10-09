//! The skills one session may use, which of them the model has loaded, and the hook that
//! offers a skill's tools only once it is loaded.
//!
//! Every ready skill's tools are registered with Rig up front. [`SkillGate`] narrows each
//! request's tool list to the built-ins plus the tools of loaded skills; Rig takes a fresh
//! tool snapshot for every model call, so a `load_skill` in one turn takes effect in the next.

use std::{
    collections::{BTreeMap, BTreeSet},
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
};

use alloy_primitives::Address;
use reqwest::Url;
use rig_agent::agent::{
    AgentHook, CompletionCallAction, CompletionCallEvent, HookContext, RequestPatch,
};
use serde_json::{Value, json};

use super::{
    LOAD_SKILL,
    author::{self, DraftStore},
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
    drafts: Option<DraftStore>,
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
            drafts: None,
        }
    }

    pub fn with_drafts(mut self, drafts: DraftStore) -> Self {
        self.drafts = Some(drafts);
        self
    }

    pub fn drafts(&self) -> Option<&DraftStore> {
        self.drafts.as_ref()
    }

    /// Authoring tools are registered only when `skill-creator` is in the catalog and a drafts
    /// folder is set.
    pub fn authoring_enabled(&self) -> bool {
        self.catalog.get(author::CREATOR).is_some() && self.drafts.is_some()
    }

    /// No skills: the agent behaves exactly as it did before skills existed.
    pub fn empty() -> Self {
        Self::new(Catalog::default(), &[], Runner::from_env())
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

    /// A snapshot of `skill` to run from, checked against the hash the user agreed to. The
    /// script runs from the copy, so an edit, `git pull` or planted file in the live folder
    /// after consent never runs. The copy is removed when the returned guard drops.
    pub fn prepare_run(&self, skill: &Skill) -> Result<(Skill, RunDir), String> {
        static RUNS: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "edw-skill-run-{}-{}",
            std::process::id(),
            RUNS.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).map_err(|e| format!("cannot prepare a run folder ({e})"))?;
        let run = RunDir(std::fs::canonicalize(&dir).unwrap_or(dir));
        let hash = super::lock::snapshot(&skill.dir, &run.0)
            .map_err(|e| format!("{}: {e}; nothing was run.", skill.name))?;
        let agreed = self.hash(&skill.name);
        if hash != agreed {
            return Err(format!(
                "{} changed since you agreed to it (sha256 {} then, {} now); restart edw-tui to review it again. Nothing was run.",
                skill.name,
                &agreed[..agreed.len().min(12)],
                &hash[..12]
            ));
        }
        let mut copy = skill.clone();
        copy.dir = run.0.clone();
        Ok((copy, run))
    }

    /// Keeps the skills `previous` had loaded that are still in this catalog, so a rebuild
    /// after a Skills-tab change does not make the model load them again.
    pub fn carry_loaded(&self, previous: &SkillSet) {
        let before = previous.loaded.lock().expect("not poisoned").clone();
        let mut loaded = self.loaded.lock().expect("not poisoned");
        for name in before {
            if self.catalog.get(&name).is_some() {
                loaded.insert(name);
            }
        }
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
        if loaded.contains(author::CREATOR) {
            names.extend(author::TOOL_NAMES.map(str::to_owned));
        }
        names
    }

    /// What a script is told besides its arguments: where it runs, and the manifest's
    /// addresses for this chain so it can read them without hard-coding any.
    /// With the wallet locked (`at` is `None`) there is no chain, sender or RPC: only read
    /// tools run then, and they see `"wallet": "locked"`.
    pub fn context(&self, skill: &Skill, at: Option<&SkillContext>) -> Value {
        let Some(at) = at else {
            return json!({
                "chain_id": null,
                "me": null,
                "network": null,
                "wallet": "locked",
                "contracts": {},
                "tokens": {},
            });
        };
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
            "wallet": "unlocked",
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

/// A run's snapshot folder; removed on drop.
pub struct RunDir(PathBuf);

impl Drop for RunDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
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

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;
    use crate::skills::catalog::{self, SkillState};

    fn set_with_one_skill(root: &std::path::Path) -> SkillSet {
        let dir = root.join("demo");
        fs::create_dir_all(dir.join("scripts")).unwrap();
        fs::write(
            dir.join("SKILL.md"),
            "---\nname: demo\ndescription: d\n---\nbody\n",
        )
        .unwrap();
        fs::write(dir.join("scripts/run.py"), "print('reviewed')\n").unwrap();
        let mut installed = catalog::discover(&[root.to_owned()]);
        installed[0].state = SkillState::Ready;
        SkillSet::new(
            Catalog::from_installed(&installed),
            &installed,
            Runner::from_env(),
        )
    }

    fn set_with_creator(root: &std::path::Path) -> SkillSet {
        let dir = root.join("skill-creator");
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("SKILL.md"),
            "---\nname: skill-creator\ndescription: Create a new skill from a description or from this chat.\n---\nbody\n",
        )
        .unwrap();
        let mut installed = catalog::discover(&[root.to_owned()]);
        installed[0].state = SkillState::Ready;
        SkillSet::new(
            Catalog::from_installed(&installed),
            &installed,
            Runner::from_env(),
        )
    }

    #[test]
    fn authoring_tools_are_offered_only_once_skill_creator_is_loaded() {
        let root = tempfile::tempdir().unwrap();
        let set = set_with_creator(root.path());
        let builtin = vec!["balance".to_owned()];
        assert_eq!(set.active_tools(&builtin), builtin);
        set.load("skill-creator");
        let active = set.active_tools(&builtin);
        for name in crate::skills::author::TOOL_NAMES {
            assert!(
                active.iter().any(|t| t == name),
                "{name} missing: {active:?}"
            );
        }
    }

    #[test]
    fn a_run_uses_a_snapshot_with_the_agreed_hash() {
        let root = tempfile::tempdir().unwrap();
        let set = set_with_one_skill(root.path());
        let skill = set.catalog.get("demo").unwrap().clone();
        let (copy, run_dir) = set.prepare_run(&skill).unwrap();
        assert_ne!(
            copy.dir, skill.dir,
            "scripts never run from the live folder"
        );
        assert_eq!(
            fs::read_to_string(copy.dir.join("scripts/run.py")).unwrap(),
            "print('reviewed')\n"
        );
        // A change to the live folder after the snapshot does not reach the run.
        fs::write(skill.dir.join("scripts/run.py"), "print('swapped')\n").unwrap();
        assert_eq!(
            fs::read_to_string(copy.dir.join("scripts/run.py")).unwrap(),
            "print('reviewed')\n"
        );
        let path = copy.dir.clone();
        drop(run_dir);
        assert!(!path.exists(), "the snapshot is removed after the run");
    }

    #[test]
    fn a_skill_edited_after_consent_does_not_run() {
        let root = tempfile::tempdir().unwrap();
        let set = set_with_one_skill(root.path());
        let skill = set.catalog.get("demo").unwrap().clone();
        fs::write(skill.dir.join("scripts/run.py"), "print('swapped')\n").unwrap();
        let error = set.prepare_run(&skill).err().unwrap();
        assert!(error.contains("changed since you agreed"), "{error}");
        fs::write(skill.dir.join("scripts/run.py"), "print('reviewed')\n").unwrap();
        fs::write(skill.dir.join("scripts/new.py"), "x").unwrap();
        assert!(
            set.prepare_run(&skill).is_err(),
            "an added file is a change too"
        );
    }

    #[test]
    fn the_protocol_helper_is_edw_tuis_own() {
        let runner = Runner::from_env();
        let sdk = fs::read_to_string(runner.sdk.join("edw_skill.py")).unwrap();
        assert_eq!(sdk, crate::skills::sandbox::SDK);
        assert!(runner.sdk.is_absolute());
    }
}
