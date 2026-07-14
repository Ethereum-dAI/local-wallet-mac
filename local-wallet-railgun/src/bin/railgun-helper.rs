//! `railgun-helper` sidecar: serves `balance` / `prepareShield` / `prepareUnshield` over
//! a bearer-authenticated Unix-socket JSON-RPC API, wrapping the RAILGUN Rust SDK.
//!
//! Config comes from env (fork/standalone path used by the e2e); the fd-5 app-spawn
//! contract is a later step (see design §1 "out of scope"). All env values are testnet.

use std::collections::HashMap;
use std::sync::Arc;

use alloy::primitives::Address;
use railgun::chain_config::ChainConfig;
use railgun_helper::pool::RailgunHelper;
use railgun_helper::provider::connect_provider;
use railgun_helper::rpc::{serve_rpc, Handlers};
use railgun_helper::{keys, rpc_handler};
use serde_json::{json, Value};
use tokio::sync::Mutex;

fn env(key: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| panic!("missing env {key}"))
}

/// Parse a wei amount given as a JSON decimal string or number.
fn parse_amount(v: &Value) -> Result<u128, String> {
    match v {
        Value::String(s) => s.parse::<u128>().map_err(|e| format!("bad amount {s}: {e}")),
        Value::Number(n) => n
            .as_u64()
            .map(u128::from)
            .ok_or_else(|| "amount not a u64".to_string()),
        _ => Err("amount must be a string or number".to_string()),
    }
}

fn parse_addr(v: &Value) -> Result<Address, String> {
    v.as_str()
        .ok_or_else(|| "address must be a string".to_string())?
        .parse::<Address>()
        .map_err(|e| format!("bad address: {e}"))
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let rpc_url = std::env::var("RAILGUN_RPC_URL")
        .or_else(|_| std::env::var("LOCAL_WALLET_PRIVACY_RPC_URL"))
        .expect("missing RAILGUN_RPC_URL / LOCAL_WALLET_PRIVACY_RPC_URL");
    let entropy = env("RAILGUN_ENTROPY_HEX");
    let fork_block: u64 = env("RAILGUN_FORK_BLOCK").parse().expect("RAILGUN_FORK_BLOCK");
    let socket = env("RAILGUN_SOCKET");
    let token = env("RAILGUN_TOKEN");

    let chain = ChainConfig::sepolia();
    let signer = keys::derive_railgun_signer(&entropy, chain.id).expect("derive signer");
    let provider = connect_provider(&rpc_url, None).await.expect("connect provider");
    let helper = RailgunHelper::new(chain, provider, fork_block, signer)
        .await
        .expect("build railgun helper");
    // Non-Send (RAILGUN provider); the sidecar is single-threaded (see rpc.rs).
    #[allow(clippy::arc_with_non_send_sync)]
    let helper = Arc::new(Mutex::new(helper));

    let mut handlers: Handlers = HashMap::new();

    {
        let h = helper.clone();
        handlers.insert(
            "balance".to_string(),
            rpc_handler!(move |_p: Value| {
                let h = h.clone();
                async move {
                    let mut g = h.lock().await;
                    let split = g.balance_split().await?;
                    Ok(serde_json::to_value(split).unwrap())
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
                    let mut g = h.lock().await;
                    let txs = g.prepare_shield_native(amount).await?;
                    Ok(serde_json::to_value(txs).unwrap())
                }
            }),
        );
    }
    {
        let h = helper.clone();
        handlers.insert(
            "prepareUnshield".to_string(),
            rpc_handler!(move |p: Value| {
                let h = h.clone();
                async move {
                    let amount = parse_amount(p.get("amountWei").unwrap_or(&Value::Null))?;
                    let to = parse_addr(p.get("to").unwrap_or(&Value::Null))?;
                    let mut g = h.lock().await;
                    let tx = g.prepare_unshield(to, amount).await?;
                    Ok(serde_json::to_value(tx).unwrap())
                }
            }),
        );
    }

    // Ready signal for the standalone/e2e path (fd-3 token/socket write is the app path).
    println!("{}", json!({"ready": true, "socket": socket}));
    tracing::info!("railgun-helper serving on {socket}");
    serve_rpc(&socket, token, handlers).await.expect("serve");
}
