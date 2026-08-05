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
//! 2. three exits run at DIFFERENT amounts, so the contract's real unshield-fee rounding is
//!    MEASURED rather than assumed — see [`UNSHIELD_AMOUNTS`] for what each one rules out and
//!    [`measured_delivery`] for the convention they identify;
//! 3. for each exit the recipient's **native ETH** balance delta equals the `deliveredWei` the
//!    sidecar reported, exactly — this is what proves the unwrap-and-forward tail call ran and
//!    that the recipient got ETH, not WETH;
//! 4. **the privacy paymaster paid**: its EntryPoint deposit strictly falls across every exit,
//!    while the ephemeral sender holds zero native ETH both before and after. Together those say
//!    the gas came from the paymaster and from nothing of ours — which is the name of the feature
//!    and the reason this fixture exists. Every other measurement here would hold identically if
//!    the ETH had arrived by some other funding route;
//! 5. each exit's sender is the address the SEED DERIVES at the index the sidecar reported — not
//!    merely a different address than last time. That is what makes a `DeliveryReverted` index
//!    able to recover stranded funds;
//! 6. no two exits share a sender or an index (rotation);
//! 7. a labelled calibration line records the WETH dust, the sponsored gas cost and the fee-loop
//!    iteration count per exit, so the real conventions can be read off a run instead of inferred.
//!
//! Run: `RPC_URL_SEPOLIA=<sepolia-rpc> cargo test --features fork-sync --test e2e_fork --
//! --ignored --nocapture` (or `scripts/e2e-fork.sh`). `#[ignore]` by default — needs network,
//! anvil, and npx.

#![cfg(feature = "fork-sync")]

use std::collections::HashMap;
use std::io::BufRead;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use alloy::network::Ethereum;
use alloy::primitives::{address, Address, U256};
use alloy::providers::{DynProvider, Provider, ProviderBuilder};
use eip_1193_provider::tx_data::TxData;
use railgun_helper::spawn::{spawn_child_with_fd5, ChildGuard};
use railgun_helper::{keys, rpc};
use serde_json::json;
use userop_kit::entry_point::ENTRY_POINT_08;

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

