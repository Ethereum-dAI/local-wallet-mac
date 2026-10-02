//! Skills end to end through the real terminal, on an anvil fork of Ethereum mainnet: approve
//! the shipped skills on their cards, look up lending rates, supply 100 USDC to Aave v3 (review,
//! then y), and withdraw it all. Uses the scripted model, the pinned edw, and Docker.
//!
//! Needs the network (the fork, DefiLlama): `cargo test --test e2e_aave -- --ignored`.
//! `EDW_TUI_E2E_RECORD=1` also records `target/e2e-screenshots/aave.mp4`.

mod common;

use std::path::Path;

use alloy_primitives::{Address, U256};
use alloy_provider::{Provider, ProviderBuilder};
use alloy_sol_types::{SolCall, sol};
use common::scenario::{Chain, ETHER, Scenario};
use edw_tui::skills::{manifest, sandbox};

sol! {
    function balanceOf(address owner) returns (uint256);
}

const MAINNET: u64 = 1;

async fn balance(rpc: &str, token: Address, owner: Address) -> U256 {
    let provider = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    let tx = alloy_rpc_types_eth::TransactionRequest::default()
        .to(token)
        .input(balanceOfCall { owner }.abi_encode().into());
    balanceOfCall::abi_decode_returns(&provider.call(tx).await.unwrap()).unwrap()
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
