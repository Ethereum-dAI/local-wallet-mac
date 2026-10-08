//! Authoring: the folder the model writes a new skill into. A draft is never loaded, hashed or
//! run from here. It becomes a skill only through `skills::install_draft`, which the user starts
//! (`/skill install <name>`) and which ends in the normal approval card.

use std::{
    fs,
    path::{Component, Path, PathBuf},
};

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
            if path.is_dir() { count_files(&path) } else { 1 }
        })
        .sum()
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
}
