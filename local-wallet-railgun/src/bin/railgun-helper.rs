//! `railgun-helper` sidecar: the wallet's single privacy entry point. Serves
//! `balance` / `prepareShield` / `unshield` / `unshieldStatus` over a bearer-authenticated
//! Unix-socket JSON-RPC API, wrapping the RAILGUN Rust SDK.
//!
//! It SPAWNS and owns the `railgun-broadcaster` child process (secret delivered over fd 5)
//! and proxies unshields through it, so the app only ever talks to this one socket.
//!
//! - `balance` → `{valid,pending,total}` (0x hex wei).
//! - `prepareShield {amountWei}` → `[{to,data,value}]` for the OWNER to self-submit.
//! - `unshield {amountWei,to}` → `{jobId}` immediately; Groth16 proving + the broadcaster
//!   relay run in the background (proving exceeds any sane RPC timeout).
//! - `unshieldStatus {jobId}` → `{status: pending|done|error, result?|error?}`.
//!
//! The secret (RAILGUN entropy) arrives on **fd 5** (`HelperFd5`); env is a standalone/dev
//! fallback only. The broadcaster EOA key is derived from that same entropy root, never
//! carried separately. Non-secret config is via env.

use std::collections::HashMap;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use alloy::primitives::Address;
use alloy::providers::Provider;
use railgun::chain_config::ChainConfig;
use railgun_helper::pool::RailgunHelper;
use railgun_helper::provider::connect_provider;
use railgun_helper::rpc::{self, serve_rpc, Handlers};
use railgun_helper::secret::HelperFd5;
use railgun_helper::spawn::{read_fd5, spawn_child_with_fd5, ChildGuard};
use railgun_helper::{keys, rpc_handler};
use serde_json::{json, Value};
use tokio::sync::Mutex;

fn env(key: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| panic!("missing env {key}"))
}

/// How long a finished (or abandoned-pending) unshield job lingers before the TTL sweep
/// drops it. Far longer than proving (tens of seconds) + the client's poll deadline, so it
/// never evicts a job a caller still cares about — it only bounds the map against jobs that
/// are never polled to a terminal read.
const JOB_TTL: Duration = Duration::from_secs(600);

/// Drop job entries whose last update is older than `JOB_TTL`. Cheap linear sweep — the map
/// holds at most a handful of in-flight jobs for this single-user sidecar.
fn prune_jobs(map: &mut HashMap<String, (Instant, Value)>, now: Instant) {
    map.retain(|_, (updated, _)| now.duration_since(*updated) < JOB_TTL);
}

