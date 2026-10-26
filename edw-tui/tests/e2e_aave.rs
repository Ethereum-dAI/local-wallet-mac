//! Skills end to end through the real terminal, on an anvil fork of Ethereum mainnet, with the
//! scripted model, the pinned edw, and Docker. Each review is answered with y after reading it.
//! - `aave`: approve the shipped skills on their cards, look up lending rates, supply 100 USDC to
//!   Aave v3, and withdraw it all.
//! - `aave_borrow`: supply 2 ETH through Aave's WETH gateway, read the account's health, borrow
//!   1000 USDC against it, repay 400 and then the rest, stop using the ETH as collateral, and
//!   withdraw it as ETH.
//!
//! Needs the network (the fork, DefiLlama): `cargo test --test e2e_aave -- --ignored`.
//! `EDW_TUI_E2E_RECORD=1` also records `target/e2e-screenshots/<name>.mp4`.

mod common;

use std::path::Path;

use alloy_primitives::{Address, U256};
use alloy_provider::{Provider, ProviderBuilder};
use alloy_sol_types::{SolCall, sol};
use common::scenario::{Chain, ETHER, Scenario};
use edw_tui::skills::{manifest, sandbox};

sol! {
    function balanceOf(address owner) returns (uint256);
    function allowance(address owner, address spender) returns (uint256);
    function getUserAccountData(address user) returns (uint256 collateral, uint256 debt, uint256 canBorrow, uint256 liquidationThreshold, uint256 ltv, uint256 healthFactor);
}

const MAINNET: u64 = 1;

async fn view<C: SolCall>(rpc: &str, to: Address, call: C) -> C::Return {
    let provider = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    let tx = alloy_rpc_types_eth::TransactionRequest::default()
        .to(to)
        .input(call.abi_encode().into());
    C::abi_decode_returns(&provider.call(tx).await.unwrap()).unwrap()
}

async fn balance(rpc: &str, token: Address, owner: Address) -> U256 {
    view(rpc, token, balanceOfCall { owner }).await
}

async fn block(rpc: &str) -> u64 {
    ProviderBuilder::new()
        .connect_http(rpc.parse().unwrap())
        .get_block_number()
        .await
        .unwrap()
}

fn shows(review: &str, needles: &[&str]) {
    for needle in needles {
        assert!(
            review.contains(needle),
            "the review lacks {needle:?}:\n{review}"
        );
    }
}

