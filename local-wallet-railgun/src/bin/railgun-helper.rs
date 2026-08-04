//! `railgun-helper` sidecar: the wallet's single privacy entry point. Serves
//! `balance` / `maxUnshieldable` / `prepareShield` / `unshield` / `unshieldStatus` over a
//! bearer-authenticated Unix-socket JSON-RPC API, wrapping the RAILGUN Rust SDK.
//!
//! An unshield exits through RAILGUN's privacy paymaster as an ERC-4337 UserOperation
//! submitted by a PUBLIC bundler. There is no local broadcaster child: nothing of ours pays
//! gas, so this is the only process the app talks to and there is nothing to fund.
//!
//! - `balance` → `{valid,pending,total}` (0x hex wei).
//! - `maxUnshieldable` → `{maxValueWei,receivableAtMaxWei,reserveWei}` (0x hex wei).
//! - `prepareShield {amountWei}` → `[{to,data,value}]` for the OWNER to self-submit.
//! - `unshield {amountWei,to}` → `{jobId}` immediately; proving + submission run in the
//!   background (proving alone exceeds any sane RPC timeout).
//! - `unshieldStatus {jobId}` → `{status: pending|submitted|done|error, result?, error?, code?,
//!   submitted?}`. `submitted` appears only on `status: error` for codes where the code alone
//!   cannot say whether a UserOperation reached the bundler's mempool — see [`error_status`].
//!
//! Every wei amount crossing this boundary — in BOTH directions — is a `0x`-hex string, never a
//! JSON number: 2^53 wei is 0.009 ETH, so a number would silently lose precision in any
//! Double-backed decoder.
//!
//! **Failure codes.** Both failure paths give the app a stable camelCase code to switch on
//! instead of a sentence to substring-match. Asynchronous failures carry it as `code` inside
//! the `unshieldStatus` payload (from `ExitError::code()`); synchronous rejections carry it as
//! `error.data.code` in the JSON-RPC error object (from `RpcError`). The synchronous set is:
//!
//! - `badRequest` — malformed params (unparseable amount or recipient, missing `jobId`).
//! - `insufficientShieldedBalance` — the amount exceeds the live spendable ceiling.
//! - `bundlerUnavailable` — the bundler's gas endpoint could not be read, so the fee reserve
//!   cannot be sized. Distinct from the above because nothing is wrong with the user's balance.
//! - `unknownJobId` — no such job (never started, or already read to a terminal state, or
//!   TTL-swept).
//! - `error` — anything else (RAILGUN sync/build failures, internal invariants).
//!
//! The secret (RAILGUN entropy) arrives on **fd 5** (`HelperFd5`); env is a standalone/dev
//! fallback only. Every ephemeral exit sender is derived from that same entropy root, never
//! carried separately. Non-secret config is via env.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use alloy::primitives::Address;
use railgun::chain_config::ChainConfig;
use railgun_helper::exit::ExitOutcome;
use railgun_helper::pool::RailgunHelper;
use railgun_helper::provider::connect_provider;
use railgun_helper::rpc::{serve_rpc, Handlers, RpcError};
use railgun_helper::secret::HelperFd5;
use railgun_helper::spawn::read_fd5;
use railgun_helper::{exit, fee, keys, rpc_handler};
use serde_json::{json, Value};
use tokio::sync::Mutex;

fn env(key: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| panic!("missing env {key}"))
}

/// Synchronous failure codes. See the module header for what each one means to the app; they
/// are a wire contract, so rename one only alongside the client.
const CODE_BAD_REQUEST: &str = "badRequest";
const CODE_INSUFFICIENT: &str = "insufficientShieldedBalance";
const CODE_BUNDLER_UNAVAILABLE: &str = "bundlerUnavailable";
const CODE_UNKNOWN_JOB: &str = "unknownJobId";

