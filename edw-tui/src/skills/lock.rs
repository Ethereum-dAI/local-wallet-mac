//! `skills.lock`: what the user agreed to. A skill is trusted only while its folder hashes to
//! the recorded value and it declares no HTTP host beyond the recorded ones.

use std::{
    collections::BTreeMap,
    fs, io,
    path::{Path, PathBuf},
};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::manifest::Skill;

/// Never part of a skill, and never run: Finder litter.
const IGNORED: [&str; 1] = [".DS_Store"];

/// Compiled Python is refused rather than skipped: the interpreter imports a `.pyc` from
/// `__pycache__` even when the `.py` next to it differs, so it would be code that runs without
/// being part of the hash the user agreed to.
fn compiled_python(name: &std::ffi::OsStr) -> bool {
    name == "__pycache__"
        || Path::new(name)
            .extension()
            .is_some_and(|e| e == "pyc" || e == "pyo")
}

/// sha256 over every file under `dir`, in sorted path order: `path \0 len \0 bytes`.
/// A symlink anywhere is refused, so the hash always covers what actually runs.
pub fn hash_dir(dir: &Path) -> Result<String, String> {
    let mut files = Vec::new();
    collect(dir, dir, &mut files)?;
    files.sort();
    let mut hasher = Sha256::new();
    for relative in files {
        let bytes = fs::read(dir.join(&relative))
            .map_err(|e| format!("{}: cannot read ({e})", relative.display()))?;
        hasher.update(relative.to_string_lossy().as_bytes());
        hasher.update([0]);
        hasher.update(bytes.len().to_le_bytes());
        hasher.update([0]);
        hasher.update(&bytes);
    }
    Ok(hex(&hasher.finalize()))
}

/// Copies the skill folder `dir` into the empty folder `into` (same rules as [`hash_dir`]) and
/// returns the hash of the copy: the code that will run is exactly the code that was hashed,
/// whatever happens to `dir` afterwards.
pub fn snapshot(dir: &Path, into: &Path) -> Result<String, String> {
    let mut files = Vec::new();
    collect(dir, dir, &mut files)?;
    for relative in &files {
        let target = into.join(relative);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
        }
        fs::copy(dir.join(relative), &target)
            .map_err(|e| format!("{}: cannot copy ({e})", relative.display()))?;
    }
    hash_dir(into)
}

fn collect(root: &Path, dir: &Path, out: &mut Vec<PathBuf>) -> Result<(), String> {
    let entries = fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        let name = entry.file_name();
        if IGNORED.iter().any(|i| name == *i) {
            continue;
        }
        let path = entry.path();
        let kind = fs::symlink_metadata(&path)
            .map_err(|e| format!("{}: {e}", path.display()))?
            .file_type();
        let relative = path.strip_prefix(root).unwrap_or(&path).to_owned();
        if compiled_python(&name) {
            return Err(format!(
                "{}: compiled Python is not allowed in a skill folder; delete it",
                relative.display()
            ));
        }
        if kind.is_symlink() {
            return Err(format!(
                "{}: symlinks are not allowed in a skill folder",
                relative.display()
            ));
        } else if kind.is_dir() {
            collect(root, &path, out)?;
        } else if kind.is_file() {
            out.push(relative);
        }
    }
    Ok(())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct LockEntry {
    pub version: String,
    pub hash: String,
    pub hosts: Vec<String>,
}

pub struct Lock {
    path: PathBuf,
    entries: BTreeMap<String, LockEntry>,
}

impl Lock {
    /// A missing or unreadable lock trusts nothing.
    pub fn open(path: &Path) -> Self {
        let entries = fs::read_to_string(path)
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default();
        Self {
            path: path.to_owned(),
            entries,
        }
    }

    pub fn is_trusted(&self, skill: &Skill, hash: &str) -> bool {
        self.entries.get(&skill.name).is_some_and(|entry| {
            entry.hash == hash
                && skill
                    .manifest
                    .hosts
                    .iter()
                    .all(|host| entry.hosts.contains(host))
        })
    }

