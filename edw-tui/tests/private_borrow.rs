//! A private borrow through the agent, the review and the real `edw`, on the anvil that answers as
//! Sepolia (`common::fake_sepolia`). That chain has neither Aave nor Tornado pools, so where the
//! skill's script runs it is swapped for one that writes the same plan without reading Aave, and
//! the 1 ETH note a borrow unshields is mined there by `common::mine_eth_notes`. edw picks it,
//! proves, and fails before sending, as the chain has no EntryPoint. What is checked is what the
//! harness promises: a profile whose notes cannot pay for the unshield is refused before any
//! preparation or card, one card shows the whole operation, nothing is sent without a yes, the
//! model sees no calldata, and a preparation is reused until an attempt may have put it on chain.
//! Skips without edw or anvil, and the card tests without Docker.
//!
//! `live_sepolia_private_borrow` is the real thing, ignored by default.

mod common;

use std::{
    fs,
    path::{Path, PathBuf},
    sync::Arc,
};

use alloy_node_bindings::AnvilInstance;
use alloy_primitives::{hex, keccak256};
use common::{
    Harness, TempWallet, Turn, edw_binary, fake_sepolia, mine_eth_notes,
    recorder::{Recorder, call},
};
use edw_core::{
    instance::{DataDir, Instance},
    network::NetworkPreset,
};
use edw_tui::{
    agent::AgentEvent,
    edw,
    flow::{FlowEvent, Stage, StepState},
    scripted::ScriptedModel,
    skills::{
        catalog::{self, Catalog, SkillState},
        manifest,
        plan::{self, Account},
        sandbox::{self, Runner},
        tools::SkillSet,
    },
    tornado::{FreshAddress, PoolAmount, Token, borrow::Request, prepared::Store},
};
use rig_agent::ModelHandle;
use rig_core::message::AssistantContent;
use serde_json::{Value, json};

const PROMPT: &str = "privately borrow 100 DAI against 1 ETH";
/// What a stub plan carries besides its steps, to show the script ran for the fresh address.
const STUB: &str = r#"import edw_skill

_, args, context = edw_skill.invoke()
edw_skill.plan(
    [
        edw_skill.call_step("gateway", "depositETH", ["pool", "$self", "0"], value=int(args["supply"])),
        edw_skill.call_step("pool", "borrow", ["dai", args["borrow"], "2", "0", "$self"]),
    ],
    ["planned for " + context["me"] + " without reading Aave"],
)
"#;
/// Calldata the model must never see: ERC-20 approve, Tornado deposit, depositETH and borrow.
const SELECTORS: [&str; 4] = ["095ea7b3", "b214faa5", "474cf53d", "a415bcad"];

fn shipped() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("skills")
}

fn copy(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), target).unwrap();
        }
    }
}

/// Every skill in `dir`, agreed to.
fn skill_set(dir: &Path) -> Arc<SkillSet> {
    let mut installed = catalog::discover(&[dir.to_owned()]);
    for i in &mut installed {
        i.state = SkillState::Ready;
    }
    catalog::resolve(&mut installed, &edw::tool_names(), true);
    Arc::new(SkillSet::new(
        Catalog::from_installed(&installed),
        &installed,
        Runner::from_env(),
    ))
}

/// The shipped skills, with private-aave-borrow's script swapped for [`STUB`].
fn stubbed(root: &Path) -> Arc<SkillSet> {
    let dir = root.join("skills");
    copy(&shipped(), &dir);
    fs::write(
        dir.join("private-aave-borrow/scripts/private_borrow.py"),
        STUB,
    )
    .unwrap();
    skill_set(&dir)
}

/// The model's side of one private borrow per entry in `calls`, after loading the skill once.
fn recorder(calls: &[Value]) -> Recorder {
    let mut replies = vec![call("load_skill", json!({"name": "private-aave-borrow"}))];
    for args in calls {
        replies.push(call("private_aave_borrow", args.clone()));
        replies.push(AssistantContent::text("done"));
    }
    Recorder::new(replies)
}

struct Borrowing {
    h: Harness,
    model: Recorder,
    _chain: AnvilInstance,
    _skills: tempfile::TempDir,
}

