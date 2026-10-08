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
use alloy_primitives::{Address, U256};
use alloy_sol_types::{SolCall, sol};
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
                "GET {BASE}/safes/{SAFE}/multisig-transactions/?executed=false&nonce__gte={nonce}&ordering=nonce&limit=20"
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
    extra: BTreeMap<String, String>,
) -> Result<Value, String> {
    match run(tool, args, context, extra).await? {
        Output::Result(value) => Ok(value),
        Output::Plan(plan) => panic!("a read tool returned a plan: {plan}"),
    }
}

async fn run(
    tool: &str,
    args: Value,
    context: Value,
    mut extra: BTreeMap<String, String>,
) -> Result<Output, String> {
    let skill = skill();
    let def = skill
        .read_tool(tool)
        .or_else(|| skill.action(tool).map(|a| &a.tool))
        .unwrap();
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
    runner.run(&skill, &def.run, invoke, &host).await
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
fn the_skill_reads_and_can_only_approve_a_hash_on_the_safe_the_user_names() {
    let skill = skill();
    assert_eq!(skill.manifest.hosts, ["api.safe.global"]);
    assert_eq!(
        skill.tool_names(),
        [
            "safe_info",
            "safe_queue",
            "safe_activity",
            "safe_approve_hash"
        ]
    );
    // Not pinned: its address is the call's own `address`, and it may do exactly one thing.
    let [safe] = &skill.manifest.contracts[..] else {
        panic!("one contract")
    };
    assert!(safe.address.is_empty());
    assert_eq!(safe.address_arg.as_deref(), Some("address"));
    assert_eq!(safe.functions.len(), 1);
    assert_eq!(safe.functions[0].name, "approveHash");
    assert!(skill.manifest.actions[0].approves.is_empty());
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

sol! {
    function getTransactionHash(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, uint256 _nonce) returns (bytes32);
    function isOwner(address owner) returns (bool);
    function nonce() returns (uint256);
    function approvedHashes(address owner, bytes32 hash) returns (uint256);
}

const ME: &str = "0x1c20Fd4b76E2ec0BFd417eD18C02F45c1e8190C0";

fn rpc(data: Vec<u8>, answer: &str) -> (String, String) {
    (
        format!(
            r#"rpc eth_call [{{"data":"0x{}","to":"{}"}},"latest"]"#,
            alloy_primitives::hex::encode(data),
            SAFE.to_lowercase()
        ),
        format!("\"{answer}\""),
    )
}

/// What the Safe says on chain for the first waiting proposal (the 1 COW transfer at nonce 1445).
fn approve_reads(owner: bool, hash: &str, approved: bool) -> BTreeMap<String, String> {
    let queue: Value = serde_json::from_str(&fixture("queue.json")).unwrap();
    let tx = &queue["results"][0];
    let text = |key: &str| tx[key].as_str().unwrap().to_owned();
    let number = |key: &str| {
        tx[key]
            .as_str()
            .map_or_else(|| tx[key].as_u64().unwrap().to_string(), str::to_owned)
            .parse::<U256>()
            .unwrap()
    };
    let me: Address = ME.parse().unwrap();
    let hash_call = getTransactionHashCall {
        to: text("to").parse().unwrap(),
        value: number("value"),
        data: alloy_primitives::hex::decode(text("data")).unwrap().into(),
        operation: 0,
        safeTxGas: number("safeTxGas"),
        baseGas: number("baseGas"),
        gasPrice: number("gasPrice"),
        gasToken: text("gasToken").parse().unwrap(),
        refundReceiver: text("refundReceiver").parse().unwrap(),
        _nonce: number("nonce"),
    };
    let flag = |yes: bool| format!("0x{}", word(u64::from(yes)));
    BTreeMap::from([
        rpc(isOwnerCall { owner: me }.abi_encode(), &flag(owner)),
        rpc(nonceCall {}.abi_encode(), &format!("0x{}", word(1445))),
        rpc(hash_call.abi_encode(), hash),
        rpc(
            approvedHashesCall {
                owner: me,
                hash: hash.parse().unwrap(),
            }
            .abi_encode(),
            &format!("0x{}", word(u64::from(approved))),
        ),
    ])
}

fn first_hash() -> String {
    serde_json::from_str::<Value>(&fixture("queue.json")).unwrap()["results"][0]["safeTxHash"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn wallet() -> Value {
    json!({"chain_id": 1, "me": ME})
}

#[tokio::test]
async fn approving_a_waiting_transaction_proposes_exactly_approve_hash_on_the_safe() {
    if !docker().await {
        return;
    }
    let hash = first_hash();
    let Output::Plan(plan) = run(
        "safe_approve_hash",
        json!({"address": SAFE, "nonce": 1445, "safe_tx_hash": hash}),
        wallet(),
        approve_reads(true, &hash, false),
    )
    .await
    .unwrap() else {
        panic!("expected a plan")
    };
    assert_eq!(
        plan,
        json!({"steps": [{"call": {"contract": "safe", "function": "approveHash", "args": [hash]}}]})
    );
    // And the checker compiles it, at the Safe the user named and nowhere else.
    let skill = skill();
    let action = skill.action("safe_approve_hash").unwrap();
    let checked = edw_tui::skills::plan::check(
        &plan,
        &skill,
        action,
        1,
        ME.parse().unwrap(),
        &json!({"address": SAFE, "nonce": 1445}),
    )
    .unwrap();
    assert_eq!(checked.steps.len(), 1);
    assert_eq!(checked.steps[0].to, SAFE.parse::<Address>().unwrap());
    assert_eq!(checked.steps[0].value, U256::ZERO);
    assert_eq!(checked.steps[0].data.len(), 4 + 32);
}

#[tokio::test]
async fn approving_refuses_what_the_chain_does_not_back() {
    if !docker().await {
        return;
    }
    let hash = first_hash();
    let refuse = |args: Value, reads: BTreeMap<String, String>| async move {
        run("safe_approve_hash", args, wallet(), reads)
            .await
            .expect_err("a refusal")
    };
    // Two proposals share nonce 1445: ask which, never pick one.
    let error = refuse(
        json!({"address": SAFE, "nonce": 1445}),
        approve_reads(true, &hash, false),
    )
    .await;
    assert!(
        error.contains("competing") && error.contains(&hash),
        "{error}"
    );
    // The service's transaction does not hash to what the Safe computes.
    let other = format!("0x{}", "ab".repeat(32));
    let error = refuse(
        json!({"address": SAFE, "nonce": 1445, "safe_tx_hash": hash}),
        approve_reads(true, &other, false),
    )
    .await;
    assert!(error.contains("does not hash"), "{error}");
    // The profile is not an owner.
    let error = refuse(
        json!({"address": SAFE, "nonce": 1445, "safe_tx_hash": hash}),
        approve_reads(false, &hash, false),
    )
    .await;
    assert!(error.contains("not an owner"), "{error}");
    // A nonce the Safe has already used.
    let error = refuse(
        json!({"address": SAFE, "nonce": 1000}),
        approve_reads(true, &hash, false),
    )
    .await;
    assert!(error.contains("already been used"), "{error}");
}

#[tokio::test]
async fn an_approval_already_sent_is_reported_not_repeated() {
    if !docker().await {
        return;
    }
    let hash = first_hash();
    let out = run(
        "safe_approve_hash",
        json!({"address": SAFE, "nonce": 1445, "safe_tx_hash": hash}),
        wallet(),
        approve_reads(true, &hash, true),
    )
    .await
    .unwrap();
    let Output::Result(value) = out else {
        panic!("expected a result")
    };
    assert_eq!(value["already_approved"], true);
}

#[tokio::test]
async fn safe_queue_shows_an_approval_the_profile_sent_on_chain() {
    if !docker().await {
        return;
    }
    let hash = first_hash();
    // Not the proposer: the service already lists that owner as having signed.
    let me: Address = "0x00000000000000000000000000000000000000A1"
        .parse()
        .unwrap();
    let reads = BTreeMap::from([rpc(
        approvedHashesCall {
            owner: me,
            hash: hash.parse().unwrap(),
        }
        .abi_encode(),
        &format!("0x{}", word(1)),
    )]);
    let out = call(
        "safe_queue",
        json!({"address": SAFE, "chain": "Ethereum", "limit": 5}),
        json!({"chain_id": 1, "me": me}),
        reads,
    )
    .await
    .unwrap();
    let rows = out["transactions"].as_array().unwrap();
    let mine: Vec<&Value> = rows
        .iter()
        .filter(|r| r["you_approved_on_chain"] == true)
        .collect();
    assert_eq!(mine.len(), 1, "{out}");
    assert_eq!(mine[0]["safe_tx_hash"], hash);
    assert_eq!(mine[0]["you_have_signed"], true);
}
