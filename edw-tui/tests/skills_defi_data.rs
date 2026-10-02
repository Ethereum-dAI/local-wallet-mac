//! The shipped `defi-data` skill, run in Docker against recorded API responses (offline).
//! Skips when Docker is not running. `-- --ignored` adds one live run against the real APIs.

use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use edw_tui::skills::{
    host::{Host, HostConfig, SharedCache},
    manifest::{self, Skill},
    sandbox::{self, Output, Runner},
};
use serde_json::{Value, json};

const POOLS: &str = "https://yields.llama.fi/pools";
const WETH_USDC: &str = "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640";

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).to_owned()
}

fn skill() -> Skill {
    manifest::load(&root().join("skills/defi-data")).unwrap()
}

fn fixture(name: &str) -> String {
    fs::read_to_string(root().join("tests/fixtures/defi").join(name)).unwrap()
}

fn fixtures() -> BTreeMap<String, String> {
    BTreeMap::from([
        (format!("GET {POOLS}"), fixture("pools_trimmed.json")),
        (
            "GET https://api.coingecko.com/api/v3/asset_platforms".into(),
            fixture("asset_platforms.json"),
        ),
        (
            "GET https://api.llama.fi/v2/chains".into(),
            fixture("llama_chains.json"),
        ),
        (
            "GET https://yields.llama.fi/chart/fc9f488e-8183-416f-a61e-4e5c571d4395".into(),
            fixture("chart.json"),
        ),
        (
            format!("GET https://api.geckoterminal.com/api/v2/networks/eth/pools/{WETH_USDC}"),
            fixture("gecko_pool.json"),
        ),
        (
            format!("GET https://api.dexscreener.com/latest/dex/pairs/ethereum/{WETH_USDC}"),
            fixture("dexscreener_pair.json"),
        ),
    ])
}

async fn call(
    tool: &str,
    args: Value,
    fixtures: Option<BTreeMap<String, String>>,
) -> Result<Value, String> {
    call_on(1, tool, args, fixtures).await
}

/// As [`call`], with the wallet on `chain_id`.
async fn call_on(
    chain_id: u64,
    tool: &str,
    args: Value,
    fixtures: Option<BTreeMap<String, String>>,
) -> Result<Value, String> {
    let skill = skill();
    let def = skill
        .read_tool(tool)
        .unwrap_or_else(|| panic!("no read tool {tool}"));
    let host = Host::new(
        HostConfig {
            skill: skill.name.clone(),
            hosts: skill.manifest.hosts.clone(),
            cache: def.cache.clone(),
            rpc: None,
            fixtures: fixtures.map(Arc::new),
            log: Arc::new(|_| {}),
        },
        SharedCache::default(),
    );
    let runner = Runner {
        timeout: Duration::from_secs(60),
        ..Runner::from_env()
    };
    let invoke = sandbox::invoke_message(tool, &args, json!({"chain_id": chain_id}));
    match runner.run(&skill, &def.run, invoke, &host).await? {
        Output::Result(value) => Ok(value),
        Output::Plan(plan) => panic!("a read tool returned a plan: {plan}"),
    }
}

async fn docker() -> bool {
    let ok = sandbox::docker_available().await;
    if !ok {
        eprintln!("skipping: Docker is not running");
    }
    ok
}

fn symbols(value: &Value) -> Vec<String> {
    value["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| {
            format!(
                "{} {}",
                r["symbol"].as_str().unwrap(),
                r["pool_meta"].as_str().unwrap_or("")
            )
        })
        .collect()
}

#[test]
fn the_skill_declares_only_its_hosts_and_no_contracts() {
    let skill = skill();
    assert_eq!(
        skill.manifest.hosts,
        [
            "yields.llama.fi",
            "api.llama.fi",
            "api.coingecko.com",
            "api.geckoterminal.com",
            "api.dexscreener.com"
        ]
    );
    assert!(skill.manifest.contracts.is_empty() && skill.manifest.actions.is_empty());
    assert_eq!(
        skill.tool_names(),
        ["top_yields", "yield_history", "dex_pool"]
    );
}