async fn start(name: &str, attempts: usize) -> Option<Borrowing> {
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return None;
    };
    if !sandbox::docker_available().await {
        eprintln!("skipping: Docker is not running");
        return None;
    }
    let (wallet, chain) = fake_sepolia(binary, name).await?;
    mine_eth_notes(&wallet, &chain, "1").await;
    let skills = tempfile::tempdir().unwrap();
    let model = recorder(&vec![json!({"eth": "1", "amount": "100"}); attempts]);
    let h = Harness::start_with_skills(
        wallet,
        ModelHandle::named("recorder", model.clone()),
        None,
        stubbed(skills.path()),
    );
    Some(Borrowing {
        h,
        model,
        _chain: chain,
        _skills: skills,
    })
}

async fn fresh_address(wallet: &TempWallet) -> FreshAddress {
    let peek = wallet
        .edw(&["next-fresh-address", "--peek", "--profile", "0/0"])
        .await;
    FreshAddress::from_document(&peek.document().unwrap()).unwrap()
}

fn unshield(fresh: FreshAddress) -> String {
    format!(
        "edw unshield --token ETH --amount-formatted 1 --tail-calls <4 calls> --expected-fresh-address {} --profile 0/0",
        fresh.address
    )
}

fn records(wallet: &TempWallet) -> Vec<Value> {
    let dir = wallet.config.data_dir.join("edw-tui/prepared-shields");
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut records: Vec<Value> = entries
        .map(|e| fs::read_to_string(e.unwrap().path()).unwrap())
        .map(|text| serde_json::from_str(&text).unwrap())
        .collect();
    records.sort_by_key(|r| r["id"].as_str().unwrap().to_owned());
    records
}

