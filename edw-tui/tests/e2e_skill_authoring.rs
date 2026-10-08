//! Skill authoring end to end through the real terminal, on an anvil fork of Ethereum mainnet:
//! the shipped skills are approved except `safe-multisig` (it is left out of the skills folder),
//! then `/skill new` has the scripted model drive the real authoring tools to draft a read-only
//! Safe skill, `/skill install` reviews and installs it on the normal approval card, and the new
//! skill answers a question about a real Safe from the chain, in the Docker sandbox. Uses the
//! scripted model, the pinned edw, and Docker.
//!
//! Needs the network (the fork): `cargo test --test e2e_skill_authoring -- --ignored`.
//! `EDW_TUI_E2E_RECORD=1` also records `target/e2e-screenshots/skill-authoring.mp4`.

mod common;

use std::{
    fs,
    path::{Path, PathBuf},
};

use common::scenario::{Chain, Scenario};
use edw_tui::skills::sandbox;

/// A 4-of-11 mainnet Safe (the one `e2e_safe` asks about).
const MAINNET_SAFE: &str = "0xA03be496e67Ec29bC62F01a428683D7F9c204930";

/// A copy of the shipped skills without `omit`.
fn copy_skills_without(from: &Path, to: &Path, omit: &str) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        if entry.file_name() == omit {
            continue;
        }
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_skills_without(&entry.path(), &target, omit);
        } else {
            fs::copy(entry.path(), target).unwrap();
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "forks mainnet over the network; needs anvil, edw and Docker"]
async fn a_safe_skill_is_authored_installed_and_used() {
    if !sandbox::docker_available().await {
        eprintln!("skipping: Docker is not running");
        return;
    }
    let shipped = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("skills");
    let without_safe = tempfile::tempdir().unwrap();
    copy_skills_without(&shipped, without_safe.path(), "safe-multisig");
    assert!(!without_safe.path().join("safe-multisig").exists());

    let Some(mut s) = Scenario::start_with_skills_dir(
        "skill-authoring",
        Chain::MainnetFork,
        without_safe.path().to_owned(),
    )
    .await
    else {
        return;
    };
    s.confirmed("unlock mainnet", "Unlocked");
    let state = s.wallet.config.data_dir.join("skills-state");
    let drafts = state.join("drafts");
    let added = state.join("added");

    // Author: the model drives the real tools; the check must really pass.
    s.ask(
        "/skill new a read-only skill that shows who owns a Safe, its threshold and nonce",
        "/skill install safe-multisig",
    );
    s.screenshot("draft_ready");
    let screen = s.tui.screen();
    for step in [
        "skill_draft_write safe-multisig",
        "skill_draft_check safe-multisig",
    ] {
        assert!(screen.contains(step), "{step} missing:\n{screen}");
    }
    for file in ["SKILL.md", "skill.toml", "scripts/safe_info.py"] {
        assert!(drafts.join("safe-multisig").join(file).is_file(), "{file}");
    }
    assert!(!added.join("safe-multisig").exists(), "not installed yet");

    // Install: the normal approval card, read, then allowed.
    s.tui.submit("/skill install safe-multisig");
    s.tui.wait_for_within("the approval card", 120, |s| {
        s.contains("Allow skill safe-multisig")
    });
    s.tui.linger(2500);
    s.screenshot("consent_card");
    s.tui.answer(b"y");
    s.tui.wait_for_within("the card to close", 60, |s| {
        !s.contains("Allow skill safe-multisig")
    });
    s.idle();
    assert!(added.join("safe-multisig/SKILL.md").is_file());
    assert!(
        drafts.join("safe-multisig/SKILL.md").is_file(),
        "the draft stays"
    );

    // The Skills tab lists it as ready.
    s.tui.submit("/skills");
    s.tui
        .wait_for_within("the Skills tab", 30, |s| s.contains("safe-multisig"));
    s.tui.linger(2000);
    s.screenshot("skills_tab");
    let tab = s.tui.screen();
    assert!(tab.contains("safe-multisig") && tab.contains('●'), "{tab}");
    s.tui.press(b"\t"); // back to the chat

    // Use: the drafted skill's script runs in the sandbox and reads the Safe from the chain.
    s.ask(
        &format!("who controls safe {MAINNET_SAFE}?"),
        "4 of 11 owners must sign",
    );
    s.screenshot("safe_answer");
    let answer = s.tui.screen();
    assert!(answer.contains("skill safe-multisig/safe_info"), "{answer}");
    assert!(answer.contains("4 of 11 owners must sign"), "{answer}");
    s.finish("skill-authoring");
}
