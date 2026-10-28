//! A rehearsal of the private borrow on a Sepolia fork, end to end and for real. The pinned edw
//! shields two 0.1 ETH notes into Sepolia's Tornado pool. Then the agent (scripted model, the
//! shipped skill's script in Docker) borrows 100 DAI against one of them: it peeks the fresh
//! address, plans Aave for it, prepares a 100 DAI shield, and edw proves and sends the one
//! combined unshield through a local bundler. Everything is checked from chain state afterwards.
//! Then gas gets expensive, and the same request against the other note must be refused before
//! signing, with nothing sent. Ignored by default; it reads Sepolia over the network and takes
//! about two minutes.
//!
//! What edw needs, found by trying it (`common::sepolia_fork`):
//! - RPC: anvil forked from Sepolia answers with chain id 11155111 and takes state overrides;
//!   `network rpc-config add --use` points edw at it.
//! - Bundler: alto 0.0.21 (the version kohaku-rs's fork kit pins), against the EntryPoint v0.8
//!   Sepolia already has. edw lets the Pimlico default be removed once another URL is listed, so
//!   alto is its only bundler and nothing reaches public Pimlico. The paymaster, its adapters and
//!   its EntryPoint deposit are Sepolia's own, as of the fork block.
//! - Pool history: edw's indexer cannot be turned off here. The public RPC answers `eth_getLogs`
//!   at the pools' deploy block (5,594,400) with "pruned history unavailable" and caps a request
//!   at 50,000 blocks (edw asks for 500 at a time, so about 13,000 requests per pool). The
//!   indexer stays on as it is live: Saga serves history up to its last update, the fork the rest.
//!
//! Needs `EDW_BIN` (the pinned edw), anvil, Docker, alto (`ALTO_BIN`, or `alto` on PATH) and the
//! network (`EDW_TUI_SEPOLIA_RPC`, default a public endpoint); skips with a message without them.
//!
//! `EDW_BIN=… ALTO_BIN=… cargo test --test fork_private_borrow -- --ignored --nocapture`

mod common;

use std::time::{Duration, Instant};

use alloy_primitives::{
    Address, B256, U256,
    utils::{format_ether, format_units, parse_ether},
};
use alloy_provider::{Provider, ProviderBuilder};
use alloy_rpc_types_eth::{TransactionReceipt, TransactionRequest};
use alloy_sol_types::{SolCall, SolEvent, sol};
use common::{
    Harness, edw_binary, records,
    sepolia_fork::{Alto, ENTRY_POINT, alto_binary, fork_sepolia, last_run, timeline, wallet_on},
    shipped, skill_set,
};
use edw_core::vault::tornadocash::Pool;
use edw_tui::{
    agent::AgentEvent,
    edw::{self, EdwResult},
    flow::FlowEvent,
    scripted::ScriptedModel,
    skills::{manifest, sandbox},
    tornado::{self, borrow::FEE_RESERVE_BPS},
};
use rig_agent::ModelHandle;
use serde_json::{Value, json};

const SEPOLIA: u64 = 11_155_111;
const PROMPT: &str = "privately borrow 100 DAI against 0.1 ETH";
const SHIELD_ETH: [&str; 9] = [
    "shield",
    "--token",
    "ETH",
    "--amount-formatted",
    "0.1",
    "--from",
    "0",
    "--profile",
    "0/0",
];

sol! {
    function balanceOf(address owner) returns (uint256);
    function getUserAccountData(address user) returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }
    function getReserveData(address asset) returns (ReserveData);
    event UserOperationEvent(
        bytes32 indexed userOpHash,
        address indexed sender,
        address indexed paymaster,
        uint256 nonce,
        bool success,
        uint256 actualGasCost,
        uint256 actualGasUsed
    );
}

async fn view<C: SolCall>(provider: &impl Provider, to: Address, call: C) -> C::Return {
    let request = TransactionRequest::default()
        .to(to)
        .input(call.abi_encode().into());
    C::abi_decode_returns(&provider.call(request).await.unwrap()).unwrap()
}

/// One edw command in the rehearsal's wallet, with the Tornado commands' time limit.
async fn edw_ok(config: &edw::EdwConfig, args: &[&str]) -> EdwResult {
    let argv: Vec<String> = args.iter().map(|a| (*a).to_owned()).collect();
    let result = edw::run_with_timeout(config, &argv, tornado::TIMEOUT).await;
    assert!(result.ok(), "{result:?}");
    result
}

