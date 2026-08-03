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
//! - `unshieldStatus {jobId}` → `{status: pending|submitted|done|error, result?, error?, code?}`.
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
use railgun_helper::pool::RailgunHelper;
use railgun_helper::provider::connect_provider;
use railgun_helper::rpc::{serve_rpc, Handlers};
use railgun_helper::secret::HelperFd5;
use railgun_helper::spawn::read_fd5;
use railgun_helper::{exit, fee, keys, rpc_handler};
use serde_json::{json, Value};
use tokio::sync::Mutex;

fn env(key: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| panic!("missing env {key}"))
}

/// How long a finished (or abandoned-pending) unshield job lingers before the TTL sweep
/// drops it. It only bounds the map against jobs that are never polled to a terminal read;
/// it must never evict a job that is still progressing.
///
/// Derived from [`exit::RECEIPT_POLL_BUDGET`] rather than hardcoded, because a `submitted`
/// job's timestamp is only refreshed when receipt polling finishes. At an equal TTL, an op
/// that takes the full budget to land would be swept out from under the app mid-poll —
/// `unknown jobId` on an exit that is fine — and then RESURRECTED when polling finally wrote
/// its result. The margin also covers `wait_for_receipt`'s own 60s timeout overshooting the
/// budget's top-of-loop check.
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
async fn spendable_ceiling(helper: &mut RailgunHelper) -> Result<Ceiling, String> {
    let split = helper.balance_split().await?;
    // POI is intentionally OFF (see `pool`), so `total == valid`: every note is spendable now
    // and `total` is exactly what the app's balance card shows. If POI is ever enabled this
    // must switch to `valid`, or the ceiling would promise notes that cannot yet be spent.
    let balance = u128::from_str_radix(split.total.trim_start_matches("0x"), 16)
        .map_err(|e| format!("parse balance {}: {e}", split.total))?;
    let url = exit::resolve_bundler_url(helper.chain_id());
    let max_fee = exit::fetch_max_fee_per_gas(&url).await?;
    let reserve = fee::gas_reserve_wei(&fee::RAILGUN_UNSHIELD_GAS_UNITS, max_fee);
    Ok(Ceiling {
        max: fee::max_unshieldable(balance, helper.unshield_fee_bps(), reserve),
        reserve,
    })
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
    let state_dir =
        std::path::PathBuf::from(std::env::var("RAILGUN_STATE_DIR").unwrap_or_else(|_| {
            std::path::Path::new(&socket)
                .parent()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_else(|| ".".to_string())
        }));
    // The RAILGUN account seed AND every exit sender come from this one root. Never logged.
    let entropy = load_secrets();

    let chain = ChainConfig::sepolia();

    // Build the RAILGUN provider (read-only: the exit's UserOperation is signed by its
    // ephemeral sender and broadcast by a public bundler, so nothing here submits a tx).
    let signer = keys::derive_railgun_signer(&entropy, chain.id).expect("derive signer");
    let provider = connect_provider(&rpc_url, None)
        .await
        .expect("connect provider");
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
                    let amount = parse_amount(p.get("amountWei").unwrap_or(&Value::Null))?;
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
                    let amount = parse_amount(p.get("amountWei").unwrap_or(&Value::Null))?;
                    let recipient = parse_addr(p.get("to").unwrap_or(&Value::Null))?;

                    // Fail fast: nobody should wait ~13s (or ~28s if the fee loop struggles)
                    // for a proof that cannot fit. Same ceiling `maxUnshieldable` reports.
                    {
                        let c = spendable_ceiling(&mut *h.lock().await).await?;
                        if amount > c.max.max_value {
                            return Err(format!(
                                "insufficientShieldedBalance: {amount} wei exceeds the \
                                 spendable maximum {} wei (gas fee headroom {} wei must stay \
                                 in the pool)",
                                c.max.max_value, c.reserve
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
                                jobs.lock().await.insert(
                                    jid,
                                    (
                                        Instant::now(),
                                        json!({
                                            "status": "error",
                                            "code": e.code(),
                                            "error": e.to_string(),
                                        }),
                                    ),
                                );
                                return;
                            }
                        };

                        // Publish `submitted` the moment a hash exists, so the app shows a real
                        // op hash instead of a spinner and stops counting inclusion time
                        // against its proving deadline. NOT terminal — the job stays in the map.
                        jobs.lock().await.insert(
                            jid.clone(),
                            (
                                Instant::now(),
                                json!({
                                    "status": "submitted",
                                    "deliveredAsset": "ETH",
                                    "result": serde_json::to_value(&sub).unwrap(),
                                }),
                            ),
                        );

                        // Phase 2: poll for the receipt WITHOUT the helper lock, so `balance`
                        // and `maxUnshieldable` keep answering during inclusion.
                        let url = exit::resolve_bundler_url(chain_id);
                        let status = match exit::await_exit(&url, &sub).await {
                            Ok(outcome) => json!({
                                "status": if outcome.included { "done" } else { "submitted" },
                                "deliveredAsset": "ETH",
                                "result": serde_json::to_value(&outcome).unwrap(),
                            }),
                            Err(e) => json!({
                                "status": "error",
                                "code": e.code(),
                                "error": e.to_string(),
                            }),
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
                        .ok_or_else(|| "missing jobId".to_string())?;
                    let mut map = jobs.lock().await;
                    prune_jobs(&mut map, Instant::now());
                    let status = map
                        .get(id)
                        .map(|(_, v)| v.clone())
                        .ok_or_else(|| format!("unknown jobId: {id}"))?;
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
    fn job_ttl_outlives_the_receipt_poll_budget() {
        // A `submitted` job's timestamp is not refreshed while phase 2 polls, so an equal (or
        // shorter) TTL would sweep a still-progressing exit and then see it resurrected.
        assert!(
            JOB_TTL > exit::RECEIPT_POLL_BUDGET,
            "TTL {JOB_TTL:?} must exceed the poll budget {:?}",
            exit::RECEIPT_POLL_BUDGET
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
}
