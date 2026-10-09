//! Skill authoring end to end through the real terminal, on an anvil fork of Ethereum mainnet:
//! the shipped skills are approved except `safe-multisig` (it is left out of the skills folder),
//! then `/skill new` has the scripted model drive the real authoring tools to draft a read-only
//! Safe skill, the model offers it and the user allows it on the normal approval card, and the new
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

    // Author: the model drives the real tools; the check must really pass, and the model then
    // offers the draft: the user's approval card follows its reply.
    s.ask(
        "/skill new a read-only skill that shows who owns a Safe, its threshold and nonce",
        "Is that what you want",
    );
    s.screenshot("question");
    assert!(
        !drafts.join("safe-multisig").exists(),
        "nothing is written before the user answers"
    );
    s.tui.linger(2500);
    s.tui.submit(
        "Yes, build it: the Safe skill on Ethereum mainnet only, read-only, no other chains.",
    );
    s.tui.wait_for_within("the approval card", 240, |s| {
        s.contains("Allow skill safe-multisig")
    });
    s.screenshot("draft_ready");
    let screen = s.tui.screen();
    for step in [
        "skill_draft_write safe-multisig",
        "skill_draft_check safe-multisig",
        "skill_draft_install safe-multisig",
    ] {
        assert!(screen.contains(step), "{step} missing:\n{screen}");
    }
    for file in ["SKILL.md", "skill.toml", "scripts/safe_info.py"] {
        assert!(drafts.join("safe-multisig").join(file).is_file(), "{file}");
    }

    // The card is read, then allowed.
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

/// A real Ollama model (`EDW_TUI_E2E_MODEL`, default qwen3:8b) is asked to author a skill. What
/// it writes is not scripted, so this only reports: the screen, the files, and the real check.
/// `cargo test --test e2e_skill_authoring real_model -- --ignored --nocapture`
#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs Ollama, Docker, anvil and edw; the outcome depends on the model"]
async fn real_model_drafts_a_skill() {
    if !sandbox::docker_available().await {
        eprintln!("skipping: Docker is not running");
        return;
    }
    let model = std::env::var("EDW_TUI_E2E_MODEL").unwrap_or_else(|_| "qwen3:8b".into());
    // SAFETY: set before the scenario spawns anything, in a test with no other threads reading it.
    unsafe { std::env::set_var("EDW_TUI_E2E_MODEL", &model) };
    let Some(mut s) = Scenario::start_with_skills("real-model-authoring", Chain::Local).await
    else {
        return;
    };
    let drafts = s.wallet.config.data_dir.join("skills-state/drafts");
    s.tui.submit(&format!(
        "/skill new a read-only skill that shows who owns the Safe {MAINNET_SAFE} on chain 1, its threshold and nonce"
    ));
    // The turn cap (10) can stop a model mid-draft, as a user would see; a user says "continue".
    for round in 0..4 {
        s.tui.wait_for_within("the turn to end", 900, |s| {
            s.contains("edw:") || s.contains("error:")
        });
        s.idle();
        let screen = s.tui.screen();
        if screen.contains("no problems found") || screen.contains("The draft loads") {
            break;
        }
        eprintln!("round {round}: not checked clean yet; saying continue");
        s.tui.submit(&format!(
            "Continue the Safe skill (a script tool that reads the owners, threshold and nonce of {MAINNET_SAFE}): call skill_draft_check, fix each error it reports with skill_draft_write, then tell me it is ready."
        ));
    }
    eprintln!("model={model}\n{}", s.tui.screen());
    let mut any = false;
    for entry in fs::read_dir(&drafts).into_iter().flatten().flatten() {
        any = true;
        let report = edw_tui::skills::author::check(&entry.path());
        eprintln!(
            "draft {:?}: ok={} errors={:?} warnings={:?}",
            entry.file_name(),
            report.ok(),
            report.errors,
            report.warnings
        );
    }
    assert!(any, "the model wrote no draft");
}

/// A real model can take minutes for one answer.
fn wait_idle(s: &Scenario) {
    s.tui
        .wait_for_within("the agent to finish", 900, |s| !s.contains("thinking…"));
}

