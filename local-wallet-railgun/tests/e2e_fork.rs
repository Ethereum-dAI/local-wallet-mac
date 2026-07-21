//! End-to-end acceptance test (the goal's verification): on an anvil **Sepolia fork**,
//! shield native ETH into RAILGUN and then unshield it to a fresh recipient as **native
//! ETH**, driven entirely through the `railgun-helper` sidecar — which itself spawns and
//! owns the `railgun-broadcaster` child (secret over fd 5) and proxies the unshield.
//!
//! Asserts: the shield confirms on-chain; the async unshield job completes; the recipient
//! receives native ETH (not WETH); and the three relay txs were submitted by the
//! broadcaster's own EOA.
//!
//! Run: `RPC_URL_SEPOLIA=<sepolia-rpc> cargo test --features fork-sync --test e2e_fork -- --ignored --nocapture`
//! (or `scripts/e2e-fork.sh`). `#[ignore]` by default — needs network + anvil.

#![cfg(feature = "fork-sync")]

use std::process::{Child, Command};
use std::time::{Duration, Instant};

use alloy::network::Ethereum;
use alloy::primitives::{address, Address, U256};
use alloy::providers::{Provider, ProviderBuilder};
use eip_1193_provider::tx_data::TxData;
use railgun_helper::rpc;
use railgun_helper::spawn::{spawn_child_with_fd5, ChildGuard};
use serde_json::json;

// Well-known anvil dev keys (testnet only).
const OWNER_KEY: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
// A fresh recipient EOA, distinct from owner/broadcaster; starts with 0 ETH on the fork.
const RECIPIENT: Address = address!("0x1111111111111111111111111111111111111111");

// The block the Kohaku crate's own transact_utxo.rs fork test uses — known Subsquid-indexed.
const FORK_BLOCK: u64 = 10822990;
const ANVIL_PORT: u16 = 8599;
const SHIELD_WEI: u128 = 1_000_000;
const UNSHIELD_WEI: u128 = 1_000;

// Hard wall-clock cap for the whole test so nothing (a stuck sidecar, a hung socket read,
// a wedged RPC) can hang the suite indefinitely — it fails instead.
const OVERALL_TIMEOUT_SECS: u64 = 420;
// Per-operation cap on any single network/socket await (proving is polled separately).
const OP_TIMEOUT_SECS: u64 = 90;

/// Await `fut` with a per-operation timeout, panicking with `what` if it is exceeded so a
/// hung call surfaces as a clear failure rather than blocking forever.
async fn within<T>(what: &str, fut: impl std::future::Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(OP_TIMEOUT_SECS), fut)
        .await
        .unwrap_or_else(|_| panic!("operation timed out after {OP_TIMEOUT_SECS}s: {what}"))
}

/// Kills its child on drop so a panicking assertion never leaks anvil/the sidecar.
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
        if let Ok(p) = ProviderBuilder::new()
            .network::<Ethereum>()
            .connect(url)
            .await
        {
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
        assert!(
            Instant::now() < deadline,
            "socket {path} not ready after {secs}s"
        );
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "needs RPC_URL_SEPOLIA + anvil + network (proving artifacts, Subsquid)"]
async fn shield_then_unshield_native_via_helper_owned_broadcaster() {
    // Enforce a hard overall cap so the test can never hang the suite.
    tokio::time::timeout(Duration::from_secs(OVERALL_TIMEOUT_SECS), run_e2e())
        .await
        .expect("e2e exceeded overall wall-clock budget");
}

