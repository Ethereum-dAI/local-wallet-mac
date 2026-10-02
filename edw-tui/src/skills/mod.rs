//! Skills: folders the agent loads on demand (see the README section "Skills").
//!
//! [`start`] finds them, asks the user about any that are new or changed, and returns the
//! ready ones as a [`tools::SkillSet`] for the agent.

pub mod abi;
pub mod catalog;
pub mod consent;
pub mod host;
pub mod lock;
pub mod manifest;
pub mod plan;
pub mod sandbox;
pub mod simulate;
pub mod tools;

use std::{collections::BTreeMap, path::PathBuf, sync::Arc};

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

/// Skills found on disk, with the ones that need the user's consent laid out for the TUI.
pub struct Discovery {
    installed: Vec<Installed>,
    lock: lock::Lock,
    lock_path: PathBuf,
    /// In discovery order; the TUI shows one approval card per request.
    pub requests: Vec<consent::ConsentRequest>,
}

/// Finds skills and checks them against the lock, without asking anything yet.
pub fn discover(paths: &Paths) -> Discovery {
    let mut installed = catalog::discover(&paths.dirs);
    let lock = lock::Lock::open(&paths.lock);
    catalog::apply_lock(&mut installed, &lock);
    let requests = installed
        .iter()
        .filter(|i| i.state == SkillState::NeedsConsent)
        .filter_map(|i| {
            let skill = i.skill.as_ref()?;
            let reason = consent::Reason::from_status(lock.status(skill, &i.hash))?;
            Some(consent::ConsentRequest::new(skill, &i.hash, reason))
        })
        .collect();
    Discovery {
        installed,
        lock,
        lock_path: paths.lock.clone(),
        requests,
    }
}

/// Applies the user's answers (by skill name; anything unanswered is a no), records the yeses
/// in the lock, and resolves which skills are ready: Docker, dependencies, tool names.
pub async fn finish(discovery: Discovery, answers: &BTreeMap<String, bool>) -> Startup {
    let Discovery {
        mut installed,
        mut lock,
        lock_path,
        requests,
    } = discovery;
    let mut notes = Vec::new();
    for i in installed.iter_mut() {
        if i.state != SkillState::NeedsConsent {
            continue;
        }
        let Some(skill) = &i.skill else { continue };
        // Only an answer to the very hash that was shown counts.
        let shown = requests
            .iter()
            .any(|r| r.name == i.name && r.hash == i.hash);
        if shown && answers.get(&i.name) == Some(&true) {
            if let Err(error) = lock.trust(skill, i.hash.clone()) {
                notes.push(format!(
                    "Skill {} is allowed for this session, but {} could not be written ({error}); you will be asked again.",
                    i.name,
                    lock_path.display()
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
        if let Err(error) = sandbox::ensure_image(&runner.image, sandbox::PULL_TIMEOUT).await {
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

#[cfg(test)]
mod tests {
    use std::{collections::BTreeMap, fs};

    use super::*;
    use crate::skills::consent::Reason;

    fn knowledge_skill(root: &std::path::Path, name: &str) {
        let dir = root.join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("SKILL.md"),
            format!("---\nname: {name}\ndescription: about {name}\n---\nbody\n"),
        )
        .unwrap();
    }

    #[tokio::test]
    async fn answers_from_the_tui_decide_the_catalog_and_the_lock() {
        let root = tempfile::tempdir().unwrap();
        knowledge_skill(root.path(), "alpha");
        knowledge_skill(root.path(), "beta");
        let paths = Paths {
            dirs: vec![root.path().to_owned()],
            lock: root.path().join("state/skills.lock"),
        };
        let found = discover(&paths);
        let asked: Vec<(&str, Reason)> = found
            .requests
            .iter()
            .map(|r| (r.name.as_str(), r.reason))
            .collect();
        assert_eq!(asked, [("alpha", Reason::New), ("beta", Reason::New)]);

        let answers = BTreeMap::from([("alpha".to_owned(), true), ("beta".to_owned(), false)]);
        let startup = finish(found, &answers).await;
        let names: Vec<&str> = startup
            .set
            .catalog
            .skills
            .iter()
            .map(|s| s.name.as_str())
            .collect();
        assert_eq!(names, ["alpha"]);
        assert!(describe(&startup.installed)[1].contains("declined"));

        // Next start: only the declined one is asked about again.
        let again = discover(&paths);
        let asked: Vec<&str> = again.requests.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(asked, ["beta"]);
    }

    #[tokio::test]
    async fn no_answer_is_a_no() {
        let root = tempfile::tempdir().unwrap();
        knowledge_skill(root.path(), "alpha");
        let paths = Paths {
            dirs: vec![root.path().to_owned()],
            lock: root.path().join("skills.lock"),
        };
        let startup = finish(discover(&paths), &BTreeMap::new()).await;
        assert!(startup.set.catalog.skills.is_empty());
        assert!(!paths.lock.exists());
    }
}
