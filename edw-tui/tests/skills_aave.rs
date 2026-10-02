//! The shipped `aave-v3-lend` skill.
//!
//! Offline: the manifest pins what it should. With `-- --ignored` (network):
//! - every pinned address is checked against Aave's own registry on mainnet and Sepolia;
//! - supply and withdraw run end to end on an anvil mainnet fork, through the real agent loop,
//!   Docker and edw (RPC: `ETH_RPC_URL`, default a public no-tracking endpoint).

mod common;

use std::{path::Path, sync::Arc};

use alloy_node_bindings::Anvil;
use alloy_primitives::{Address, U256, address};
use alloy_provider::{Provider, ProviderBuilder};
use alloy_sol_types::{SolCall, sol};
use common::{
    Harness, TempWallet, edw_binary,
    recorder::{Recorder, call},
};
use edw_tui::{
    interim::Interim,
    skills::{
        catalog::{self, Catalog, SkillState},
        manifest::{self, Skill},
        sandbox::{self, Runner},
        tools::SkillSet,
    },
};
use rig_agent::ModelHandle;
use rig_core::message::AssistantContent;
use serde_json::json;

const MAINNET: u64 = 1;
const SEPOLIA: u64 = 11_155_111;
const MAINNET_PROVIDER: Address = address!("0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e");
const SEPOLIA_PROVIDER: Address = address!("0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A");

sol! {
    function getPool() returns (address);
    function decimals() returns (uint8);
    function balanceOf(address owner) returns (uint256);
    struct ReserveDataLegacy {
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
    function getReserveData(address asset) returns (ReserveDataLegacy);
}

fn root() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
}

fn skill() -> Skill {
    manifest::load(&root().join("skills/aave-v3-lend")).unwrap()
}

#[test]
fn the_manifest_pins_the_pool_and_only_supply_and_withdraw() {
    let skill = skill();
    let m = &skill.manifest;
    assert_eq!(m.requires, ["defi-data"]);
    assert!(m.hosts.is_empty(), "everything it needs comes over RPC");
    assert_eq!(m.contracts.len(), 1);
    let pool = m.contract("pool").unwrap();
    let functions: Vec<String> = pool.functions.iter().map(|f| f.signature()).collect();
    assert_eq!(
        functions,
        [
            "supply(address,uint256,address,uint16)",
            "withdraw(address,uint256,address)"
        ]
    );
    for action in &m.actions {
        assert!(
            action.approves.iter().all(|a| a == "pool"),
            "{}",
            action.tool.name
        );
    }
    for id in ["usdc", "usdt", "dai"] {
        assert!(m.token(id).unwrap().movable, "{id}");
        assert!(!m.token(&format!("a{id}")).unwrap().movable, "a{id}");
    }
    for t in &m.tokens {
        assert!(
            t.address.contains_key(&MAINNET) && t.address.contains_key(&SEPOLIA),
            "{}",
            t.id
        );
    }
    assert!(pool.address.contains_key(&MAINNET) && pool.address.contains_key(&SEPOLIA));
}

async fn view<C: SolCall>(provider: &impl Provider, to: Address, call: C) -> C::Return {
    let tx = alloy_rpc_types_eth::TransactionRequest::default()
        .to(to)
        .input(call.abi_encode().into());
    let out = provider.call(tx).await.unwrap();
    C::abi_decode_returns(&out).unwrap()
}

async fn check_against_aave(rpc: &str, chain: u64, registry: Address) {
    let provider = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    assert_eq!(provider.get_chain_id().await.unwrap(), chain);
    let skill = skill();
    let m = &skill.manifest;
    let pool = m.contract("pool").unwrap().address[&chain];
    assert_eq!(
        view(&provider, registry, getPoolCall {}).await,
        pool,
        "chain {chain}: pool"
    );
    for id in ["usdc", "usdt", "dai"] {
        let token = m.token(id).unwrap();
        let address = token.address[&chain];
        let reserve = view(&provider, pool, getReserveDataCall { asset: address }).await;
        let a_token = m.token(&format!("a{id}")).unwrap();
        assert_eq!(
            reserve.aTokenAddress, a_token.address[&chain],
            "chain {chain}: a{id}"
        );
        assert_eq!(
            view(&provider, address, decimalsCall {}).await,
            token.decimals,
            "chain {chain}: {id}"
        );
        assert_eq!(
            view(&provider, a_token.address[&chain], decimalsCall {}).await,
            a_token.decimals
        );
    }
}

