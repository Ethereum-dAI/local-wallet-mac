//! End-to-end acceptance test (the goal's verification): on an anvil **Sepolia fork**,
//! shield native ETH into RAILGUN and then unshield it, with the unshield relayed by the
//! locally-run `railgun-broadcaster` process. Asserts both txs confirm on-chain and that
//! the unshield was submitted by the broadcaster's own EOA.
//!
//! Run: `RPC_URL_SEPOLIA=<sepolia-rpc> cargo test --features fork-sync --test e2e_fork -- --ignored --nocapture`
//! (or `scripts/e2e-fork.sh`). `#[ignore]` by default — needs network + anvil.
//!
//! Requires the `fork-sync` feature so the sidecar caps Subsquid sync at the fork block.

#![cfg(feature = "fork-sync")]

use std::process::{Child, Command};
use std::time::{Duration, Instant};

use alloy::network::Ethereum;
use alloy::primitives::{address, Address, U256};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::sol;
use eip_1193_provider::tx_data::TxData;
use railgun_helper::rpc;
use serde_json::json;

// Well-known anvil dev keys (testnet only).
const OWNER_KEY: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const BROADCASTER_KEY: &str = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
const BROADCASTER_ADDR: Address = address!("0x70997970C51812dc3A010C7d01b50e0d17dc79C8");
// A fresh recipient EOA, distinct from owner/broadcaster.
const RECIPIENT: Address = address!("0x1111111111111111111111111111111111111111");
// WETH on Sepolia (== ChainConfig::sepolia().wrapped_base_token). Unshield delivers WETH.
const WETH: Address = address!("0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14");

// The block the Kohaku crate's own transact_utxo.rs fork test uses — known Subsquid-indexed.
const FORK_BLOCK: u64 = 10822990;
const ANVIL_PORT: u16 = 8599;
const SHIELD_WEI: u128 = 1_000_000;
const UNSHIELD_WEI: u128 = 1_000;

sol! {
    #[sol(rpc)]
    contract WETH { function balanceOf(address) external view returns (uint256); }
}

