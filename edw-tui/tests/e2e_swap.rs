//! Swap end to end through a real terminal, on an anvil fork of Sepolia (Uniswap v3 is live
//! there): unlock sepolia, fund the default profile, check the balance, swap 0.01 ETH for USDC
//! through the review modal, check the balance again. Screenshots and the MP4 are for people;
//! the assertions are on the chain: exactly one transaction was mined, it succeeded, went from
//! the profile to Uniswap's router carrying exactly 0.01 ETH, the profile paid exactly that plus
//! the receipt's fee, and USDC arrived.
//!
//! Needs the network, so it is ignored by default:
//! `cargo test --test e2e_swap -- --ignored`; add `EDW_TUI_E2E_RECORD=1` for
//! `target/e2e-screenshots/swap.mp4` (the `feature-video` skill).

mod common;

use alloy_primitives::{Address, U256, address};
use alloy_provider::{Provider, ProviderBuilder};
use alloy_rpc_types_eth::{BlockNumberOrTag, TransactionRequest};
use common::scenario::{Chain, ETHER, Scenario};
use edw_tui::interim::swap;

const SEPOLIA_USDC: Address = address!("0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238");

async fn usdc(rpc: &str, who: Address) -> U256 {
    let mut data = vec![0x70, 0xa0, 0x82, 0x31]; // balanceOf(address)
    data.extend_from_slice(&[0u8; 12]);
    data.extend_from_slice(who.as_slice());
    let tx = TransactionRequest::default()
        .to(SEPOLIA_USDC)
        .input(data.into());
    let raw = ProviderBuilder::new()
        .connect_http(rpc.parse().unwrap())
        .call(tx)
        .await
        .unwrap();
    U256::from_be_slice(&raw)
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "forks Sepolia over the network"]
async fn swap_eth_for_usdc_end_to_end() {
    let Some(mut s) = Scenario::start("swap", Chain::SepoliaFork).await else {
        return;
    };
    s.confirmed("unlock sepolia", "Unlocked sepolia");
    let me = s.address("0/0").await;
    s.fund(me, U256::from(ETHER)).await;
    let usdc_before = usdc(&s.rpc, me).await;
    let eth_before = s.eth(me).await;
    s.ask("what is my balance", "1 ETH");

    s.confirmed("swap 0.01 ETH for USDC", "succeeded");

    // A second balance: the log then holds two balance entries.
    s.tui.submit("what is my balance");
    s.tui.wait_for_within("the second balance", 240, |screen| {
        screen.matches("$ interim balance").count() >= 2
    });
    s.idle();
    s.tui.linger(1500);
    s.screenshot("swap_final");

    // The chain is the verdict. Funding was a state override and unlocking touches no chain,
    // so the latest block holds exactly the swap.
    let provider = ProviderBuilder::new().connect_http(s.rpc.parse().unwrap());
    let block = provider
        .get_block_by_number(BlockNumberOrTag::Latest)
        .await
        .unwrap()
        .expect("anvil has a latest block");
    let hashes: Vec<_> = block.transactions.hashes().collect();
    assert_eq!(
        hashes.len(),
        1,
        "exactly one transaction was mined: {hashes:?}"
    );
    let receipt = provider
        .get_transaction_receipt(hashes[0])
        .await
        .unwrap()
        .expect("the swap has a receipt");
    assert!(receipt.status(), "the swap succeeded on chain");
    assert_eq!(receipt.from, me, "sent from the default profile");
    let router = swap::contracts(11_155_111).unwrap().router;
    assert_eq!(receipt.to, Some(router), "sent to Uniswap's SwapRouter02");
    let value = U256::from(ETHER / 100);
    let fee = U256::from(receipt.gas_used) * U256::from(receipt.effective_gas_price);
    assert_eq!(
        eth_before - s.eth(me).await,
        value + fee,
        "the profile paid exactly 0.01 ETH (the swap's input) plus the fee in the receipt"
    );
    assert!(usdc(&s.rpc, me).await > usdc_before, "USDC arrived");
    s.finish("swap");
}
