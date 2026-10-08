//! The shipped `safe-multisig` skill, run in Docker against recorded Safe Transaction Service
//! responses for a real mainnet Safe (offline). Skips when Docker is not running.

use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use alloy_dyn_abi::DynSolValue;
use alloy_primitives::Address;
use edw_tui::skills::{
    host::{Host, HostConfig, SharedCache},
    manifest::{self, Skill},
    sandbox::{self, Output, Runner},
};
use serde_json::{Value, json};

const SAFE: &str = "0xA03be496e67Ec29bC62F01a428683D7F9c204930";
const COW: &str = "0xDEf1CA1fb7FBcDC777520aa7f396b4E015F497aB";
const BASE: &str = "https://api.safe.global/tx-service/eth/api/v1";

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).to_owned()
}

fn skill() -> Skill {
    manifest::load(&root().join("skills/safe-multisig")).unwrap()
}

fn fixture(name: &str) -> String {
    fs::read_to_string(root().join("tests/fixtures/safe").join(name)).unwrap()
}

fn fixtures() -> BTreeMap<String, String> {
    // The service sends `nonce` as a string.
    let nonce = serde_json::from_str::<Value>(&fixture("info.json")).unwrap()["nonce"]
        .as_str()
        .unwrap()
        .to_owned();
    BTreeMap::from([
        (format!("GET {BASE}/safes/{SAFE}/"), fixture("info.json")),
        (
            format!("GET {BASE}/tokens/{COW}/"),
            json!({"symbol": "COW", "decimals": 18}).to_string(),
        ),
        (
            format!(
                "GET {BASE}/safes/{SAFE}/multisig-transactions/?executed=false&nonce__gte={nonce}&ordering=nonce&limit=5"
            ),
            fixture("queue.json"),
        ),
        (
            format!(
                "GET {BASE}/safes/{SAFE}/multisig-transactions/?executed=true&ordering=-executionDate&limit=5"
            ),
            fixture("activity.json"),
        ),
    ])
}

