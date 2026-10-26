//! The shipped `aave-v3-lend` skill.
//!
//! Offline: the manifest pins what it should. With `-- --ignored` (network):
//! - every pinned address is checked against Aave's own registry on mainnet and Sepolia, on an
//!   anvil fork of each;
//! - USDC supply and withdraw, and ETH supply, borrow, repay and withdraw through the WETH gateway,
//!   run end to end on anvil forks, through the real agent loop, Docker and edw (RPC:
//!   `ETH_RPC_URL` and `EDW_TUI_SEPOLIA_RPC`, default public no-tracking endpoints).

mod common;

use std::{path::Path, sync::Arc};

use alloy_node_bindings::{Anvil, AnvilInstance};
use alloy_primitives::{Address, U256, address, keccak256};
use alloy_provider::{Provider, ProviderBuilder};
use alloy_sol_types::{SolCall, sol};
use common::{
    Harness, TempWallet, Turn, edw_binary,
    recorder::{Recorder, call},
};
use edw_tui::{
    interim::Interim,
    skills::{
        catalog::{self, Catalog, SkillState},
        manifest::{self, Approval, Skill},
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
    function allowance(address owner, address spender) returns (uint256);
    function borrowAllowance(address fromUser, address toUser) returns (uint256);
    function getWETHAddress() returns (address);
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

fn signatures(skill: &Skill, contract: &str) -> Vec<String> {
    let c = skill.manifest.contract(contract).unwrap();
    c.functions.iter().map(|f| f.signature()).collect()
}

/// What the skill may ever call, and what each of its actions may grant to whom.
#[test]
fn the_manifest_pins_aaves_pool_and_weth_gateway_and_scopes_every_grant() {
    let skill = skill();
    let m = &skill.manifest;
    assert_eq!(m.requires, ["defi-data"]);
    assert!(m.hosts.is_empty(), "everything it needs comes over RPC");
    assert_eq!(m.contracts.len(), 2);
    assert_eq!(
        signatures(&skill, "pool"),
        [
            "supply(address,uint256,address,uint16)",
            "withdraw(address,uint256,address)",
            "borrow(address,uint256,uint256,uint16,address)",
            "repay(address,uint256,uint256,address)",
            "setUserUseReserveAsCollateral(address,bool)",
        ]
    );
    assert_eq!(
        signatures(&skill, "gateway"),
        [
            "depositETH(address,address,uint16)",
            "withdrawETH(address,uint256,address)",
            "borrowETH(address,uint256,uint16)",
            "borrowETH(address,uint256,uint256,uint16)",
            "repayETH(address,uint256,address)",
            "repayETH(address,uint256,uint256,address)",
        ]
    );
    let approves = |name: &str| skill.action(name).unwrap().approves.clone();
    assert_eq!(approves("aave_supply"), ["pool"]);
    assert_eq!(approves("aave_repay"), ["pool"]);
    assert_eq!(approves("aave_withdraw"), ["gateway"]);
    assert_eq!(approves("aave_borrow"), ["gateway"]);
    assert!(approves("aave_collateral").is_empty());

    let only = |ids: &[&str]| Some(ids.iter().map(|i| (*i).to_owned()).collect());
    for id in ["usdc", "usdt", "dai", "weth"] {
        let policy = |id: &str| m.token(id).unwrap().approval.clone();
        assert_eq!(
            policy(id),
            Approval::Allowance {
                only: only(&["pool"])
            },
            "{id}"
        );
        let receipt = format!("a{id}");
        let debt = format!("{id}_debt");
        if id == "weth" {
            // The gateway pulls aWETH to withdraw ETH, and borrows ETH in the user's name.
            assert_eq!(
                policy(&receipt),
                Approval::Allowance {
                    only: only(&["gateway"])
                }
            );
            assert_eq!(
                policy(&debt),
                Approval::Delegation {
                    to: vec!["gateway".into()]
                }
            );
        } else {
            assert_eq!(policy(&receipt), Approval::Never, "{receipt}");
            assert_eq!(policy(&debt), Approval::Never, "{debt}");
        }
    }
    for t in &m.tokens {
        assert!(
            t.address.contains_key(&MAINNET) && t.address.contains_key(&SEPOLIA),
            "{}",
            t.id
        );
    }
    for c in &m.contracts {
        assert!(
            c.address.contains_key(&MAINNET) && c.address.contains_key(&SEPOLIA),
            "{}",
            c.id
        );
    }
    let account = &m.review_reads[0];
    assert_eq!(account.function.name, "getUserAccountData");
    assert!(account.show.iter().any(|s| s.name == "healthFactor"));
    assert!(account.show.iter().any(|s| s.name == "debt"));
}

async fn view<C: SolCall>(provider: &impl Provider, to: Address, call: C) -> C::Return {
    let tx = alloy_rpc_types_eth::TransactionRequest::default()
        .to(to)
        .input(call.abi_encode().into());
    let out = provider.call(tx).await.unwrap();
    C::abi_decode_returns(&out).unwrap()
}

/// Whether `code` dispatches `signature`: Solidity's selector table pushes each selector with
/// PUSH4 (0x63).
fn dispatches(code: &[u8], signature: &str) -> bool {
    let selector = &keccak256(signature)[..4];
    code.windows(5).any(|w| w[0] == 0x63 && &w[1..] == selector)
}

async fn check_against_aave(rpc: &str, chain: u64, registry: Address) {
    let node = Anvil::new().fork(rpc).try_spawn().expect("anvil fork");
    let provider = ProviderBuilder::new().connect_http(node.endpoint_url());
    assert_eq!(provider.get_chain_id().await.unwrap(), chain);
    let skill = skill();
    let m = &skill.manifest;
    let pool = m.contract("pool").unwrap().address[&chain];
    assert_eq!(
        view(&provider, registry, getPoolCall {}).await,
        pool,
        "chain {chain}: pool"
    );
    for id in ["usdc", "usdt", "dai", "weth"] {
        let token = m.token(id).unwrap();
        let address = token.address[&chain];
        let reserve = view(&provider, pool, getReserveDataCall { asset: address }).await;
        let a_token = m.token(&format!("a{id}")).unwrap();
        let debt = m.token(&format!("{id}_debt")).unwrap();
        assert_eq!(
            reserve.aTokenAddress, a_token.address[&chain],
            "chain {chain}: a{id}"
        );
        assert_eq!(
            reserve.variableDebtTokenAddress, debt.address[&chain],
            "chain {chain}: {id}_debt"
        );
        for t in [token, a_token, debt] {
            assert_eq!(
                view(&provider, t.address[&chain], decimalsCall {}).await,
                t.decimals,
                "chain {chain}: {} decimals",
                t.id
            );
        }
    }
    let gateway = m.contract("gateway").unwrap().address[&chain];
    let code = provider.get_code_at(gateway).await.unwrap();
    assert!(!code.is_empty(), "chain {chain}: the gateway has code");
    assert_eq!(
        view(&provider, gateway, getWETHAddressCall {}).await,
        m.token("weth").unwrap().address[&chain],
        "chain {chain}: the gateway wraps the pinned WETH"
    );
    // The forms the scripts send here (aave_common.GATEWAY_TAKES_RATE_MODE): Aave v3.2 dropped
    // the rate-mode argument; Sepolia's gateway predates that.
    let legacy = chain == SEPOLIA;
    for (signature, expected) in [
        ("depositETH(address,address,uint16)", true),
        ("withdrawETH(address,uint256,address)", true),
        ("borrowETH(address,uint256,uint16)", !legacy),
        ("repayETH(address,uint256,address)", !legacy),
        ("borrowETH(address,uint256,uint256,uint16)", legacy),
        ("repayETH(address,uint256,uint256,address)", legacy),
    ] {
        assert_eq!(
            dispatches(&code, signature),
            expected,
            "chain {chain}: gateway {signature}"
        );
    }
}

fn mainnet_rpc() -> String {
    std::env::var("ETH_RPC_URL").unwrap_or_else(|_| "https://ethereum-rpc.publicnode.com".into())
}

fn sepolia_rpc() -> String {
    std::env::var("EDW_TUI_SEPOLIA_RPC")
        .unwrap_or_else(|_| "https://ethereum-sepolia-rpc.publicnode.com".into())
}

#[tokio::test]
#[ignore = "forks mainnet and Sepolia over the network; needs anvil"]
async fn every_pinned_address_is_aaves_own() {
    check_against_aave(&mainnet_rpc(), MAINNET, MAINNET_PROVIDER).await;
    check_against_aave(&sepolia_rpc(), SEPOLIA, SEPOLIA_PROVIDER).await;
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

/// An anvil fork of `rpc`, a fresh wallet unlocked on `network` with 10 ETH, and the real agent
/// loop over the shipped skills, driven by `replies`. `None` (with a message) without edw or
/// Docker.
struct Fork {
    h: Harness,
    rpc: String,
    me: Address,
    chain: u64,
    _node: AnvilInstance,
}

impl Fork {
    async fn start(
        name: &str,
        rpc: String,
        network: &str,
        replies: Vec<AssistantContent>,
    ) -> Option<Self> {
        let Some(binary) = edw_binary() else {
            eprintln!("skipping: edw is not installed");
            return None;
        };
        if !sandbox::docker_available().await {
            eprintln!("skipping: Docker is not running");
            return None;
        }
        let node = Anvil::new().fork(rpc).try_spawn().expect("anvil fork");
        let rpc = node.endpoint();
        let wallet = TempWallet::new(binary, name);
        wallet.edw(&["unlock", "--network", network]).await;
        let mut interim = wallet.interim(Some(rpc.clone()), network == "sepolia");
        interim.mainnet_fork = network == "mainnet";
        let me = Interim::new(interim.clone()).address(None).await.unwrap();
        let provider = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
        let _: () = provider
            .raw_request("anvil_setBalance".into(), (me, U256::from(10u128.pow(19))))
            .await
            .unwrap();
        let chain = provider.get_chain_id().await.unwrap();
        let h = Harness::start_with_skills(
            wallet,
            ModelHandle::named("recorder", Recorder::new(replies)),
            Some(interim),
            shipped(),
        );
        Some(Self {
            h,
            rpc,
            me,
            chain,
            _node: node,
        })
    }

    fn provider(&self) -> impl Provider + use<> {
        ProviderBuilder::new().connect_http(self.rpc.parse().unwrap())
    }

    async fn balance(&self, token: Address) -> U256 {
        view(&self.provider(), token, balanceOfCall { owner: self.me }).await
    }

    fn token(&self, id: &str) -> Address {
        skill().manifest.token(id).unwrap().address[&self.chain]
    }

    fn contract(&self, id: &str) -> Address {
        skill().manifest.contract(id).unwrap().address[&self.chain]
    }

    /// One user turn, approved; returns its review after checking it reads `needles` and that
    /// every transaction succeeded.
    async fn approved(&mut self, prompt: &str, needles: &[&str]) -> String {
        let turn: Turn = self.h.turn(prompt, true).await;
        let preview = turn
            .previews
            .first()
            .unwrap_or_else(|| panic!("no review for {prompt:?}: {turn:?}"))
            .clone();
        eprintln!("{preview}");
        for needle in needles {
            assert!(preview.contains(needle), "missing {needle:?} in\n{preview}");
        }
        assert!(
            turn.outputs.last().unwrap().contains("succeeded"),
            "{turn:?}"
        );
        preview
    }
}

#[tokio::test]
#[ignore = "forks mainnet over the network; needs anvil, edw and Docker"]
async fn supplies_and_withdraws_usdc_on_a_mainnet_fork() {
    let Some(mut f) = Fork::start(
        "aave-usdc",
        mainnet_rpc(),
        "mainnet",
        vec![
            call("load_skill", json!({"name": "aave-v3-lend"})),
            call("aave_supply", json!({"token": "USDC", "amount": "100"})),
            AssistantContent::text("supplied"),
            call("aave_withdraw", json!({"token": "USDC", "amount": "all"})),
            AssistantContent::text("withdrawn"),
        ],
    )
    .await
    else {
        return;
    };
    let (usdc, ausdc) = (f.token("usdc"), f.token("ausdc"));
    let _: () = f
        .provider()
        .raw_request(
            "anvil_dealERC20".into(),
            (f.me, usdc, U256::from(1_000_000_000u64)),
        )
        .await
        .unwrap();
    assert_eq!(f.balance(usdc).await, U256::from(1_000_000_000u64));

    f.approved(
        "put 100 USDC on aave",
        &[
            "Skill    aave-v3-lend",
            "approve 100 USDC for Aave Pool",
            "Aave Pool.supply(asset=USDC, amount=100 USDC (100000000), onBehalfOf=you, referralCode=0)",
            "−100 USDC",
            "aUSDC",
            "Aave account (simulated, before → after)",
        ],
    )
    .await;
    assert_eq!(f.balance(usdc).await, U256::from(900_000_000u64));
    assert!(f.balance(ausdc).await >= U256::from(99_990_000u64));

    f.approved("take it all back", &["amount=all"]).await;
    assert!(f.balance(usdc).await >= U256::from(999_990_000u64));
    assert_eq!(f.balance(ausdc).await, U256::ZERO);
}

/// ETH through the WETH gateway: supplied as the value, borrowed under a credit delegation of
/// exactly the amount, repaid in full with the gateway returning the margin, and withdrawn
/// under an exact aWETH approval. Every grant is used up, so none is left behind.
#[tokio::test]
#[ignore = "forks mainnet over the network; needs anvil, edw and Docker"]
async fn supplies_borrows_repays_and_withdraws_eth_through_the_gateway_on_a_mainnet_fork() {
    let Some(mut f) = Fork::start(
        "aave-eth",
        mainnet_rpc(),
        "mainnet",
        vec![
            call("load_skill", json!({"name": "aave-v3-lend"})),
            call("aave_supply", json!({"token": "ETH", "amount": "2"})),
            AssistantContent::text("supplied"),
            call("aave_borrow", json!({"token": "ETH", "amount": "0.5"})),
            AssistantContent::text("borrowed"),
            call("aave_repay", json!({"token": "ETH", "amount": "all"})),
            AssistantContent::text("repaid"),
            call("aave_withdraw", json!({"token": "ETH", "amount": "all"})),
            AssistantContent::text("withdrawn"),
        ],
    )
    .await
    else {
        return;
    };
    let (aweth, debt, gateway) = (
        f.token("aweth"),
        f.token("weth_debt"),
        f.contract("gateway"),
    );
    let half = U256::from(5u64) * U256::from(10u64).pow(U256::from(17u64));
    let two = U256::from(2u64) * U256::from(10u64).pow(U256::from(18u64));

    f.approved(
        "put 2 ETH on aave",
        &[
            "Aave WETH Gateway.depositETH(pool=Aave Pool, onBehalfOf=you, referralCode=0) with 2 ETH",
            "−2 ETH",
            "aWETH",
            "health factor  ∞ → ∞",
        ],
    )
    .await;
    let supplied = f.balance(aweth).await;
    assert!(
        supplied >= two - U256::from(2u8) && supplied < two + U256::from(10u64.pow(12)),
        "about 2 aWETH, plus interest by the time it is read: {supplied}"
    );

    let eth_before = f.provider().get_balance(f.me).await.unwrap();
    f.approved(
        "borrow 0.5 ETH from aave",
        &[
            "allow Aave WETH Gateway to take on up to 0.5 WETH debt in your name (credit delegation)",
            "Aave WETH Gateway.borrowETH(pool=Aave Pool, amount=0.5 WETH (500000000000000000), referralCode=0)",
            "+0.5 ETH",
            "debt           0.00 → ",
            "health factor  ∞ → ",
        ],
    )
    .await;
    assert!(f.balance(debt).await >= half);
    assert!(f.provider().get_balance(f.me).await.unwrap() > eth_before);
    let delegated = view(
        &f.provider(),
        debt,
        borrowAllowanceCall {
            fromUser: f.me,
            toUser: gateway,
        },
    )
    .await;
    assert_eq!(
        delegated,
        U256::ZERO,
        "the delegation was exactly the amount"
    );

    f.approved(
        "repay all my ETH debt on aave",
        &[
            "Aave WETH Gateway.repayETH(pool=Aave Pool, amount=all, onBehalfOf=you) with 0.50005",
            "Skill says (not checked): Covers the debt plus 0.01%",
        ],
    )
    .await;
    assert_eq!(f.balance(debt).await, U256::ZERO);

    f.approved(
        "withdraw all my ETH from aave",
        &[
            "aWETH for Aave WETH Gateway",
            "Aave WETH Gateway.withdrawETH(pool=Aave Pool, amount=2",
            "health factor  ∞ → ∞",
        ],
    )
    .await;
    let dust = f.balance(aweth).await;
    assert!(
        dust < U256::from(10u64.pow(12)),
        "only interest dust stays: {dust}"
    );
    let left = view(
        &f.provider(),
        aweth,
        allowanceCall {
            owner: f.me,
            spender: gateway,
        },
    )
    .await;
    assert_eq!(
        left,
        U256::ZERO,
        "the aWETH approval was exactly what was pulled"
    );
}

sol! {
    function getACLAdmin() returns (address);
    function getACLManager() returns (address);
    function getPoolConfigurator() returns (address);
    function addPoolAdmin(address admin);
    function setReserveBorrowing(address asset, bool enabled);
}

/// Aave's Sepolia market does not lend WETH. Switches borrowing on in this fork, as Aave's own
/// ACL admin, so the older gateway's borrow and repay forms can run.
async fn enable_weth_borrowing(f: &Fork) {
    let p = f.provider();
    let admin = view(&p, SEPOLIA_PROVIDER, getACLAdminCall {}).await;
    let acl = view(&p, SEPOLIA_PROVIDER, getACLManagerCall {}).await;
    let configurator = view(&p, SEPOLIA_PROVIDER, getPoolConfiguratorCall {}).await;
    let _: () = p
        .raw_request("anvil_impersonateAccount".into(), (admin,))
        .await
        .unwrap();
    let _: () = p
        .raw_request(
            "anvil_setBalance".into(),
            (admin, U256::from(10u128.pow(18))),
        )
        .await
        .unwrap();
    for (to, input) in [
        (acl, addPoolAdminCall { admin }.abi_encode()),
        (
            configurator,
            setReserveBorrowingCall {
                asset: f.token("weth"),
                enabled: true,
            }
            .abi_encode(),
        ),
    ] {
        let tx = alloy_rpc_types_eth::TransactionRequest::default()
            .from(admin)
            .to(to)
            .input(input.into());
        let receipt = p
            .send_transaction(tx)
            .await
            .unwrap()
            .get_receipt()
            .await
            .unwrap();
        assert!(receipt.status(), "{receipt:?}");
    }
}

/// Sepolia's gateway predates Aave v3.2 and takes a rate-mode argument in borrowETH and
/// repayETH; the skill sends that form there. Where Aave has borrowing off, the skill says so
/// before anything is built.
#[tokio::test]
#[ignore = "forks Sepolia over the network; needs anvil, edw and Docker"]
async fn borrows_and_repays_eth_through_sepolias_older_gateway() {
    let borrow = || call("aave_borrow", json!({"token": "ETH", "amount": "0.1"}));
    let Some(mut f) = Fork::start(
        "aave-eth-sepolia",
        sepolia_rpc(),
        "sepolia",
        vec![
            call("load_skill", json!({"name": "aave-v3-lend"})),
            call("aave_supply", json!({"token": "ETH", "amount": "1"})),
            AssistantContent::text("supplied"),
            borrow(),
            AssistantContent::text("not lent"),
            borrow(),
            AssistantContent::text("borrowed"),
            call("aave_repay", json!({"token": "ETH", "amount": "all"})),
            AssistantContent::text("repaid"),
        ],
    )
    .await
    else {
        return;
    };
    let debt = f.token("weth_debt");
    f.approved("put 1 ETH on aave", &["depositETH"]).await;

    let refused = f.h.turn("borrow 0.1 ETH from aave", true).await;
    assert!(refused.previews.is_empty(), "{refused:?}");
    assert!(
        refused
            .outputs
            .last()
            .unwrap()
            .contains("borrowing it is turned off"),
        "{refused:?}"
    );

    enable_weth_borrowing(&f).await;
    f.approved(
        "borrow 0.1 ETH from aave",
        &["Aave WETH Gateway.borrowETH(pool=Aave Pool, amount=0.1 WETH (100000000000000000), interestRateMode=2, referralCode=0)"],
    )
    .await;
    assert!(f.balance(debt).await >= U256::from(10u64.pow(17)));
    f.approved(
        "repay all my ETH debt on aave",
        &["Aave WETH Gateway.repayETH(pool=Aave Pool, amount=all, interestRateMode=2, onBehalfOf=you)"],
    )
    .await;
    assert_eq!(f.balance(debt).await, U256::ZERO);
}