/// How long an unshield job lingers, since its last update, before the TTL sweep drops it.
/// It exists only to bound the map against jobs a client abandons; it must never evict a job
/// that is still progressing.
///
/// The primary defence against evicting a live job is that `unshieldStatus` restamps every
/// non-terminal read, so an actively-polled job cannot expire at any TTL. This constant is the
/// second line, for the window before the first poll: it is derived from
/// [`exit::RECEIPT_POLL_BUDGET`] rather than hardcoded because at an equal TTL an op that took
/// the full budget to land would be swept out from under the app mid-poll — `unknown jobId` on
/// an exit that is fine — and then RESURRECTED when polling finally wrote its result. The
/// margin also covers `wait_for_receipt`'s own 60s timeout overshooting the budget's
/// top-of-loop check, plus one poll interval.
const JOB_TTL: Duration = Duration::from_secs(exit::RECEIPT_POLL_BUDGET.as_secs() + 300);

/// Drop job entries whose last update is older than `JOB_TTL`. Cheap linear sweep — the map
/// holds at most a handful of in-flight jobs for this single-user sidecar.
fn prune_jobs(map: &mut HashMap<String, (Instant, Value)>, now: Instant) {
    map.retain(|_, (updated, _)| now.duration_since(*updated) < JOB_TTL);
}

/// Parse a wei amount from the wire.
///
/// Accepts `0x`-prefixed hex as well as decimal, because every wei amount this sidecar
/// RETURNS is `0x`-hex (`balance`, `maxUnshieldable`) — so a caller that feeds
/// `maxValueWei` straight back into `unshield` must not be rejected. A JSON number is
/// tolerated for hand-driven calls only: above 2^53 it is not representable, which is
/// exactly why the wire format is a string.
fn parse_amount(v: &Value) -> Result<u128, String> {
    match v {
        Value::String(s) => match s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
            Some(hex) => u128::from_str_radix(hex, 16),
            None => s.parse::<u128>(),
        }
        .map_err(|e| format!("bad amount {s}: {e}")),
        Value::Number(n) => n
            .as_u64()
            .map(u128::from)
            .ok_or_else(|| "amount not a u64".into()),
        _ => Err("amount must be a string or number".into()),
    }
}

fn parse_addr(v: &Value) -> Result<Address, String> {
    v.as_str()
        .ok_or_else(|| "address must be a string".to_string())?
        .parse::<Address>()
        .map_err(|e| format!("bad address: {e}"))
}

/// Secret: fd-5 `HelperFd5` (entropy only) if provided, else env (standalone/dev).
fn load_secrets() -> String {
    match read_fd5() {
        Some(bytes) => {
            let s: HelperFd5 = serde_json::from_slice(&bytes).expect("invalid fd-5 helper secret");
            s.entropy_hex
        }
        None => {
            std::env::var("RAILGUN_ENTROPY_HEX").expect("no fd-5 secret and no RAILGUN_ENTROPY_HEX")
        }
    }
}

/// The spendable ceiling: the largest `value` that can leave the pool, plus the headroom
/// held back for it.
struct Ceiling {
    max: fee::MaxUnshieldable,
    /// Wei held back in the pool to pay the paymaster's in-pool fee note.
    reserve: u128,
}

/// Compute the ceiling from a live shielded balance and a live bundler gas sample (two
/// network calls — not an accessor).
///
/// ONE implementation on purpose, shared by `maxUnshieldable` and `unshield`'s fail-fast
/// pre-check. `maxUnshieldable` tells the app the largest amount it may ask for and
/// `unshield` refuses anything larger; if the two computed it separately they could drift
/// apart and the UI would offer a maximum the sidecar then rejects.
async fn spendable_ceiling(helper: &mut RailgunHelper) -> Result<Ceiling, RpcError> {
    let split = helper.balance_split().await?;
    // POI is intentionally OFF (see `pool`), so `total == valid`: every note is spendable now
    // and `total` is exactly what the app's balance card shows. If POI is ever enabled this
    // must switch to `valid`, or the ceiling would promise notes that cannot yet be spent.
    let balance = u128::from_str_radix(split.total.trim_start_matches("0x"), 16)
        .map_err(|e| format!("parse balance {}: {e}", split.total))?;
    let url = exit::resolve_bundler_url(helper.chain_id());
    // Coded distinctly: the user's balance is fine, we just cannot size the reserve without a
    // gas sample. Reporting this as "insufficient balance" would send the app to the wrong copy.
    let max_fee = exit::fetch_max_fee_per_gas(&url).await.map_err(|e| {
        RpcError::new(
            CODE_BUNDLER_UNAVAILABLE,
            format!("cannot read the bundler's gas price, so the fee reserve cannot be sized: {e}"),
        )
    })?;
    let reserve = fee::gas_reserve_wei(&fee::RAILGUN_UNSHIELD_GAS_UNITS, max_fee);
    Ok(Ceiling {
        max: fee::max_unshieldable(balance, helper.unshield_fee_bps(), reserve),
        reserve,
    })
}

