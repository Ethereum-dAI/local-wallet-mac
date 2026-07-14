//! `railgun-broadcaster`: the per-wallet **local broadcaster**. Owns its own EOA and
//! submits the proved unshield tx on-chain over a bearer-authenticated Unix-socket
//! JSON-RPC API (`relay` / `address`). Never delegates to a third-party/Waku broadcaster.
//!
//! Config from env (testnet). See `broadcaster.rs` for the anonymity-set-of-one tradeoff.

use std::collections::HashMap;
use std::sync::Arc;

use eip_1193_provider::tx_data::TxData;
use railgun_helper::broadcaster::LocalBroadcaster;
use railgun_helper::rpc::{serve_rpc, Handlers};
use railgun_helper::rpc_handler;
use serde_json::{json, Value};

fn env(key: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| panic!("missing env {key}"))
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let rpc_url = std::env::var("RAILGUN_RPC_URL")
        .or_else(|_| std::env::var("LOCAL_WALLET_PRIVACY_RPC_URL"))
        .expect("missing RAILGUN_RPC_URL / LOCAL_WALLET_PRIVACY_RPC_URL");
    let key = env("RAILGUN_BROADCASTER_KEY");
    let socket = env("RAILGUN_BROADCASTER_SOCKET");
    let token = env("RAILGUN_BROADCASTER_TOKEN");

    let broadcaster = Arc::new(
        LocalBroadcaster::new(&rpc_url, &key)
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
                    let receipt = b.relay(tx).await?;
                    Ok(serde_json::to_value(receipt).unwrap())
                }
            }),
        );
    }

    println!(
        "{}",
        json!({"ready": true, "address": format!("{addr:?}"), "socket": socket})
    );
    tracing::info!("railgun-broadcaster (EOA {addr:?}) serving on {socket}");
    serve_rpc(&socket, token, handlers).await.expect("serve");
}
