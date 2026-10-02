//! Skill approval inside the real TUI: the binary in a pseudo-terminal shows one card per new
//! skill, takes y or n, and starts chatting with only the allowed ones.

mod common;

use std::{fs, path::PathBuf, thread, time::Duration};

use common::pty::Tui;

fn knowledge_skill(root: &std::path::Path, name: &str) {
    let dir = root.join(name);
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: The {name} skill, for this test.\n---\nbody\n"),
    )
    .unwrap();
}

#[test]
fn skills_are_approved_on_cards_and_managed_in_the_skills_tab() {
    let root = tempfile::tempdir().unwrap();
    let skills = root.path().join("skills");
    knowledge_skill(&skills, "alpha");
    knowledge_skill(&skills, "beta");
    let downloads = root.path().join("downloads");
    knowledge_skill(&downloads, "gamma");
    let gamma = downloads.join("gamma");
    let added = root.path().join("config/user-skills");
    let lock = root.path().join("config/skills.lock");

    let mut tui = Tui::spawn(
        &PathBuf::from(env!("CARGO_BIN_EXE_edw-tui")),
        &[
            ("EDW_TUI_MODEL", "scripted".into()),
            (
                "EDW_DATA_DIR",
                root.path().join("data").display().to_string(),
            ),
            (
                "EDW_RUNTIME_DIR",
                root.path().join("run").display().to_string(),
            ),
            ("EDW_TUI_SKILLS_DIR", skills.display().to_string()),
            ("EDW_TUI_SKILLS_LOCK", lock.display().to_string()),
            ("EDW_TUI_SKILLS_USER_DIR", added.display().to_string()),
        ],
        30,
        110,
    );
    let screen = tui.wait_for("Allow skill alpha? (1 of 2)");
    for needle in [
        "alpha 0 · new · sha256",
        "The alpha skill, for this test.",
        "nothing (read-only)",
        "TOOLS      none (instructions only)",
        "WEB        none",
        "[y] allow",
    ] {
        assert!(screen.contains(needle), "missing {needle:?} in\n{screen}");
    }

    // Past the grace period, so the keys count.
    thread::sleep(Duration::from_millis(600));
    tui.press(b"y");
    tui.wait_for("Allow skill beta? (2 of 2)");
    thread::sleep(Duration::from_millis(600));
    tui.press(b"n");
    // The card closes; the status bar's hints are past the screen edge here (long temp paths),
    // so give startup a moment to finish (no Docker check: these skills have no scripts).
    for _ in 0..50 {
        if !tui.screen().contains("Allow skill") {
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }
    assert!(!tui.screen().contains("Allow skill"), "{}", tui.screen());
    thread::sleep(Duration::from_millis(500));

    let lock_text = fs::read_to_string(&lock).unwrap();
    assert!(lock_text.contains("\"name\": \"alpha\""), "{lock_text}");
    assert!(!lock_text.contains("beta"), "{lock_text}");

    // The Skills tab: /skills opens it.
    tui.type_text("/skills");
    tui.press(b"\r");
    let screen = tui.wait_for("Skills · Tab: chat");
    assert!(screen.contains("alpha"), "{screen}");
    assert!(screen.contains("declined"), "{screen}");
    assert!(screen.contains("↑↓ select · d disable"), "{screen}");

    // d disables the selected skill (alpha, the first).
    tui.press(b"d");
    tui.wait_for("disabled");

    // a adds a folder: its approval card comes up in the TUI, y keeps it.
    tui.press(b"a");
    tui.wait_for("Skill folder:");
    tui.type_text(&gamma.display().to_string());
    tui.press(b"\r");
    tui.wait_for("Allow skill gamma?");
    thread::sleep(Duration::from_millis(600));
    tui.press(b"y");
    let screen = tui.wait_for("gamma");
    assert!(added.join("gamma/SKILL.md").exists(), "{screen}");

    // x deletes it again, after a y/n.
    tui.press(b"\x1b[B");
    tui.press(b"\x1b[B");
    tui.wait_for("▶ ● gamma");
    tui.press(b"x");
    tui.wait_for("Delete gamma from disk?");
    tui.press(b"y");
    for _ in 0..50 {
        if !added.join("gamma").exists() {
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }
    assert!(!added.join("gamma").exists(), "{}", tui.screen());
}
