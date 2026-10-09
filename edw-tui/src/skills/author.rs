//! Authoring: the folder the model writes a new skill into. A draft is never loaded, hashed or
//! run from here. It becomes a skill only through `skills::install_draft`, which the user starts
//! (`/skill install <name>`) and which ends in the normal approval card.

use regex::Regex;
use std::{
    fs,
    path::{Component, Path, PathBuf},
    process::Command,
};

use super::manifest::{self, Skill};

/// The shipped skill whose instructions drive authoring; loading it offers the tools below.
pub const CREATOR: &str = "skill-creator";
pub const WRITE: &str = "skill_draft_write";
pub const CHECK: &str = "skill_draft_check";
pub const GUIDE: &str = "skill_draft_guide";
pub const TOOL_NAMES: [&str; 3] = [WRITE, CHECK, GUIDE];

pub const MAX_FILE: usize = 64 * 1024;
pub const MAX_FILES: usize = 24;

/// `<drafts>/<name>/…`: the only place an authoring tool writes.
#[derive(Clone, Debug)]
pub struct DraftStore {
    root: PathBuf,
}

impl DraftStore {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    /// The folder for draft `name`, after checking `name` is a plain skill name.
    pub fn dir(&self, name: &str) -> Result<PathBuf, String> {
        valid_name(name)?;
        Ok(self.root.join(name))
    }

    /// Writes one file of a draft; returns a line for the model.
    pub fn write(&self, name: &str, path: &str, content: &str) -> Result<String, String> {
        let dir = self.dir(name)?;
        let relative = allowed_path(path)?;
        if content.len() > MAX_FILE {
            return Err(format!(
                "{path} is {} bytes; a draft file is at most {MAX_FILE}",
                content.len()
            ));
        }
        let target = dir.join(&relative);
        if target.is_symlink() {
            return Err(format!("{path} is a symlink; refusing to write through it"));
        }
        if !target.exists() && count_files(&dir) >= MAX_FILES {
            return Err(format!("a draft holds at most {MAX_FILES} files"));
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
        }
        fs::write(&target, content).map_err(|e| format!("cannot write {path}: {e}"))?;
        Ok(format!("wrote {path} ({} bytes)", content.len()))
    }
}

fn valid_name(name: &str) -> Result<(), String> {
    let ok = (2..=40).contains(&name.len())
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        && !name.starts_with('-')
        && !name.ends_with('-');
    if ok {
        Ok(())
    } else {
        Err(format!(
            "`{name}` is not a skill name: use 2-40 lowercase letters, digits and dashes, e.g. `compound-lend`"
        ))
    }
}

/// `SKILL.md`, `skill.toml`, or `scripts/…/*.py` at most three levels deep.
fn allowed_path(path: &str) -> Result<PathBuf, String> {
    let relative = Path::new(path);
    let parts: Vec<&str> = relative
        .components()
        .map(|c| match c {
            Component::Normal(part) => part
                .to_str()
                .ok_or_else(|| format!("`{path}` is not valid text")),
            _ => Err(format!("`{path}` must be a relative path inside the draft")),
        })
        .collect::<Result<_, _>>()?;
    match parts.as_slice() {
        ["SKILL.md"] | ["skill.toml"] => Ok(relative.to_owned()),
        ["scripts", rest @ ..]
            if !rest.is_empty()
                && rest.len() <= 3
                && parts.last().is_some_and(|f| f.ends_with(".py")) =>
        {
            Ok(relative.to_owned())
        }
        _ => Err(format!(
            "`{path}` is not allowed: a draft holds SKILL.md, skill.toml and scripts/*.py"
        )),
    }
}

fn count_files(dir: &Path) -> usize {
    fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| {
            let path = entry.path();
            match entry.file_type() {
                Ok(kind) if kind.is_dir() => count_files(&path),
                _ => 1,
            }
        })
        .sum()
}

/// What `check` found. Errors stop an install; warnings are for the model to fix or the user to
/// weigh.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Report {
    pub errors: Vec<String>,
    pub warnings: Vec<String>,
}