async fn call(
    tool: &str,
    args: Value,
    context: Value,
    mut extra: BTreeMap<String, String>,
) -> Result<Value, String> {
    let skill = skill();
    let def = skill.read_tool(tool).unwrap();
    extra.extend(fixtures());
    let host = Host::new(
        HostConfig {
            skill: skill.name.clone(),
            hosts: skill.manifest.hosts.clone(),
            cache: def.cache.clone(),
            rpc: None,
            fixtures: Some(Arc::new(extra)),
            log: Arc::new(|_| {}),
        },
        SharedCache::default(),
    );
    let runner = Runner {
        timeout: Duration::from_secs(60),
        ..Runner::from_env()
    };
    let invoke = sandbox::invoke_message(tool, &args, context);
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

fn word(value: u64) -> String {
    format!("{value:064x}")
}

/// The raw return of `getOwners()` for these owners.
fn owners_return(owners: &[String]) -> String {
    let array = DynSolValue::Array(
        owners
            .iter()
            .map(|o| DynSolValue::Address(o.parse::<Address>().unwrap()))
            .collect(),
    );
    format!(
        "0x{}",
        alloy_primitives::hex::encode(DynSolValue::Tuple(vec![array]).abi_encode_params())
    )
}

fn chain_reads(owners: &[String], threshold: u64) -> BTreeMap<String, String> {
    let key = |data: &str| {
        format!(
            r#"rpc eth_call [{{"data":"{data}","to":"{}"}},"latest"]"#,
            SAFE.to_lowercase()
        )
    };
    BTreeMap::from([
        (key("0xa0e67e2b"), format!("\"{}\"", owners_return(owners))),
        (key("0xe75235b8"), format!("\"0x{}\"", word(threshold))),
    ])
}

fn owners() -> Vec<String> {
    serde_json::from_str::<Value>(&fixture("info.json")).unwrap()["owners"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| o.as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn the_skill_only_reads_and_declares_one_host() {
    let skill = skill();
    assert_eq!(skill.manifest.hosts, ["api.safe.global"]);
    assert!(skill.manifest.contracts.is_empty() && skill.manifest.actions.is_empty());
    assert_eq!(
        skill.tool_names(),
        ["safe_info", "safe_queue", "safe_activity"]
    );
}

#[tokio::test]
async fn safe_info_reports_the_signer_rule_and_flags_modules() {
    if !docker().await {
        return;
    }
    let out = call(
        "safe_info",
        json!({"address": SAFE.to_lowercase(), "chain": "ethereum"}),
        json!({"chain_id": 11155111}),
        BTreeMap::new(),
    )
    .await
    .unwrap();
    // A lowercase address works: the script checksums it for the service.
    assert_eq!(out["safe"], SAFE);
    assert_eq!(out["rule"], "4 of 11 owners must sign");
    assert_eq!(out["version"], "1.3.0");
    assert!(
        out["warning"].as_str().unwrap().contains("Modules"),
        "{out}"
    );
    assert!(
        out["onchain_check"]
            .as_str()
            .unwrap()
            .starts_with("not checked: the wallet is not on Ethereum"),
        "{out}"
    );
}

#[tokio::test]
async fn safe_info_trusts_the_chain_over_the_service() {
    if !docker().await {
        return;
    }
    let args = json!({"address": SAFE});
    let ctx = json!({"chain_id": 1});

    let ok = call(
        "safe_info",
        args.clone(),
        ctx.clone(),
        chain_reads(&owners(), 4),
    )
    .await
    .unwrap();
    assert_eq!(
        ok["onchain_check"], "owners and threshold match the chain",
        "{ok}"
    );

    // The chain says 5-of-11: the service is stale or lying, and the answer follows the chain.
    let bad = call("safe_info", args, ctx, chain_reads(&owners(), 5))
        .await
        .unwrap();
    assert!(
        bad["onchain_check"]
            .as_str()
            .unwrap()
            .starts_with("MISMATCH"),
        "{bad}"
    );
    assert_eq!(bad["threshold"], 5);
}

#[tokio::test]
async fn safe_queue_names_who_has_not_signed_and_warns() {
    if !docker().await {
        return;
    }
    let out = call(
        "safe_queue",
        json!({"address": SAFE, "chain": "Ethereum", "limit": 5}),
        json!({"chain_id": 1}),
        chain_reads(&owners(), 4),
    )
    .await
    .unwrap();
    let rows = out["transactions"].as_array().unwrap();
    assert_eq!(rows.len(), 3, "{out}");
    assert_eq!(out["rule"], "4 of 11 owners must sign");
    assert_eq!(out["more_than_shown"], true);

    // Nonce 1445 has two competing proposals; one has 1 of 4 signatures.
    let first = &rows[0];
    assert_eq!(first["nonce"], 1445);
    assert_eq!(first["signatures"], "1 of 4");
    assert_eq!(first["ready_to_execute"], false);
    assert_eq!(first["still_needs"].as_array().unwrap().len(), 10);
    let warnings = |row: &Value| row["warnings"].to_string();
    assert!(
        warnings(&rows[0]).contains("same nonce") && warnings(&rows[1]).contains("same nonce"),
        "{out}"
    );

    // A fully signed delegatecall batch is ready to run.
    let batch = &rows[2];
    assert_eq!(batch["nonce"], 1446);
    assert_eq!(batch["ready_to_execute"], true);
    assert_eq!(batch["still_needs"], json!([]));
    assert_eq!(
        batch["summary"],
        "Pays 14,784.643716 COW to 19 recipients in 32 transfers"
    );
    assert_eq!(batch["kind"], "payout");
    assert_eq!(rows[0]["summary"], "Sends 1 COW to 0x6C9F…5711");
    // The other proposal at 1445 is a rejection: an empty call to the Safe itself.
    assert_eq!(rows[1]["kind"], "rejection", "{out}");
    // MultiSend is an expected delegatecall; it must not be raised as one.
    assert!(!warnings(batch).contains("DELEGATECALL"), "{batch}");
    for row in rows {
        assert!(row["safe_tx_hash"].as_str().unwrap().starts_with("0x"));
    }
}

#[tokio::test]
async fn safe_activity_lists_executed_batches_newest_first() {
    if !docker().await {
        return;
    }
    let out = call(
        "safe_activity",
        json!({"address": SAFE, "limit": 5}),
        json!({"chain_id": 1}),
        BTreeMap::new(),
    )
    .await
    .unwrap();
    let rows = out["transactions"].as_array().unwrap();
    assert_eq!(
        rows.iter()
            .map(|r| r["nonce"].as_u64().unwrap())
            .collect::<Vec<_>>(),
        [1444, 1443]
    );
    assert_eq!(rows[0]["succeeded"], true);
    assert_eq!(out["shown"], 2);
    assert_eq!(out["by_kind"], json!({"payout": 2}));
    assert_eq!(
        rows[0]["summary"],
        "Pays 2,775.112583 COW to 6 recipients in 13 transfers"
    );
}

/// Real transactions from other Safes (Ethereum, one per shape the sample turned up), served as one
/// history so each shape's label and warning is pinned.
#[tokio::test]
async fn safe_activity_labels_the_shapes_real_safes_use() {
    if !docker().await {
        return;
    }
    let other = "0x72dce6fA22ebA1F0abCb28629A3918c6C88269Da";
    let extra = BTreeMap::from([(
        format!(
            "GET {BASE}/safes/{other}/multisig-transactions/?executed=true&ordering=-executionDate&limit=10"
        ),
        fixture("patterns.json"),
    )]);
    let out = call(
        "safe_activity",
        json!({"address": other, "limit": 10}),
        json!({"chain_id": 1}),
        extra,
    )
    .await
    .unwrap();
    let by_kind = |kind: &str| -> Value {
        out["transactions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["kind"] == kind)
            .unwrap_or_else(|| panic!("no {kind} row in {out}"))
            .clone()
    };
    assert_eq!(
        by_kind("swap_order")["summary"],
        "Places a CoW Protocol swap order (signs it on chain)"
    );
    assert!(
        by_kind("swap")["summary"]
            .as_str()
            .unwrap()
            .contains("unlimited amount of USDT")
    );
    let control = by_kind("control");
    assert!(
        control["warnings"]
            .to_string()
            .contains("changes who controls the Safe"),
        "{control}"
    );
    // A delegatecall that is not Safe's own MultiSend is the dangerous one, and is said once.
    let call_row = out["transactions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["warnings"].to_string().contains("DELEGATECALL"))
        .unwrap();
    assert_eq!(
        call_row["warnings"].as_array().unwrap().len(),
        1,
        "{call_row}"
    );
    assert!(
        by_kind("approval")["warnings"]
            .to_string()
            .contains("unlimited approval")
    );
}

#[tokio::test]
async fn bad_input_fails_with_a_reason() {
    if !docker().await {
        return;
    }
    let err = call(
        "safe_queue",
        json!({"address": "vitalik.eth"}),
        json!({"chain_id": 1}),
        BTreeMap::new(),
    )
    .await
    .unwrap_err();
    assert!(err.contains("0x address"), "{err}");
    let err = call(
        "safe_queue",
        json!({"address": SAFE, "chain": "dogechain"}),
        json!({}),
        BTreeMap::new(),
    )
    .await
    .unwrap_err();
    assert!(err.contains("does not cover"), "{err}");
}
