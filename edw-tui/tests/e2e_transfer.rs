//! End to end through a real terminal: the compiled `edw-tui` in a pseudo-terminal, driven by
//! keystrokes like a person, with the scripted model (deterministic), real `edw`, and a
//! throwaway anvil chain.
//!
//! Steps: 0. start anvil; a. create profiles alice and bob; b. fund alice
//! (`anvil_setBalance`); c. send 0.1 ETH from alice to bob through the review modal.
//!
//! The wallet is seeded with Foundry's well-known test mnemonic (the way edw's own first
//! unlock seeds a random one), so every address and even the transaction hash are the same on
//! every run. Screenshots of the review modal and the final screen are written to
//! `target/e2e-screenshots/` (SVG for people, TXT for diffs) for a person to look at; they are
//! NOT asserted. What the test asserts is the chain: bob's balance rises by exactly 0.1 ETH,
//! alice's falls by exactly 0.1 ETH plus the fee in the transaction's own receipt, and the one
//! mined transaction went from alice to bob and succeeded.
//!
//! `EDW_TUI_E2E_RECORD=1` also records the whole session to
//! `target/e2e-screenshots/transfer.mp4`; it needs `rsvg-convert` and `ffmpeg`. Skips when `edw` or `anvil` is missing, or when the installed
//! edw is not the pinned one (its startup warning would change the screen).

mod common;

use std::path::PathBuf;

use alloy_node_bindings::Anvil;
use alloy_primitives::{Address, U256};
use alloy_provider::{Provider, ProviderBuilder};
use alloy_rpc_types_eth::BlockNumberOrTag;
use common::{TempWallet, edw_binary, pty::Tui};
use edw_tui::{
    edw::{self, Pin},
    interim::Interim,
};

const ROWS: u16 = 50;
const COLS: u16 = 240;
const ETHER: u128 = 1_000_000_000_000_000_000;

fn screenshots_dir() -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target/e2e-screenshots");
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Saves the screen as SVG and text for a person to look at. Not asserted: the screen's layout is
/// not the behaviour under test, and the chain state at the end of `alice_sends_bob_…` is.
fn screenshot(tui: &Tui, name: &str) {
    let dir = screenshots_dir();
    std::fs::write(dir.join(format!("{name}.svg")), tui.screenshot_svg()).unwrap();
    std::fs::write(dir.join(format!("{name}.txt")), tui.screen()).unwrap();
}

/// Waits until the agent has answered and the input is free again.
fn idle(tui: &Tui) {
    tui.wait_until("the agent to finish", |s| !s.contains("thinking…"));
}

/// Answers a confirmation modal with `y` and waits for `done` on screen.
fn confirm(tui: &mut Tui, done: &str) {
    tui.wait_for("[y] run");
    tui.answer(b"y");
    tui.wait_for(done);
    idle(tui);
}

/// Foundry's public test mnemonic. Never holds real funds.
const TEST_MNEMONIC: &str = "test test test test test test test test test test test junk";

/// Creates the local network's store as edw's first unlock does (encrypted with the password,
/// mnemonic 0, profile 0), but with a known mnemonic instead of a random one.
async fn seed_wallet(config: &edw::EdwConfig) {
    use std::sync::Arc;

    use edw_core::database::{Database, encrypted::EncryptedDatabase, file::FileDatabase};
    let dir = config.data_dir.join("local");
    std::fs::create_dir_all(&dir).unwrap();
    let backend: Arc<dyn Database> = Arc::new(FileDatabase::open(&dir).unwrap());
    let store: Arc<dyn Database> = Arc::new(
        EncryptedDatabase::create(backend, config.password.as_bytes())
            .await
            .unwrap(),
    );
    let record = edw_core::mnemonic::add_mnemonic(store.clone(), TEST_MNEMONIC.to_owned().into())
        .await
        .unwrap();
    edw_core::profile::simple::bootstrap_profile(store, record.index, 0, None)
        .await
        .unwrap();
}

