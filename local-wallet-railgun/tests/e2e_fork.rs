//! End-to-end acceptance test (the goal's verification): on an anvil **Sepolia fork**, shield
//! native ETH into RAILGUN and then exit it to a fresh recipient as **native ETH** through
//! RAILGUN's privacy paymaster — an ERC-4337 UserOperation on EntryPoint v0.8, submitted by a
//! bundler, with the gas paid from an in-pool fee note. Nothing of ours pays gas, so nothing
//! of ours needs funding: there is no broadcaster and no relayer EOA anywhere in this file.
//!
//! The bundler is a LOCAL Alto (see `utils/alto.rs`): a public bundler cannot see the fork.
//!
//! What this proves, and why each assertion is here:
//!
//! 1. the shield confirms on-chain;
//! 2. two exits run at DIFFERENT amounts, so the contract's real unshield-fee rounding is
//!    MEASURED rather than assumed — one amount makes `value * bps` a multiple of the bps
//!    denominator and the other does not, which is the case that separates the two candidate
//!    conventions (see `measured_delivery`);
//! 3. for each exit the recipient's **native ETH** balance delta equals the `deliveredWei` the
//!    sidecar reported, exactly — this is what proves the unwrap-and-forward tail call ran and
//!    that the recipient got ETH, not WETH;
//! 4. the two exits used DIFFERENT sender addresses — per-exit rotation is the whole reason the
//!    derived exit index exists, and without it every exit clusters under one address;
//! 5. each ephemeral sender keeps ZERO native ETH — it forwarded everything;
//! 6. a labelled calibration line records the WETH dust left at each sender and the fee-loop
//!    iteration count, so the real fee convention can be read off a run instead of inferred.
//!
//! Run: `RPC_URL_SEPOLIA=<sepolia-rpc> cargo test --features fork-sync --test e2e_fork --
//! --ignored --nocapture` (or `scripts/e2e-fork.sh`). `#[ignore]` by default — needs network,
//! anvil, and npx.

#![cfg(feature = "fork-sync")]

use std::io::BufRead;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use alloy::network::Ethereum;
use alloy::primitives::{address, Address, U256};
use alloy::providers::{DynProvider, Provider, ProviderBuilder};
use eip_1193_provider::tx_data::TxData;
use railgun_helper::rpc;
use railgun_helper::spawn::{spawn_child_with_fd5, ChildGuard};
use serde_json::json;

#[path = "utils/alto.rs"]
mod alto;

alloy::sol! {
    /// Read-only WETH view used to measure the dust left in a single-use sender. The library's
    /// `exit::WETH` declares only `withdraw`, and adding a test-only getter to a production ABI
    /// would be the wrong place for it.
    #[sol(rpc)]
    contract WETHTest {
        function balanceOf(address who) external view returns (uint256);
    }
}

// Well-known anvil dev key (testnet only): the OWNER account that self-submits the shield.
const OWNER_KEY: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
// A fresh recipient EOA, distinct from the owner and from every derived exit sender.
const RECIPIENT: Address = address!("0x1111111111111111111111111111111111111111");

/// Fork height.
///
/// NOT the 10822990 the pre-paymaster fixture used: RAILGUN's privacy paymaster
/// (`0xBb9D6507…`) and fee adapter (`0xeBabF510…`) have **no code at that height** — verified
/// via `eth_getCode` — so the entire paymaster path is unreachable there. 11011021 is the block
/// upstream Kohaku's own `broadcast_utxo.rs` paymaster fork test pins, it is Subsquid-indexed,
/// and at it both contracts are deployed and the paymaster holds ~0.21 ETH of EntryPoint
/// deposit (i.e. it can actually sponsor).
const FORK_BLOCK: u64 = 11011021;
const ANVIL_PORT: u16 = 8599;
const ALTO_PORT: u16 = 3010;

/// Shield 0.1 ETH.
///
/// Sized by the RESERVE, not by the exit amounts. The paymaster is paid from an in-pool fee
/// note, so `maxUnshieldable` holds back `3_350_000 gas x maxFeePerGas x 1.2` — roughly 0.004
/// ETH at 1 gwei, 0.02 ETH at 5 gwei. Anything at the old fixture's 1e6-wei scale makes
/// `max_value` saturate to 0 and every unshield is refused up front with
/// `insufficientShieldedBalance`. Step 7 below asserts the margin against the LIVE
/// `maxUnshieldable` reserve rather than trusting this constant to still be big enough.
const SHIELD_WEI: u128 = 100_000_000_000_000_000;

