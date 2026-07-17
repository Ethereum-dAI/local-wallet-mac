//! `railgun-broadcaster`: the per-wallet **local broadcaster**. Owns its own EOA and
//! submits/relays the proved unshield tx on-chain over a bearer-authenticated Unix-socket
//! JSON-RPC API. Never delegates to a third-party/Waku broadcaster.
//!
//! Secret (the EOA key) arrives on **fd 5** (`{"keyHex":"0x.."}`) when spawned by
//! `railgun-helper`; env `RAILGUN_BROADCASTER_KEY` is a standalone/dev fallback only.
//! Non-secret config (rpc url, socket, token) is via env.

use std::collections::HashMap;
use std::sync::Arc;

use alloy::primitives::Address;
use eip_1193_provider::tx_data::TxData;
use railgun::chain_config::ChainConfig;
use railgun_helper::broadcaster::LocalBroadcaster;
use railgun_helper::rpc::{serve_rpc, Handlers};
use railgun_helper::rpc_handler;
use railgun_helper::secret::BroadcasterFd5;
use railgun_helper::spawn::read_fd5;
use serde::Deserialize;
use serde_json::{json, Value};

fn env(key: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| panic!("missing env {key}"))
}

fn load_key() -> String {
    match read_fd5() {
        Some(bytes) => {
            let s: BroadcasterFd5 =
                serde_json::from_slice(&bytes).expect("invalid fd-5 broadcaster secret");
            s.key_hex
        }
        None => std::env::var("RAILGUN_BROADCASTER_KEY")
            .expect("no fd-5 secret and no RAILGUN_BROADCASTER_KEY"),
    }
}

#[derive(Deserialize)]
struct NativeRelayParams {
    tx: TxData,
    recipient: Address,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let rpc_url = std::env::var("RAILGUN_RPC_URL")
        .or_else(|_| std::env::var("LOCAL_WALLET_PRIVACY_RPC_URL"))
        .expect("missing RAILGUN_RPC_URL / LOCAL_WALLET_PRIVACY_RPC_URL");
    let socket = env("RAILGUN_BROADCASTER_SOCKET");
    let token = env("RAILGUN_BROADCASTER_TOKEN");
    let key = load_key();

    let chain = ChainConfig::sepolia();
    let allowed_targets = vec![chain.relay_adapt_contract, chain.railgun_smart_wallet];
    let broadcaster = Arc::new(
        LocalBroadcaster::new(&rpc_url, &key, allowed_targets, chain.wrapped_base_token)
            .await
            .expect("build broadcaster"),
    );
    let addr = broadcaster.address();

    let mut handlers: Handlers = HashMap::new();
    {
        let b = broadcaster.clone();
        handlers.insert(
            "address".to_string(),
            rpc_handler!(move |_p: Value| {
                let b = b.clone();
                async move { Ok(json!({ "address": format!("{:?}", b.address()) })) }
            }),
        );
    }
    {
        let b = broadcaster.clone();
        handlers.insert(
            "relay".to_string(),
            rpc_handler!(move |p: Value| {
                let b = b.clone();
                async move {
                    let tx: TxData =
                        serde_json::from_value(p).map_err(|e| format!("bad tx payload: {e}"))?;
                    Ok(serde_json::to_value(b.relay(tx).await?).unwrap())
                }
            }),
        );
    }
    {
        let b = broadcaster.clone();
        handlers.insert(
            "relayUnshieldNative".to_string(),
            rpc_handler!(move |p: Value| {
                let b = b.clone();
                async move {
                    let params: NativeRelayParams =
                        serde_json::from_value(p).map_err(|e| format!("bad params: {e}"))?;
                    let receipt = b.relay_unshield_native(params.tx, params.recipient).await?;
                    Ok(serde_json::to_value(receipt).unwrap())
                }
            }),
        );
    }

    // Orphan backstop: if our parent (railgun-helper) dies, we're reparented to pid 1 —
    // exit so we don't linger holding the funded EOA.
    tokio::spawn(async {
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            if unsafe { libc::getppid() } == 1 {
                std::process::exit(0);
            }
        }
    });

    println!(
        "{}",
        json!({"ready": true, "address": format!("{addr:?}"), "socket": socket})
    );
    tracing::info!("railgun-broadcaster (EOA {addr:?}) serving on {socket}");
    serve_rpc(&socket, token, handlers).await.expect("serve");
}