/// The whole flow with a real Ollama model (`EDW_TUI_E2E_MODEL`, default qwen3:8b) on a mainnet
/// fork: it drafts a Safe skill, the user installs it, and the model then uses it. Nothing is
/// scripted, so the outcome depends on the model. `EDW_TUI_E2E_RECORD=1` records
/// `target/e2e-screenshots/skill-authoring-real-model.mp4`.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs Ollama, Docker, anvil, edw and the network; the outcome depends on the model"]
async fn real_model_authors_installs_and_uses_a_skill() {
    if !sandbox::docker_available().await {
        eprintln!("skipping: Docker is not running");
        return;
    }
    let model = std::env::var("EDW_TUI_E2E_MODEL").unwrap_or_else(|_| "qwen3:8b".into());
    // SAFETY: set before the scenario spawns anything, in a test with no other threads reading it.
    unsafe { std::env::set_var("EDW_TUI_E2E_MODEL", &model) };
    let shipped = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("skills");
    let without_safe = tempfile::tempdir().unwrap();
    copy_skills_without(&shipped, without_safe.path(), "safe-multisig");
    let Some(mut s) = Scenario::start_with_skills_dir(
        "skill-authoring-real-model",
        Chain::MainnetFork,
        without_safe.path().to_owned(),
    )
    .await
    else {
        return;
    };
    let state = s.wallet.config.data_dir.join("skills-state");

    // Reads on chain need the wallet unlocked.
    s.tui.submit("unlock mainnet");
    s.tui
        .wait_for_within("a confirmation", 600, |s| s.contains("[y] "));
    s.tui.linger(2000);
    s.tui.answer(b"y");
    s.idle();

    s.tui.submit(&format!(
        "/skill new a read-only skill with a script tool that reads who owns the Safe {MAINNET_SAFE} on chain 1, its threshold and nonce from the chain"
    ));
    for round in 0..4 {
        s.tui.wait_for_within("the turn to end", 900, |s| {
            s.contains("edw:") || s.contains("error:")
        });
        wait_idle(&s);
        let screen = s.tui.screen();
        let has_tool = fs::read_dir(state.join("drafts"))
            .into_iter()
            .flatten()
            .flatten()
            .any(|d| d.path().join("skill.toml").is_file());
        if has_tool && (screen.contains("no problems found") || screen.contains("The draft loads"))
        {
            break;
        }
        eprintln!("round {round}: not checked clean yet; saying continue");
        s.tui.submit(&format!(
            "Continue the Safe skill (a script tool that reads the owners, threshold and nonce of {MAINNET_SAFE}): call skill_draft_check, fix each error it reports with skill_draft_write, then tell me it is ready."
        ));
    }
    s.screenshot("draft_ready");
    eprintln!("{}", s.tui.screen());
    let draft = fs::read_dir(state.join("drafts"))
        .unwrap()
        .flatten()
        .filter(|d| {
            d.path().join("skill.toml").is_file() && edw_tui::skills::author::check(&d.path()).ok()
        })
        .map(|d| d.file_name().to_string_lossy().into_owned())
        .next()
        .expect("the model wrote no draft with a tool that passes the check");
    eprintln!("model={model} draft={draft}");

    // The model offers a clean draft itself; if it did not, the user's own command does.
    if !s.tui.screen().contains(&format!("Allow skill {draft}")) {
        s.tui.submit(&format!("/skill install {draft}"));
    }
    s.tui.wait_for_within("the approval card", 120, |s| {
        s.contains(&format!("Allow skill {draft}"))
    });
    s.tui.linger(2500);
    s.screenshot("consent_card");
    s.tui.answer(b"y");
    s.tui.wait_for_within("the card to close", 60, |s| {
        !s.contains(&format!("Allow skill {draft}"))
    });
    s.idle();
    assert!(state.join("added").join(&draft).join("SKILL.md").is_file());

    s.tui.submit(&format!(
        "Load the {draft} skill and use it to look up the owners, threshold and nonce of the Safe {MAINNET_SAFE} (read only, nothing to send)."
    ));
    s.tui.wait_for_within("a skill run", 900, |s| {
        s.contains(&format!("skill {draft}/"))
    });
    wait_idle(&s);
    s.tui.linger(2500);
    s.screenshot("skill_answer");
    let answer = s.tui.screen();
    eprintln!("{answer}");
    assert!(answer.contains(&format!("skill {draft}/")), "{answer}");
    s.finish("skill-authoring-real-model");
}