/// edw's own count of the profile's pending private `symbol`: notes reserved or not yet mined.
async fn pending_private(wallet: &TempWallet, symbol: &str) -> String {
    let balance = wallet.edw(&["balance", "--detailed", "--", "0/0"]).await;
    let document = balance.document().unwrap();
    let asset = document["assets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|asset| asset["symbol"] == symbol)
        .unwrap_or_else(|| panic!("no {symbol} in {document}"));
    asset["private"]["pending"]["formatted"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn sent(turn: &Turn) -> bool {
    turn.flow.iter().any(|event| {
        matches!(
            event,
            FlowEvent::Step {
                stage: Stage::Send,
                state: StepState::Done,
                ..
            }
        )
    })
}

fn no_calldata(texts: &[String]) {
    for text in texts {
        for selector in SELECTORS {
            assert!(!text.contains(selector), "{selector} in {text}");
        }
    }
}

#[tokio::test]
async fn one_card_shows_the_whole_operation_and_nothing_is_sent_before_yes() {
    let Some(mut b) = start("private-borrow-card", 1).await else {
        return;
    };
    let fresh = fresh_address(&b.h.wallet).await;
    let declined = b.h.turn(PROMPT, false).await;
    assert_eq!(declined.confirms, [unshield(fresh)], "{declined:?}");
    let card = &declined.previews[0];
    for line in [
        "Skill    private-aave-borrow 0.1.0 (sha256 ",
        "Unshield 1 ETH on sepolia (chain 11155111) from profile 0/0's shielded notes",
        &format!("Fresh    {} (address index {})", fresh.address, fresh.index),
        "Aave 1   Aave WETH Gateway.depositETH(pool=Aave Pool, onBehalfOf=the fresh account, referralCode=0) with 0.9 ETH",
        "Aave 2   Aave Pool.borrow(asset=DAI, amount=100 DAI (100000000000000000000), interestRateMode=2, referralCode=0, onBehalfOf=the fresh account)",
        "Shield   100 DAI into 1 new note (shield-",
        "prepared now): 2 calls, approve then deposit",
        "Note     dai-100-11155111 (commitment 0x",
        &format!(
            "Skill says (not checked): planned for {} without reading Aave",
            fresh.address
        ),
        "has 0.9 ETH supplied to Aave and owes 100 DAI",
    ] {
        assert!(card.contains(line), "{line}\n{card}");
    }
    assert!(!sent(&declined));
    let [record] = records(&b.h.wallet).try_into().unwrap();
    assert!(record["consumed"].is_null(), "{record}");
    // The notes are reserved, nothing is on chain.
    assert_eq!(pending_private(&b.h.wallet, "DAI").await, "100");

    no_calldata(&declined.outputs);
    let seen = b.model.seen.lock().unwrap().clone();
    assert!(seen.iter().any(|s| s.contains("declined")), "{seen:?}");
    no_calldata(&seen);
}

#[tokio::test]
async fn a_failed_unshield_leaves_the_preparation_for_the_retry() {
    let Some(mut b) = start("private-borrow-retry", 2).await else {
        return;
    };
    let fresh = fresh_address(&b.h.wallet).await;
    for attempt in 0..2 {
        let turn = b.h.turn(PROMPT, true).await;
        assert_eq!(turn.confirms, [unshield(fresh)], "{turn:?}");
        let prepared = if attempt == 0 {
            "prepared now"
        } else {
            "prepared before"
        };
        assert!(turn.previews[0].contains(prepared), "{turn:?}");
        // edw picks the mined note and proves, then fails before sending, as there is no EntryPoint.
        let failed = turn
            .outputs
            .iter()
            .find(|o| o.starts_with(&unshield(fresh)))
            .unwrap_or_else(|| panic!("no unshield in {turn:?}"));
        assert!(
            failed.contains("=> 1:")
                && failed.contains("edw/error")
                && !failed.contains("held notes cannot make"),
            "{failed}"
        );
        assert!(!sent(&turn));
        no_calldata(&turn.outputs);
    }
    let [record] = records(&b.h.wallet).try_into().unwrap();
    assert!(record["consumed"].is_null(), "{record}");
    assert_eq!(pending_private(&b.h.wallet, "DAI").await, "100");
    let seen = b.model.seen.lock().unwrap().clone();
    assert!(seen.iter().any(|s| s.contains("edw/error")), "{seen:?}");
    no_calldata(&seen);
}

/// edw stores a fresh address once a bundler accepted the user operation using it, so a fresh
/// address that moves during a failed attempt retires its preparation, whatever moved it. Here it
/// is stored by hand while the card is open; edw refuses the unshield, held to the reviewed
/// address, and the next attempt prepares new notes for the next fresh address.
#[tokio::test]
async fn a_fresh_address_used_during_the_attempt_retires_its_preparation() {
    let Some(mut b) = start("private-borrow-consumed", 2).await else {
        return;
    };
    let fresh = fresh_address(&b.h.wallet).await;
    b.h.prompt(PROMPT);
    let mut outputs = Vec::new();
    loop {
        match b.h.next().await {
            AgentEvent::Confirm { reply, .. } => {
                b.h.wallet
                    .edw(&["next-fresh-address", "--profile", "0/0"])
                    .await;
                reply.send(true).unwrap();
            }
            AgentEvent::ToolFinished(result) => outputs.push(format!(
                "{} => {}: {}",
                result.command, result.exit_code, result.output
            )),
            AgentEvent::Reply(_) => break,
            AgentEvent::Error(error) => panic!("{error}"),
            _ => {}
        }
    }
    let refused = outputs
        .iter()
        .find(|o| o.starts_with(&unshield(fresh)))
        .unwrap_or_else(|| panic!("{outputs:?}"));
    assert!(
        refused.contains(&format!("expected fresh address {}", fresh.address)),
        "{refused}"
    );
    let [record] = records(&b.h.wallet).try_into().unwrap();
    assert!(
        record["consumed"]
            .as_str()
            .is_some_and(|why| why.contains(&fresh.address.to_string())),
        "{record}"
    );

    let next = fresh_address(&b.h.wallet).await;
    assert_ne!(next, fresh);
    let again = b.h.turn(PROMPT, false).await;
    assert_eq!(again.confirms, [unshield(next)], "{again:?}");
    assert!(again.previews[0].contains("prepared now"), "{again:?}");
    let records = records(&b.h.wallet);
    assert_eq!(records.len(), 2, "{records:?}");
    assert_eq!(pending_private(&b.h.wallet, "DAI").await, "200");
}

#[tokio::test]
async fn what_the_harness_refuses_never_reaches_a_card() {
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return;
    };
    let Some((wallet, _chain)) = fake_sepolia(binary, "private-borrow-refused").await else {
        return;
    };
    let mut h = Harness::start_with_skills(
        wallet,
        ModelHandle::named("scripted", ScriptedModel::default()),
        None,
        skill_set(&shipped()),
    );
    for (prompt, why) in [
        ("privately borrow 100 USDC against 1 ETH", "shields DAI"),
        (
            "privately borrow 150 DAI against 1 ETH",
            "not a sum of the sepolia DAI pool sizes",
        ),
        (
            "privately borrow 100 DAI against 1.15 ETH",
            "not a sum of the sepolia ETH pool sizes",
        ),
    ] {
        let turn = h.turn(prompt, true).await;
        assert!(turn.confirms.is_empty(), "{turn:?}");
        let refused = turn
            .outputs
            .iter()
            .find(|o| o.starts_with("skill private-aave-borrow/private_aave_borrow"))
            .unwrap_or_else(|| panic!("{turn:?}"));
        assert!(
            refused.contains(why) && refused.contains("nothing was sent"),
            "{refused}"
        );
    }
    assert!(records(&h.wallet).is_empty());
}

/// A wallet on the fake Sepolia whose model asks for 100 DAI against each of `eth`, in turn, with
/// the shipped skill. Each case served here is refused before the script runs, so no Docker.
async fn asking(name: &str, eth: &[&str]) -> Option<(Harness, Recorder, AnvilInstance)> {
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return None;
    };
    let (wallet, chain) = fake_sepolia(binary, name).await?;
    let calls: Vec<Value> = eth
        .iter()
        .map(|eth| json!({"eth": eth, "amount": "100"}))
        .collect();
    let model = recorder(&calls);
    let h = Harness::start_with_skills(
        wallet,
        ModelHandle::named("recorder", model.clone()),
        None,
        skill_set(&shipped()),
    );
    Some((h, model, chain))
}

/// The refusal the model got for the borrow in `turn`, once nothing was reserved, reviewed or
/// sent (no card, no stored preparation, no DAI notes reserved in edw).
async fn refused_before_anything(turn: &Turn, model: &Recorder, wallet: &TempWallet) -> String {
    assert!(turn.confirms.is_empty(), "{turn:?}");
    assert!(!sent(turn));
    assert!(
        !turn.outputs.iter().any(|o| o.starts_with("edw shield")),
        "{turn:?}"
    );
    assert!(records(wallet).is_empty());
    assert_eq!(pending_private(wallet, "DAI").await, "0");
    let refused = turn
        .outputs
        .iter()
        .find(|o| o.starts_with("skill private-aave-borrow/private_aave_borrow"))
        .unwrap_or_else(|| panic!("{turn:?}"));
    assert!(
        refused.contains("=> 1:") && refused.contains("; nothing was sent."),
        "{refused}"
    );
    let output = refused.split_once(" => 1: ").unwrap().1;
    let answered = model.seen.lock().unwrap().last().cloned().unwrap();
    assert!(
        answered.contains(r#"\"exit_code\":1"#) && answered.contains(output),
        "the model got the refusal as a failed tool result: {answered}"
    );
    output.to_owned()
}

#[tokio::test]
async fn a_wallet_without_notes_is_refused_before_any_preparation_or_card() {
    let Some((mut h, model, _chain)) = asking("private-borrow-no-notes", &["1"]).await else {
        return;
    };
    let turn = h.turn(PROMPT, true).await;
    let refused = refused_before_anything(&turn, &model, &h.wallet).await;
    assert!(
        refused.contains("profile 0/0 holds no mined Tornado ETH notes")
            && refused.contains("exactly 1 ETH")
            && refused.contains("only unshielded whole"),
        "{refused}"
    );
}

#[tokio::test]
async fn notes_that_cannot_make_the_amount_are_refused_with_what_is_held_and_needed() {
    let Some((mut h, model, chain)) = asking("private-borrow-short", &["1"]).await else {
        return;
    };
    mine_eth_notes(&h.wallet, &chain, "0.1").await;
    let turn = h.turn(PROMPT, true).await;
    let refused = refused_before_anything(&turn, &model, &h.wallet).await;
    assert!(
        refused.contains(
            "holds mined Tornado ETH notes of 0.1 ETH, which cannot make the 1 ETH needed exactly"
        ) && refused.contains("only unshielded whole"),
        "{refused}"
    );
}

#[tokio::test]
async fn pending_notes_and_notes_without_a_paymaster_are_refused_as_edw_would() {
    let Some((mut h, model, chain)) = asking("private-borrow-unspendable", &["1", "10"]).await
    else {
        return;
    };
    h.wallet
        .edw(&[
            "shield",
            "--prepare",
            "--token",
            "ETH",
            "--amount-formatted",
            "1",
            "--profile",
            "0/0",
        ])
        .await;
    let turn = h.turn(PROMPT, true).await;
    let refused = refused_before_anything(&turn, &model, &h.wallet).await;
    assert!(refused.contains("not mined yet (1 ETH)"), "{refused}");

    mine_eth_notes(&h.wallet, &chain, "10").await;
    let turn = h.turn(PROMPT, true).await;
    let refused = refused_before_anything(&turn, &model, &h.wallet).await;
    assert!(
        refused.contains("edw picks to make 10 ETH (10 ETH) are all in pools without a paymaster"),
        "{refused}"
    );
}

#[tokio::test]
async fn notes_edw_cannot_read_refuse_the_borrow_rather_than_skip_the_check() {
    let Some((mut h, _model, chain)) = asking("private-borrow-unread", &["1"]).await else {
        return;
    };
    drop(chain);
    let turn = h.turn(PROMPT, true).await;
    assert!(turn.confirms.is_empty(), "{turn:?}");
    assert!(
        !turn.outputs.iter().any(|o| o.starts_with("edw ")),
        "{turn:?}"
    );
    assert!(records(&h.wallet).is_empty());
    let refused = turn
        .outputs
        .iter()
        .find(|o| o.starts_with("skill private-aave-borrow/private_aave_borrow"))
        .unwrap_or_else(|| panic!("{turn:?}"));
    assert!(
        refused.contains("=> 1: the profile's Tornado notes could not be read (RPC config")
            && refused.contains("; nothing was sent."),
        "{refused}"
    );
}

/// The argv the harness builds, run as edw itself: every flag, the tail-call list and the
/// expected fresh address get past edw's argument and tail-call parsing (a usage error would be
/// exit 2), and it stops where this chain must: no notes to make 1 ETH.
#[tokio::test]
async fn edw_takes_the_combined_unshield_flag_for_flag() {
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return;
    };
    let Some((wallet, _chain)) = fake_sepolia(binary, "private-borrow-argv").await else {
        return;
    };
    let fresh = fresh_address(&wallet).await;
    let request = Request::from_call(
        &json!({"eth": "1", "amount": "100"}),
        NetworkPreset::Sepolia,
    )
    .unwrap();
    let skill = manifest::load(&shipped().join("private-aave-borrow")).unwrap();
    let action = skill.action("private_aave_borrow").unwrap();
    let args = request.script_args();
    let plan = json!({"steps": [
        {"call": {"contract": "gateway", "function": "depositETH", "args": ["pool", "$self", "0"], "value": args["supply"]}},
        {"call": {"contract": "pool", "function": "borrow", "args": ["dai", args["borrow"], "2", "0", "$self"]}},
    ]});
    let checked = plan::check(
        &plan,
        &skill,
        action,
        11_155_111,
        Account::Fresh(fresh.address),
        &args,
    )
    .unwrap();
    let aave = request.aave(checked, fresh.address).unwrap();
    let prepared = wallet
        .edw(&[
            "shield",
            "--prepare",
            "--token",
            "DAI",
            "--amount-formatted",
            "100",
            "--profile",
            "0/0",
        ])
        .await
        .document()
        .unwrap();
    let dai = PoolAmount::new(NetworkPreset::Sepolia, Token::Dai, "100").unwrap();
    let (shield, _) = Store::in_data_dir(&wallet.config.data_dir)
        .reuse_or(&dai, "0/0", || async { Ok::<_, String>(prepared.clone()) })
        .await
        .unwrap();
    let borrow = request.with_shield(fresh, aave, shield).unwrap();

    let argv = borrow.command().argv("0/0");
    let tail = &argv[argv.iter().position(|a| a == "--tail-calls").unwrap() + 1];
    assert_eq!(tail.split(',').count(), 4);
    let shield_calls = prepared["tail_calls"].as_str().unwrap();
    assert!(tail.ends_with(&format!(",{shield_calls}")), "{tail}");
    let result =
        edw::run_with_timeout(&wallet.config, &argv, std::time::Duration::from_secs(120)).await;
    assert_eq!(result.exit_code, 1, "{result:?}");
    let error = result.document().unwrap();
    assert_eq!(
        (error["kind"].as_str(), error["message"].as_str()),
        (
            Some("edw/error"),
            Some("held notes cannot make 1000000000000000000 wei exactly")
        ),
        "{result:?}"
    );
}

#[test]
fn the_selectors_kept_from_the_model_are_those_calls() {
    for (signature, selector) in [
        ("approve(address,uint256)", SELECTORS[0]),
        ("deposit(bytes32)", SELECTORS[1]),
        ("depositETH(address,address,uint16)", SELECTORS[2]),
        (
            "borrow(address,uint256,uint256,uint16,address)",
            SELECTORS[3],
        ),
    ] {
        assert_eq!(
            &hex::encode(keccak256(signature))[..8],
            selector,
            "{signature}"
        );
    }
}

/// The real thing on Sepolia: unshield ETH notes to a fresh address that supplies the ETH to
/// Aave, borrows 100 DAI and shields it, in one user operation through the public bundler. Moves
/// real Sepolia funds and takes minutes. Needs:
/// - `EDW_TUI_LIVE_PHRASE`: a throwaway mnemonic whose profile 0 holds mined shielded ETH notes
///   that make `EDW_TUI_LIVE_ETH` exactly (default 1), one of them in a pool with a paymaster;
/// - optionally `EDW_TUI_LIVE_RPC`, a Sepolia RPC that supports state overrides (else edw's
///   public default);
/// - Docker (the skill's script reads Aave's Sepolia market), edw and the network.
///
/// `cargo test --test private_borrow live -- --ignored --nocapture`
#[tokio::test]
#[ignore = "moves real Sepolia funds; needs EDW_TUI_LIVE_PHRASE, edw, Docker and the network"]
async fn live_sepolia_private_borrow() {
    let Ok(phrase) = std::env::var("EDW_TUI_LIVE_PHRASE") else {
        eprintln!("skipping: EDW_TUI_LIVE_PHRASE is not set");
        return;
    };
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return;
    };
    let eth = std::env::var("EDW_TUI_LIVE_ETH").unwrap_or_else(|_| "1".into());
    let wallet = TempWallet::new(binary, "live-private-borrow");
    Instance::open_or_create(
        &DataDir::new(&wallet.config.data_dir),
        "sepolia".parse().unwrap(),
        wallet.config.password.as_bytes(),
    )
    .await
    .unwrap()
    .import_profile(phrase.into(), 0, None)
    .await
    .unwrap();
    wallet.unlock("sepolia").await;
    if let Ok(rpc) = std::env::var("EDW_TUI_LIVE_RPC") {
        wallet
            .edw(&[
                "network",
                "rpc-config",
                "add",
                "live",
                "--url",
                &rpc,
                "--use",
            ])
            .await;
    }
    let mut h = Harness::start_with_skills(
        wallet,
        ModelHandle::named("scripted", ScriptedModel::default()),
        None,
        skill_set(&shipped()),
    );
    let turn = h
        .turn(&format!("privately borrow 100 DAI against {eth} ETH"), true)
        .await;
    eprintln!("{turn:#?}");
    assert!(sent(&turn), "{turn:?}");
    let [record] = records(&h.wallet).try_into().unwrap();
    assert!(
        record["consumed"]
            .as_str()
            .is_some_and(|why| why.starts_with("user operation 0x")),
        "{record}"
    );
}