async fn eth(rpc: &str, who: Address) -> U256 {
    ProviderBuilder::new()
        .connect_http(rpc.parse().unwrap())
        .get_balance(who)
        .await
        .unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn alice_sends_bob_one_tenth_of_an_eth() {
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return;
    };
    if edw::check_pin(&binary) != Pin::Matches {
        eprintln!("skipping: the installed edw is not the pinned revision");
        return;
    }

    // 0. A throwaway chain.
    let Ok(chain) = Anvil::new().try_spawn() else {
        eprintln!("skipping: cannot start anvil");
        return;
    };
    let rpc = chain.endpoint();

    let wallet = TempWallet::new(binary.clone(), "e2e");
    let config = &wallet.config;
    seed_wallet(config).await;
    let mut tui = Tui::spawn(
        &PathBuf::from(env!("CARGO_BIN_EXE_edw-tui")),
        &[
            ("EDW_TUI_MODEL", "scripted".into()),
            ("EDW_BIN", binary.display().to_string()),
            ("EDW_DATA_DIR", config.data_dir.display().to_string()),
            ("EDW_RUNTIME_DIR", config.runtime_dir.display().to_string()),
            ("EDW_DECRYPTION_PASSWORD", config.password.clone()),
            ("EDW_TUI_RPC_URL", rpc.clone()),
        ],
        ROWS,
        COLS,
    );
    if std::env::var("EDW_TUI_E2E_RECORD").is_ok_and(|v| !v.is_empty() && v != "0") {
        tui.start_recording();
    }
    tui.wait_for("Ask in plain language");
    tui.linger(800);

    // a. A wallet on the local chain, and two profiles in it.
    tui.submit("unlock local");
    confirm(&mut tui, "Unlocked local");
    tui.submit("add a profile named alice");
    confirm(&mut tui, "Created profile 0/1 (alice)");
    tui.submit("add a profile named bob");
    confirm(&mut tui, "Created profile 0/2 (bob)");

    // Alice sends from here on.
    tui.submit("/profile alice");
    tui.wait_for("from alice");
    idle(&tui);

    // b. Fund alice on anvil.
    let interim = Interim::new(wallet.interim(Some(rpc.clone()), false));
    let alice = interim.address(Some("alice")).await.unwrap();
    let bob = interim.address(Some("bob")).await.unwrap();
    let provider = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    let _: () = provider
        .raw_request("anvil_setBalance".into(), (alice, U256::from(10 * ETHER)))
        .await
        .unwrap();

    let alice_before = eth(&rpc, alice).await;
    let bob_before = eth(&rpc, bob).await;
    assert_eq!(alice_before, U256::from(10 * ETHER));

    // c. Alice sends 0.1 ETH to bob; the review modal shows the dry run first.
    tui.submit(&format!("send 0.1 ETH to {bob}"));
    let review = tui.wait_for("Send this transaction?");
    assert!(
        review.contains("From     alice (0/1)") && review.contains(&bob.to_string()),
        "{review}"
    );
    screenshot(&tui, "transfer_review");
    tui.linger(2500); // time to read the dry run
    tui.answer(b"y");
    tui.wait_for("succeeded");
    idle(&tui);
    screenshot(&tui, "transfer_final");
    tui.linger(1500);
    if let Some(video) = tui.finish_recording(&screenshots_dir(), "transfer") {
        eprintln!("recorded {}", video.display());
    }

    // The chain is the verdict. anvil mines one block per transaction and funding alice was a
    // state override, not a transaction, so the latest block holds exactly the transfer.
    let block = provider
        .get_block_by_number(BlockNumberOrTag::Latest)
        .await
        .unwrap()
        .expect("anvil has a latest block");
    let hashes: Vec<_> = block.transactions.hashes().collect();
    assert_eq!(
        hashes.len(),
        1,
        "exactly one transaction was mined: {hashes:?}"
    );
    let receipt = provider
        .get_transaction_receipt(hashes[0])
        .await
        .unwrap()
        .expect("the transfer has a receipt");
    assert!(receipt.status(), "the transfer succeeded on chain");
    assert_eq!(receipt.from, alice, "sent from alice");
    assert_eq!(receipt.to, Some(bob), "sent to bob");
    let fee = U256::from(receipt.gas_used) * U256::from(receipt.effective_gas_price);

    let value = U256::from(ETHER / 10);
    assert_eq!(
        eth(&rpc, bob).await - bob_before,
        value,
        "bob gains exactly 0.1 ETH"
    );
    assert_eq!(
        alice_before - eth(&rpc, alice).await,
        value + fee,
        "alice pays exactly 0.1 ETH plus the fee in the receipt"
    );
    assert!(tui.quit(), "edw-tui exits cleanly on Ctrl-C");
}