// Two different amounts, so the fixture IDENTIFIES the contract's real fee rounding rather than
// assuming it. `value * 25` is a multiple of 10_000 for 10_000 wei and not for 5_000 wei, which
// is exactly the case that separates "floor the fee, then subtract" from "floor the product" —
// see `measured_delivery`. They are deliberately tiny: they calibrate the fee, they do not
// move size.
const UNSHIELD_WEI_EXACT: u128 = 10_000;
const UNSHIELD_WEI_ROUNDING: u128 = 5_000;

/// The rate both this fixture and `fee::delivered_lower_bound` assume. `submit_exit` fails
/// closed if the live `unshieldFee()` disagrees, so reaching an assertion here means it matched.
const FEE_BPS: u128 = 25;
const BPS_DENOMINATOR: u128 = 10_000;
/// Mirrors `fee::DELIVERY_EPSILON_WEI` (not `pub` for a reason — it is an internal guard, and
/// naming it here keeps the expected-delivery arithmetic readable).
const DELIVERY_EPSILON_WEI: u128 = 1_000;

// Fork-backend throttling. See the anvil spawn for why these are required and not tuning.
const ANVIL_COMPUTE_UNITS_PER_SECOND: u32 = 60;
const ANVIL_FORK_RETRIES: u32 = 12;
const ANVIL_FORK_RETRY_BACKOFF_MS: u32 = 1_000;
const ANVIL_FORK_TIMEOUT_MS: u32 = 120_000;

// Hard wall-clock cap for the whole test so nothing (a stuck sidecar, a hung socket read, a
// wedged RPC) can hang the suite indefinitely — it fails instead. Two exits, each proving 2+
// Groth16 proofs, plus a first-run circuit-artifact download and two inclusion waits.
const OVERALL_TIMEOUT_SECS: u64 = 2700;
// Per-operation cap on any single network/socket await (proving is polled separately). Covers a
// `sync()` plus a bundler gas sample, both of which sit inside one RPC — and a `sync()` re-walks
// the UTXO trees through a deliberately throttled fork backend, so this is minutes, not seconds.
const OP_TIMEOUT_SECS: u64 = 600;
// Per-exit cap on polling `unshieldStatus` to a terminal state.
const EXIT_TIMEOUT_SECS: u64 = 600;

/// Await `fut` with a per-operation timeout, panicking with `what` if it is exceeded so a
/// hung call surfaces as a clear failure rather than blocking forever.
async fn within<T>(what: &str, fut: impl std::future::Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(OP_TIMEOUT_SECS), fut)
        .await
        .unwrap_or_else(|_| panic!("operation timed out after {OP_TIMEOUT_SECS}s: {what}"))
}

/// Kills its child on drop so a panicking assertion never leaks anvil.
struct Killer(Child);
impl Drop for Killer {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// Counters scraped from the sidecar's own log stream.
///
/// The fee loop and the artifact cache are the two things this fixture is expected to REPORT
/// (they are the calibration output, per the task), and neither is visible over the RPC — the
/// sidecar has no reason to expose "how many proofs did that take" on the wire. Reading its
/// log is the only non-invasive way to get them, so the fixture pipes the child's stdout
/// (where `tracing_subscriber::fmt` writes) instead of inheriting it.
#[derive(Default)]
struct HelperLog {
    /// `railgun`'s "Building broadcast transaction with fee value" — one per Groth16 proof
    /// round in `prepare_userop`'s convergence loop.
    fee_iterations: AtomicUsize,
    /// "Downloading proving key" — expected ONCE per circuit shape per process. Once per
    /// *proof* would mean the artifact LRU is thrashing.
    proving_key_downloads: AtomicUsize,
    /// "Loading WASM Module" — expected once per proof; a known, measured cost, not a
    /// regression.
    wasm_loads: AtomicUsize,
}

impl HelperLog {
    fn fee_iterations(&self) -> usize {
        self.fee_iterations.load(Ordering::SeqCst)
    }
}

/// Forward the child's log to our stderr (so `--nocapture` shows it) while counting the
/// markers the calibration line reports.
fn tap_helper_log(stdout: std::process::ChildStdout, log: Arc<HelperLog>) {
    std::thread::spawn(move || {
        for line in std::io::BufReader::new(stdout)
            .lines()
            .map_while(Result::ok)
        {
            if line.contains("Building broadcast transaction with fee value") {
                log.fee_iterations.fetch_add(1, Ordering::SeqCst);
            }
            if line.contains("Downloading proving key") {
                log.proving_key_downloads.fetch_add(1, Ordering::SeqCst);
            }
            if line.contains("Loading WASM Module") {
                log.wasm_loads.fetch_add(1, Ordering::SeqCst);
            }
            eprintln!("[helper] {line}");
        }
    });
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
            "socket {path} not ready after {secs}s (the sidecar syncs RAILGUN before it binds)"
        );
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
}

