//! Skills: folders the agent loads on demand (see the README section "Skills").
//!
//! [`start`] finds them, asks the user about any that are new or changed, and returns the
//! ready ones as a [`tools::SkillSet`] for the agent.

pub mod abi;
pub mod catalog;
pub mod host;
pub mod lock;
pub mod manifest;
pub mod plan;
pub mod sandbox;
pub mod simulate;
pub mod tools;

use std::{path::PathBuf, sync::Arc};

use catalog::{Installed, SkillState};

/// The one built-in skill tool: loads a skill (and what it requires) for the conversation.
pub const LOAD_SKILL: &str = "load_skill";

/// Where skills and the lock live. Read from the environment by [`Paths::from_env`]. The
/// protocol helper is not here: it is compiled in (`sandbox::SDK`).
#[derive(Clone, Debug)]
pub struct Paths {
    pub dirs: Vec<PathBuf>,
    pub lock: PathBuf,
}

impl Paths {
    /// `EDW_TUI_SKILLS_DIR` (`:`-separated, default `skills`) and `EDW_TUI_SKILLS_LOCK`
    /// (default `~/.config/edw-tui/skills.lock`, see [`lock::default_path`]).
    pub fn from_env() -> Self {
        let dirs: Vec<PathBuf> = std::env::var("EDW_TUI_SKILLS_DIR")
            .unwrap_or_else(|_| "skills".into())
            .split(':')
            .filter(|d| !d.is_empty())
            .map(PathBuf::from)
            .collect();
        let lock = std::env::var("EDW_TUI_SKILLS_LOCK")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                lock::default_path(
                    std::env::var("XDG_CONFIG_HOME").ok().as_deref(),
                    std::env::var("HOME").ok().as_deref(),
                )
            });
        Self { dirs, lock }
    }
}

pub struct Startup {
    pub set: Arc<tools::SkillSet>,
    pub installed: Vec<Installed>,
    /// Shown in the chat once the TUI is up.
    pub notes: Vec<String>,
}

/// Discovers skills, asks `ask` (with the consent summary) about each one that needs
/// consent, records the answers, and resolves which skills are ready.
pub async fn start(paths: &Paths, mut ask: impl FnMut(&str) -> bool) -> Startup {
    let mut notes = Vec::new();
    let mut installed = catalog::discover(&paths.dirs);
    let mut lock = lock::Lock::open(&paths.lock);
    catalog::apply_lock(&mut installed, &lock);
    for i in installed.iter_mut() {
        if i.state != SkillState::NeedsConsent {
            continue;
        }
        let Some(skill) = &i.skill else { continue };
        if ask(&catalog::consent_summary(skill, &i.hash)) {
            if let Err(error) = lock.trust(skill, i.hash.clone()) {
                notes.push(format!(
                    "Skill {} is allowed for this session, but {} could not be written ({error}); you will be asked again.",
                    i.name,
                    paths.lock.display()
                ));
            }
            i.state = SkillState::Ready;
        } else {
            i.state = SkillState::Declined;
        }
    }
    let needs_docker = installed.iter().any(|i| {
        i.state == SkillState::Ready && i.skill.as_ref().is_some_and(manifest::Skill::has_scripts)
    });
    let runner = sandbox::Runner::from_env();
    let mut docker = !needs_docker || sandbox::docker_available().await;
    if needs_docker && docker {
        if let Err(error) = sandbox::ensure_image(&runner.image).await {
            notes.push(format!("Skills with scripts are off: {error}"));
            docker = false;
        }
    } else if needs_docker {
        notes.push(
            "Skills with scripts are off: Docker is not running. Start it and restart edw-tui."
                .into(),
        );
    }
    catalog::resolve(&mut installed, &crate::edw::tool_names(), docker);
    for i in &installed {
        if let SkillState::Broken(why) = &i.state {
            notes.push(format!("Skill {} is not available: {why}", i.name));
        }
    }
    let set = tools::SkillSet::new(
        catalog::Catalog::from_installed(&installed),
        &installed,
        runner,
    );
    Startup {
        set: Arc::new(set),
        installed,
        notes,
    }
}

/// One line per installed skill, for `/skills`.
pub fn describe(installed: &[Installed]) -> Vec<String> {
    if installed.is_empty() {
        return vec!["No skills installed (EDW_TUI_SKILLS_DIR, default ./skills).".into()];
    }
    installed
        .iter()
        .map(|i| {
            let state = match &i.state {
                SkillState::Ready => "ready".to_owned(),
                SkillState::NeedsConsent => "needs consent (restart to be asked)".to_owned(),
                SkillState::Declined => "declined this session".to_owned(),
                SkillState::NeedsDocker => "needs Docker".to_owned(),
                SkillState::Broken(why) => format!("unavailable: {why}"),
            };
            let description = i
                .skill
                .as_ref()
                .map_or(String::new(), |s| format!(": {}", s.description));
            format!("{} ({state}){description}", i.name)
        })
        .collect()
}