/// The profile's private (spendable, pending) balance of the asset `pick` selects, as edw
/// reports it.
async fn private(config: &edw::EdwConfig, pick: impl Fn(&Value) -> bool) -> (String, String) {
    let balance = edw_ok(config, &["balance", "--detailed", "--", "0/0"])
        .await
        .document()
        .unwrap();
    let asset = balance["assets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| pick(a))
        .unwrap_or_else(|| panic!("no such asset in {balance}"));
    let amount = |state: &str| {
        asset["private"][state]["formatted"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    (amount("spendable"), amount("pending"))
}

fn is_eth(asset: &Value) -> bool {
    asset["address"].is_null()
}

fn is_dai(asset: &Value) -> bool {
    asset["symbol"] == "DAI"
}

fn hex_u256(value: &Value) -> U256 {
    value.as_str().unwrap().parse().unwrap()
}

fn owned(pair: (&str, &str)) -> (String, String) {
    (pair.0.into(), pair.1.into())
}

fn lap(stages: &mut Vec<(&'static str, Duration)>, stage: &'static str, since: Instant) {
    let took = since.elapsed();
    eprintln!("stage {stage}: {:.1} s", took.as_secs_f64());
    stages.push((stage, took));
}

/// What one private borrow request did: the cards (approved), every tool result, and the reply.
struct Attempt {
    cards: Vec<(String, String)>,
    outputs: Vec<EdwResult>,
    reply: String,
}

impl Attempt {
    fn unshield(&self) -> &EdwResult {
        self.outputs
            .iter()
            .find(|o| o.command.starts_with("edw unshield"))
            .unwrap_or_else(|| panic!("no unshield ran: {:#?}\n{}", self.outputs, self.reply))
    }
}

/// Asks for the borrow, approves every card, and prints when each step happened.
async fn attempt(h: &mut Harness) -> Attempt {
    let started = Instant::now();
    h.prompt(PROMPT);
    let (mut cards, mut outputs) = (Vec::new(), Vec::new());
    eprintln!("\nthe turn, seconds after the prompt:");
    let reply = loop {
        let event = h.next_within(tornado::TIMEOUT).await;
        let at = started.elapsed().as_secs_f64();
        let line = match event {
            AgentEvent::Confirm {
                command,
                preview,
                reply,
            } => {
                cards.push((command.clone(), preview.unwrap_or_default()));
                reply.send(true).unwrap();
                format!("card: {command}")
            }
            AgentEvent::ToolStarted { command } => format!("start: {command}"),
            AgentEvent::ToolFinished(result) => {
                let line = format!("done ({}): {}", result.exit_code, result.command);
                outputs.push(result);
                line
            }
            AgentEvent::Flow(FlowEvent::Step { stage, state, .. }) => {
                format!("{stage:?} {state:?}")
            }
            AgentEvent::Reply(reply) => break reply,
            AgentEvent::Error(error) => panic!("{error}"),
            _ => continue,
        };
        eprintln!(
            "  {at:>6.1}  {}",
            line.chars().take(150).collect::<String>()
        );
    };
    Attempt {
        cards,
        outputs,
        reply,
    }
}

/// Mines a block with base fee `base` and returns what kohaku then prices the fee at: the
/// bundler's slow maxFee + maxPriorityFee.
async fn quote_at(provider: &impl Provider, bundler: &Alto, base: U256) -> U256 {
    let _: Value = provider
        .raw_request("anvil_setNextBlockBaseFeePerGas".into(), (base,))
        .await
        .unwrap();
    let _: Value = provider.raw_request("evm_mine".into(), ()).await.unwrap();
    let price = bundler
        .call("pimlico_getUserOperationGasPrice", json!([]))
        .await
        .unwrap();
    hex_u256(&price["slow"]["maxFeePerGas"]) + hex_u256(&price["slow"]["maxPriorityFeePerGas"])
}

/// Sets the fork's base fee so the bundler quotes about `target`, from two probes of its quote,
/// which follows the base fee linearly. Returns the price quoted.
async fn price_gas(provider: &impl Provider, bundler: &Alto, target: U256) -> U256 {
    let (low, high) = (U256::from(10u64.pow(9)), U256::from(10 * 10u64.pow(9)));
    let (at_low, at_high) = (
        quote_at(provider, bundler, low).await,
        quote_at(provider, bundler, high).await,
    );
    assert!(
        at_low < target && at_low < at_high,
        "{at_low} {at_high} {target}"
    );
    let base = low + (target - at_low) * (high - low) / (at_high - at_low);
    quote_at(provider, bundler, base).await
}

/// The receipts of every transaction to the EntryPoint in blocks `from..=to`.
async fn to_entry_point(provider: &impl Provider, from: u64, to: u64) -> Vec<TransactionReceipt> {
    let mut found = Vec::new();
    for block in from..=to {
        let receipts = provider
            .get_block_receipts(block.into())
            .await
            .unwrap()
            .unwrap_or_default();
        found.extend(receipts.into_iter().filter(|r| r.to == Some(ENTRY_POINT)));
    }
    found
}

#[tokio::test]
#[ignore = "forks Sepolia over the network; needs edw, anvil, alto and Docker"]
async fn the_private_borrow_runs_end_to_end_on_a_sepolia_fork() {
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed (EDW_BIN)");
        return;
    };
    let Some(alto) = alto_binary() else {
        eprintln!("skipping: alto is not installed (ALTO_BIN, or alto on PATH)");
        return;
    };
    if !sandbox::docker_available().await {
        eprintln!("skipping: Docker is not running");
        return;
    }
    let mut stages = Vec::new();

    let started = Instant::now();
    let Some((chain, fork_block)) = fork_sepolia().await else {
        return;
    };
    eprintln!("forked Sepolia at block {fork_block}");
    lap(&mut stages, "fork", started);

    let started = Instant::now();
    let logs = tempfile::tempdir().unwrap();
    let bundler = Alto::start(&alto, &chain, logs.path().join("alto.log")).await;
    lap(&mut stages, "bundler", started);

    let started = Instant::now();
    let (wallet, profile) = wallet_on(
        &binary,
        "fork-private-borrow",
        &chain,
        &bundler.url,
        parse_ether("1").unwrap(),
    )
    .await;
    lap(&mut stages, "wallet", started);

    let started = Instant::now();
    for _ in 0..2 {
        let shield = edw_ok(&wallet.config, &SHIELD_ETH).await;
        assert_eq!(
            shield.document().unwrap()["kind"],
            "edw/shield",
            "{shield:?}"
        );
    }
    lap(&mut stages, "shield 2 x 0.1 ETH", started);

    let started = Instant::now();
    assert_eq!(
        private(&wallet.config, is_eth).await,
        owned(("0.2", "0")),
        "edw lists both notes as mined"
    );
    lap(&mut stages, "notes listed as mined", started);

    let provider = ProviderBuilder::new().connect_http(chain.endpoint_url());
    let skill = manifest::load(&shipped().join("private-aave-borrow")).unwrap();
    let aave_pool = skill.manifest.contract("pool").unwrap().address[&SEPOLIA];
    let dai = skill.manifest.token("dai").unwrap().address[&SEPOLIA];
    let tornado_dai = Pool::SEPOLIA_DAI_100.address;
    let head_before = provider.get_block_number().await.unwrap();
    let pool_dai_before = view(&provider, dai, balanceOfCall { owner: tornado_dai }).await;
    let profile_eth_before = provider.get_balance(profile).await.unwrap();
    let profile_nonce_before = provider.get_transaction_count(profile).await.unwrap();

    let started = Instant::now();
    let mut h = Harness::start_with_skills(
        wallet,
        ModelHandle::named("scripted", ScriptedModel::default()),
        None,
        skill_set(&shipped()),
    );
    let borrowed = attempt(&mut h).await;
    lap(&mut stages, "private borrow turn", started);

    let [(command, card)] = borrowed.cards.as_slice() else {
        panic!("one card: {:?}\n{}", borrowed.cards, borrowed.reply);
    };
    eprintln!("\nthe card:\n{card}\n");
    assert!(
        command.starts_with(
            "edw unshield --token ETH --amount-formatted 0.1 --tail-calls <4 calls> --expected-fresh-address 0x"
        ),
        "{command}"
    );
    eprintln!("the unshield, edw's own log, seconds after its first line:");
    for (at, line) in timeline(&last_run(&h.wallet, " unshield "))
        .into_iter()
        .skip(1)
    {
        let at = at.map_or("     ~".into(), |s| format!("{s:>6.1}"));
        eprintln!("  {at}  {}", line.chars().take(140).collect::<String>());
    }
    let unshield = borrowed.unshield();
    assert!(unshield.ok(), "{unshield:?}\n{}", bundler.log_tail());
    let report = unshield.document().unwrap();
    assert_eq!(report["kind"], "edw/unshield", "{report}");
    let fresh: Address = report["fresh_address"].as_str().unwrap().parse().unwrap();
    let user_op: B256 = report["user_operation"].as_str().unwrap().parse().unwrap();
    let sent_in: B256 = report["transaction"].as_str().unwrap().parse().unwrap();
    assert!(
        command.ends_with(&format!("{fresh} --profile 0/0")),
        "{command}"
    );

    let started = Instant::now();
    let head_after = provider.get_block_number().await.unwrap();
    let bundles = to_entry_point(&provider, head_before + 1, head_after).await;
    let [bundle] = bundles.as_slice() else {
        panic!(
            "one transaction to the EntryPoint during the borrow, not {}",
            bundles.len()
        );
    };
    assert_eq!(bundle.transaction_hash, sent_in);
    assert!(bundle.status(), "{bundle:?}");
    let user_ops: Vec<_> = bundle
        .inner
        .logs()
        .iter()
        .filter(|log| log.topic0() == Some(&UserOperationEvent::SIGNATURE_HASH))
        .map(|log| UserOperationEvent::decode_log(&log.inner).unwrap().data)
        .collect();
    let [op] = user_ops.as_slice() else {
        panic!("one user operation in the bundle, not {}", user_ops.len());
    };
    assert_eq!(
        (op.userOpHash, op.sender, op.success),
        (user_op, fresh, true)
    );
    assert_eq!(
        op.paymaster,
        Pool::SEPOLIA_ETHER_01.paymaster.unwrap().address
    );
    let code = provider.get_code_at(fresh).await.unwrap();
    assert!(
        code.starts_with(&[0xef, 0x01, 0x00]),
        "the fresh account is an EIP-7702 delegation: {code}"
    );

    let account = view(&provider, aave_pool, getUserAccountDataCall { user: fresh }).await;
    assert!(
        account.totalCollateralBase > U256::ZERO,
        "Aave holds collateral for {fresh}"
    );
    let debt_token = view(&provider, aave_pool, getReserveDataCall { asset: dai })
        .await
        .variableDebtTokenAddress;
    let debt = view(&provider, debt_token, balanceOfCall { owner: fresh }).await;
    let hundred = parse_ether("100").unwrap();
    assert!(debt >= hundred, "variable DAI debt {debt} for {fresh}");
    let pool_dai_after = view(&provider, dai, balanceOfCall { owner: tornado_dai }).await;
    assert_eq!(
        pool_dai_after - pool_dai_before,
        hundred,
        "the Tornado DAI pool took exactly 100 DAI"
    );
    assert_eq!(
        view(&provider, dai, balanceOfCall { owner: fresh }).await,
        U256::ZERO
    );
    assert_eq!(
        (
            provider.get_balance(profile).await.unwrap(),
            provider.get_transaction_count(profile).await.unwrap()
        ),
        (profile_eth_before, profile_nonce_before),
        "nothing was sent from the profile's public address"
    );
    assert_eq!(
        private(&h.wallet.config, is_dai).await,
        owned(("100", "0")),
        "edw lists a mined 100 DAI note"
    );
    assert_eq!(
        private(&h.wallet.config, is_eth).await,
        owned(("0.1", "0")),
        "one 0.1 ETH note was spent"
    );
    let [record] = records(&h.wallet).try_into().unwrap();
    assert_eq!(
        record["consumed"].as_str(),
        Some(format!("user operation {user_op}").as_str()),
        "{record}"
    );
    lap(&mut stages, "checks", started);

    let fee = parse_ether(report["fee"].as_str().unwrap()).unwrap();
    let reserve = parse_ether("0.1").unwrap() * U256::from(FEE_RESERVE_BPS) / U256::from(10_000);
    let quoted = bundler
        .call("eth_getUserOperationByHash", json!([user_op]))
        .await
        .unwrap();
    let fields = &quoted["userOperation"];
    let gas: U256 = [
        "callGasLimit",
        "verificationGasLimit",
        "preVerificationGas",
        "paymasterVerificationGasLimit",
        "paymasterPostOpGasLimit",
    ]
    .iter()
    .map(|field| hex_u256(&fields[field]))
    .sum();
    let price = hex_u256(&fields["maxFeePerGas"]) + hex_u256(&fields["maxPriorityFeePerGas"]);
    // kohaku proves the fee as gas limit x (maxFee + maxPriorityFee), plus 1%.
    let break_even = reserve * U256::from(10_000) / (gas * U256::from(10_100));
    let gwei = |wei: U256| format_units(wei, "gwei").unwrap();
    eprintln!(
        "\nfee: proven {} ETH = {:.1}% of the {} ETH reserve ({}% of 0.1 ETH)",
        format_ether(fee),
        fee.to::<u128>() as f64 / reserve.to::<u128>() as f64 * 100.0,
        format_ether(reserve),
        FEE_RESERVE_BPS / 100
    );
    eprintln!(
        "     at gas limit {gas} and maxFee + maxPriorityFee {} gwei; the reserve covers up to {} gwei",
        gwei(price),
        gwei(break_even)
    );
    eprintln!(
        "     paid on chain {} ETH ({} gas); the fresh account keeps {} ETH",
        format_ether(op.actualGasCost),
        op.actualGasUsed,
        format_ether(provider.get_balance(fresh).await.unwrap())
    );
    eprintln!(
        "aave: {fresh} has {} USD collateral, {} USD debt, {} DAI variable debt, health factor {}",
        format_units(account.totalCollateralBase, 8).unwrap(),
        format_units(account.totalDebtBase, 8).unwrap(),
        format_ether(debt),
        format_ether(account.healthFactor)
    );
    assert!(fee <= reserve, "the proven fee fits in the reserve");

    // The fee outgrows the reserve once gas costs more than `break_even`. At 1.5 times that, the
    // bundler's estimate still passes on edw's simulation funding (a tenth of the note) and edw's
    // own check refuses; at 3 times, the estimate itself reverts. Either way nothing is sent.
    for (stage, half_steps, edw_explains) in [
        ("borrow at 1.5x gas", 3u64, true),
        ("borrow at 3x gas", 6, false),
    ] {
        let target = break_even * U256::from(half_steps) / U256::from(2);
        let price = price_gas(&provider, &bundler, target).await;
        let head_before = provider.get_block_number().await.unwrap();
        let started = Instant::now();
        let expensive = attempt(&mut h).await;
        lap(&mut stages, stage, started);
        assert_eq!(expensive.cards.len(), 1, "{:?}", expensive.cards);
        let refused = expensive.unshield();
        let error = refused.document().unwrap();
        let message = error["message"].as_str().unwrap_or_default();
        eprintln!("\nquoted {} gwei, edw refused: {message}", gwei(price));
        assert_eq!(
            (refused.exit_code, error["kind"].as_str()),
            (1, Some("edw/error")),
            "{refused:?}"
        );
        if edw_explains {
            assert!(
                message.contains("sponsor fee") && message.contains("does not cover 0.09"),
                "{error}"
            );
        }
        let head_after = provider.get_block_number().await.unwrap();
        assert!(
            to_entry_point(&provider, head_before + 1, head_after)
                .await
                .is_empty(),
            "nothing reached the EntryPoint"
        );
        assert_eq!(
            private(&h.wallet.config, is_eth).await,
            owned(("0.1", "0")),
            "the note is still there"
        );
        assert_eq!(
            view(&provider, dai, balanceOfCall { owner: tornado_dai }).await,
            pool_dai_after
        );
        let [first, second] = records(&h.wallet).try_into().unwrap();
        let retry = if first["id"] == record["id"] {
            second
        } else {
            first
        };
        assert!(
            retry["consumed"].is_null(),
            "the refused attempt's preparation is kept for a retry: {retry}"
        );
    }

    eprintln!("\nstages:");
    for (stage, took) in &stages {
        eprintln!("  {stage:<22} {:>6.1} s", took.as_secs_f64());
    }
}
