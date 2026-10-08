//! Skills: folders the agent loads on demand (see the README section "Skills").
//!
//! [`discover`] finds them and lays out approval cards for any that are new or changed;
//! [`finish`] applies the answers and returns the ready ones as a [`tools::SkillSet`].
//! [`add`], [`disable`], [`enable`] and [`delete`] back the TUI's Skills tab.

pub mod abi;
pub mod author;
pub mod catalog;
pub mod consent;
pub mod explain;
pub mod host;
pub mod lock;
pub mod manifest;
pub mod plan;
pub mod sandbox;
pub mod simulate;
pub mod tools;

use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    sync::Arc,
};

use catalog::{Installed, SkillState};

/// The one built-in skill tool: loads a skill (and what it requires) for the conversation.
pub const LOAD_SKILL: &str = "load_skill";

/// Where skills and the lock live. Read from the environment by [`Paths::from_env`]. The
/// protocol helper is not here: it is compiled in (`sandbox::SDK`).
#[derive(Clone, Debug)]
pub struct Paths {
    /// Shipped skills (the repo's `skills/`); never deleted from the TUI.
    pub dirs: Vec<PathBuf>,
    /// Skills the user added from the Skills tab are copied here.
    pub user_dir: PathBuf,
    pub lock: PathBuf,
}

impl Paths {
    /// `EDW_TUI_SKILLS_DIR` (`:`-separated, default `skills`), `EDW_TUI_SKILLS_USER_DIR`
    /// (default `~/.config/edw-tui/skills`) and `EDW_TUI_SKILLS_LOCK` (default
    /// `~/.config/edw-tui/skills.lock`, see [`lock::default_path`]).
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
        let user_dir = std::env::var("EDW_TUI_SKILLS_USER_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| lock.with_file_name("skills"));
        Self {
            dirs,
            user_dir,
            lock,
        }
    }

    /// Shipped folders first, then the user's.
    fn all_dirs(&self) -> Vec<PathBuf> {
        let mut dirs = self.dirs.clone();
        dirs.push(self.user_dir.clone());
        dirs
    }

    fn origin(&self, dir: &Path) -> Origin {
        let user = fs::canonicalize(&self.user_dir).unwrap_or_else(|_| self.user_dir.clone());
        if dir.starts_with(&user) || dir.starts_with(&self.user_dir) {
            Origin::Added
        } else {
            Origin::Shipped
        }
    }
}

/// Where a skill came from: shipped with edw-tui, or added by the user (and deletable).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Origin {
    Shipped,
    Added,
}

/// One line of the Skills tab, with the details shown for the selected one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SkillRow {
    pub name: String,
    pub version: String,
    /// ready, disabled, declined, needs approval, needs Docker, unavailable
    pub state: String,
    /// Why a skill is unavailable.
    pub note: Option<String>,
    pub description: String,
    pub origin: Origin,
    pub dir: PathBuf,
    pub details: Option<consent::ConsentRequest>,
}

pub fn rows(installed: &[Installed], paths: &Paths) -> Vec<SkillRow> {
    installed
        .iter()
        .map(|i| {
            let (state, note) = match &i.state {
                SkillState::Ready => ("ready", None),
                SkillState::NeedsConsent => ("needs approval", None),
                SkillState::Declined => ("declined", None),
                SkillState::Disabled => ("disabled", None),
                SkillState::NeedsDocker => ("needs Docker", None),
                SkillState::Broken(why) => ("unavailable", Some(why.clone())),
            };
            SkillRow {
                name: i.name.clone(),
                version: i
                    .skill
                    .as_ref()
                    .map_or(String::new(), |s| plan::one_line(&s.manifest.version)),
                state: state.to_owned(),
                note,
                description: i
                    .skill
                    .as_ref()
                    .map_or(String::new(), |s| plan::one_line(&s.description)),
                origin: paths.origin(&i.dir),
                dir: i.dir.clone(),
                details: i
                    .skill
                    .as_ref()
                    .map(|s| consent::ConsentRequest::new(s, &i.hash, consent::Reason::New)),
            }
        })
        .collect()
}

fn installed_named(paths: &Paths, name: &str) -> Result<Installed, String> {
    catalog::discover(&paths.all_dirs())
        .into_iter()
        .find(|i| i.name == name)
        .ok_or_else(|| format!("there is no skill named {name}"))
}