fn parse_amount(v: &Value) -> Result<u128, String> {
    match v {
        Value::String(s) => s
            .parse::<u128>()
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

async fn wait_for_socket(path: &str, secs: u64) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(secs);
    loop {
        if tokio::net::UnixStream::connect(path).await.is_ok() {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!("broadcaster socket {path} not ready after {secs}s"));
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
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
    let bc_bin = env("RAILGUN_BROADCASTER_BIN");
    let bc_socket = env("RAILGUN_BROADCASTER_SOCKET");
    let bc_token = env("RAILGUN_BROADCASTER_TOKEN");
    let entropy = load_secrets();
    // Derive the broadcaster EOA key from the same root (m/44'/60'/0'/0/0).
    let bc_key = keys::derive_broadcaster_key(&entropy).expect("derive broadcaster key");

    let chain = ChainConfig::sepolia();

    // 1) Spawn the local broadcaster as our child, delivering its EOA key over fd 5.
    let mut cmd = Command::new(&bc_bin);
    cmd.env("RAILGUN_RPC_URL", &rpc_url)
        .env("RAILGUN_BROADCASTER_SOCKET", &bc_socket)
        .env("RAILGUN_BROADCASTER_TOKEN", &bc_token)
        .env_remove("RAILGUN_BROADCASTER_KEY"); // key travels via fd-5, not env
    let bc_secret = json!({ "keyHex": bc_key }).to_string();
    let _bc_guard = ChildGuard(
        spawn_child_with_fd5(cmd, bc_secret.as_bytes()).expect("spawn railgun-broadcaster"),
    );
    wait_for_socket(&bc_socket, 30)
        .await
        .expect("broadcaster not ready");
    let bc_addr_v = rpc::call(&bc_socket, &bc_token, "address", json!(null))
        .await
        .expect("broadcaster address");
    let broadcaster_addr: Address = bc_addr_v["address"]
        .as_str()
        .expect("address")
        .parse()
        .expect("parse broadcaster address");
    tracing::info!("owns broadcaster {broadcaster_addr:?} on {bc_socket}");

    // 2) Build the RAILGUN provider (read-only; POI off).
    let signer = keys::derive_railgun_signer(&entropy, chain.id).expect("derive signer");
    let provider = connect_provider(&rpc_url, None)
        .await
        .expect("connect provider");
    // Keep a provider handle for reading the broadcaster EOA's gas balance (broadcasterStatus).
    let balance_provider = provider.clone();
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
        // broadcasterStatus: the local broadcaster's EOA + its gas balance, so the app can
        // show it (like the bundler) and prompt to top it up when it can't pay unshield gas.
        let bp = balance_provider.clone();
        handlers.insert(
            "broadcasterStatus".to_string(),
            rpc_handler!(move |_p: Value| {
                let bp = bp.clone();
                async move {
                    let bal = bp
                        .get_balance(broadcaster_addr)
                        .await
                        .map_err(|e| format!("broadcaster balance: {e}"))?;
                    Ok(json!({
                        "address": format!("{broadcaster_addr:?}"),
                        "balanceWei": format!("0x{bal:x}"),
                    }))
                }
            }),
        );
    }

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
        // unshield: kick off proving + relay in the background, return a jobId now.
        let h = helper.clone();
        let jobs = jobs.clone();
        let seq = job_seq.clone();
        let bc_socket = bc_socket.clone();
        let bc_token = bc_token.clone();
        handlers.insert(
            "unshield".to_string(),
            rpc_handler!(move |p: Value| {
                let (h, jobs, seq) = (h.clone(), jobs.clone(), seq.clone());
                let (bc_socket, bc_token) = (bc_socket.clone(), bc_token.clone());
                async move {
                    let amount = parse_amount(p.get("amountWei").unwrap_or(&Value::Null))?;
                    let recipient = parse_addr(p.get("to").unwrap_or(&Value::Null))?;
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
                        let result: Result<Value, String> = async {
                            // Unshield note recipient = the broadcaster (it will unwrap+forward).
                            let proved = h
                                .lock()
                                .await
                                .prepare_unshield(broadcaster_addr, amount)
                                .await?;
                            let params = json!({
                                "tx": serde_json::to_value(proved).unwrap(),
                                "recipient": format!("{recipient:?}"),
                            });
                            rpc::call(&bc_socket, &bc_token, "relayUnshieldNative", params).await
                        }
                        .await;
                        let status = match result {
                            Ok(receipt) => json!({"status":"done","result":receipt}),
                            Err(e) => json!({"status":"error","error":e}),
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

    println!(
        "{}",
        json!({"ready": true, "socket": socket, "broadcaster": format!("{broadcaster_addr:?}")})
    );
    tracing::info!("railgun-helper serving on {socket}");

    // current_thread runtime + LocalSet so the non-Send proving tasks can spawn_local.
    let local = tokio::task::LocalSet::new();
    // Orphan backstop: exit if our parent (the app) dies, so we don't linger holding the
    // shielded seed. Our broadcaster child has the same backstop, so it follows us out.
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
    fn prune_is_a_noop_when_nothing_is_expired() {
        let mut map: HashMap<String, (Instant, Value)> = HashMap::new();
        let now = Instant::now();
        map.insert("a".to_string(), (now, json!({"status": "pending"})));
        map.insert("b".to_string(), (now, json!({"status": "done"})));
        prune_jobs(&mut map, now);
        assert_eq!(map.len(), 2);
    }
}