impl Report {
    pub fn ok(&self) -> bool {
        self.errors.is_empty()
    }

    /// Text for the model, errors first.
    pub fn render(&self, name: &str) -> String {
        if self.errors.is_empty() && self.warnings.is_empty() {
            return format!("{name}: no problems found.");
        }
        let mut out = String::new();
        if !self.errors.is_empty() {
            out.push_str("Errors (fix these):\n");
            for e in &self.errors {
                out.push_str(&format!("- {e}\n"));
            }
            let all = self.errors.join("\n");
            if all.contains("SKILL.md") {
                out.push_str("SKILL.md starts with this frontmatter, then the instructions:\n---\nname: <the draft's name>\ndescription: <20-300 characters: what it does and when to use it>\n---\n");
            }
            if all.contains("skill.toml") {
                out.push_str("Do not guess skill.toml fields: call skill_draft_guide with topic manifest now (note the tables are `[[contract]]`, `[[read_tool]]` and `[[action]]`, each written with double brackets), then rewrite the file.\n");
            }
            if all.contains(".py") {
                out.push_str(
                    "For scripts, call skill_draft_guide with topic sdk, then rewrite the file.\n",
                );
            }
        }
        if !self.warnings.is_empty() {
            out.push_str("Warnings (fix them, or tell the user):\n");
            for w in &self.warnings {
                out.push_str(&format!("- {w}\n"));
            }
        }
        out.trim_end().to_owned()
    }
}

/// Loads the draft with the real manifest loader, then lints what the loader allows but a user
/// would regret.
pub fn check(dir: &Path) -> Report {
    let mut report = Report::default();
    match manifest::load(dir) {
        Ok(skill) => lint(&skill, &mut report),
        Err(why) => report.errors.push(why),
    }
    report
}

/// Words that tell a reader a skill can send transactions.
const ACTING: &[&str] = &[
    "send",
    "supply",
    "withdraw",
    "approve",
    "swap",
    "transfer",
    "deposit",
    "stake",
    "execute",
    "sign",
    "buy",
    "sell",
    "lend",
    "borrow",
    "repay",
    "transaction",
    "claim",
    "mint",
    "bridge",
    "vote",
    "harvest",
];

/// `token` is `word` or an ordinary inflection of it (sends, sending, signed), so that
/// "design" does not count as "sign" nor "sender" as "send".
fn is_form_of(token: &str, word: &str) -> bool {
    let stem = word.strip_suffix('e').unwrap_or(word);
    token
        .strip_prefix(word)
        .is_some_and(|rest| matches!(rest, "" | "s" | "es" | "ed" | "d" | "ing"))
        || token.strip_prefix(stem).is_some_and(|rest| rest == "ing")
}

fn mentions_acting(description: &str) -> bool {
    description
        .split(|c: char| !c.is_ascii_alphabetic())
        .any(|token| ACTING.iter().any(|word| is_form_of(token, word)))
}