/// Turns a skill off: no longer offered or asked about, until [`enable`].
pub fn disable(paths: &Paths, name: &str) -> Result<(), String> {
    let installed = installed_named(paths, name)?;
    let skill = installed
        .skill
        .ok_or_else(|| format!("{name} does not load, so there is nothing to disable"))?;
    lock::Lock::open(&paths.lock)
        .disable(&skill)
        .map_err(|e| format!("cannot write {}: {e}", paths.lock.display()))
}

/// Turns a disabled skill back on; its approval card is shown again before it may run.
pub fn enable(paths: &Paths, name: &str) -> Result<(), String> {
    let installed = installed_named(paths, name)?;
    let skill = installed
        .skill
        .ok_or_else(|| format!("{name} does not load: {}", describe_state(&installed.state)))?;
    lock::Lock::open(&paths.lock)
        .enable(&skill)
        .map_err(|e| format!("cannot write {}: {e}", paths.lock.display()))
}

/// Copies the skill folder at `source` into the user's skills folder, after the same checks
/// a skill gets on start (it loads, no symlinks, no compiled code). It is not trusted: its
/// approval card comes next. Returns its name.
pub fn add(paths: &Paths, source: &Path) -> Result<String, String> {
    let skill = manifest::load(source)?;
    lock::hash_dir(&skill.dir).map_err(|e| format!("{}: {e}", skill.name))?;
    if installed_named(paths, &skill.name).is_ok() {
        return Err(format!("a skill named {} is already installed", skill.name));
    }
    let target = paths.user_dir.join(&skill.name);
    if target.exists() {
        return Err(format!("{} already exists", target.display()));
    }
    fs::create_dir_all(&target).map_err(|e| format!("cannot create {}: {e}", target.display()))?;
    if let Err(error) = lock::snapshot(&skill.dir, &target) {
        let _ = fs::remove_dir_all(&target);
        return Err(format!("{}: {error}", skill.name));
    }
    Ok(skill.name)
}

/// Deletes a skill the user added (never a shipped one) and forgets its approval.
pub fn delete(paths: &Paths, name: &str) -> Result<(), String> {
    let installed = installed_named(paths, name)?;
    if paths.origin(&installed.dir) != Origin::Added {
        return Err(format!(
            "{name} is shipped with edw-tui, so it is not deleted; disable it instead"
        ));
    }
    fs::remove_dir_all(&installed.dir)
        .map_err(|e| format!("cannot delete {}: {e}", installed.dir.display()))?;
    lock::Lock::open(&paths.lock)
        .forget(&installed.dir)
        .map_err(|e| format!("cannot write {}: {e}", paths.lock.display()))
}