alloy::sol! {
    /// The one EntryPoint getter this fixture needs: a paymaster's ETH deposit.
    ///
    /// This is the ONLY direct evidence that the privacy paymaster actually sponsored the
    /// operation. Everything else the fixture measures — the recipient's ETH, the empty sender —
    /// would look identical if the gas had come from somewhere else entirely, so without this
    /// read the fixture would not assert the feature it exists to prove.
    #[sol(rpc)]
    contract EntryPointTest {
        function balanceOf(address account) external view returns (uint256);
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

/// The chain id `RPC_URL_SEPOLIA` must answer (11155111 / `0xaa36a7`). Checked once, before
/// anvil ever spawns — see the preflight in [`run_e2e`] for why.
const SEPOLIA_CHAIN_ID: u64 = 11_155_111;

/// Shield 0.1 ETH.
///
/// Sized by the RESERVE, not by the exit amounts. The paymaster is paid from an in-pool fee
/// note, so `maxUnshieldable` holds back `3_350_000 gas x maxFeePerGas x 1.2` — roughly 0.004
/// ETH at 1 gwei, 0.02 ETH at 5 gwei. Anything at the old fixture's 1e6-wei scale makes
/// `max_value` saturate to 0 and every unshield is refused up front with
/// `insufficientShieldedBalance`. Step 7 below asserts the margin against the LIVE
/// `maxUnshieldable` reserve rather than trusting this constant to still be big enough.
const SHIELD_WEI: u128 = 100_000_000_000_000_000;

// Three different amounts, so the fixture IDENTIFIES the contract's real fee rounding rather than
// assuming it. Each one rules out a candidate the previous cannot:
//
//   * 10_000 — `value * bps` is an exact multiple of the denominator, so EVERY candidate
//     convention agrees (9975). Establishes the baseline, discriminates nothing.
//   * 5_000  — `value * bps / denom` is 12.5, so flooring the PRODUCT (4987) differs from
//     flooring the FEE (4988). Separates `fee::delivered_lower_bound`'s arithmetic from the
//     contract's.
//   * 5_001  — 12.5025, so floor-the-fee (4989) differs from round-the-fee-to-nearest (4988).
//     Without it, round-half-down would still fit the first two points.
//
// They are deliberately tiny: they calibrate the fee, they do not move size.
const UNSHIELD_WEI_EXACT: u128 = 10_000;
const UNSHIELD_WEI_ROUNDING: u128 = 5_000;
const UNSHIELD_WEI_TIE_BREAK: u128 = 5_001;
const UNSHIELD_AMOUNTS: [u128; 3] = [
    UNSHIELD_WEI_EXACT,
    UNSHIELD_WEI_ROUNDING,
    UNSHIELD_WEI_TIE_BREAK,
];

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
// wedged RPC) can hang the suite indefinitely — it fails instead. Three exits, each proving 2+
// Groth16 proofs, plus a first-run circuit-artifact download and three inclusion waits.
const OVERALL_TIMEOUT_SECS: u64 = 2700;
// Per-operation cap on any single network/socket await (proving is polled separately). Covers a
// `sync()` plus a bundler gas sample, both of which sit inside one RPC — and a `sync()` re-walks
// the UTXO trees through a deliberately throttled fork backend, so this is minutes, not seconds.
const OP_TIMEOUT_SECS: u64 = 600;
// Per-exit cap on polling `unshieldStatus` to a terminal state.
const EXIT_TIMEOUT_SECS: u64 = 600;

/// How many Groth16 proof rounds the pinned SDK allows per attempt before `FeeDidNotConverge`
/// (`railgun::provider::prepare_userop`'s `for _ in 0..5`).
const FEE_LOOP_SDK_CAP: usize = 5;
/// Iterations at or above this get a loud warning: the run is within one round of the cap, which
/// is the signal that matters and which a passing test would otherwise swallow.
const FEE_LOOP_HEADROOM_WARN: usize = 4;

/// How many derived exit-sender indices to snapshot before each exit.
///
/// A WINDOW rather than the single next index, because `submit_exit` burns a SECOND index on its
/// unconditional convergence retry — so the index an exit will report is genuinely not knowable
/// in advance.
const DERIVED_SENDER_WINDOW: u32 = 8;

/// Await `fut` with a per-operation timeout, panicking with `what` if it is exceeded so a
/// hung call surfaces as a clear failure rather than blocking forever.
async fn within<T>(what: &str, fut: impl std::future::Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(OP_TIMEOUT_SECS), fut)
        .await
        .unwrap_or_else(|_| panic!("operation timed out after {OP_TIMEOUT_SECS}s: {what}"))
}

// --- Rate-limit classification -------------------------------------------------------------
//
// A real run of this fixture panicked at "fund alto key: ErrorResp(ErrorPayload { code:
// -32603, message: \"failed to get account for 0x… : Max retries exceeded HTTP error 429 with
// body: {\\\"code\\\":-32005,\\\"message\\\":\\\"Too Many Requests\\\", …} \" })" and read, to
// the human running it, as "the fixture (or RAILGUN) is broken". It was not: the identical
// fixture passed 3/3 on a non-throttled RPC key. The anvil spawn below already throttles the
// fork backend itself (`--compute-units-per-second`, `--retries`, `--fork-retry-backoff`) —
// that mitigates a slow provider, but nothing mitigates a provider that has run out of quota
// for the hour. What was missing was not a fix, only classification: telling the reader which
// kind of failure they are looking at.
//
// Every RPC-touching site below that can surface a throttled fork backend — the anvil setup
// calls, the anvil readiness wait, and the sidecar's own on-chain reads/writes — routes its
// error through `rpc_fail`/`rpc_expect` so the panic says so plainly instead of reading like a
// protocol bug.

/// Substrings that mark an RPC-touching failure as the upstream provider throttling anvil's
/// fork backend, rather than a bug in this fixture or in RAILGUN. `429` and "Too Many Requests"
/// are the HTTP-layer signal; `-32005` is the JSON-RPC error code Infura (and others) use for
/// the same thing. Matching any one is enough — they show up in different combinations
/// depending on which layer (anvil, the provider's HTTP client, or the upstream RPC) rendered
/// the error.
const RATE_LIMIT_MARKERS: [&str; 3] = ["429", "Too Many Requests", "-32005"];

/// True if `rendered` — an error's own text — carries a rate-limit marker.
fn is_rate_limited(rendered: &str) -> bool {
    RATE_LIMIT_MARKERS
        .iter()
        .any(|marker| rendered.contains(marker))
}

/// Panic at `context`, classifying the error first.
///
/// If `err`'s rendered text carries a rate-limit marker, the panic states PLAINLY that the
/// upstream RPC provider is throttling anvil's fork backend, that this is an infrastructure
/// failure and NOT a RAILGUN or fixture failure, and that the fix is to retry later or use a
/// less-throttled `RPC_URL_SEPOLIA` — while still preserving the original error text, so nothing
/// is lost. Anything else panics exactly as the call site always did: `context: err`.
fn rpc_fail(context: &str, err: impl std::fmt::Display) -> ! {
    let rendered = err.to_string();
    if is_rate_limited(&rendered) {
        panic!(
            "{context}: the RPC provider behind RPC_URL_SEPOLIA is RATE-LIMITING anvil's fork \
             backend (matched a 429 / \"Too Many Requests\" / -32005 marker). This is an \
             INFRASTRUCTURE failure of that provider's quota — it is NOT a RAILGUN or fixture \
             failure. Retry later, or point RPC_URL_SEPOLIA at a less-throttled key. Original \
             error: {rendered}"
        );
    }
    panic!("{context}: {rendered}");
}

/// Same classification as [`rpc_fail`], for a call site whose message already stands alone
/// (nothing to prefix it with).
fn rpc_fail_bare(err: impl std::fmt::Display) -> ! {
    let rendered = err.to_string();
    if is_rate_limited(&rendered) {
        panic!(
            "the RPC provider behind RPC_URL_SEPOLIA is RATE-LIMITING anvil's fork backend \
             (matched a 429 / \"Too Many Requests\" / -32005 marker). This is an \
             INFRASTRUCTURE failure of that provider's quota — it is NOT a RAILGUN or fixture \
             failure. Retry later, or point RPC_URL_SEPOLIA at a less-throttled key. Original \
             error: {rendered}"
        );
    }
    panic!("{rendered}");
}

/// `.expect`-style sugar for [`rpc_fail`]: identical message on an ordinary failure, classified
/// first when the underlying error is a throttled fork backend.
trait RpcResultExt<T> {
    fn rpc_expect(self, context: &str) -> T;
}

impl<T, E: std::fmt::Display> RpcResultExt<T> for Result<T, E> {
    fn rpc_expect(self, context: &str) -> T {
        match self {
            Ok(v) => v,
            Err(e) => rpc_fail(context, e),
        }
    }
}

#[cfg(test)]
mod rate_limit_classifier_tests {
    use super::is_rate_limited;

    /// The exact rendering from the real panic this fix responds to (trimmed to the relevant
    /// clause) must classify as a rate limit.
    #[test]
    fn matches_the_real_infura_429() {
        let rendered = "ErrorResp(ErrorPayload { code: -32603, message: \"failed to get account \
             for 0xe567a07c…: Max retries exceeded HTTP error 429 with body: \
             {\\\"code\\\":-32005,\\\"message\\\":\\\"Too Many Requests\\\",\\\"data\\\":{\\\"see\\\":\\\"https://infura.io/dashboard\\\"}}\" })";
        assert!(is_rate_limited(rendered));
    }

    #[test]
    fn matches_each_marker_in_isolation() {
        assert!(is_rate_limited("HTTP error 429 with body: {}"));
        assert!(is_rate_limited("blah blah Too Many Requests blah"));
        assert!(is_rate_limited("{\"code\":-32005,\"message\":\"nope\"}"));
    }

    /// An ordinary protocol/assertion failure must NOT be misclassified as an infra issue —
    /// that would be just as misleading in the other direction.
    #[test]
    fn does_not_match_an_unrelated_failure() {
        assert!(!is_rate_limited(
            "exit of 5000 wei: the contract delivered 4987, but the measured convention says 4988"
        ));
        assert!(!is_rate_limited("insufficientShieldedBalance (error)"));
        assert!(!is_rate_limited(""));
    }
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
        // Captured fresh each pass so a timeout can say WHY the last attempt failed, not just
        // that it did — a fork-backend 429 answering anvil's own `eth_chainId` reads exactly
        // like anvil never starting unless that reason is surfaced.
        let attempt_err = match ProviderBuilder::new()
            .network::<Ethereum>()
            .connect(url)
            .await
        {
            Ok(p) => match p.get_chain_id().await {
                Ok(_) => return,
                Err(e) => e.to_string(),
            },
            Err(e) => e.to_string(),
        };
        if Instant::now() >= deadline {
            rpc_fail(&format!("anvil not ready after {secs}s"), attempt_err);
        }
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

/// The address of the exit sender the sidecar SHOULD derive for `index`.
///
/// Re-derived here from the same entropy the sidecar received over fd 5, using the sidecar's own
/// `keys::derive_exit_key`, so the fixture can assert the sender is *derivable* and not merely
/// *different* from the last one. That distinction is the whole recovery story: a regression to
/// `PrivateKeySigner::random()` — which is literally what the upstream Kohaku fixture does —
/// would satisfy any "senders differ" check perfectly while making `DeliveryReverted`'s exit
/// index meaningless and every stranded exit unrecoverable.
fn derived_sender(entropy: &str, index: u32) -> Address {
    let key = keys::derive_exit_key(entropy, index)
        .unwrap_or_else(|e| panic!("derive exit key for index {index}: {e}"));
    key.parse::<alloy::signers::local::PrivateKeySigner>()
        .unwrap_or_else(|e| panic!("exit key for index {index} does not parse: {e}"))
        .address()
}

/// A derived sender's balances as they stood BEFORE an exit ran.
struct SenderState {
    address: Address,
    weth: U256,
    native: U256,
}

/// Snapshot every sender in the derivation window before an exit.
///
/// The WETH read has to be a DELTA, not an absolute. Senders are deterministic across runs, so
/// any leftover balance — the classic source being a leftover anvil on [`ANVIL_PORT`] serving a
/// stale fork that a fresh run silently attaches to — would fold straight into the exact
/// fee-convention assertion and report "RailgunSmartWallet's fee rounding has changed", sending
/// the next person to audit a governance parameter instead of killing a stray process.
async fn snapshot_derived_senders(
    provider: &DynProvider,
    weth: Address,
    entropy: &str,
) -> HashMap<u32, SenderState> {
    let weth_contract = WETHTest::new(weth, provider.clone());
    let mut out = HashMap::new();
    for index in 0..DERIVED_SENDER_WINDOW {
        let address = derived_sender(entropy, index);
        out.insert(
            index,
            SenderState {
                address,
                weth: weth_contract
                    .balanceOf(address)
                    .call()
                    .await
                    .rpc_expect("read derived sender WETH"),
                native: provider
                    .get_balance(address)
                    .await
                    .rpc_expect("read derived sender native balance"),
            },
        );
    }
    out
}

/// Everything `run_exit` needs that does not change between exits.
struct ExitCtx<'a> {
    socket: &'a str,
    token: &'a str,
    provider: &'a DynProvider,
    weth: Address,
    /// RAILGUN's privacy paymaster for this chain. Its EntryPoint deposit is what must pay.
    paymaster: Address,
    /// The same entropy the sidecar got over fd 5, so senders can be re-derived here.
    entropy: &'a str,
    log: &'a Arc<HelperLog>,
}

/// What one exit produced, measured on-chain rather than taken on trust.
struct ExitObservation {
    /// The recipient's NATIVE ETH balance delta across the exit.
    recipient_delta: U256,
    /// WETH left behind in the single-use sender, as a DELTA — the fee-prediction error.
    sender_dust: U256,
    /// The sender's native ETH balance after the exit; must be zero.
    sender_native_after: U256,
    /// Wei the privacy paymaster's EntryPoint deposit fell by — the sponsorship, measured.
    paymaster_spent: U256,
    /// What the sidecar said it forwarded.
    delivered: u128,
    sender: Address,
    exit_index: u64,
    /// Groth16 proof rounds this exit consumed.
    fee_iterations: usize,
}

/// Run one exit through the sidecar and measure what actually happened on-chain.
async fn run_exit(ctx: &ExitCtx<'_>, amount: u128) -> ExitObservation {
    let (socket, token, provider) = (ctx.socket, ctx.token, ctx.provider);
    let entry_point = EntryPointTest::new(ENTRY_POINT_08, provider.clone());

    // A fork inherits real Sepolia state, so the recipient may already hold ETH. Assert on the
    // DELTA; an absolute assertion would be wrong for reasons that have nothing to do with us.
    let before = provider
        .get_balance(RECIPIENT)
        .await
        .rpc_expect("read recipient balance (before exit)");
    // Snapshot the paymaster's EntryPoint deposit and the whole derived-sender window BEFORE the
    // op, so sponsorship and dust are both measured as deltas.
    let paymaster_before = entry_point
        .balanceOf(ctx.paymaster)
        .call()
        .await
        .rpc_expect("read paymaster EntryPoint deposit (before exit)");
    let senders_before = snapshot_derived_senders(provider, ctx.weth, ctx.entropy).await;
    let iterations_before = ctx.log.fee_iterations();
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
    .unwrap_or_else(|e| rpc_fail(&format!("unshield of {amount} wei was refused"), e));
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
        .rpc_expect("unshieldStatus must answer");
        match st["status"].as_str() {
            // NOTE: `deliveredAsset` is deliberately NOT asserted here. The sidecar hardcodes
            // that string literal in `exit_status`, so it is not derived from anything on-chain
            // and would still read "ETH" for an exit that delivered WETH. The recipient's native
            // `get_balance` delta below is the real native-delivery check; a second assertion
            // that cannot fail would only give a maintainer a misleading message to trust.
            Some("done") => break st["result"].clone(),
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

    let after = provider
        .get_balance(RECIPIENT)
        .await
        .rpc_expect("read recipient balance (after exit)");
    let sender: Address = outcome["sender"]
        .as_str()
        .expect("outcome must name the sender")
        .parse()
        .expect("sender must be an address");
    let delivered = hex_wei(&outcome["deliveredWei"], "deliveredWei");
    let exit_index = outcome["exitIndex"]
        .as_u64()
        .expect("outcome must name the exit index");
    let fee_iterations = ctx.log.fee_iterations() - iterations_before;

    // The sender must be the address the seed derives at the index the sidecar reported — not
    // merely some address it has not used before. See `derived_sender`.
    let index_u32 = u32::try_from(exit_index).expect("exit index fits u32");
    let expected = senders_before.get(&index_u32).unwrap_or_else(|| {
        panic!(
            "exit reported index {exit_index}, outside the snapshotted window \
             0..{DERIVED_SENDER_WINDOW} — widen DERIVED_SENDER_WINDOW (more retries fired than \
             the window allows for)"
        )
    });
    assert_eq!(
        sender, expected.address,
        "exit {exit_index}'s sender must be the address derived from the seed at that index \
         ({:?}), not an unrelated one — otherwise the index in a DeliveryReverted error cannot \
         recover the funds",
        expected.address
    );
    // Zero BEFORE as well as after: together these two say the ephemeral sender never held gas
    // money of its own, so the gas cannot have come from us.
    assert_eq!(
        expected.native,
        U256::ZERO,
        "exit {exit_index}'s sender {sender:?} held native ETH BEFORE the operation; a funded \
         sender would mean the exit was not purely paymaster-sponsored"
    );

    let sender_native_after = provider
        .get_balance(sender)
        .await
        .rpc_expect("read sender native balance (after exit)");
    let sender_weth_after = WETHTest::new(ctx.weth, provider.clone())
        .balanceOf(sender)
        .call()
        .await
        .rpc_expect("read sender WETH (after exit)");
    let paymaster_after = entry_point
        .balanceOf(ctx.paymaster)
        .call()
        .await
        .rpc_expect("read paymaster EntryPoint deposit (after exit)");
    // The feature, asserted: a sponsored op is paid out of the paymaster's EntryPoint deposit,
    // so that deposit MUST fall. Every other measurement in this fixture would hold identically
    // if the gas had come from somewhere else.
    assert!(
        paymaster_after < paymaster_before,
        "the privacy paymaster's EntryPoint deposit did not fall across exit {exit_index} \
         ({paymaster_before} -> {paymaster_after}), so the operation was NOT sponsored by it"
    );

    eprintln!(
        "[e2e] EXIT amount={amount} sender={sender:?} index={exit_index} \
         op={} delivered={delivered} wethDust={} paymasterSpent={} \
         feeLoopIterations={fee_iterations} wallClock={elapsed:?}",
        outcome["userOpHash"],
        sender_weth_after - expected.weth,
        paymaster_before - paymaster_after,
    );

    ExitObservation {
        recipient_delta: after - before,
        // A DELTA, so leftover state in a deterministic sender cannot corrupt the fee measurement.
        sender_dust: sender_weth_after - expected.weth,
        sender_native_after,
        paymaster_spent: paymaster_before - paymaster_after,
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
/// larger amount. That is what the three calibration amounts pin down: 10_000 cannot distinguish
/// any candidate (all give 9975), 5_000 separates floor-the-fee (4988) from floor-the-product
/// (4987), and 5_001 separates floor-the-fee (4989) from round-the-fee (4988). The library's
/// "lower bound" framing is therefore correct as written, and the 1-wei gap is absorbed as dust
/// rather than risking a revert.
///
/// Asserted exactly, not as a bound: it is the contract behaviour this task exists to pin down,
/// so a change to it should fail this fixture rather than quietly widen the dust.
fn measured_delivery(value: u128) -> u128 {
    value - value * FEE_BPS / BPS_DENOMINATOR
}

// --- Chain-id preflight ---------------------------------------------------------------------
//
// A real run supplied `https://eth-mainnet.g.alchemy.com/v2/<key>` for RPC_URL_SEPOLIA. Nothing
// downstream would have caught that cleanly: FORK_BLOCK (11011021) is a November-2020 mainnet
// block, and the Sepolia RAILGUN contracts this fixture pins do not exist at those addresses on
// mainnet, so the mistake would have surfaced as a confusing no-code/revert error deep inside
// setup rather than at its actual cause. `run_e2e` calls `eth_chainId` once, before anvil ever
// spawns, and routes the result through this pure predicate so the message — the whole point of
// the guard — has a unit test independent of a real RPC.

/// `Some(message)` naming the mismatch if `found_chain_id` is not Sepolia's; `None` if it matches.
fn sepolia_chain_id_mismatch(found_chain_id: u64) -> Option<String> {
    if found_chain_id == SEPOLIA_CHAIN_ID {
        return None;
    }
    Some(format!(
        "RPC_URL_SEPOLIA answered chain id {found_chain_id} (0x{found_chain_id:x}), not Sepolia's \
         {SEPOLIA_CHAIN_ID} (0x{SEPOLIA_CHAIN_ID:x}) — a MAINNET (or other non-Sepolia) RPC URL \
         was supplied where a SEPOLIA one is required. If this was copy-pasted from a working \
         mainnet URL, the same provider key usually works by swapping the host from \
         `eth-mainnet` to `eth-sepolia` — that is exactly the mismatch that produced this check."
    ))
}

#[cfg(test)]
mod chain_id_preflight_tests {
    use super::{sepolia_chain_id_mismatch, SEPOLIA_CHAIN_ID};

    #[test]
    fn sepolia_itself_passes() {
        assert!(sepolia_chain_id_mismatch(SEPOLIA_CHAIN_ID).is_none());
    }

    /// The exact mistake this guard responds to: a mainnet URL where Sepolia was required.
    #[test]
    fn mainnet_is_named_directly_and_hints_the_fix() {
        let msg = sepolia_chain_id_mismatch(1).expect("chain id 1 (mainnet) must be rejected");
        assert!(msg.contains("chain id 1"), "{msg}");
        assert!(msg.contains(&SEPOLIA_CHAIN_ID.to_string()), "{msg}");
        assert!(msg.contains("MAINNET"), "{msg}");
        assert!(msg.contains("eth-mainnet"), "{msg}");
        assert!(msg.contains("eth-sepolia"), "{msg}");
    }

    #[test]
    fn any_other_chain_is_also_rejected() {
        assert!(sepolia_chain_id_mismatch(137).is_some());
    }
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

    // 0. Fail fast if RPC_URL_SEPOLIA is not actually Sepolia.
    //
    // A real run supplied an `eth-mainnet.g.alchemy.com` URL here. Nothing downstream would have
    // caught that cleanly: FORK_BLOCK (11011021) is a November-2020 mainnet block, and the
    // Sepolia RAILGUN contracts this fixture pins (RailgunSmartWallet, the privacy paymaster,
    // WETH) do not exist at those addresses on mainnet — so the mistake would have surfaced as a
    // confusing no-code/revert error deep inside setup, far from its actual cause. One
    // `eth_chainId` call, before anvil (or anything else) spawns, turns that into an immediate,
    // named failure instead — the cost is a single HTTP request.
    let chain_probe: DynProvider = ProviderBuilder::new()
        .network::<Ethereum>()
        .connect(&rpc)
        .await
        .expect("RPC_URL_SEPOLIA does not parse as a URL")
        .erased();
    let found_chain_id = chain_probe
        .get_chain_id()
        .await
        .rpc_expect("read chain id from RPC_URL_SEPOLIA (pre-flight network check)");
    if let Some(msg) = sepolia_chain_id_mismatch(found_chain_id) {
        panic!("{msg}");
    }

    let dir = tempfile::tempdir().unwrap();
    // Held for the whole test: it holds the exit-index counter, which is what makes the two
    // exits derive DIFFERENT senders.
    let state_dir = tempfile::tempdir().unwrap();
    let helper_sock = dir.path().join("helper.sock").to_string_lossy().to_string();
    let entropy = "0x1122334455667788990011223344556677889900112233445566778899001122";
    let token = "helper-token";

    // 1. Refuse to run against a leftover anvil, the same way `alto::spawn` refuses a leftover
    //    Alto. `wait_for_rpc` cannot tell a fresh fork from a stale one, and attaching to a stale
    //    one is not a clean failure: the derived senders are DETERMINISTIC, so they would already
    //    hold WETH dust from the previous run, and the exact fee-convention assertion would then
    //    fail with "RailgunSmartWallet's fee rounding has changed" — sending the next person to
    //    audit a governance parameter instead of killing a stray process.
    assert!(
        std::net::TcpStream::connect(("127.0.0.1", ANVIL_PORT)).is_err(),
        "port {ANVIL_PORT} is already bound — a leftover anvil from an interrupted run is still \
         serving a STALE fork. Kill it before re-running; this fixture must own its fork."
    );

    // 2. anvil fork of Sepolia.
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

    // 3. Fund Alto's executor and utility EOAs BEFORE Alto starts: the utility account deploys
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
            .rpc_expect("fund alto key");
    }

    // 4. Local Alto: a public bundler cannot see the fork. Required, never skipped.
    let alto_log = dir.path().join("alto.log");
    let _alto = alto::spawn(&anvil_url(), ALTO_PORT, &alto_log)
        .await
        .unwrap_or_else(|e| rpc_fail_bare(e));
    let bundler_url = format!("http://127.0.0.1:{ALTO_PORT}");

    // 5. Spawn ONLY the sidecar (entropy over fd 5 — this dogfoods the fd-5 spawn contract).
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
        // The fixture must be self-sufficient under its OWN documented invocation, not only via
        // `scripts/e2e-fork.sh`. `tap_helper_log` counts the SDK's log lines to get the fee-loop
        // iteration count, and at the default filter the sidecar emits none of them — so a bare
        // `cargo test --features fork-sync --test e2e_fork -- --ignored` would do three minutes of
        // *successful* on-chain work and then fail with "0 fee-loop iterations", blaming a
        // convergence regression for a missing env var. The script's export is belt-and-braces.
        .env(
            "RUST_LOG",
            std::env::var("RUST_LOG").unwrap_or_else(|_| "railgun_helper=info,railgun=info".into()),
        )
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

    // 6. SHIELD: the sidecar builds the tx(s), the owner self-submits each.
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
    .rpc_expect("prepareShield");
    let txs: Vec<TxData> = serde_json::from_value(shield_txs).expect("shield tx list");
    assert!(!txs.is_empty(), "expected >=1 shield tx");
    for tx in txs {
        let receipt = within("shield submit", async {
            owner_provider
                .send_transaction(tx.into())
                .await
                .rpc_expect("send shield")
                .get_receipt()
                .await
                .rpc_expect("shield receipt")
        })
        .await;
        assert!(receipt.status(), "shield tx must succeed: {receipt:?}");
        eprintln!(
            "[e2e] shield tx {:?} confirmed in block {:?}",
            receipt.transaction_hash, receipt.block_number
        );
    }

    // 7. The shielded balance reflects the deposit.
    let bal = within(
        "balance",
        rpc::call(&helper_sock, token, "balance", json!(null)),
    )
    .await
    .rpc_expect("balance");
    let total = hex_wei(&bal["total"], "balance.total");
    eprintln!("[e2e] shielded balance total = {total} wei ({bal})");
    assert!(
        total >= SHIELD_WEI * 99 / 100,
        "shielded balance {total} too low for a {SHIELD_WEI} wei shield"
    );

    // 8. The reserve is the real constraint on SHIELD_WEI, and it is priced from the LIVE
    //    bundler gas sample — so assert the margin against the live number rather than trusting
    //    the constant. If this fires, raise SHIELD_WEI; do not shrink the reserve.
    let ceiling = within(
        "maxUnshieldable",
        rpc::call(&helper_sock, token, "maxUnshieldable", json!(null)),
    )
    .await
    .rpc_expect("maxUnshieldable");
    let max_value = hex_wei(&ceiling["maxValueWei"], "maxValueWei");
    let reserve = hex_wei(&ceiling["reserveWei"], "reserveWei");
    eprintln!(
        "[e2e] maxUnshieldable: maxValue={max_value} reserve={reserve} \
         receivableAtMax={} (shielded {total})",
        hex_wei(&ceiling["receivableAtMaxWei"], "receivableAtMaxWei")
    );
    let needed: u128 = UNSHIELD_AMOUNTS.iter().sum();
    assert!(
        max_value >= needed,
        "the live fee reserve ({reserve} wei) leaves only {max_value} wei spendable out of \
         {total}, which cannot cover the {needed} wei of calibration exits — raise SHIELD_WEI"
    );

    let chain = railgun::chain_config::ChainConfig::sepolia();
    let ctx = ExitCtx {
        socket: &helper_sock,
        token,
        provider: &owner_provider,
        weth: chain.wrapped_base_token,
        paymaster: chain
            .privacy_paymaster
            .expect("Sepolia must have a privacy paymaster configured"),
        entropy,
        log: &log,
    };

    // 9. The exits. Asserted per-exit inside the loop rather than after it, so a failure names the
    //    amount that produced it and stops before spending another ~40s of proving.
    //    `implied` — forwarded + dust — is what the contract ACTUALLY delivered.
    let implied = |obs: &ExitObservation| U256::from(obs.delivered) + obs.sender_dust;
    let mut observations: Vec<(u128, ExitObservation)> = Vec::new();
    for value in UNSHIELD_AMOUNTS {
        let obs = run_exit(&ctx, value).await;

        assert_eq!(
            obs.delivered,
            expected_forward(value),
            "exit of {value} wei must forward the predicted delivery minus the epsilon guard"
        );
        assert_eq!(
            obs.recipient_delta,
            U256::from(obs.delivered),
            "exit of {value} wei: the recipient must receive exactly the forwarded amount as \
             NATIVE ETH — a mismatch means the unwrap-and-forward tail call did not do what we \
             think, or that WETH arrived instead"
        );
        // Single-use and forwards everything: combined with the zero-before check inside
        // `run_exit`, the sender never holds value at either end.
        assert_eq!(
            obs.sender_native_after,
            U256::ZERO,
            "exit of {value} wei: the ephemeral sender {:?} must forward all native ETH, \
             keeping none",
            obs.sender
        );
        // The measured convention, pinned exactly — the assertion that IDENTIFIES the rounding
        // rather than restating our own arithmetic back at us.
        assert_eq!(
            implied(&obs),
            U256::from(measured_delivery(value)),
            "exit of {value} wei: the contract delivered {}, but the measured convention \
             `value - floor(value * {FEE_BPS} / {BPS_DENOMINATOR})` says {} — RailgunSmartWallet's \
             fee rounding has changed and fee.rs needs re-checking",
            implied(&obs),
            measured_delivery(value)
        );
        // ...and therefore `delivered_lower_bound` really is a lower bound. Kept separate because
        // THIS is the property `forward_amount` depends on for `WETH.withdraw` never to revert;
        // the equality above is merely the explanation for it.
        assert!(
            implied(&obs) >= U256::from(predicted_delivery(value)),
            "exit of {value} wei: the contract delivered {} but fee::delivered_lower_bound \
             predicted at least {} — the 'lower bound' is not a lower bound, and WETH.withdraw \
             only did not revert because of the {DELIVERY_EPSILON_WEI} wei guard",
            implied(&obs),
            predicted_delivery(value)
        );
        // The loop cannot converge on its first proof (the SDK's seed `fee_value` is orders of
        // magnitude below a real sponsored fee), so 2 is the floor; >5 means the convergence
        // retry fired, which is worth seeing but not a failure.
        assert!(
            (2..=2 * FEE_LOOP_SDK_CAP).contains(&obs.fee_iterations),
            "exit of {value} wei: {} fee-loop iterations is outside the expected \
             2..={} ({FEE_LOOP_SDK_CAP} per attempt, at most one convergence retry). Zero \
             iterations means the sidecar's log was not captured, NOT a convergence regression.",
            obs.fee_iterations,
            2 * FEE_LOOP_SDK_CAP
        );
        // Drift toward the SDK's cap is the finding that a passing test would otherwise swallow:
        // the cap is hard, and this is an IDLE fork with a flat gas price.
        if obs.fee_iterations >= FEE_LOOP_HEADROOM_WARN {
            eprintln!(
                "[e2e] WARNING: the exit of {value} wei used {} fee-convergence rounds — within \
                 {} of the SDK's hard {FEE_LOOP_SDK_CAP}-round cap, on an IDLE fork with a flat \
                 gas price. On live Sepolia with a moving base fee this is where \
                 FeeDidNotConverge starts to bite.",
                obs.fee_iterations,
                FEE_LOOP_SDK_CAP.saturating_sub(obs.fee_iterations),
            );
        }

        observations.push((value, obs));
    }

    // 10. Rotation: no two exits may share a sender or an index, or every exit clusters under one
    //    address again. (That each sender is *derivable* — the property recovery depends on — is
    //    asserted per-exit inside `run_exit`.)
    for (i, (v1, o1)) in observations.iter().enumerate() {
        for (v2, o2) in observations.iter().skip(i + 1) {
            assert_ne!(
                o1.sender, o2.sender,
                "the {v1} wei and {v2} wei exits shared sender {:?} (indices {} and {})",
                o1.sender, o1.exit_index, o2.exit_index
            );
            assert_ne!(
                o1.exit_index, o2.exit_index,
                "the {v1} wei and {v2} wei exits shared index {} — each exit must burn its own",
                o1.exit_index
            );
        }
    }

    // 11. Calibration. The dust is the fee-prediction error: `delivered_lower_bound` is
    //     deliberately a LOWER bound, so what stays behind is `actual_delivery - forwarded`.
    //     `paymasterSpent` is the sponsored gas cost, read off the paymaster's EntryPoint deposit.
    let mut line = format!("FEE CALIBRATION: epsilon={DELIVERY_EPSILON_WEI} wei");
    for (value, obs) in &observations {
        line.push_str(&format!(
            " | value={value} lowerBound={} measured={} forwarded={} dust={} impliedDelivery={} \
             paymasterSpent={} feeLoopIterations={}",
            predicted_delivery(*value),
            measured_delivery(*value),
            obs.delivered,
            obs.sender_dust,
            implied(obs),
            obs.paymaster_spent,
            obs.fee_iterations,
        ));
    }
    line.push_str(&format!(
        " | provingKeyDownloads={} wasmModuleLoads={}",
        log.proving_key_downloads.load(Ordering::SeqCst),
        log.wasm_loads.load(Ordering::SeqCst),
    ));
    eprintln!("{line}");

    eprintln!(
        "[e2e] PASS: shield + {} paymaster-sponsored exits at different amounts delivered native \
         ETH to {RECIPIENT:?} from distinct, seed-derivable single-use senders, each paid for out \
         of the privacy paymaster's EntryPoint deposit, confirmed on-chain.",
        observations.len()
    );
}