fn lint(skill: &Skill, report: &mut Report) {
    let len = skill.description.chars().count();
    if len < 20 {
        report.errors.push(format!(
            "the description is {len} characters; the model picks skills from it, so say what the skill does and when to use it (20-300 characters)"
        ));
    } else if len > 1000 {
        report.errors.push(format!(
            "the description is {len} characters; at most 1000, and every skill's description is in every request, so keep it under 300"
        ));
    } else if len > 300 {
        report.warnings.push(format!(
            "the description is {len} characters; every skill's description is in every request, so keep it under 300"
        ));
    }
    let has_script = fs::read_dir(skill.dir.join("scripts"))
        .into_iter()
        .flatten()
        .flatten()
        .any(|entry| entry.file_name().to_string_lossy().ends_with(".py"));
    if has_script && !skill.has_scripts() {
        report.errors.push(
            "scripts/ has a script but skill.toml declares no `[[read_tool]]` or `[[action]]` that runs it, so the skill would load with no tools; add one (skill_draft_guide with topic manifest shows how)".into(),
        );
    }
    if !skill.has_scripts() && !skill.manifest.contracts.is_empty() {
        report.errors.push(
            "skill.toml declares contracts but no `[[read_tool]]` or `[[action]]`, so the skill has no tool that can use them and cannot read anything; add a tool and its script (skill_draft_guide with topic manifest shows how)".into(),
        );
    }
    if skill.body.trim().is_empty() {
        report
            .errors
            .push("SKILL.md has no instructions below the frontmatter".into());
    }
    if Regex::new(r"\b(ALWAYS|NEVER|MUST)\b")
        .expect("valid pattern")
        .is_match(&skill.body)
    {
        report.warnings.push(
            "SKILL.md uses ALWAYS/NEVER/MUST in capital letters; models follow a stated reason better than shouting, so say why".into(),
        );
    }
    let m = &skill.manifest;
    for tool in m.read_tools.iter().chain(m.actions.iter().map(|a| &a.tool)) {
        let script = skill.dir.join(&tool.run);
        if !script.is_file() {
            report.errors.push(format!(
                "{} runs {}, which is not in the draft",
                tool.name, tool.run
            ));
        } else if let Some(why) = python_syntax(&script) {
            report.errors.push(format!("{}: {why}", tool.run));
        }
        if !skill.body.contains(&tool.name) {
            report.warnings.push(format!(
                "SKILL.md never mentions the tool {}; say when to call it and what to tell the user",
                tool.name
            ));
        }
    }
    let description = skill.description.to_lowercase();
    if !m.actions.is_empty() && !mentions_acting(&description) {
        report.warnings.push(
            "the skill can send transactions (it declares actions) but its description never says so; a user reading the skill list would not expect that".into(),
        );
    }
}