#[tokio::test]
async fn top_yields_filters_sorts_and_limits() {
    if !docker().await {
        return;
    }
    let value = call(
        "top_yields",
        json!({"chain": "ethereum", "project": "uniswap-v3", "symbol": "WETH", "limit": 3}),
        Some(fixtures()),
    )
    .await
    .unwrap();
    assert_eq!(
        symbols(&value),
        ["WETH-USDT 0.3%", "USDC-WETH 0.3%", "USDC-WETH 0.05%"],
        "{value}"
    );
    assert_eq!(value["source"], "DefiLlama yields (yields.llama.fi)");
    let row = &value["rows"][0];
    for key in [
        "project",
        "tvl_usd",
        "apy_base",
        "apy_mean_30d",
        "volume_usd_7d",
        "il_risk",
        "pool_id",
    ] {
        assert!(row.get(key).is_some(), "missing {key}: {row}");
    }
    assert_eq!(row["pool_id"], "fc9f488e-8183-416f-a61e-4e5c571d4395");
}

#[tokio::test]
async fn top_yields_knows_lending_and_staking_and_respects_tvl() {
    if !docker().await {
        return;
    }
    let lend = call(
        "top_yields",
        json!({"chain": "Ethereum", "symbol": "USDC", "kind": "lend"}),
        Some(fixtures()),
    )
    .await
    .unwrap();
    let projects: Vec<&str> = lend["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["project"].as_str().unwrap())
        .collect();
    assert_eq!(projects, ["aave-v3"], "{lend}");

    let stake = call(
        "top_yields",
        json!({"chain": "Ethereum", "kind": "stake"}),
        Some(fixtures()),
    )
    .await
    .unwrap();
    assert_eq!(stake["rows"][0]["project"], "lido", "{stake}");

    // Small pools are hidden unless asked for, and at most 10 rows ever come back.
    let all = call(
        "top_yields",
        json!({"chain": "Ethereum", "project": "uniswap-v3", "min_tvl_usd": 0, "limit": 50}),
        Some(fixtures()),
    )
    .await
    .unwrap();
    assert_eq!(all["rows"].as_array().unwrap().len(), 10, "{all}");
    let default = call(
        "top_yields",
        json!({"chain": "Ethereum", "project": "uniswap-v3", "limit": 10}),
        Some(fixtures()),
    )
    .await
    .unwrap();
    assert!(
        !symbols(&default)
            .iter()
            .any(|s| s.starts_with("YNG") || s.starts_with("STK"))
    );
}

#[tokio::test]
async fn yield_history_is_downsampled_and_ends_at_the_latest_point() {
    if !docker().await {
        return;
    }
    let value = call(
        "yield_history",
        json!({"pool_id": "fc9f488e-8183-416f-a61e-4e5c571d4395", "days": 90}),
        Some(fixtures()),
    )
    .await
    .unwrap();
    let points = value["points"].as_array().unwrap();
    assert!(points.len() <= 30 && points.len() >= 20, "{}", points.len());
    assert_eq!(points.last().unwrap()["date"], "2026-10-02");
    assert!(points.last().unwrap()["apy_base"].is_number());
}

#[tokio::test]
async fn dex_pool_reads_geckoterminal_and_falls_back_to_dexscreener() {
    if !docker().await {
        return;
    }
    let value = call(
        "dex_pool",
        json!({"chain": "Ethereum", "address": WETH_USDC}),
        Some(fixtures()),
    )
    .await
    .unwrap();
    assert_eq!(value["source"], "GeckoTerminal");
    assert_eq!(value["name"], "WETH / USDC 0.05%");
    assert!(value["liquidity_usd"].as_f64().unwrap() > 1e6, "{value}");

    let mut limited = fixtures();
    limited.insert(
        format!("GET https://api.geckoterminal.com/api/v2/networks/eth/pools/{WETH_USDC}"),
        "status:429\n{}".into(),
    );
    let value = call(
        "dex_pool",
        json!({"chain": "Ethereum", "address": WETH_USDC}),
        Some(limited),
    )
    .await
    .unwrap();
    assert_eq!(value["source"], "DexScreener");
    assert!(value["volume_usd_24h"].as_f64().unwrap() > 0.0, "{value}");

    let error = call(
        "dex_pool",
        json!({"chain": "Sepolia", "address": WETH_USDC}),
        Some(fixtures()),
    )
    .await
    .unwrap_err();
    assert!(error.contains("Sepolia"), "{error}");
}

#[tokio::test]
#[ignore = "calls DefiLlama over the network"]
async fn live_top_yields() {
    if !docker().await {
        return;
    }
    let value = call(
        "top_yields",
        json!({"chain": "Ethereum", "kind": "lend", "symbol": "USDC"}),
        None,
    )
    .await
    .unwrap();
    eprintln!("{value:#}");
    assert!(!value["rows"].as_array().unwrap().is_empty());
}

/// The model writes chains every way: names, "mainnet", ids, short names. All resolve through
/// CoinGecko's platform list and DefiLlama's chain list to the names DefiLlama's pools use.
#[tokio::test]
async fn chains_resolve_however_they_are_written() {
    if !docker().await {
        return;
    }
    let ethereum = call(
        "top_yields",
        json!({"chain": "Ethereum", "project": "uniswap-v3", "limit": 3}),
        Some(fixtures()),
    )
    .await
    .unwrap();
    assert!(
        !ethereum["rows"].as_array().unwrap().is_empty(),
        "{ethereum}"
    );
    for asked in ["Ethereum Mainnet", "mainnet", "1", "ETH", "ethereum"] {
        let value = call(
            "top_yields",
            json!({"chain": asked, "project": "uniswap-v3", "limit": 3}),
            Some(fixtures()),
        )
        .await
        .unwrap();
        assert_eq!(value["rows"], ethereum["rows"], "{asked}: {value}");
        assert_eq!(value["chain"]["name"], "Ethereum", "{asked}");
        assert_eq!(value["chain"]["chain_id"], 1, "{asked}");
    }
    let base = call(
        "top_yields",
        json!({"chain": "base mainnet"}),
        Some(fixtures()),
    )
    .await
    .unwrap();
    assert_eq!(base["chain"]["name"], "Base", "{base}");
    assert!(
        base["rows"]
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r["project"] == "aerodrome-slipstream"),
        "{base}"
    );
}

