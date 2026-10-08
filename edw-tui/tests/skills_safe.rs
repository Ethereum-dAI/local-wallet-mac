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
                "GET {BASE}/safes/{SAFE}/multisig-transactions/?executed=false&nonce=1445&limit=20"
            ),
            fixture("queue.json"),
        ),
        (
            format!(
                "GET {BASE}/safes/{SAFE}/multisig-transactions/?executed=false&nonce=1446&limit=20"
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
    extra: BTreeMap<String, String>,
) -> Result<Output, String> {
    let skill = skill();
    let def = skill
        .read_tool(tool)
        .or_else(|| skill.action(tool).map(|a| &a.tool))
        .unwrap();
    let mut all = fixtures();
    all.extend(extra);
    let extra = all;
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
fn the_skill_reads_and_acts_only_on_the_safe_the_user_names() {
    let skill = skill();
    assert_eq!(skill.manifest.hosts, ["api.safe.global"]);
    assert_eq!(
        skill.tool_names(),
        [
            "safe_info",
            "safe_queue",
            "safe_activity",
            "safe_approve_hash",
            "safe_execute"
        ]
    );
    // Not pinned: its address is the call's own `address`, and it may do two things.
    let [safe] = &skill.manifest.contracts[..] else {
        panic!("one contract")
    };
    assert!(safe.address.is_empty());
    assert_eq!(safe.address_arg.as_deref(), Some("address"));
    let names: Vec<&str> = safe.functions.iter().map(|f| f.name.as_str()).collect();
    assert_eq!(names, ["approveHash", "execTransaction"]);
    assert_eq!(safe.signed_calls, ["execTransaction"]);
    assert!(skill.manifest.actions.iter().all(|a| a.approves.is_empty()));
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
    // The delegatecall, and that this skill cannot read what the code behind it does.
    assert_eq!(
        call_row["warnings"].as_array().unwrap().len(),
        2,
        "{call_row}"
    );
    assert!(
        call_row["warnings"].to_string().contains("UNKNOWN CALL"),
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
    function masterCopy() returns (address);
    function VERSION() returns (string);
    function approvedHashes(address owner, bytes32 hash) returns (uint256);
    function approve(address spender, uint256 amount) returns (bool);
    function checkNSignatures(bytes32 dataHash, bytes data, bytes signatures, uint256 requiredSignatures);
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

/// A Safe's own contracts, as the skill checks them before it proposes anything.
fn identity(singleton: &str, version: &str) -> BTreeMap<String, String> {
    let word = |hex: String| format!("0x{hex}");
    let singleton: Address = singleton.parse().unwrap();
    let string = {
        let mut out = format!("{:064x}{:064x}", 32, version.len());
        out.push_str(&alloy_primitives::hex::encode(version.as_bytes()));
        out.push_str(&"0".repeat(64 - version.len() * 2 % 64));
        out
    };
    BTreeMap::from([
        rpc(
            masterCopyCall {}.abi_encode(),
            &word(format!(
                "{:0>64}",
                alloy_primitives::hex::encode(singleton.as_slice())
            )),
        ),
        rpc(VERSIONCall {}.abi_encode(), &word(string)),
    ])
}

const SINGLETON_130: &str = "0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552";

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
    let mut reads = identity(SINGLETON_130, "1.3.0");
    reads.extend([
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
    ]);
    reads
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
    let call = &plan["steps"][0]["call"];
    assert_eq!(call["function"], "approveHash");
    assert_eq!(call["args"], json!([hash]));
    // It names the transaction behind the hash, for the harness to check against the Safe.
    assert_eq!(call["explain"]["nonce"], "1445");
    assert_eq!(call["explain"]["to"], queued(0)["to"]);
    let notes = plan["notes"].to_string();
    assert!(
        notes.contains("Sends 1 COW") && notes.contains("cannot be taken back"),
        "{notes}"
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

/// The fixture's waiting transactions, by position: 0 and 1 compete at nonce 1445, 2 is the fully
/// signed MultiSend payout at 1446.
fn queued(index: usize) -> Value {
    serde_json::from_str::<Value>(&fixture("queue.json")).unwrap()["results"][index].clone()
}

fn hash_call_of(tx: &Value) -> getTransactionHashCall {
    let text = |key: &str| tx[key].as_str().unwrap().to_owned();
    let number = |key: &str| {
        tx[key]
            .as_str()
            .map_or_else(|| tx[key].as_u64().unwrap().to_string(), str::to_owned)
            .parse::<U256>()
            .unwrap()
    };
    getTransactionHashCall {
        to: text("to").parse().unwrap(),
        value: number("value"),
        data: alloy_primitives::hex::decode(tx["data"].as_str().unwrap_or("0x"))
            .unwrap()
            .into(),
        operation: tx["operation"].as_u64().unwrap() as u8,
        safeTxGas: number("safeTxGas"),
        baseGas: number("baseGas"),
        gasPrice: number("gasPrice"),
        gasToken: text("gasToken").parse().unwrap(),
        refundReceiver: text("refundReceiver").parse().unwrap(),
        _nonce: number("nonce"),
    }
}

/// `threshold` signatures from the fixture's confirmations, owners ascending, as the Safe wants.
fn joined_signatures(tx: &Value, threshold: usize) -> String {
    let mut sigs: Vec<(U256, String)> = tx["confirmations"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| {
            (
                U256::from_be_slice(
                    c["owner"]
                        .as_str()
                        .unwrap()
                        .parse::<Address>()
                        .unwrap()
                        .as_slice(),
                ),
                c["signature"].as_str().unwrap()[2..].to_owned(),
            )
        })
        .collect();
    sigs.sort();
    format!(
        "0x{}",
        sigs.into_iter()
            .take(threshold)
            .map(|(_, s)| s)
            .collect::<String>()
    )
}

/// What the Safe says on chain when it is at `next` and the transaction at `index` is up.
fn execute_reads(
    next: u64,
    index: usize,
    threshold: u64,
    accepts: bool,
) -> BTreeMap<String, String> {
    let tx = queued(index);
    let hash = tx["safeTxHash"].as_str().unwrap().to_owned();
    let mut reads = identity(SINGLETON_130, "1.3.0");
    reads.extend([
        rpc(nonceCall {}.abi_encode(), &format!("0x{}", word(next))),
        rpc(
            alloy_primitives::hex::decode("e75235b8").unwrap(),
            &format!("0x{}", word(threshold)),
        ),
        rpc(
            alloy_primitives::hex::decode("a0e67e2b").unwrap(),
            &owners_return(&owners()),
        ),
        rpc(hash_call_of(&tx).abi_encode(), &hash),
    ]);
    if accepts {
        reads.extend([rpc(
            checkNSignaturesCall {
                dataHash: hash.parse().unwrap(),
                data: Default::default(),
                signatures: alloy_primitives::hex::decode(
                    &joined_signatures(&tx, threshold as usize)[2..],
                )
                .unwrap()
                .into(),
                requiredSignatures: U256::from(threshold),
            }
            .abi_encode(),
            "0x",
        )]);
    }
    reads
}

#[tokio::test]
async fn executing_proposes_exec_transaction_with_the_owners_signatures_in_order() {
    if !docker().await {
        return;
    }
    let tx = queued(2);
    let Output::Plan(plan) = run(
        "safe_execute",
        json!({"address": SAFE, "nonce": 1446}),
        wallet(),
        execute_reads(1446, 2, 4, true),
    )
    .await
    .unwrap() else {
        panic!("expected a plan")
    };
    let args = plan["steps"][0]["call"]["args"].as_array().unwrap();
    assert_eq!(plan["steps"][0]["call"]["function"], "execTransaction");
    assert_eq!(args[0], tx["to"]);
    assert_eq!(args[3], "1", "the MultiSend batch is a delegatecall");
    assert_eq!(args[9], joined_signatures(&tx, 4));
    // The checker takes it, at the Safe the user named, and the review says what it carries.
    let skill = skill();
    let action = skill.action("safe_execute").unwrap();
    let checked = edw_tui::skills::plan::check(
        &plan,
        &skill,
        action,
        1,
        ME.parse().unwrap(),
        &json!({"address": SAFE}),
    )
    .unwrap();
    assert_eq!(checked.steps[0].to, SAFE.parse::<Address>().unwrap());
    assert!(
        checked.steps[0]
            .label
            .contains("execTransaction(to=0x40A2aCCbd92BCA938b02010E17A5b8929b49130D"),
        "{}",
        checked.steps[0].label
    );
    assert!(
        checked.steps[0].label.contains("signatures=0x"),
        "{}",
        checked.steps[0].label
    );
}

#[tokio::test]
async fn executing_refuses_what_is_not_ready() {
    if !docker().await {
        return;
    }
    let refuse = |args: Value, reads: BTreeMap<String, String>| async move {
        run("safe_execute", args, wallet(), reads)
            .await
            .expect_err("a refusal")
    };
    // Only the Safe's next nonce can run.
    let error = refuse(
        json!({"address": SAFE, "nonce": 1446}),
        execute_reads(1445, 2, 4, true),
    )
    .await;
    assert!(error.contains("next nonce (1445)"), "{error}");
    // One signature of four.
    let first = queued(0)["safeTxHash"].as_str().unwrap().to_owned();
    let error = refuse(
        json!({"address": SAFE, "nonce": 1445, "safe_tx_hash": first}),
        execute_reads(1445, 0, 4, true),
    )
    .await;
    assert!(error.contains("1 of 4"), "{error}");
    // The Safe itself does not accept the signatures.
    let error = refuse(
        json!({"address": SAFE, "nonce": 1446}),
        execute_reads(1446, 2, 4, false),
    )
    .await;
    assert!(error.contains("rejected these signatures"), "{error}");
    // The service's transaction does not hash to what the Safe computes.
    let mut reads = execute_reads(1446, 2, 4, true);
    reads.extend([rpc(
        hash_call_of(&queued(2)).abi_encode(),
        &format!("0x{}", "ab".repeat(32)),
    )]);
    let error = refuse(json!({"address": SAFE, "nonce": 1446}), reads).await;
    assert!(error.contains("does not hash"), "{error}");
}

/// The service's page of waiting transactions, with the rows replaced.
fn page(rows: Vec<Value>) -> String {
    json!({"count": rows.len(), "next": null, "results": rows}).to_string()
}

fn service_at(nonce: u64) -> String {
    format!("GET {BASE}/safes/{SAFE}/multisig-transactions/?executed=false&nonce={nonce}&limit=20")
}

/// The reads for a transaction the test has altered: the Safe computes the same hash for it.
fn reads_for(tx: &Value, next: u64) -> BTreeMap<String, String> {
    let hash = tx["safeTxHash"].as_str().unwrap().to_owned();
    let mut reads = identity(SINGLETON_130, "1.3.0");
    reads.extend([
        rpc(nonceCall {}.abi_encode(), &format!("0x{}", word(next))),
        rpc(
            isOwnerCall {
                owner: ME.parse().unwrap(),
            }
            .abi_encode(),
            &format!("0x{}", word(1)),
        ),
        rpc(hash_call_of(tx).abi_encode(), &hash),
        rpc(
            approvedHashesCall {
                owner: ME.parse().unwrap(),
                hash: hash.parse().unwrap(),
            }
            .abi_encode(),
            &format!("0x{}", word(0)),
        ),
    ]);
    reads
}

#[tokio::test]
async fn a_service_that_misdescribes_the_calldata_is_refused() {
    if !docker().await {
        return;
    }
    // The bytes approve the router for everything; the service says "transfer 1".
    let mut tx = queued(0);
    let data = approveCall {
        spender: "0x1111111111111111111111111111111111111111"
            .parse()
            .unwrap(),
        amount: U256::MAX,
    }
    .abi_encode();
    tx["data"] = json!(format!("0x{}", alloy_primitives::hex::encode(data)));
    tx["dataDecoded"] = json!({"method": "transfer", "parameters": [
        {"name": "to", "type": "address", "value": "0x1111111111111111111111111111111111111111"},
        {"name": "value", "type": "uint256", "value": "1"}]});
    let mut reads = reads_for(&tx, 1445);
    reads.insert(service_at(1445), page(vec![tx.clone()]));
    let error = run(
        "safe_approve_hash",
        json!({"address": SAFE, "nonce": 1445, "acknowledge_warnings": true}),
        wallet(),
        reads,
    )
    .await
    .expect_err("a refusal");
    assert!(
        error.contains("does not match the transaction's calldata"),
        "{error}"
    );

    // Read straight from the bytes, the queue says what it really is, whatever the service said.
    let mut queue = BTreeMap::from([(
        format!(
            "GET {BASE}/safes/{SAFE}/multisig-transactions/?executed=false&nonce__gte=1445&ordering=nonce&limit=5"
        ),
        page(vec![tx]),
    )]);
    queue.extend(chain_reads(&owners(), 4));
    let out = call(
        "safe_queue",
        json!({"address": SAFE}),
        json!({"chain_id": 1}),
        queue,
    )
    .await
    .unwrap();
    let row = &out["transactions"][0];
    assert!(
        row["summary"].as_str().unwrap().contains("unlimited"),
        "{row}"
    );
    assert_eq!(row["mismatch"], true, "{row}");
    assert!(
        row["warnings"]
            .to_string()
            .contains("does not match its calldata"),
        "{row}"
    );
}

#[tokio::test]
async fn a_call_this_skill_cannot_read_needs_the_users_ok() {
    if !docker().await {
        return;
    }
    let mut tx = queued(0);
    tx["data"] = json!("0xdeadbeef00");
    tx["dataDecoded"] = Value::Null;
    let mut reads = reads_for(&tx, 1445);
    reads.insert(service_at(1445), page(vec![tx]));
    let error = run(
        "safe_approve_hash",
        json!({"address": SAFE, "nonce": 1445}),
        wallet(),
        reads.clone(),
    )
    .await
    .expect_err("a refusal");
    assert!(
        error.contains("UNKNOWN CALL") && error.contains("0xdeadbeef"),
        "{error}"
    );
    // Once the user has heard it, it goes ahead, and the review is told about it.
    let Output::Plan(plan) = run(
        "safe_approve_hash",
        json!({"address": SAFE, "nonce": 1445, "acknowledge_warnings": true}),
        wallet(),
        reads,
    )
    .await
    .unwrap() else {
        panic!("expected a plan")
    };
    assert!(
        plan["notes"]
            .to_string()
            .contains("warning heard: UNKNOWN CALL"),
        "{plan}"
    );
}

#[tokio::test]
async fn only_a_real_recent_safe_is_acted_on_and_only_at_its_next_nonce() {
    if !docker().await {
        return;
    }
    let hash = first_hash();
    let args = json!({"address": SAFE, "nonce": 1445, "safe_tx_hash": hash});
    // An address whose code is not one of Safe's own contracts.
    let mut reads = approve_reads(true, &hash, false);
    reads.extend(identity(
        "0x1111111111111111111111111111111111111111",
        "1.3.0",
    ));
    let error = run("safe_approve_hash", args.clone(), wallet(), reads)
        .await
        .expect_err("a refusal");
    assert!(
        error.contains("not running one of Safe's own contracts"),
        "{error}"
    );
    // A Safe whose hash does not include the chain.
    let mut reads = approve_reads(true, &hash, false);
    reads.extend(identity(SINGLETON_130, "1.2.0"));
    let error = run("safe_approve_hash", args.clone(), wallet(), reads)
        .await
        .expect_err("a refusal");
    assert!(error.contains("before 1.3.0"), "{error}");
    // A later nonce: an approval never expires, so it is not offered early.
    let mut reads = approve_reads(true, &hash, false);
    reads.extend(execute_reads(1445, 2, 4, true));
    let error = run(
        "safe_approve_hash",
        json!({"address": SAFE, "nonce": 1446}),
        wallet(),
        reads,
    )
    .await
    .expect_err("a refusal");
    assert!(
        error.contains("never expires") && error.contains("1445"),
        "{error}"
    );
    // Not a number.
    let error = run(
        "safe_approve_hash",
        json!({"address": SAFE, "nonce": "latest"}),
        wallet(),
        approve_reads(true, &hash, false),
    )
    .await
    .expect_err("a refusal");
    assert!(error.contains("whole number"), "{error}");
}

#[tokio::test]
async fn a_service_claiming_the_senders_approval_does_not_make_the_signature() {
    if !docker().await {
        return;
    }
    // The service lists the sender as having approved the 4-of-4 payout and drops the others:
    // it is not believed, because the Safe's own record has no such approval.
    let mut tx = queued(2);
    let me = ME.to_lowercase();
    tx["confirmations"] = json!([{
        "owner": ME, "signatureType": "APPROVED_HASH",
        "signature": format!("0x{}{}{}01", "00".repeat(12), &me[2..], "00".repeat(32)),
    }]);
    let mut reads = execute_reads(1446, 2, 4, true);
    reads.insert(service_at(1446), page(vec![tx]));
    let error = run(
        "safe_execute",
        json!({"address": SAFE, "nonce": 1446}),
        wallet(),
        reads,
    )
    .await
    .expect_err("a refusal");
    assert!(
        error.contains("not enough signatures") && error.contains("0 of 4"),
        "{error}"
    );
}

#[tokio::test]
async fn execute_counts_approvals_the_safe_itself_records() {
    if !docker().await {
        return;
    }
    // Three owners signed; the fourth approved on chain, which the service has not indexed.
    let mut tx = queued(2);
    let kept: Vec<Value> = tx["confirmations"].as_array().unwrap()[..3].to_vec();
    let fourth = tx["confirmations"][3]["owner"].as_str().unwrap().to_owned();
    tx["confirmations"] = json!(kept);
    let mut reads = execute_reads(1446, 2, 4, true);
    let hash = tx["safeTxHash"].as_str().unwrap();
    reads.extend([rpc(
        approvedHashesCall {
            owner: fourth.parse().unwrap(),
            hash: hash.parse().unwrap(),
        }
        .abi_encode(),
        &format!("0x{}", word(1)),
    )]);
    // The Safe is then asked about the four signatures it will actually be handed.
    let mut sigs: Vec<(U256, String)> = tx["confirmations"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| {
            (
                U256::from_be_slice(
                    c["owner"]
                        .as_str()
                        .unwrap()
                        .parse::<Address>()
                        .unwrap()
                        .as_slice(),
                ),
                c["signature"].as_str().unwrap()[2..].to_owned(),
            )
        })
        .collect();
    sigs.push((
        U256::from_be_slice(fourth.parse::<Address>().unwrap().as_slice()),
        format!(
            "{}{}{}01",
            "00".repeat(12),
            &fourth.to_lowercase()[2..],
            "00".repeat(32)
        ),
    ));
    sigs.sort();
    let joined: String = sigs.into_iter().map(|(_, s)| s).collect();
    reads.extend([rpc(
        checkNSignaturesCall {
            dataHash: hash.parse().unwrap(),
            data: Default::default(),
            signatures: alloy_primitives::hex::decode(&joined).unwrap().into(),
            requiredSignatures: U256::from(4),
        }
        .abi_encode(),
        "0x",
    )]);
    reads.insert(service_at(1446), page(vec![tx]));
    let Output::Plan(plan) = run(
        "safe_execute",
        json!({"address": SAFE, "nonce": 1446}),
        wallet(),
        reads,
    )
    .await
    .unwrap() else {
        panic!("expected a plan")
    };
    assert_eq!(plan["steps"][0]["call"]["args"][9], format!("0x{joined}"));
    assert!(
        plan["notes"]
            .to_string()
            .contains("1 of them approvals recorded on chain"),
        "{plan}"
    );
}

#[tokio::test]
async fn a_signature_check_that_cannot_fail_is_not_believed() {
    if !docker().await {
        return;
    }
    // If the Safe also "accepts" a call with no signatures, the check is not real (an unknown
    // selector fell through to the fallback), so nothing is proposed.
    let tx = queued(2);
    let hash = tx["safeTxHash"].as_str().unwrap();
    let mut reads = execute_reads(1446, 2, 4, true);
    reads.extend([rpc(
        checkNSignaturesCall {
            dataHash: hash.parse().unwrap(),
            data: Default::default(),
            signatures: Default::default(),
            requiredSignatures: U256::from(4),
        }
        .abi_encode(),
        "0x",
    )]);
    let error = run(
        "safe_execute",
        json!({"address": SAFE, "nonce": 1446}),
        wallet(),
        reads,
    )
    .await
    .expect_err("a refusal");
    assert!(
        error.contains("could not be confirmed to be real"),
        "{error}"
    );
}

#[tokio::test]
async fn the_queue_and_info_follow_the_chain_not_the_service() {
    if !docker().await {
        return;
    }
    // The service says one signature is enough; the Safe says four.
    let mut first = queued(0);
    first["confirmationsRequired"] = json!(1);
    let queue_key = format!(
        "GET {BASE}/safes/{SAFE}/multisig-transactions/?executed=false&nonce__gte=1445&ordering=nonce&limit=5"
    );
    let mut reads = BTreeMap::from([(queue_key, page(vec![first]))]);
    reads.extend(chain_reads(&owners(), 4));
    let out = call(
        "safe_queue",
        json!({"address": SAFE}),
        json!({"chain_id": 1}),
        reads,
    )
    .await
    .unwrap();
    let row = &out["transactions"][0];
    assert_eq!(row["ready_to_execute"], false, "{row}");
    assert_eq!(row["signatures"], "1 of 4");
    assert_eq!(row["signatures_checked_on_chain"], true);
    // Elsewhere the same answer says plainly that it is the service's.
    let mut elsewhere = BTreeMap::new();
    elsewhere.insert(
        format!("GET {BASE}/safes/{SAFE}/multisig-transactions/?executed=false&nonce__gte=1445&ordering=nonce&limit=5"),
        page(vec![queued(0)]),
    );
    let out = call(
        "safe_queue",
        json!({"address": SAFE, "chain": "Ethereum"}),
        json!({"chain_id": 100}),
        elsewhere,
    )
    .await
    .unwrap();
    assert_eq!(out["transactions"][0]["signatures_checked_on_chain"], false);
    assert!(
        out["signer_set"]
            .as_str()
            .unwrap()
            .contains("not checked on chain"),
        "{out}"
    );

    // A mismatch changes every field that depends on it, not just two.
    let bad = call(
        "safe_info",
        json!({"address": SAFE}),
        json!({"chain_id": 1, "me": ME}),
        chain_reads(&owners()[..3], 2),
    )
    .await
    .unwrap();
    assert_eq!(bad["rule"], "2 of 3 owners must sign", "{bad}");
    assert_eq!(bad["owner_count"], 3);
    assert_eq!(bad["you_are_an_owner"], false);
}