/// Kills its child on drop so a panicking assertion never leaks anvil/sidecars.
struct Killer(Child);
impl Drop for Killer {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn anvil_url() -> String {
    format!("http://127.0.0.1:{ANVIL_PORT}")
}

async fn wait_for_rpc(url: &str, secs: u64) {
    let deadline = Instant::now() + Duration::from_secs(secs);
    loop {
        if let Ok(p) = ProviderBuilder::new().network::<Ethereum>().connect(url).await {
            if p.get_chain_id().await.is_ok() {
                return;
            }
        }
        assert!(Instant::now() < deadline, "anvil not ready after {secs}s");
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
}

async fn wait_for_socket(path: &str, secs: u64) {
    let deadline = Instant::now() + Duration::from_secs(secs);
    loop {
        if tokio::net::UnixStream::connect(path).await.is_ok() {
            return;
        }
        assert!(Instant::now() < deadline, "socket {path} not ready after {secs}s");
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "needs RPC_URL_SEPOLIA + anvil + network (proving artifacts, Subsquid)"]
async fn shield_then_unshield_via_local_broadcaster() {
    let rpc = std::env::var("RPC_URL_SEPOLIA").expect("set RPC_URL_SEPOLIA to a Sepolia RPC");
    let dir = tempfile::tempdir().unwrap();
    let helper_sock = dir.path().join("helper.sock").to_string_lossy().to_string();
    let bc_sock = dir.path().join("bc.sock").to_string_lossy().to_string();
    let entropy = "0x1122334455667788990011223344556677889900112233445566778899001122";
    let (htok, btok) = ("helper-token", "bc-token");

    // 1. anvil fork of Sepolia.
    let _anvil = Killer(
        Command::new("anvil")
            .args([
                "--fork-url", &rpc,
                "--fork-block-number", &FORK_BLOCK.to_string(),
                "--port", &ANVIL_PORT.to_string(),
                "--silent",
            ])
            .env("FOUNDRY_DISABLE_NIGHTLY_WARNING", "1")
            .spawn()
            .expect("spawn anvil (is foundry installed?)"),
    );
    wait_for_rpc(&anvil_url(), 60).await;

    // 2. sidecar (RAILGUN provider) — env-configured against the fork.
    let _helper = Killer(
        Command::new(env!("CARGO_BIN_EXE_railgun-helper"))
            .env("RAILGUN_RPC_URL", anvil_url())
            .env("RAILGUN_ENTROPY_HEX", entropy)
            .env("RAILGUN_FORK_BLOCK", FORK_BLOCK.to_string())
            .env("RAILGUN_SOCKET", &helper_sock)
            .env("RAILGUN_TOKEN", htok)
            .spawn()
            .expect("spawn railgun-helper"),
    );

    // 3. LOCAL BROADCASTER process — owns its own EOA (anvil key #1).
    let _bc = Killer(
        Command::new(env!("CARGO_BIN_EXE_railgun-broadcaster"))
            .env("RAILGUN_RPC_URL", anvil_url())
            .env("RAILGUN_BROADCASTER_KEY", BROADCASTER_KEY)
            .env("RAILGUN_BROADCASTER_SOCKET", &bc_sock)
            .env("RAILGUN_BROADCASTER_TOKEN", btok)
            .spawn()
            .expect("spawn railgun-broadcaster"),
    );

    // RailgunHelper::new syncs on register, so allow generous startup.
    wait_for_socket(&bc_sock, 60).await;
    wait_for_socket(&helper_sock, 180).await;

    // broadcaster reports its own EOA address.
    let bc_addr = rpc::call(&bc_sock, btok, "address", json!(null)).await.unwrap();
    assert_eq!(
        bc_addr["address"].as_str().unwrap().to_lowercase(),
        format!("{BROADCASTER_ADDR:?}").to_lowercase()
    );

    // owner provider submits the (public) shield tx(s).
    let owner: alloy::signers::local::PrivateKeySigner = OWNER_KEY.parse().unwrap();
    let owner_provider = ProviderBuilder::new()
        .network::<Ethereum>()
        .wallet(owner)
        .connect(&anvil_url())
        .await
        .unwrap()
        .erased();

    // 4. SHIELD: helper builds tx(s), owner self-submits each.
    let shield_txs = rpc::call(&helper_sock, htok, "prepareShield", json!({"amountWei": SHIELD_WEI.to_string()}))
        .await
        .expect("prepareShield");
    let txs: Vec<TxData> = serde_json::from_value(shield_txs).expect("shield tx list");
    assert!(!txs.is_empty(), "expected >=1 shield tx");
    for tx in txs {
        let receipt = owner_provider
            .send_transaction(tx.into())
            .await
            .expect("send shield")
            .get_receipt()
            .await
            .expect("shield receipt");
        assert!(receipt.status(), "shield tx must succeed: {:?}", receipt.transaction_hash);
        eprintln!("[e2e] shield tx {:?} in block {:?}", receipt.transaction_hash, receipt.block_number);
    }

    // 5. balance reflects the shielded deposit.
    let bal = rpc::call(&helper_sock, htok, "balance", json!(null)).await.expect("balance");
    let total = u128::from_str_radix(bal["total"].as_str().unwrap().trim_start_matches("0x"), 16).unwrap();
    eprintln!("[e2e] shielded balance total = {total} wei ({bal})");
    assert!(total >= SHIELD_WEI * 99 / 100, "shielded balance {total} too low");

    let weth = WETH::new(WETH, &owner_provider);
    let before = weth.balanceOf(RECIPIENT).call().await.unwrap();
    assert_eq!(before, U256::ZERO, "recipient should start with 0 WETH");

    // 6. UNSHIELD: helper proves the tx (Groth16; may download artifacts, tens of seconds).
    eprintln!("[e2e] proving unshield (may download circuit artifacts)...");
    let proved = rpc::call(
        &helper_sock,
        htok,
        "prepareUnshield",
        json!({"amountWei": UNSHIELD_WEI.to_string(), "to": format!("{RECIPIENT:?}")}),
    )
    .await
    .expect("prepareUnshield");
    let proved_tx: TxData = serde_json::from_value(proved).expect("proved tx");

    // 7. RELAY via the LOCAL BROADCASTER process (its own EOA submits).
    let relay = rpc::call(&bc_sock, btok, "relay", serde_json::to_value(&proved_tx).unwrap())
        .await
        .expect("relay");
    eprintln!("[e2e] relay receipt = {relay}");
    assert!(relay["status"].as_bool().unwrap(), "unshield relay must succeed");
    let unshield_hash = relay["txHash"].as_str().unwrap().to_string();

    // 8. Assertions: recipient received WETH, and the LOCAL BROADCASTER submitted it.
    let after = weth.balanceOf(RECIPIENT).call().await.unwrap();
    eprintln!("[e2e] recipient WETH: {before} -> {after}");
    assert!(after > U256::ZERO, "recipient must receive unshielded WETH");
    assert!(after <= U256::from(UNSHIELD_WEI), "cannot exceed unshield amount");
    assert!(after >= U256::from(UNSHIELD_WEI * 95 / 100), "received {after} < ~95% of {UNSHIELD_WEI}");

    let tx = owner_provider
        .get_transaction_by_hash(unshield_hash.parse().unwrap())
        .await
        .unwrap()
        .expect("unshield tx present");
    assert_eq!(
        tx.inner.signer(),
        BROADCASTER_ADDR,
        "unshield MUST be submitted by the local broadcaster EOA, not the owner"
    );

    eprintln!("[e2e] PASS: shield + unshield confirmed on-chain; broadcaster relayed the unshield.");
}