/// The `unshieldStatus` payload for an exit that has a real op hash.
///
/// ONE builder for BOTH phases, so `submitted` has exactly one schema on the wire no matter
/// which phase wrote it: phase 1 publishes the outcome it can already prove
/// (`included: false`) and phase 2 overwrites it with the polled one. Two shapes behind one
/// status string would break any client decoder with a non-optional `included`.
fn exit_status(outcome: &ExitOutcome) -> Value {
    json!({
        "status": if outcome.included { "done" } else { "submitted" },
        "deliveredAsset": "ETH",
        "result": serde_json::to_value(outcome).expect("ExitOutcome serialises"),
    })
}

/// The `unshieldStatus` payload for a failed exit, carrying the same stable code the
/// synchronous path puts in `error.data.code`.
///
/// `submitted` rides ALONGSIDE the code, present only where the code cannot answer the question
/// on its own (today: `bundlerRejected`). The app needs it to decide whether to revert the card:
/// `submitted: false` means nothing was ever sent and the card should revert, `true` means the op
/// may be in the mempool and the card must stay Submitted. Encoding that as a second code instead
/// would fork the code space and the app's copy map for one bit of information.
fn error_status(e: &exit::ExitError) -> Value {
    let mut v = json!({
        "status": "error",
        "code": e.code(),
        "error": e.to_string(),
    });
    if let Some(submitted) = e.submitted() {
        v["submitted"] = json!(submitted);
    }
    v
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let rpc_url = std::env::var("RAILGUN_RPC_URL")
        .or_else(|_| std::env::var("LOCAL_WALLET_PRIVACY_RPC_URL"))
        .expect("missing RAILGUN_RPC_URL / LOCAL_WALLET_PRIVACY_RPC_URL");
    // Only used under the `fork-sync` feature (caps Subsquid at the fork block). For the
    // app / live use it is irrelevant, so default to 0 when unset.
    let fork_block: u64 = std::env::var("RAILGUN_FORK_BLOCK")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let socket = env("RAILGUN_SOCKET");
    let token = env("RAILGUN_TOKEN");
    // Where the per-exit rotation counter lives. Not a secret. The app passes its
    // Application Support dir; the fork fixture passes a tempdir.
    //
    // The fallback (the socket's parent) is a convenience for standalone runs, and it WARNS
    // loudly: this is a privacy-critical value. If the socket lives somewhere volatile the
    // counter is lost on restart, the index restarts at 0, and exit senders are reused across
    // exits — silently costing each reused exit its unlinkability. Degrading quietly is exactly
    // what must not happen here.
    let state_dir = match std::env::var("RAILGUN_STATE_DIR") {
        Ok(dir) => std::path::PathBuf::from(dir),
        Err(_) => {
            let fallback = std::path::Path::new(&socket)
                .parent()
                .map(|p| p.to_path_buf())
                .unwrap_or_else(|| std::path::PathBuf::from("."));
            tracing::warn!(
                "RAILGUN_STATE_DIR is unset; keeping the per-exit rotation counter next to the \
                 socket at {}. If that directory is not persistent, exit senders WILL be reused \
                 across restarts and each reused exit loses its unlinkability.",
                fallback.display()
            );
            fallback
        }
    };
    // The RAILGUN account seed AND every exit sender come from this one root. Never logged.
    let entropy = load_secrets();

    let chain = ChainConfig::sepolia();

    // Build the RAILGUN provider (read-only: the exit's UserOperation is signed by its
    // ephemeral sender and broadcast by a public bundler, so nothing here submits a tx).
    let signer = keys::derive_railgun_signer(&entropy, chain.id).expect("derive signer");
    let provider = connect_provider(&rpc_url).await.expect("connect provider");
    let helper = RailgunHelper::new(chain, provider, fork_block, signer)
        .await
        .expect("build railgun helper");
    #[allow(clippy::arc_with_non_send_sync)]
    let helper = Arc::new(Mutex::new(helper));

    // Async unshield jobs: jobId -> (last-updated, status Value). A terminal job is dropped
    // as soon as a client reads it (below), which keeps the map empty on the normal
    // polled-to-completion path; the TTL sweep in `prune_jobs` is the backstop that bounds
    // the map even for jobs a client never polls to a terminal read (crash / navigation).
    let jobs: Arc<Mutex<HashMap<String, (Instant, Value)>>> = Arc::new(Mutex::new(HashMap::new()));
    let job_seq = Arc::new(AtomicU64::new(1));

    let mut handlers: Handlers = HashMap::new();

    {
        let h = helper.clone();
        handlers.insert(
            "balance".to_string(),
            rpc_handler!(move |_p: Value| {
                let h = h.clone();
                async move { Ok(serde_json::to_value(h.lock().await.balance_split().await?).unwrap()) }
            }),
        );
    }
    {
        // maxUnshieldable: the largest amountWei we will accept, plus what the recipient
        // would receive at that amount. Two numbers because there is NO gross-up — the
        // requested amount is what leaves the pool.
        let h = helper.clone();
        handlers.insert(
            "maxUnshieldable".to_string(),
            rpc_handler!(move |_p: Value| {
                let h = h.clone();
                async move {
                    let c = spendable_ceiling(&mut *h.lock().await).await?;
                    Ok(json!({
                        "maxValueWei": format!("0x{:x}", c.max.max_value),
                        "receivableAtMaxWei": format!("0x{:x}", c.max.receivable_at_max),
                        "reserveWei": format!("0x{:x}", c.reserve),
                    }))
                }
            }),
        );
    }
    {
        let h = helper.clone();
        handlers.insert(
            "prepareShield".to_string(),
            rpc_handler!(move |p: Value| {
                let h = h.clone();
                async move {
                    let amount = parse_amount(p.get("amountWei").unwrap_or(&Value::Null))
                        .map_err(|e| RpcError::new(CODE_BAD_REQUEST, e))?;
                    let txs = h.lock().await.prepare_shield_native(amount).await?;
                    Ok(serde_json::to_value(txs).unwrap())
                }
            }),
        );
    }
    {
        // unshield: kick off proving + submission in the background, return a jobId now.
        let h = helper.clone();
        let jobs = jobs.clone();
        let seq = job_seq.clone();
        let entropy = entropy.clone();
        let state_dir = state_dir.clone();
        handlers.insert(
            "unshield".to_string(),
            rpc_handler!(move |p: Value| {
                let (h, jobs, seq) = (h.clone(), jobs.clone(), seq.clone());
                let (entropy, state_dir) = (entropy.clone(), state_dir.clone());
                async move {
                    let amount = parse_amount(p.get("amountWei").unwrap_or(&Value::Null))
                        .map_err(|e| RpcError::new(CODE_BAD_REQUEST, e))?;
                    let recipient = parse_addr(p.get("to").unwrap_or(&Value::Null))
                        .map_err(|e| RpcError::new(CODE_BAD_REQUEST, e))?;

                    // Fail fast: nobody should wait ~13s (or ~28s if the fee loop struggles)
                    // for a proof that cannot fit. Same ceiling `maxUnshieldable` reports.
                    {
                        let c = spendable_ceiling(&mut *h.lock().await).await?;
                        if amount > c.max.max_value {
                            // Deliberately NUMBER-FREE. `rpc.rs`'s handler-error `warn!` writes
                            // this sentence to stderr, which for the app-spawned sidecar is
                            // captured into the macOS unified log and every `sysdiagnose`. The
                            // shielded balance is EXACTLY `max_value + reserve`, so naming both
                            // would persist the user's balance to a system log on every
                            // over-large unshield. The app already holds `maxUnshieldable` and
                            // renders the ceiling itself, so it needs nothing from here.
                            return Err(RpcError::new(
                                CODE_INSUFFICIENT,
                                "that amount is more than can currently leave the pool: gas for \
                                 the exit is paid by a fee note inside the pool, so some of the \
                                 shielded balance has to stay behind",
                            ));
                        }
                    }

                    let job_id = format!("job-{}", seq.fetch_add(1, Ordering::SeqCst));
                    {
                        let mut map = jobs.lock().await;
                        prune_jobs(&mut map, Instant::now());
                        map.insert(
                            job_id.clone(),
                            (Instant::now(), json!({"status":"pending"})),
                        );
                    }

                    let jid = job_id.clone();
                    // Proving is non-Send (RAILGUN provider) → spawn_local on this thread.
                    tokio::task::spawn_local(async move {
                        // Phase 1: prove + sign + submit, holding the helper lock. `chain_id`
                        // comes from the same lock so phase 2 needs no lock at all.
                        let (submitted, chain_id) = {
                            let mut guard = h.lock().await;
                            let chain_id = guard.chain_id();
                            (
                                guard
                                    .submit_exit(recipient, amount, &state_dir, &entropy)
                                    .await,
                                chain_id,
                            )
                        };
                        let sub = match submitted {
                            Ok(s) => s,
                            Err(e) => {
                                jobs.lock()
                                    .await
                                    .insert(jid, (Instant::now(), error_status(&e)));
                                return;
                            }
                        };

                        // Publish `submitted` the moment a hash exists, so the app shows a real
                        // op hash instead of a spinner and stops counting inclusion time
                        // against its proving deadline. NOT terminal — the job stays in the map.
                        //
                        // Published as the `pending_outcome`, i.e. the SAME schema phase 2 will
                        // overwrite it with, so `submitted` never has two shapes on the wire.
                        jobs.lock().await.insert(
                            jid.clone(),
                            (Instant::now(), exit_status(&sub.pending_outcome())),
                        );

                        // Phase 2: poll for the receipt WITHOUT the helper lock, so `balance`
                        // and `maxUnshieldable` keep answering during inclusion.
                        let url = exit::resolve_bundler_url(chain_id);
                        let status = match exit::await_exit(&url, &sub).await {
                            Ok(outcome) => exit_status(&outcome),
                            Err(e) => error_status(&e),
                        };
                        jobs.lock().await.insert(jid, (Instant::now(), status));
                    });

                    Ok(json!({ "jobId": job_id }))
                }
            }),
        );
    }
    {
        let jobs = jobs.clone();
        handlers.insert(
            "unshieldStatus".to_string(),
            rpc_handler!(move |p: Value| {
                let jobs = jobs.clone();
                async move {
                    let id = p
                        .get("jobId")
                        .and_then(|v| v.as_str())
                        .ok_or_else(|| RpcError::new(CODE_BAD_REQUEST, "missing jobId"))?;
                    let now = Instant::now();
                    let mut map = jobs.lock().await;
                    prune_jobs(&mut map, now);
                    let status = map.get(id).map(|(_, v)| v.clone()).ok_or_else(|| {
                        RpcError::new(CODE_UNKNOWN_JOB, format!("unknown jobId: {id}"))
                    })?;
                    // Evict terminal jobs once observed so the common (polled-to-completion)
                    // path keeps the map tiny; the TTL sweep above backstops jobs that are
                    // never polled to a terminal read.
                    //
                    // `submitted` is deliberately ABSENT: the op has a hash but no receipt yet,
                    // so the entry must survive this read for the app to keep polling it to
                    // `done`. Only `done` and `error` are terminal.
                    let terminal = matches!(
                        status.get("status").and_then(|s| s.as_str()),
                        Some("done") | Some("error")
                    );
                    if terminal {
                        map.remove(id);
                    } else if let Some((updated, _)) = map.get_mut(id) {
                        // Refresh on every non-terminal read, which closes the sweep-then-
                        // resurrect class outright instead of tuning JOB_TTL against it. A
                        // generous TTL alone is not enough: `pending` is never restamped while
                        // phase 1 runs, and phase 1 is UNBOUNDED — first-exit circuit-artifact
                        // download plus up to 10 Groth16 proofs across the authorised retry. Any
                        // fixed constant can be exceeded there. So long as a client is actually
                        // polling, its job now cannot expire under it.
                        *updated = now;
                    }
                    Ok(status)
                }
            }),
        );
    }

    println!("{}", json!({"ready": true, "socket": socket}));
    tracing::info!("railgun-helper serving on {socket}");

    // current_thread runtime + LocalSet so the non-Send proving tasks can spawn_local.
    let local = tokio::task::LocalSet::new();
    // Orphan backstop: exit if our parent (the app) dies, so we don't linger holding the
    // shielded seed.
    local.spawn_local(async {
        loop {
            tokio::time::sleep(Duration::from_secs(2)).await;
            if unsafe { libc::getppid() } == 1 {
                std::process::exit(0);
            }
        }
    });
    local
        .run_until(async move { serve_rpc(&socket, token, handlers).await })
        .await
        .expect("serve");
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// `wait_for_receipt`'s own internal timeout, which can carry one poll iteration past
    /// `RECEIPT_POLL_BUDGET`'s top-of-loop check. The bundler client does not export it, so it
    /// is mirrored here purely so the TTL margin assertion is honest about what it covers.
    const BUNDLER_RECEIPT_TIMEOUT: Duration = Duration::from_secs(60);

    #[test]
    fn prune_drops_only_expired_jobs() {
        // Simulate ages via Instant arithmetic (no real waiting): the "old" entry is stamped
        // at t0, the "fresh" one JOB_TTL later; sweeping just past t0+JOB_TTL expires only old.
        let mut map: HashMap<String, (Instant, Value)> = HashMap::new();
        let t0 = Instant::now();
        map.insert("old".to_string(), (t0, json!({"status": "done"})));
        map.insert(
            "fresh".to_string(),
            (t0 + JOB_TTL, json!({"status": "pending"})),
        );

        prune_jobs(&mut map, t0 + JOB_TTL + Duration::from_secs(1));

        assert!(!map.contains_key("old"), "expired job must be pruned");
        assert!(map.contains_key("fresh"), "in-TTL job must be retained");
    }

    #[test]
    fn job_ttl_covers_the_worst_case_receipt_poll() {
        // Encodes the FULL worst case the constant's doc comment claims to cover, not merely
        // "bigger than the budget" — that weaker form would pass at budget+1s while still
        // sweeping a job mid-poll, then resurrecting it when polling finally wrote its result.
        //
        // Worst case: the budget is only checked at the top of the loop, so one more iteration
        // can start just under it and then block for `wait_for_receipt`'s own timeout, plus the
        // inter-poll sleep.
        let worst_case =
            exit::RECEIPT_POLL_BUDGET + BUNDLER_RECEIPT_TIMEOUT + exit::RECEIPT_POLL_INTERVAL;
        assert!(
            JOB_TTL > worst_case,
            "TTL {JOB_TTL:?} must exceed the worst-case poll {worst_case:?} \
             (budget {:?} + receipt timeout {BUNDLER_RECEIPT_TIMEOUT:?} + interval {:?})",
            exit::RECEIPT_POLL_BUDGET,
            exit::RECEIPT_POLL_INTERVAL,
        );
    }

    #[test]
    fn amounts_parse_from_hex_and_decimal_strings() {
        // Hex is the format every wei amount LEAVES here in, so `maxUnshieldable`'s
        // `maxValueWei` must be feedable straight back into `unshield {amountWei}`.
        assert_eq!(parse_amount(&json!("0x2710")).unwrap(), 10_000);
        assert_eq!(parse_amount(&json!("10000")).unwrap(), 10_000);
        // Beyond 2^53, where a JSON number would already have lost precision.
        assert_eq!(
            parse_amount(&json!("0xde0b6b3a7640000")).unwrap(),
            1_000_000_000_000_000_000
        );
        assert_eq!(
            parse_amount(&json!("1000000000000000000")).unwrap(),
            1_000_000_000_000_000_000
        );
        // Garbage must be refused, not silently coerced to 0.
        assert!(parse_amount(&json!("0xzz")).is_err());
        assert!(parse_amount(&json!("12abc")).is_err());
        assert!(parse_amount(&json!(null)).is_err());
    }

    #[test]
    fn prune_is_a_noop_when_nothing_is_expired() {
        let mut map: HashMap<String, (Instant, Value)> = HashMap::new();
        let now = Instant::now();
        map.insert("a".to_string(), (now, json!({"status": "pending"})));
        map.insert("b".to_string(), (now, json!({"status": "done"})));
        prune_jobs(&mut map, now);
        assert_eq!(map.len(), 2);
    }

    fn submission() -> railgun_helper::exit::ExitSubmission {
        railgun_helper::exit::ExitSubmission {
            user_op_hash: "0x1c3fa5b0e2d47c8916aa0b3d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081"
                .to_string(),
            sender: "0x4b39f7b0624b9db86ad293686bc38b903142dbbc".to_string(),
            // 1 ETH: past 2^53, so a JSON number here would already be inexact.
            delivered_wei: 1_000_000_000_000_000_000,
            exit_index: 3,
        }
    }

    #[test]
    fn submitted_and_done_share_one_schema_with_hex_wei_amounts() {
        // Asserted as whole-document equality, not field probes, because this IS the wire
        // contract Task 8's decoder is written against. Two things are pinned:
        //   1. `deliveredWei` is a 0x-hex STRING, never a JSON number (1e18 > 2^53).
        //   2. `submitted` and `done` differ ONLY in `status` and `included` — same keys, same
        //      types — so one Decodable with a non-optional `included` handles both.
        let sub = submission();

        let submitted = exit_status(&sub.pending_outcome());
        assert_eq!(
            submitted,
            json!({
                "status": "submitted",
                "deliveredAsset": "ETH",
                "result": {
                    "userOpHash": "0x1c3fa5b0e2d47c8916aa0b3d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081",
                    "sender": "0x4b39f7b0624b9db86ad293686bc38b903142dbbc",
                    "deliveredWei": "0xde0b6b3a7640000",
                    "exitIndex": 3,
                    "included": false,
                },
            })
        );

        let done = exit_status(&ExitOutcome {
            included: true,
            ..sub.pending_outcome()
        });
        assert_eq!(
            done,
            json!({
                "status": "done",
                "deliveredAsset": "ETH",
                "result": {
                    "userOpHash": "0x1c3fa5b0e2d47c8916aa0b3d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081",
                    "sender": "0x4b39f7b0624b9db86ad293686bc38b903142dbbc",
                    "deliveredWei": "0xde0b6b3a7640000",
                    "exitIndex": 3,
                    "included": true,
                },
            })
        );

        // Same key set in both, so neither is a superset of the other.
        let keys = |v: &Value| {
            let mut k: Vec<String> = v["result"]
                .as_object()
                .unwrap()
                .keys()
                .cloned()
                .collect::<Vec<_>>();
            k.sort();
            k
        };
        assert_eq!(keys(&submitted), keys(&done));

        // And the amount must survive the round trip back through the request parser.
        assert_eq!(
            parse_amount(&submitted["result"]["deliveredWei"]).unwrap(),
            sub.delivered_wei
        );
    }

    #[test]
    fn error_status_carries_the_stable_code() {
        // The app switches card state on `code`; the sentence is for humans only.
        let s = error_status(&exit::ExitError::PaymasterNotConfigured);
        assert_eq!(s["status"], "error");
        assert_eq!(s["code"], "paymasterNotConfigured");
        assert!(s["error"].as_str().unwrap().contains("privacy paymaster"));
        // Absent for every code whose meaning is unambiguous, so the app never branches on a
        // value it cannot interpret.
        assert!(s.get("submitted").is_none(), "unexpected submitted: {s}");
    }

    #[test]
    fn bundler_rejection_status_reports_whether_anything_was_submitted() {
        // The branch this whole field exists for. Same code both times — the app tells the two
        // apart on `submitted`, and reverting the card on the `true` case would tell a user whose
        // exit is still executing that it reverted.
        let pre_send = error_status(&exit::ExitError::BundlerRejected {
            message: "rejected during gas estimation: AA33 reverted".into(),
            exit_index: 4,
            sender: "0xbeef".into(),
            submitted: false,
        });
        assert_eq!(pre_send["code"], "bundlerRejected");
        assert_eq!(pre_send["submitted"], json!(false));

        let lost_response = error_status(&exit::ExitError::BundlerRejected {
            message: "connection reset".into(),
            exit_index: 4,
            sender: "0xbeef".into(),
            submitted: true,
        });
        assert_eq!(lost_response["code"], "bundlerRejected");
        assert_eq!(lost_response["submitted"], json!(true));
        // The recovery pointer must survive into the payload the app renders.
        let msg = lost_response["error"].as_str().unwrap();
        assert!(msg.contains("index 4") && msg.contains("0xbeef"), "{msg}");
    }
}