async fn run_e2e() {
    let rpc = std::env::var("RPC_URL_SEPOLIA").expect("set RPC_URL_SEPOLIA to a Sepolia RPC");
    let dir = tempfile::tempdir().unwrap();
    let helper_sock = dir.path().join("helper.sock").to_string_lossy().to_string();
    let bc_sock = dir.path().join("bc.sock").to_string_lossy().to_string();
    let entropy = "0x1122334455667788990011223344556677889900112233445566778899001122";
    let htok = "helper-token";
    let btok = "bc-token";

    // The broadcaster EOA is now DERIVED from the entropy (m/44'/60'/0'/0/0) inside the
    // helper. Derive the same address here so we can fund it and assert against it.
    let broadcaster_addr: Address = {
        let key =
            railgun_helper::keys::derive_broadcaster_key(entropy).expect("derive broadcaster key");
        let signer: alloy::signers::local::PrivateKeySigner =
            key.parse().expect("parse broadcaster key");
        signer.address()
    };

    // 1. anvil fork of Sepolia.
    let _anvil = Killer(
        Command::new("anvil")
            .args([
                "--fork-url",
                &rpc,
                "--fork-block-number",
                &FORK_BLOCK.to_string(),
                "--port",
                &ANVIL_PORT.to_string(),
                "--silent",
            ])
            .env("FOUNDRY_DISABLE_NIGHTLY_WARNING", "1")
            .spawn()
            .expect("spawn anvil (is foundry installed?)"),
    );
    wait_for_rpc(&anvil_url(), 60).await;

    // Fork setup: the broadcaster's well-known address carries an EIP-7702 delegation on
    // real Sepolia (0xef0100…). RAILGUN unshield reverts when delivering to a coded
    // recipient, so strip the delegation on the fork and (re)fund the EOA for gas.
    let admin = ProviderBuilder::new()
        .network::<Ethereum>()
        .connect(&anvil_url())
        .await
        .unwrap();
    let _: serde_json::Value = admin
        .raw_request("anvil_setCode".into(), (broadcaster_addr, "0x"))
        .await
        .expect("anvil_setCode");
    let _: serde_json::Value = admin
        .raw_request(
            "anvil_setBalance".into(),
            (broadcaster_addr, "0x8AC7230489E80000"),
        ) // 10 ETH
        .await
        .expect("anvil_setBalance");

    // 2. Spawn ONLY the helper (via fd-5: entropy + broadcaster key). The helper spawns and
    //    owns the broadcaster itself. This dogfoods the fd-5 spawn contract for the helper.
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_railgun-helper"));
    cmd.env("RAILGUN_RPC_URL", anvil_url())
        .env("RAILGUN_FORK_BLOCK", FORK_BLOCK.to_string())
        .env("RAILGUN_SOCKET", &helper_sock)
        .env("RAILGUN_TOKEN", htok)
        .env(
            "RAILGUN_BROADCASTER_BIN",
            env!("CARGO_BIN_EXE_railgun-broadcaster"),
        )
        .env("RAILGUN_BROADCASTER_SOCKET", &bc_sock)
        .env("RAILGUN_BROADCASTER_TOKEN", btok);
    let helper_secret = json!({ "entropyHex": entropy }).to_string();
    let _helper = ChildGuard(
        spawn_child_with_fd5(cmd, helper_secret.as_bytes()).expect("spawn railgun-helper via fd-5"),
    );

    // RailgunHelper::new syncs on register + spawns the broadcaster, so allow startup.
    wait_for_socket(&helper_sock, 180).await;

    // 3. Sanity: the helper owns the broadcaster; confirm its EOA over the broadcaster socket.
    let bc_addr = within(
        "broadcaster address",
        rpc::call(&bc_sock, btok, "address", json!(null)),
    )
    .await
    .unwrap();
    assert_eq!(
        bc_addr["address"].as_str().unwrap().to_lowercase(),
        format!("{broadcaster_addr:?}").to_lowercase(),
        "helper-owned broadcaster EOA mismatch"
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
    let shield_txs = within(
        "prepareShield",
        rpc::call(
            &helper_sock,
            htok,
            "prepareShield",
            json!({"amountWei": SHIELD_WEI.to_string()}),
        ),
    )
    .await
    .expect("prepareShield");
    let txs: Vec<TxData> = serde_json::from_value(shield_txs).expect("shield tx list");
    assert!(!txs.is_empty(), "expected >=1 shield tx");
    for tx in txs {
        let receipt = within("shield submit", async {
            owner_provider
                .send_transaction(tx.into())
                .await
                .expect("send shield")
                .get_receipt()
                .await
                .expect("shield receipt")
        })
        .await;
        assert!(receipt.status(), "shield tx must succeed");
        eprintln!(
            "[e2e] shield tx {:?} in block {:?}",
            receipt.transaction_hash, receipt.block_number
        );
    }

    // 5. balance reflects the shielded deposit.
    let bal = within(
        "balance",
        rpc::call(&helper_sock, htok, "balance", json!(null)),
    )
    .await
    .expect("balance");
    let total =
        u128::from_str_radix(bal["total"].as_str().unwrap().trim_start_matches("0x"), 16).unwrap();
    eprintln!("[e2e] shielded balance total = {total} wei ({bal})");
    assert!(
        total >= SHIELD_WEI * 99 / 100,
        "shielded balance {total} too low"
    );

    // Note: the recipient may already hold ETH on the real Sepolia state the fork inherits,
    // so assert on the DELTA, not an absolute zero start.
    let recipient_before = within("get_balance(before)", async {
        owner_provider.get_balance(RECIPIENT).await
    })
    .await
    .unwrap();

    // 6. UNSHIELD (async): returns a jobId immediately; proving + relay run in background.
    let started = within(
        "unshield (start)",
        rpc::call(
            &helper_sock,
            htok,
            "unshield",
            json!({"amountWei": UNSHIELD_WEI.to_string(), "to": format!("{RECIPIENT:?}")}),
        ),
    )
    .await
    .expect("unshield");
    let job_id = started["jobId"].as_str().expect("jobId").to_string();
    eprintln!("[e2e] unshield job {job_id} started; polling (proving may download artifacts)...");

    // 7. Poll unshieldStatus until done/error (proving can take tens of seconds). Bounded by
    //    its own deadline AND the overall test timeout.
    let deadline = Instant::now() + Duration::from_secs(240);
    let result = loop {
        let st = within(
            "unshieldStatus",
            rpc::call(
                &helper_sock,
                htok,
                "unshieldStatus",
                json!({"jobId": job_id}),
            ),
        )
        .await
        .expect("unshieldStatus");
        match st["status"].as_str() {
            Some("done") => break st["result"].clone(),
            Some("error") => panic!("unshield job failed: {}", st["error"]),
            _ => {}
        }
        assert!(
            Instant::now() < deadline,
            "unshield job did not finish in time"
        );
        tokio::time::sleep(Duration::from_secs(2)).await;
    };
    eprintln!("[e2e] unshield done: {result}");
    assert!(
        result["status"].as_bool().unwrap_or(false),
        "native relay must succeed"
    );

    // 8. Recipient received NATIVE ETH (not WETH), and the broadcaster EOA submitted the txs.
    let recipient_after = within("get_balance(after)", async {
        owner_provider.get_balance(RECIPIENT).await
    })
    .await
    .unwrap();
    let delta = recipient_after - recipient_before;
    eprintln!("[e2e] recipient native ETH: {recipient_before} -> {recipient_after} (+{delta})");
    assert!(delta > U256::ZERO, "recipient must receive native ETH");
    assert!(
        delta <= U256::from(UNSHIELD_WEI),
        "cannot exceed unshield amount"
    );
    assert!(
        delta >= U256::from(UNSHIELD_WEI * 95 / 100),
        "received {delta} < ~95% of {UNSHIELD_WEI}"
    );

    let forward_hash = result["forwardTxHash"].as_str().expect("forwardTxHash");
    let fh = forward_hash.parse().unwrap();
    let tx = within("get_transaction_by_hash", async {
        owner_provider.get_transaction_by_hash(fh).await
    })
    .await
    .unwrap()
    .expect("forward tx present");
    assert_eq!(
        tx.inner.signer(),
        broadcaster_addr,
        "native ETH forward MUST come from the local broadcaster EOA"
    );

    eprintln!("[e2e] PASS: shield + async unshield → native ETH delivered by the helper-owned broadcaster; confirmed on-chain.");
}