/// Parse a `0x`-hex wei string off the wire. Every wei amount the sidecar returns is a hex
/// STRING, never a JSON number (2^53 wei is 0.009 ETH), so a numeric decode here would be a
/// silent precision bug on any realistic amount.
fn hex_wei(v: &serde_json::Value, what: &str) -> u128 {
    let s = v
        .as_str()
        .unwrap_or_else(|| panic!("{what} must be a 0x-hex string, got {v}"));
    u128::from_str_radix(s.trim_start_matches("0x"), 16)
        .unwrap_or_else(|e| panic!("{what} {s} is not hex: {e}"))
}

/// What one exit produced, measured on-chain rather than taken on trust.
struct ExitObservation {
    /// The recipient's NATIVE ETH balance delta across the exit.
    recipient_delta: U256,
    /// WETH left behind in the single-use sender — the fee-prediction error.
    sender_dust: U256,
    /// The sender's native ETH balance after the exit; must be zero.
    sender_native_after: U256,
    /// What the sidecar said it forwarded.
    delivered: u128,
    sender: Address,
    exit_index: u64,
    /// Groth16 proof rounds this exit consumed.
    fee_iterations: usize,
}

/// Run one exit through the sidecar and measure what actually happened on-chain.
async fn run_exit(
    socket: &str,
    token: &str,
    provider: &DynProvider,
    weth: Address,
    amount: u128,
    log: &Arc<HelperLog>,
) -> ExitObservation {
    // A fork inherits real Sepolia state, so the recipient may already hold ETH. Assert on the
    // DELTA; an absolute assertion would be wrong for reasons that have nothing to do with us.
    let before = provider.get_balance(RECIPIENT).await.unwrap();
    let iterations_before = log.fee_iterations();
    let started_at = Instant::now();

    let started = within(
        "unshield (start)",
        rpc::call(
            socket,
            token,
            "unshield",
            json!({"amountWei": format!("0x{amount:x}"), "to": format!("{RECIPIENT:?}")}),
        ),
    )
    .await
    .unwrap_or_else(|e| panic!("unshield of {amount} wei was refused: {e}"));
    let job_id = started["jobId"]
        .as_str()
        .expect("unshield must return a jobId")
        .to_string();
    eprintln!("[e2e] exit of {amount} wei started as {job_id}; polling...");

    // Poll to a terminal state. `submitted` is NOT terminal — the op has a hash but no receipt
    // — so only `done` ends the loop successfully.
    let deadline = Instant::now() + Duration::from_secs(EXIT_TIMEOUT_SECS);
    let outcome = loop {
        let st = within(
            "unshieldStatus",
            rpc::call(socket, token, "unshieldStatus", json!({"jobId": &job_id})),
        )
        .await
        .expect("unshieldStatus must answer");
        match st["status"].as_str() {
            Some("done") => {
                assert_eq!(
                    st["deliveredAsset"].as_str(),
                    Some("ETH"),
                    "the exit must deliver native ETH, not WETH"
                );
                break st["result"].clone();
            }
            // A real on-chain verdict or a refusal — never soften it into a retry.
            Some("error") => panic!("exit of {amount} wei failed: {st}"),
            _ => {}
        }
        assert!(
            Instant::now() < deadline,
            "exit of {amount} wei did not reach a terminal state in {EXIT_TIMEOUT_SECS}s \
             (last status: {st})"
        );
        tokio::time::sleep(Duration::from_secs(3)).await;
    };
    let elapsed = started_at.elapsed();

    let after = provider.get_balance(RECIPIENT).await.unwrap();
    let sender: Address = outcome["sender"]
        .as_str()
        .expect("outcome must name the sender")
        .parse()
        .expect("sender must be an address");
    let sender_dust = WETHTest::new(weth, provider.clone())
        .balanceOf(sender)
        .call()
        .await
        .expect("read sender WETH");
    let sender_native_after = provider.get_balance(sender).await.unwrap();
    let delivered = hex_wei(&outcome["deliveredWei"], "deliveredWei");
    let exit_index = outcome["exitIndex"]
        .as_u64()
        .expect("outcome must name the exit index");
    let fee_iterations = log.fee_iterations() - iterations_before;

    eprintln!(
        "[e2e] EXIT amount={amount} sender={sender:?} index={exit_index} \
         op={} delivered={delivered} wethDust={sender_dust} feeLoopIterations={fee_iterations} \
         wallClock={elapsed:?}",
        outcome["userOpHash"]
    );

    ExitObservation {
        recipient_delta: after - before,
        sender_dust,
        sender_native_after,
        delivered,
        sender,
        exit_index,
        fee_iterations,
    }
}