/// `Some(reason)` when python3 is present and rejects the file's syntax. Without python3 there
/// is nothing to say. Parses only: nothing in the file runs, and no `__pycache__` is written.
fn python_syntax(script: &Path) -> Option<String> {
    let out = Command::new("python3")
        .args([
            "-I",
            "-c",
            "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read(), sys.argv[1])",
        ])
        .arg(script)
        .output()
        .ok()?;
    if out.status.success() {
        return None;
    }
    let stderr = String::from_utf8_lossy(&out.stderr);
    Some(format!(
        "Python syntax error: {}",
        stderr.lines().last().unwrap_or("unknown")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (tempfile::TempDir, DraftStore) {
        let root = tempfile::tempdir().unwrap();
        let store = DraftStore::new(root.path().join("drafts"));
        (root, store)
    }

    #[test]
    fn writes_the_three_kinds_of_file_a_skill_has() {
        let (_root, store) = store();
        store
            .write("my-skill", "SKILL.md", "---\nname: my-skill\n---\n")
            .unwrap();
        store
            .write("my-skill", "skill.toml", "version = \"0.1.0\"\n")
            .unwrap();
        store
            .write("my-skill", "scripts/run.py", "print(1)\n")
            .unwrap();
        let dir = store.dir("my-skill").unwrap();
        assert!(dir.join("SKILL.md").is_file());
        assert!(dir.join("scripts/run.py").is_file());
    }

    #[test]
    fn refuses_paths_that_leave_the_draft_or_are_not_part_of_a_skill() {
        let (root, store) = store();
        for bad in [
            "../escape.py",
            "scripts/../../escape.py",
            "/etc/passwd",
            "notes.txt",
            "scripts/run.sh",
            "scripts/a.pyc",
            "scripts/a/b/c/d.py",
            "scripts",
            "",
        ] {
            assert!(
                store.write("my-skill", bad, "x").is_err(),
                "`{bad}` must be refused"
            );
        }
        assert!(!root.path().join("escape.py").exists());
        assert!(!root.path().join("drafts/escape.py").exists());
    }

    #[test]
    fn refuses_names_that_are_not_plain_skill_names() {
        let (_root, store) = store();
        for bad in [
            "",
            "a",
            "Bad_Name",
            "../x",
            "x/y",
            "-lead",
            "trail-",
            &"a".repeat(41),
        ] {
            assert!(store.dir(bad).is_err(), "`{bad}` must be refused");
        }
        assert!(store.dir("compound-v3-lend").is_ok());
    }

    #[test]
    fn caps_file_size_and_file_count() {
        let (_root, store) = store();
        let big = "x".repeat(MAX_FILE + 1);
        assert!(store.write("my-skill", "SKILL.md", &big).is_err());
        for i in 0..MAX_FILES - 1 {
            store
                .write("my-skill", &format!("scripts/s{i}.py"), "x")
                .unwrap();
        }
        store.write("my-skill", "SKILL.md", "x").unwrap();
        assert!(
            store.write("my-skill", "skill.toml", "x").is_err(),
            "file 25"
        );
        // Rewriting an existing file is not a new file.
        store.write("my-skill", "SKILL.md", "y").unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn does_not_write_through_a_symlink() {
        let (root, store) = store();
        store.write("my-skill", "SKILL.md", "x").unwrap();
        let outside = root.path().join("outside.txt");
        std::fs::write(&outside, "keep").unwrap();
        let link = store.dir("my-skill").unwrap().join("skill.toml");
        std::os::unix::fs::symlink(&outside, &link).unwrap();
        assert!(
            store
                .write("my-skill", "skill.toml", "overwritten")
                .is_err()
        );
        assert_eq!(std::fs::read_to_string(outside).unwrap(), "keep");
    }

    use std::process::Command;

    fn draft(files: &[(&str, &str)]) -> (tempfile::TempDir, PathBuf) {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("demo");
        for (path, content) in files {
            let target = dir.join(path);
            fs::create_dir_all(target.parent().unwrap()).unwrap();
            fs::write(target, content).unwrap();
        }
        (root, dir)
    }

    const GOOD_MD: &str = "---\nname: demo\ndescription: Look up the ETH balance of any address. Use when the user asks what an address holds.\n---\nCall balance_of with the address. Say which chain the number is from.\n";
    const READ_TOML: &str = "version = \"0.1.0\"\n[[read_tool]]\nname = \"balance_of\"\nrun = \"scripts/balance.py\"\ndescription = \"ETH balance of an address\"\nschema = { type = \"object\", required = [\"address\"], properties = { address = { type = \"string\" } } }\n";

    #[test]
    fn a_clean_knowledge_skill_has_no_findings() {
        let (_root, dir) = draft(&[("SKILL.md", GOOD_MD)]);
        let report = check(&dir);
        assert!(report.ok(), "{report:?}");
        assert!(report.warnings.is_empty(), "{report:?}");
    }

    #[test]
    fn a_draft_that_does_not_load_reports_the_loader_error() {
        let (_root, dir) = draft(&[("SKILL.md", "no frontmatter")]);
        let report = check(&dir);
        assert!(!report.ok());
        assert!(report.errors[0].contains("frontmatter"), "{report:?}");
    }

    #[test]
    fn a_vague_description_is_an_error_and_a_long_one_a_warning() {
        let short = "---\nname: demo\ndescription: stuff\n---\nbody\n";
        let (_a, dir) = draft(&[("SKILL.md", short)]);
        assert!(check(&dir).errors.iter().any(|e| e.contains("description")));
        let long = format!(
            "---\nname: demo\ndescription: {}\n---\nbody\n",
            "word ".repeat(80)
        );
        let (_b, dir) = draft(&[("SKILL.md", &long)]);
        let report = check(&dir);
        assert!(report.ok());
        assert!(report.warnings.iter().any(|w| w.contains("description")));
        let huge = format!(
            "---\nname: demo\ndescription: {}\n---\nbody\n",
            "word ".repeat(250)
        );
        let (_c, dir) = draft(&[("SKILL.md", &huge)]);
        let report = check(&dir);
        assert!(!report.ok());
        assert!(report.errors.iter().any(|e| e.contains("at most 1000")));
    }

    #[test]
    fn capital_letter_rules_are_a_warning() {
        let md = GOOD_MD.replace("Call balance_of", "ALWAYS call balance_of");
        let (_root, dir) = draft(&[("SKILL.md", &md)]);
        assert!(check(&dir).warnings.iter().any(|w| w.contains("capital")));
    }

    #[test]
    fn a_tool_whose_script_is_missing_is_an_error() {
        let (_root, dir) = draft(&[("SKILL.md", GOOD_MD), ("skill.toml", READ_TOML)]);
        let report = check(&dir);
        assert!(
            report
                .errors
                .iter()
                .any(|e| e.contains("scripts/balance.py")),
            "{report:?}"
        );
    }

    #[test]
    fn a_tool_the_instructions_never_mention_is_a_warning() {
        let md = GOOD_MD.replace("balance_of", "the lookup");
        let (_root, dir) = draft(&[
            ("SKILL.md", &md),
            ("skill.toml", READ_TOML),
            ("scripts/balance.py", "print(1)\n"),
        ]);
        assert!(
            check(&dir)
                .warnings
                .iter()
                .any(|w| w.contains("balance_of"))
        );
    }

    #[test]
    fn an_action_the_description_never_admits_to_is_a_warning() {
        let toml = "version = \"0.1.0\"\n[[action]]\nname = \"do_it\"\nrun = \"scripts/do.py\"\ndescription = \"does it\"\nschema = { type = \"object\" }\n";
        let md = "---\nname: demo\ndescription: Look up the ETH balance of any address for the user.\n---\nCall do_it.\n";
        let (_root, dir) = draft(&[
            ("SKILL.md", md),
            ("skill.toml", toml),
            ("scripts/do.py", "print(1)\n"),
        ]);
        let report = check(&dir);
        assert!(
            report
                .warnings
                .iter()
                .any(|w| w.contains("send transactions")),
            "{report:?}"
        );
    }

    #[test]
    fn a_python_syntax_error_is_an_error_when_python_is_available() {
        let (_root, dir) = draft(&[
            ("SKILL.md", GOOD_MD),
            ("skill.toml", READ_TOML),
            ("scripts/balance.py", "def broken(:\n"),
        ]);
        let report = check(&dir);
        if Command::new("python3").arg("--version").output().is_ok() {
            assert!(
                report.errors.iter().any(|e| e.contains("syntax")),
                "{report:?}"
            );
        } else {
            assert!(
                report.ok(),
                "no python3: the syntax check is skipped, not failed"
            );
        }
    }

    #[test]
    fn a_script_no_tool_runs_is_an_error() {
        let (_root, dir) = draft(&[
            (
                "SKILL.md",
                "---\nname: demo\ndescription: Shows something useful about a demo, when asked.\n---\nUse it.\n",
            ),
            ("skill.toml", "version = \"1\"\n"),
            ("scripts/run.py", "print(1)\n"),
        ]);
        let report = check(&dir);
        assert!(
            report.errors.iter().any(|e| e.contains("declares no")),
            "{report:?}"
        );
    }

    #[test]
    fn contracts_without_a_tool_are_an_error() {
        let (_root, dir) = draft(&[
            ("SKILL.md", GOOD_MD),
            (
                "skill.toml",
                "version = \"1\"\n[[contract]]\nid = \"x\"\nlabel = \"X\"\nfunctions = []\naddress = { 1 = \"0x0000000000000000000000000000000000000001\" }\n",
            ),
        ]);
        let report = check(&dir);
        assert!(
            report.errors.iter().any(|e| e.contains("no tool")),
            "{report:?}"
        );
    }

    #[test]
    fn the_acting_lint_matches_words_not_substrings() {
        assert!(mentions_acting("Sends tokens and signs the plan"));
        assert!(mentions_acting("Claims rewards, then bridges them"));
        assert!(!mentions_acting(
            "Shows the sender and the design of a vault"
        ));
    }

    #[test]
    fn render_lists_errors_before_warnings() {
        let report = Report {
            errors: vec!["bad".into()],
            warnings: vec!["meh".into()],
        };
        let text = report.render("demo");
        assert!(text.find("bad").unwrap() < text.find("meh").unwrap());
        assert_eq!(Report::default().render("demo"), "demo: no problems found.");
    }
}