/// Every transaction mined after block `since`, as (from, to, succeeded).
async fn mined_since(rpc: &str, since: u64) -> Vec<(Address, Option<Address>, bool)> {
    let provider = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    let latest = provider.get_block_number().await.unwrap();
    let mut out = Vec::new();
    for number in since + 1..=latest {
        let block = provider
            .get_block_by_number(number.into())
            .await
            .unwrap()
            .unwrap();
        for hash in block.transactions.hashes() {
            let receipt = provider
                .get_transaction_receipt(hash)
                .await
                .unwrap()
                .unwrap();
            out.push((receipt.from, receipt.to, receipt.status()));
        }
    }
    out
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "forks mainnet over the network; needs anvil, edw and Docker"]
async fn aave_supply_and_withdraw_end_to_end() {
    if !sandbox::docker_available().await {
        eprintln!("skipping: Docker is not running");
        return;
    }
    let skill =
        manifest::load(&Path::new(env!("CARGO_MANIFEST_DIR")).join("skills/aave-v3-lend")).unwrap();
    let address = |id: &str| skill.manifest.token(id).unwrap().address[&MAINNET];
    let (usdc, ausdc) = (address("usdc"), address("ausdc"));
    let pool = skill.manifest.contract("pool").unwrap().address[&MAINNET];

    let Some(mut s) = Scenario::start_with_skills("aave", Chain::MainnetFork).await else {
        return;
    };
    s.confirmed("unlock mainnet", "Unlocked");
    let me = s.address("0/0").await;
    s.fund(me, U256::from(10 * ETHER)).await;
    let provider = ProviderBuilder::new().connect_http(s.rpc.parse().unwrap());
    let _: () = provider
        .raw_request(
            "anvil_dealERC20".into(),
            (me, usdc, U256::from(1_000_000_000u64)),
        )
        .await
        .unwrap();

    // Looking around first: no confirmations, nothing sent.
    s.ask(
        "what are the best USDC lending rates on Ethereum?",
        "Best on Ethereum",
    );
    s.ask("what does Aave pay on stablecoins?", "Aave v3 pays now");

    // Supply: the review lists the approval and the supply, then y sends both.
    let before = provider.get_block_number().await.unwrap();
    s.confirmed("put 100 USDC on aave", "succeeded");
    s.screenshot("aave_supplied");
    let mined = mined_since(&s.rpc, before).await;
    assert_eq!(
        mined,
        [(me, Some(usdc), true), (me, Some(pool), true)],
        "exactly an approve to USDC, then a supply to the Pool"
    );
    assert_eq!(balance(&s.rpc, usdc, me).await, U256::from(900_000_000u64));
    let supplied = balance(&s.rpc, ausdc, me).await;
    assert!(
        supplied >= U256::from(99_999_000u64) && supplied <= U256::from(100_001_000u64),
        "about 100 aUSDC: {supplied}"
    );

    // Withdraw everything: one call to the Pool; the aUSDC is gone, the USDC is back.
    let before = provider.get_block_number().await.unwrap();
    s.confirmed("withdraw all my USDC from aave", "succeeded");
    s.screenshot("aave_withdrawn");
    assert_eq!(mined_since(&s.rpc, before).await, [(me, Some(pool), true)]);
    assert_eq!(balance(&s.rpc, ausdc, me).await, U256::ZERO);
    let back = balance(&s.rpc, usdc, me).await;
    assert!(
        back >= U256::from(999_998_000u64),
        "the USDC is back, less Aave's rounding: {back}"
    );
    s.finish("aave");
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "forks mainnet over the network; needs anvil, edw and Docker"]
async fn aave_eth_collateral_borrow_and_repay_end_to_end() {
    if !sandbox::docker_available().await {
        eprintln!("skipping: Docker is not running");
        return;
    }
    let skill =
        manifest::load(&Path::new(env!("CARGO_MANIFEST_DIR")).join("skills/aave-v3-lend")).unwrap();
    let token = |id: &str| skill.manifest.token(id).unwrap().address[&MAINNET];
    let contract = |id: &str| skill.manifest.contract(id).unwrap().address[&MAINNET];
    let (usdc, debt, aweth) = (token("usdc"), token("usdc_debt"), token("aweth"));
    let (pool, gateway) = (contract("pool"), contract("gateway"));
    let usdc_units = |whole: u64| U256::from(whole * 1_000_000);

    let Some(mut s) = Scenario::start_with_skills("aave_borrow", Chain::MainnetFork).await else {
        return;
    };
    s.confirmed("unlock mainnet", "Unlocked");
    let me = s.address("0/0").await;
    s.fund(me, U256::from(10 * ETHER)).await;
    let rpc = s.rpc.clone();

    // Supply 2 ETH: one payable call to the gateway, with the value and the account in the review.
    let before = block(&rpc).await;
    let review = s.reviewed("put 2 ETH on aave", "succeeded");
    shows(
        &review,
        &[
            "Aave WETH Gateway.depositETH(pool=Aave Pool, onBehalfOf=you, referralCode=0) with 2 ETH",
            "Changes  −2 ETH",
            "Aave account (simulated, before → after)",
            "health factor  ∞ → ∞",
        ],
    );
    s.screenshot("aave_eth_supplied");
    assert_eq!(mined_since(&rpc, before).await, [(me, Some(gateway), true)]);
    let supplied = balance(&rpc, aweth, me).await;
    assert!(
        supplied >= U256::from(2 * ETHER - 2)
            && supplied < U256::from(2 * ETHER + 1_000_000_000_000),
        "about 2 aWETH: {supplied}"
    );

    // Reading the account sends nothing.
    let before = block(&rpc).await;
    s.ask("how healthy is my aave account?", "Your Aave account");
    s.screenshot("aave_account");
    assert!(
        s.tui.screen().contains("health factor none (no debt)"),
        "{}",
        s.tui.screen()
    );
    assert!(mined_since(&rpc, before).await.is_empty());

    // Borrow 1000 USDC: one call to the Pool; the review shows the debt and health factor it leaves.
    let before = block(&rpc).await;
    let review = s.reviewed("borrow 1000 USDC from aave", "succeeded");
    shows(
        &review,
        &[
            "Aave Pool.borrow(asset=USDC, amount=1000 USDC (1000000000), interestRateMode=2, referralCode=0, onBehalfOf=you)",
            "+1000 USDC",
            "USDC debt",
            "debt           0.00 → ",
            "health factor  ∞ → ",
        ],
    );
    s.screenshot("aave_borrowed");
    assert_eq!(mined_since(&rpc, before).await, [(me, Some(pool), true)]);
    assert_eq!(balance(&rpc, usdc, me).await, usdc_units(1000));
    assert!(balance(&rpc, debt, me).await >= usdc_units(1000));

    // Repay 400: an approval of exactly 400 USDC, then the repayment.
    let before = block(&rpc).await;
    let review = s.reviewed("repay 400 USDC on aave", "succeeded");
    shows(
        &review,
        &[
            "approve 400 USDC for Aave Pool",
            "Aave Pool.repay(asset=USDC, amount=400 USDC (400000000), interestRateMode=2, onBehalfOf=you)",
        ],
    );
    assert_eq!(
        mined_since(&rpc, before).await,
        [(me, Some(usdc), true), (me, Some(pool), true)]
    );
    assert_eq!(balance(&rpc, usdc, me).await, usdc_units(600));
    let owed = balance(&rpc, debt, me).await;
    assert!(owed >= usdc_units(600) && owed < usdc_units(601), "{owed}");

    // Repaying the rest costs the interest too, so the profile gets 100 USDC more first.
    let provider = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    let _: () = provider
        .raw_request("anvil_dealERC20".into(), (me, usdc, usdc_units(700)))
        .await
        .unwrap();
    let before = block(&rpc).await;
    let review = s.reviewed("repay all my USDC debt on aave", "succeeded");
    shows(
        &review,
        &[
            "Aave Pool.repay(asset=USDC, amount=all, interestRateMode=2, onBehalfOf=you)",
            "approve 0 USDC for Aave Pool",
            " → 0.00 USD",
        ],
    );
    s.screenshot("aave_repaid");
    assert_eq!(
        mined_since(&rpc, before).await,
        [
            (me, Some(usdc), true),
            (me, Some(pool), true),
            (me, Some(usdc), true)
        ]
    );
    assert_eq!(balance(&rpc, debt, me).await, U256::ZERO);
    let left = view(
        &rpc,
        usdc,
        allowanceCall {
            owner: me,
            spender: pool,
        },
    )
    .await;
    assert_eq!(left, U256::ZERO, "no USDC approval is left behind");

    // Stop using the ETH as collateral: the aWETH stays, but counts for nothing.
    let before = block(&rpc).await;
    let review = s.reviewed("stop using my ETH as collateral on aave", "succeeded");
    shows(
        &review,
        &["Aave Pool.setUserUseReserveAsCollateral(asset=WETH, useAsCollateral=false)"],
    );
    assert_eq!(mined_since(&rpc, before).await, [(me, Some(pool), true)]);
    let account = view(&rpc, pool, getUserAccountDataCall { user: me }).await;
    assert_eq!(account.collateral, U256::ZERO);
    assert!(balance(&rpc, aweth, me).await > U256::ZERO);

    // Withdraw it all as ETH: an exact aWETH approval to the gateway, then withdrawETH.
    let eth_before = s.eth(me).await;
    let before = block(&rpc).await;
    let review = s.reviewed("withdraw all my ETH from aave", "succeeded");
    shows(
        &review,
        &[
            "aWETH for Aave WETH Gateway",
            "Aave WETH Gateway.withdrawETH(pool=Aave Pool, amount=2",
        ],
    );
    s.screenshot("aave_eth_withdrawn");
    assert_eq!(
        mined_since(&rpc, before).await,
        [(me, Some(aweth), true), (me, Some(gateway), true)]
    );
    let dust = balance(&rpc, aweth, me).await;
    assert!(
        dust < U256::from(1_000_000_000_000u64),
        "only interest dust stays: {dust}"
    );
    let left = view(
        &rpc,
        aweth,
        allowanceCall {
            owner: me,
            spender: gateway,
        },
    )
    .await;
    assert_eq!(left, U256::ZERO, "no aWETH approval is left behind");
    let back = s.eth(me).await - eth_before;
    assert!(
        back > U256::from(ETHER * 199 / 100),
        "the ETH is back, less fees: {back}"
    );
    s.finish("aave_borrow");
}