/// `floor(value * (10000 - bps) / 10000)` — the delivery our arithmetic predicts as a LOWER
/// bound, before the epsilon guard.
fn predicted_delivery(value: u128) -> u128 {
    value * (BPS_DENOMINATOR - FEE_BPS) / BPS_DENOMINATOR
}

/// What the sidecar should forward: the predicted delivery less the epsilon guard.
fn expected_forward(value: u128) -> u128 {
    predicted_delivery(value) - DELIVERY_EPSILON_WEI
}

/// The fee convention this fixture MEASURED on-chain: RailgunSmartWallet floors the FEE and
/// subtracts it — `value - floor(value * bps / 10000)`.
///
/// That is NOT the same arithmetic as `fee::delivered_lower_bound`, which floors the PRODUCT
/// (`floor(value * (10000 - bps) / 10000)`). The two agree whenever `value * bps` is a multiple
/// of 10000 and otherwise differ by exactly 1 wei, always with the contract delivering the
/// larger amount. That is why the two calibration amounts exist: 10_000 cannot distinguish them
/// (both give 9975), 5_000 can (4988 measured vs 4987 predicted). The library's "lower bound"
/// framing is therefore correct as written, and the 1-wei gap is absorbed as dust rather than
/// risking a revert.
///
/// Asserted exactly, not as a bound: it is the contract behaviour this task exists to pin down,
/// so a change to it should fail this fixture rather than quietly widen the dust.
fn measured_delivery(value: u128) -> u128 {
    value - value * FEE_BPS / BPS_DENOMINATOR
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "needs RPC_URL_SEPOLIA + anvil + npx + network (proving artifacts, Subsquid)"]
async fn shield_then_exit_native_via_the_privacy_paymaster() {
    // Enforce a hard overall cap so the test can never hang the suite.
    tokio::time::timeout(Duration::from_secs(OVERALL_TIMEOUT_SECS), run_e2e())
        .await
        .expect("e2e exceeded overall wall-clock budget");
}

