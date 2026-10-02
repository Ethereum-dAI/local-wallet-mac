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
fn new_skills_are_approved_on_cards_in_the_tui() {
    let root = tempfile::tempdir().unwrap();
    let skills = root.path().join("skills");
    knowledge_skill(&skills, "alpha");
    knowledge_skill(&skills, "beta");
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

    tui.type_text("/skills");
    tui.press(b"\r");
    let screen = tui.wait_for("declined this session");
    assert!(screen.contains("alpha (ready)"), "{screen}");
    assert!(screen.contains("beta (declined this session)"), "{screen}");

    let lock = fs::read_to_string(&lock).unwrap();
    assert!(lock.contains("\"name\": \"alpha\""), "{lock}");
    assert!(!lock.contains("beta"), "{lock}");
}