fn mainnet_rpc() -> String {
    std::env::var("ETH_RPC_URL").unwrap_or_else(|_| "https://ethereum-rpc.publicnode.com".into())
}

#[tokio::test]
#[ignore = "reads mainnet and Sepolia over the network"]
async fn every_pinned_address_is_aaves_own() {
    check_against_aave(&mainnet_rpc(), MAINNET, MAINNET_PROVIDER).await;
    let sepolia = std::env::var("EDW_TUI_SEPOLIA_RPC")
        .unwrap_or_else(|_| "https://ethereum-sepolia-rpc.publicnode.com".into());
    check_against_aave(&sepolia, SEPOLIA, SEPOLIA_PROVIDER).await;
}

fn shipped() -> Arc<SkillSet> {
    let mut installed = catalog::discover(&[root().join("skills")]);
    for i in &mut installed {
        i.state = SkillState::Ready;
    }
    catalog::resolve(&mut installed, &edw_tui::edw::tool_names(), true);
    Arc::new(SkillSet::new(
        Catalog::from_installed(&installed),
        &installed,
        Runner::from_env(),
    ))
}

#[tokio::test]
#[ignore = "forks mainnet over the network; needs anvil, edw and Docker"]
async fn supplies_and_withdraws_usdc_on_a_mainnet_fork() {
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return;
    };
    if !sandbox::docker_available().await {
        eprintln!("skipping: Docker is not running");
        return;
    }
    let node = Anvil::new()
        .fork(mainnet_rpc())
        .try_spawn()
        .expect("anvil fork");
    let rpc = node.endpoint();
    let wallet = TempWallet::new(binary, "aave-fork");
    wallet.edw(&["unlock", "--network", "mainnet"]).await;
    let mut interim = wallet.interim(Some(rpc.clone()), false);
    interim.mainnet_fork = true;

    let skill = skill();
    let usdc = skill.manifest.token("usdc").unwrap().address[&MAINNET];
    let ausdc = skill.manifest.token("ausdc").unwrap().address[&MAINNET];
    let me = Interim::new(interim.clone()).address(None).await.unwrap();
    let provider = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    let _: () = provider
        .raw_request("anvil_setBalance".into(), (me, U256::from(10u128.pow(19))))
        .await
        .unwrap();
    let _: () = provider
        .raw_request(
            "anvil_dealERC20".into(),
            (me, usdc, U256::from(1_000_000_000u64)),
        )
        .await
        .unwrap();
    let balance = |token: Address| {
        let provider = provider.clone();
        async move { view(&provider, token, balanceOfCall { owner: me }).await }
    };
    assert_eq!(balance(usdc).await, U256::from(1_000_000_000u64));

    let model = Recorder::new(vec![
        call("load_skill", json!({"name": "aave-v3-lend"})),
        call("aave_supply", json!({"token": "USDC", "amount": "100"})),
        AssistantContent::text("supplied"),
        call("aave_withdraw", json!({"token": "USDC", "amount": "all"})),
        AssistantContent::text("withdrawn"),
    ]);
    let mut h = Harness::start_with_skills(
        wallet,
        ModelHandle::named("recorder", model),
        Some(interim),
        shipped(),
    );

    let turn = h.turn("put 100 USDC on aave", true).await;
    let preview = turn
        .previews
        .first()
        .unwrap_or_else(|| panic!("no review: {turn:?}"));
    eprintln!("{preview}");
    for needle in [
        "Skill    aave-v3-lend",
        "approve 100 USDC for Aave Pool",
        "Aave Pool.supply(asset=USDC, amount=100000000, onBehalfOf=you, referralCode=0)",
        "−100 USDC",
        "aUSDC",
    ] {
        assert!(preview.contains(needle), "missing {needle:?} in\n{preview}");
    }
    assert!(
        turn.outputs.last().unwrap().contains("all succeeded"),
        "{turn:?}"
    );
    assert_eq!(balance(usdc).await, U256::from(900_000_000u64));
    assert!(balance(ausdc).await >= U256::from(99_990_000u64));

    let turn = h.turn("take it all back", true).await;
    let preview = &turn.previews[0];
    eprintln!("{preview}");
    assert!(preview.contains("amount=all"), "{preview}");
    assert!(
        turn.outputs.last().unwrap().contains("succeeded"),
        "{turn:?}"
    );
    assert!(balance(usdc).await >= U256::from(999_990_000u64));
    assert_eq!(balance(ausdc).await, U256::ZERO);
}
