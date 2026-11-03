//! The private borrow on real Sepolia, through the real terminal: the compiled `edw-tui` in a
//! pseudo-terminal, the scripted model, the pinned edw, Docker for the skill's script, and the
//! public bundler. Moves real Sepolia funds.
//!
//! Needs a wallet whose profile 0/0 holds a mined 0.1 ETH shielded note (one in a pool with a
//! paymaster): `EDW_TUI_LIVE_DATA_DIR` is its edw data dir, with the Sepolia RPC already set
//! (`edw network rpc-config add … --use`). `EDW_DECRYPTION_PASSWORD` defaults to the demo one and
//! `EDW_TUI_LIVE_RUNTIME_DIR` to `<data dir>/../runtime`. `EDW_TUI_E2E_RECORD=1` also records
//! `target/e2e-screenshots/private_borrow_live.mp4`.
//!
//! `EDW_TUI_LIVE_DATA_DIR=… EDW_TUI_E2E_RECORD=1 cargo test --test e2e_private_borrow_live -- --ignored --nocapture`

mod common;

use std::path::PathBuf;

use common::{
    edw_binary,
    pty::Tui,
    scenario::{recording, screenshots_dir},
};

const ROWS: u16 = 50;
const COLS: u16 = 240;
const PROMPT: &str = "privately borrow 100 DAI against 0.1 ETH";

#[test]
#[ignore = "moves real Sepolia funds; needs EDW_TUI_LIVE_DATA_DIR, edw, Docker and the network"]
fn the_private_borrow_on_real_sepolia() {
    let Ok(data_dir) = std::env::var("EDW_TUI_LIVE_DATA_DIR") else {
        eprintln!("skipping: EDW_TUI_LIVE_DATA_DIR is not set");
        return;
    };
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return;
    };
    let data_dir = PathBuf::from(data_dir);
    let runtime_dir = std::env::var("EDW_TUI_LIVE_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| data_dir.join("../runtime"));
    let state = std::env::temp_dir().join(format!("edw-tui-live-skills-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&state);
    let env = vec![
        ("EDW_TUI_MODEL", "scripted".to_owned()),
        ("EDW_BIN", binary.display().to_string()),
        ("EDW_DATA_DIR", data_dir.display().to_string()),
        ("EDW_RUNTIME_DIR", runtime_dir.display().to_string()),
        (
            "EDW_DECRYPTION_PASSWORD",
            std::env::var("EDW_DECRYPTION_PASSWORD").unwrap_or_else(|_| "edw-tui-demo".into()),
        ),
        (
            "EDW_TUI_SKILLS_DIR",
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("skills")
                .display()
                .to_string(),
        ),
        (
            "EDW_TUI_SKILLS_DRAFTS_DIR",
            state.join("drafts").display().to_string(),
        ),
        (
            "EDW_TUI_SKILLS_LOCK",
            state.join("skills.lock").display().to_string(),
        ),
        (
            "EDW_TUI_SKILLS_USER_DIR",
            state.join("added").display().to_string(),
        ),
    ];
    let mut tui = Tui::spawn(
        &PathBuf::from(env!("CARGO_BIN_EXE_edw-tui")),
        &env,
        ROWS,
        COLS,
    );
    if recording() {
        tui.start_recording();
    }
    tui.wait_for("Ask in plain language");
    tui.linger(800);

    loop {
        let screen = tui.wait_for_within("the skills to settle", 180, |s| {
            s.contains("Allow skill") || !s.contains("Preparing skills")
        });
        if !screen.contains("Allow skill") {
            break;
        }
        tui.hold(4000);
        tui.answer(b"y");
        tui.wait_for_within("the card to close", 30, |s| s != screen);
    }

    tui.submit("unlock sepolia");
    tui.wait_for_within("the unlock confirmation", 120, |s| s.contains("[y] run"));
    tui.hold(3000);
    tui.answer(b"y");
    tui.wait_for_within("the unlock", 120, |s| s.contains("edw: Done"));
    tui.wait_for_within("the agent to finish", 120, |s| !s.contains("thinking…"));
    tui.linger(1500);

    tui.submit(PROMPT);
    tui.wait_for_within("the review card", 900, |s| {
        s.contains("[y] ") || s.contains("nothing was sent")
    });
    tui.hold(10_000);
    let card = tui.screen();
    assert!(card.contains("[y] "), "no review card:\n{card}");
    std::fs::write(
        screenshots_dir().join("private_borrow_live_card.txt"),
        &card,
    )
    .unwrap();
    tui.answer(b"y");

    let end = tui.wait_for_within("the unshield to land", 900, |s| {
        s.contains("✓ send") || s.contains("nothing was sent")
    });
    tui.wait_for_within("the agent to finish", 300, |s| !s.contains("thinking…"));
    std::fs::write(
        screenshots_dir().join("private_borrow_live_end.txt"),
        tui.screen(),
    )
    .unwrap();
    tui.linger(1500);
    if let Some(video) = tui.finish_recording(&screenshots_dir(), "private_borrow_live") {
        eprintln!("recorded {}", video.display());
    }
    assert!(end.contains("✓ send"), "the borrow did not land:\n{end}");
}