async fn run_e2e() {
    let rpc = std::env::var("RPC_URL_SEPOLIA").expect("set RPC_URL_SEPOLIA to a Sepolia RPC");
    let dir = tempfile::tempdir().unwrap();
    // Held for the whole test: it holds the exit-index counter, which is what makes the two
    // exits derive DIFFERENT senders.
    let state_dir = tempfile::tempdir().unwrap();
    let helper_sock = dir.path().join("helper.sock").to_string_lossy().to_string();
    let entropy = "0x1122334455667788990011223344556677889900112233445566778899001122";
    let token = "helper-token";

    // 1. anvil fork of Sepolia.
    //
    // The throttle flags are load-bearing, not tuning: verifying RAILGUN's UTXO trees walks
    // thousands of accounts/slots that the fork has to fetch from the upstream RPC, and at
    // anvil's default 330 CU/s a free Infura key answers with HTTP 429 mid-verification. anvil
    // surfaces that as `Utxo indexer error: Verification error`, i.e. an infrastructure failure
    // wearing a RAILGUN failure's clothes. Throttling ourselves and retrying with backoff keeps
    // the fixture measuring the exit path rather than the RPC provider's quota.
    let _anvil = Killer(
        Command::new("anvil")
            .args([
                "--fork-url",
                &rpc,
                "--fork-block-number",
                &FORK_BLOCK.to_string(),
                "--port",
                &ANVIL_PORT.to_string(),
                "--compute-units-per-second",
                &ANVIL_COMPUTE_UNITS_PER_SECOND.to_string(),
                "--retries",
                &ANVIL_FORK_RETRIES.to_string(),
                "--fork-retry-backoff",
                &ANVIL_FORK_RETRY_BACKOFF_MS.to_string(),
                "--timeout",
                &ANVIL_FORK_TIMEOUT_MS.to_string(),
                "--silent",
            ])
            .env("FOUNDRY_DISABLE_NIGHTLY_WARNING", "1")
            .spawn()
            .expect("spawn anvil (is foundry installed?)"),
    );
    wait_for_rpc(&anvil_url(), 90).await;

    let admin: DynProvider = ProviderBuilder::new()
        .network::<Ethereum>()
        .connect(&anvil_url())
        .await
        .unwrap()
        .erased();

    // 2. Fund Alto's executor and utility EOAs BEFORE Alto starts: the utility account deploys
    //    the simulation contracts at startup and refills the executor, so an unfunded pair
    //    makes Alto come up unable to bundle anything.
    for key in [alto::ALTO_EXECUTOR_KEY, alto::ALTO_UTILITY_KEY] {
        let signer: alloy::signers::local::PrivateKeySigner = key.parse().unwrap();
        let _: serde_json::Value = admin
            .raw_request(
                "anvil_setBalance".into(),
                (
                    signer.address(),
                    U256::from(1_000_000_000_000_000_000_000u128),
                ),
            )
            .await
            .expect("fund alto key");
    }

    // 3. Local Alto: a public bundler cannot see the fork. Required, never skipped.
    let alto_log = dir.path().join("alto.log");
    let _alto = alto::spawn(&anvil_url(), ALTO_PORT, &alto_log)
        .await
        .unwrap_or_else(|e| panic!("{e}"));
    let bundler_url = format!("http://127.0.0.1:{ALTO_PORT}");

    // 4. Spawn ONLY the sidecar (entropy over fd 5 — this dogfoods the fd-5 spawn contract).
    //    It spawns no children: there is no broadcaster.
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_railgun-helper"));
    cmd.env("RAILGUN_RPC_URL", anvil_url())
        .env("RAILGUN_FORK_BLOCK", FORK_BLOCK.to_string())
        .env("RAILGUN_SOCKET", &helper_sock)
        .env("RAILGUN_TOKEN", token)
        // fork-sync-only override: the exit path would otherwise reach for public Pimlico,
        // which cannot see this fork.
        .env("RAILGUN_BUNDLER_URL", &bundler_url)
        .env("RAILGUN_STATE_DIR", state_dir.path())
        .stdout(Stdio::piped());
    let secret = json!({ "entropyHex": entropy }).to_string();
    let mut child = spawn_child_with_fd5(cmd, secret.as_bytes()).expect("spawn railgun-helper");
    let log = Arc::new(HelperLog::default());
    tap_helper_log(
        child.stdout.take().expect("piped helper stdout"),
        log.clone(),
    );
    let _helper = ChildGuard(child);

    // `RailgunHelper::new` registers and syncs the whole pool before binding, so allow startup.
    wait_for_socket(&helper_sock, 600).await;

    // The owner submits the (public) shield tx itself; anvil pre-funds its dev accounts even on
    // a fork, so nothing here needs topping up.
    let owner: alloy::signers::local::PrivateKeySigner = OWNER_KEY.parse().unwrap();
    let owner_provider: DynProvider = ProviderBuilder::new()
        .network::<Ethereum>()
        .wallet(owner)
        .connect(&anvil_url())
        .await
        .unwrap()
        .erased();

    // 5. SHIELD: the sidecar builds the tx(s), the owner self-submits each.
    let shield_txs = within(
        "prepareShield",
        rpc::call(
            &helper_sock,
            token,
            "prepareShield",
            json!({"amountWei": format!("0x{SHIELD_WEI:x}")}),
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
        assert!(receipt.status(), "shield tx must succeed: {receipt:?}");
        eprintln!(
            "[e2e] shield tx {:?} confirmed in block {:?}",
            receipt.transaction_hash, receipt.block_number
        );
    }

    // 6. The shielded balance reflects the deposit.
    let bal = within(
        "balance",
        rpc::call(&helper_sock, token, "balance", json!(null)),
    )
    .await
    .expect("balance");
    let total = hex_wei(&bal["total"], "balance.total");
    eprintln!("[e2e] shielded balance total = {total} wei ({bal})");
    assert!(
        total >= SHIELD_WEI * 99 / 100,
        "shielded balance {total} too low for a {SHIELD_WEI} wei shield"
    );

    // 7. The reserve is the real constraint on SHIELD_WEI, and it is priced from the LIVE
    //    bundler gas sample — so assert the margin against the live number rather than trusting
    //    the constant. If this fires, raise SHIELD_WEI; do not shrink the reserve.
    let ceiling = within(
        "maxUnshieldable",
        rpc::call(&helper_sock, token, "maxUnshieldable", json!(null)),
    )
    .await
    .expect("maxUnshieldable");
    let max_value = hex_wei(&ceiling["maxValueWei"], "maxValueWei");
    let reserve = hex_wei(&ceiling["reserveWei"], "reserveWei");
    eprintln!(
        "[e2e] maxUnshieldable: maxValue={max_value} reserve={reserve} \
         receivableAtMax={} (shielded {total})",
        hex_wei(&ceiling["receivableAtMaxWei"], "receivableAtMaxWei")
    );
    assert!(
        max_value >= UNSHIELD_WEI_EXACT + UNSHIELD_WEI_ROUNDING,
        "the live fee reserve ({reserve} wei) leaves only {max_value} wei spendable out of \
         {total}, which cannot cover both calibration exits — raise SHIELD_WEI"
    );

    let weth_addr = railgun::chain_config::ChainConfig::sepolia().wrapped_base_token;

    // 8. Exit 1: `value * bps` divides the denominator exactly, so no fee rounding applies and
    //    both candidate conventions agree.
    let a = run_exit(
        &helper_sock,
        token,
        &owner_provider,
        weth_addr,
        UNSHIELD_WEI_EXACT,
        &log,
    )
    .await;
    assert_eq!(
        a.delivered,
        expected_forward(UNSHIELD_WEI_EXACT),
        "exit 1 must forward the predicted delivery minus the epsilon guard"
    );
    assert_eq!(
        a.recipient_delta,
        U256::from(a.delivered),
        "the recipient must receive exactly the forwarded amount as NATIVE ETH — a mismatch \
         means the unwrap-and-forward tail call did not do what we think"
    );

    // 9. Exit 2: `value * bps` does NOT divide the denominator, so the two conventions differ by
    //    1 wei here and the measurement below discriminates between them.
    let b = run_exit(
        &helper_sock,
        token,
        &owner_provider,
        weth_addr,
        UNSHIELD_WEI_ROUNDING,
        &log,
    )
    .await;
    assert_eq!(
        b.delivered,
        expected_forward(UNSHIELD_WEI_ROUNDING),
        "exit 2 must forward the predicted delivery minus the epsilon guard"
    );
    assert_eq!(
        b.recipient_delta,
        U256::from(b.delivered),
        "exit 2 native delivery must match the reported deliveredWei exactly"
    );

    // 10. Rotation is the whole point of the derived per-exit index: two exits must never share
    //     a sender, or every exit clusters under one address again.
    assert_ne!(
        a.sender, b.sender,
        "each exit must use a fresh derived sender (indices {} and {})",
        a.exit_index, b.exit_index
    );
    assert_ne!(
        a.exit_index, b.exit_index,
        "each exit must burn its own index"
    );

    // 11. The sender is single-use and forwards everything: it must not sit on native ETH.
    for (label, obs) in [("exit1", &a), ("exit2", &b)] {
        assert_eq!(
            obs.sender_native_after,
            U256::ZERO,
            "{label}: the ephemeral sender {:?} must forward all native ETH, keeping none",
            obs.sender
        );
    }

    // 12. Calibration. The dust is the fee-prediction error: `delivered_lower_bound` is
    //     deliberately a LOWER bound, so what stays behind is `actual_delivery - forwarded`.
    //     Reading it off a real run is what identifies RailgunSmartWallet's actual rounding —
    //     see `measured_delivery`, which the two amounts were chosen to discriminate.
    let implied = |obs: &ExitObservation| U256::from(obs.delivered) + obs.sender_dust;
    eprintln!(
        "FEE CALIBRATION: epsilon={DELIVERY_EPSILON_WEI} wei | \
         exit1 value={UNSHIELD_WEI_EXACT} lowerBound={} measured={} forwarded={} dust={} \
         impliedDelivery={} feeLoopIterations={} | \
         exit2 value={UNSHIELD_WEI_ROUNDING} lowerBound={} measured={} forwarded={} dust={} \
         impliedDelivery={} feeLoopIterations={} | \
         provingKeyDownloads={} wasmModuleLoads={}",
        predicted_delivery(UNSHIELD_WEI_EXACT),
        measured_delivery(UNSHIELD_WEI_EXACT),
        a.delivered,
        a.sender_dust,
        implied(&a),
        a.fee_iterations,
        predicted_delivery(UNSHIELD_WEI_ROUNDING),
        measured_delivery(UNSHIELD_WEI_ROUNDING),
        b.delivered,
        b.sender_dust,
        implied(&b),
        b.fee_iterations,
        log.proving_key_downloads.load(Ordering::SeqCst),
        log.wasm_loads.load(Ordering::SeqCst),
    );

    // The dust must be a rounding remainder, not a material fraction of the exit: if it ever
    // approached the whole amount, the delivery model would be wrong in kind, not degree.
    for (label, obs, value) in [
        ("exit1", &a, UNSHIELD_WEI_EXACT),
        ("exit2", &b, UNSHIELD_WEI_ROUNDING),
    ] {
        assert!(
            obs.sender_dust < U256::from(value),
            "{label}: dust {} must be a rounding remainder, not the whole {value} wei",
            obs.sender_dust
        );
        // The measured convention, pinned exactly. `implied` (forwarded + dust) is what the
        // contract actually delivered, so this is the assertion that identifies the rounding
        // rather than restating our own arithmetic back at us.
        assert_eq!(
            implied(obs),
            U256::from(measured_delivery(value)),
            "{label}: the contract delivered {} for a {value} wei unshield, but the measured \
             convention `value - floor(value * {FEE_BPS} / {BPS_DENOMINATOR})` says {} — \
             RailgunSmartWallet's fee rounding has changed and fee.rs needs re-checking",
            implied(obs),
            measured_delivery(value)
        );
        // ...and therefore `delivered_lower_bound` really is a lower bound. Kept as a separate
        // assertion because THIS is the property `forward_amount` depends on for
        // `WETH.withdraw` never to revert; the equality above is the explanation for it.
        assert!(
            implied(obs) >= U256::from(predicted_delivery(value)),
            "{label}: the contract delivered {} but fee::delivered_lower_bound predicted at \
             least {} — the 'lower bound' is not a lower bound, and WETH.withdraw only did not \
             revert because of the {DELIVERY_EPSILON_WEI} wei guard",
            implied(obs),
            predicted_delivery(value)
        );
    }

    // The fee loop cannot converge on its first proof (the SDK's seed `fee_value` is orders of
    // magnitude below a real sponsored fee), so two rounds is the floor and five is the cap
    // before `FeeDidNotConverge`. Pinning the range catches a seed/convergence regression that
    // would otherwise only show up as a slower exit.
    for (label, obs) in [("exit1", &a), ("exit2", &b)] {
        assert!(
            (2..=10).contains(&obs.fee_iterations),
            "{label}: {} fee-loop iterations is outside the expected 2..=10 \
             (5 per attempt, at most one gas-gated retry)",
            obs.fee_iterations
        );
    }

    eprintln!(
        "[e2e] PASS: shield + two paymaster-sponsored exits at different amounts delivered \
         native ETH to {RECIPIENT:?} from two distinct single-use senders, confirmed on-chain."
    );
}