#[tokio::test]
async fn no_chain_means_the_wallets_chain_and_a_testnet_falls_back_to_ethereum() {
    if !docker().await {
        return;
    }
    let base = call_on(8453, "top_yields", json!({}), Some(fixtures()))
        .await
        .unwrap();
    assert_eq!(base["chain"]["name"], "Base", "{base}");
    let sepolia = call_on(
        11_155_111,
        "top_yields",
        json!({"kind": "lend"}),
        Some(fixtures()),
    )
    .await
    .unwrap();
    assert_eq!(sepolia["chain"]["name"], "Ethereum", "{sepolia}");
    assert!(
        sepolia["chain"]["note"]
            .as_str()
            .unwrap()
            .contains("testnet"),
        "{sepolia}"
    );
}

/// CoinGecko down or rate-limited: names still resolve through DefiLlama's own chain list.
#[tokio::test]
async fn chains_still_resolve_when_coingecko_is_unavailable() {
    if !docker().await {
        return;
    }
    let mut limited = fixtures();
    limited.insert(
        "GET https://api.coingecko.com/api/v3/asset_platforms".into(),
        "status:429\n{}".into(),
    );
    let value = call(
        "top_yields",
        json!({"chain": "Ethereum Mainnet", "project": "uniswap-v3"}),
        Some(limited),
    )
    .await
    .unwrap();
    assert_eq!(value["chain"]["name"], "Ethereum", "{value}");
    assert!(!value["rows"].as_array().unwrap().is_empty(), "{value}");
}

#[tokio::test]
async fn an_unknown_chain_suggests_the_closest_ones() {
    if !docker().await {
        return;
    }
    let error = call("top_yields", json!({"chain": "Etherium"}), Some(fixtures()))
        .await
        .unwrap_err();
    assert!(
        error.contains("Etherium") && error.contains("Ethereum"),
        "{error}"
    );
    let dex = call(
        "dex_pool",
        json!({"chain": "Ethereum Mainnet", "address": WETH_USDC}),
        Some(fixtures()),
    )
    .await
    .unwrap();
    assert_eq!(dex["source"], "GeckoTerminal", "{dex}");
}