    pub fn trust(&mut self, skill: &Skill, hash: String) -> io::Result<()> {
        self.entries.insert(
            skill.name.clone(),
            LockEntry {
                version: skill.manifest.version.clone(),
                hash,
                hosts: skill.manifest.hosts.clone(),
            },
        );
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        let text = serde_json::to_string_pretty(&self.entries).map_err(io::Error::other)?;
        fs::write(&self.path, text + "\n")
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;
    use crate::skills::manifest;

    fn skill_dir(root: &Path) -> PathBuf {
        let dir = root.join("demo");
        fs::create_dir_all(dir.join("scripts")).unwrap();
        fs::write(
            dir.join("SKILL.md"),
            "---\nname: demo\ndescription: d\n---\nbody\n",
        )
        .unwrap();
        fs::write(dir.join("scripts/a.py"), "print(1)\n").unwrap();
        dir
    }

    #[test]
    fn the_hash_follows_content_not_creation_order() {
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        let da = skill_dir(a.path());
        // Same files, written in the other order.
        let db = b.path().join("demo");
        fs::create_dir_all(db.join("scripts")).unwrap();
        fs::write(db.join("scripts/a.py"), "print(1)\n").unwrap();
        fs::write(
            db.join("SKILL.md"),
            "---\nname: demo\ndescription: d\n---\nbody\n",
        )
        .unwrap();
        assert_eq!(hash_dir(&da).unwrap(), hash_dir(&db).unwrap());

        fs::write(db.join("scripts/a.py"), "print(2)\n").unwrap();
        assert_ne!(hash_dir(&da).unwrap(), hash_dir(&db).unwrap());
        // A renamed file changes it too, even with the same bytes.
        fs::rename(db.join("scripts/a.py"), db.join("scripts/b.py")).unwrap();
        fs::write(db.join("scripts/b.py"), "print(1)\n").unwrap();
        assert_ne!(hash_dir(&da).unwrap(), hash_dir(&db).unwrap());
    }

    /// Python imports a `.pyc` from `__pycache__` even when the `.py` next to it says something
    /// else, so compiled code would run without ever being part of what the user agreed to.
    #[test]
    fn compiled_python_is_refused_not_skipped() {
        let root = tempfile::tempdir().unwrap();
        let dir = skill_dir(root.path());
        fs::create_dir_all(dir.join("scripts/__pycache__")).unwrap();
        fs::write(
            dir.join("scripts/__pycache__/a.cpython-312.pyc"),
            b"\x00evil",
        )
        .unwrap();
        assert!(hash_dir(&dir).unwrap_err().contains("compiled Python"));

        let root = tempfile::tempdir().unwrap();
        let dir = skill_dir(root.path());
        fs::write(dir.join("scripts/a.pyc"), b"\x00evil").unwrap();
        assert!(hash_dir(&dir).unwrap_err().contains("compiled Python"));
    }

    #[test]
    fn a_symlink_is_refused() {
        let root = tempfile::tempdir().unwrap();
        let dir = skill_dir(root.path());
        std::os::unix::fs::symlink("/etc/hosts", dir.join("scripts/link")).unwrap();
        assert!(hash_dir(&dir).unwrap_err().contains("symlink"));
    }

    #[test]
    fn trust_round_trips_and_follows_hash_and_hosts() {
        let root = tempfile::tempdir().unwrap();
        let dir = skill_dir(root.path());
        let mut skill = manifest::load(&dir).unwrap();
        let path = root.path().join("state/skills.lock");
        let mut lock = Lock::open(&path);
        assert!(!lock.is_trusted(&skill, "h1"));
        lock.trust(&skill, "h1".into()).unwrap();
        let lock = Lock::open(&path);
        assert!(lock.is_trusted(&skill, "h1"));
        assert!(
            !lock.is_trusted(&skill, "h2"),
            "a changed folder needs consent again"
        );
        skill.manifest.hosts.push("example.com".into());
        assert!(
            !lock.is_trusted(&skill, "h1"),
            "a new host needs consent again"
        );
    }

    #[test]
    fn a_missing_or_corrupt_lock_trusts_nothing() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("skills.lock");
        fs::write(&path, "not json").unwrap();
        let skill = manifest::load(&skill_dir(root.path())).unwrap();
        assert!(!Lock::open(&path).is_trusted(&skill, "h1"));
    }
}