fn describe_state(state: &SkillState) -> String {
    match state {
        SkillState::Ready => "ready".to_owned(),
        SkillState::NeedsConsent => "needs consent (restart to be asked)".to_owned(),
        SkillState::Declined => "declined this session".to_owned(),
        SkillState::Disabled => "disabled (enable it in the Skills tab)".to_owned(),
        SkillState::NeedsDocker => "needs Docker".to_owned(),
        SkillState::Broken(why) => format!("unavailable: {why}"),
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
    let mut installed = catalog::discover(&paths.all_dirs());
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
            let state = describe_state(&i.state);
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
            user_dir: root.path().join("user"),
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
            user_dir: root.path().join("user"),
            lock: root.path().join("skills.lock"),
        };
        let startup = finish(discover(&paths), &BTreeMap::new()).await;
        assert!(startup.set.catalog.skills.is_empty());
        assert!(!paths.lock.exists());
    }

    /// A shipped skill folder, a user folder for added ones, and a lock, all throwaway.
    fn layout(root: &std::path::Path) -> Paths {
        knowledge_skill(&root.join("skills"), "alpha");
        Paths {
            dirs: vec![root.join("skills")],
            user_dir: root.join("user"),
            lock: root.join("skills.lock"),
        }
    }

    async fn ready_names(paths: &Paths, answers: &[(&str, bool)]) -> Vec<String> {
        let answers = answers.iter().map(|(n, a)| (n.to_string(), *a)).collect();
        let startup = finish(discover(paths), &answers).await;
        startup
            .set
            .catalog
            .skills
            .iter()
            .map(|s| s.name.clone())
            .collect()
    }

    #[tokio::test]
    async fn a_disabled_skill_stays_out_until_enabled_and_approved_again() {
        let root = tempfile::tempdir().unwrap();
        let paths = layout(root.path());
        assert_eq!(ready_names(&paths, &[("alpha", true)]).await, ["alpha"]);

        disable(&paths, "alpha").unwrap();
        let found = discover(&paths);
        assert!(
            found.requests.is_empty(),
            "a disabled skill is not asked about"
        );
        let startup = finish(found, &BTreeMap::new()).await;
        assert!(startup.set.catalog.skills.is_empty());
        assert!(
            describe(&startup.installed)[0].contains("disabled"),
            "{:?}",
            describe(&startup.installed)
        );

        enable(&paths, "alpha").unwrap();
        let asked: Vec<String> = discover(&paths)
            .requests
            .into_iter()
            .map(|r| r.name)
            .collect();
        assert_eq!(asked, ["alpha"], "enabling asks for approval again");
        assert_eq!(ready_names(&paths, &[("alpha", true)]).await, ["alpha"]);
        assert!(disable(&paths, "nope").unwrap_err().contains("nope"));
    }

    #[test]
    fn adding_copies_a_checked_folder_into_the_user_folder() {
        let root = tempfile::tempdir().unwrap();
        let paths = layout(root.path());
        let elsewhere = root.path().join("downloads");
        knowledge_skill(&elsewhere, "gamma");

        assert_eq!(add(&paths, &elsewhere.join("gamma")).unwrap(), "gamma");
        assert!(paths.user_dir.join("gamma/SKILL.md").exists());
        let found = discover(&paths);
        let request = found.requests.iter().find(|r| r.name == "gamma").unwrap();
        assert_eq!(request.reason, Reason::New);

        assert!(
            add(&paths, &elsewhere.join("gamma"))
                .unwrap_err()
                .contains("already")
        );
        knowledge_skill(&elsewhere, "alpha");
        assert!(
            add(&paths, &elsewhere.join("alpha"))
                .unwrap_err()
                .contains("already")
        );

        // Refused folders are not copied.
        std::fs::create_dir_all(elsewhere.join("empty")).unwrap();
        assert!(
            add(&paths, &elsewhere.join("empty"))
                .unwrap_err()
                .contains("SKILL.md")
        );
        knowledge_skill(&elsewhere, "linked");
        std::os::unix::fs::symlink("/etc/hosts", elsewhere.join("linked/hosts")).unwrap();
        assert!(
            add(&paths, &elsewhere.join("linked"))
                .unwrap_err()
                .contains("symlink")
        );
        assert!(!paths.user_dir.join("linked").exists());
        assert!(!paths.user_dir.join("empty").exists());
    }

    #[test]
    fn only_added_skills_can_be_deleted() {
        let root = tempfile::tempdir().unwrap();
        let paths = layout(root.path());
        knowledge_skill(&root.path().join("downloads"), "gamma");
        add(&paths, &root.path().join("downloads/gamma")).unwrap();

        assert!(delete(&paths, "alpha").unwrap_err().contains("shipped"));
        assert!(root.path().join("skills/alpha").exists());
        delete(&paths, "gamma").unwrap();
        assert!(!paths.user_dir.join("gamma").exists());
        assert!(delete(&paths, "gamma").unwrap_err().contains("gamma"));
    }

    #[tokio::test]
    async fn rows_list_every_skill_with_where_it_comes_from() {
        let root = tempfile::tempdir().unwrap();
        let paths = layout(root.path());
        knowledge_skill(&root.path().join("downloads"), "gamma");
        add(&paths, &root.path().join("downloads/gamma")).unwrap();
        let startup = finish(discover(&paths), &BTreeMap::from([("alpha".into(), true)])).await;
        let rows = rows(&startup.installed, &paths);
        let summary: Vec<(&str, &str, Origin)> = rows
            .iter()
            .map(|r| (r.name.as_str(), r.state.as_str(), r.origin))
            .collect();
        assert_eq!(
            summary,
            [
                ("alpha", "ready", Origin::Shipped),
                ("gamma", "declined", Origin::Added)
            ]
        );
        assert_eq!(rows[0].description, "about alpha");
        assert!(
            rows[0].details.is_some(),
            "details for the selected skill's panel"
        );
    }
}
