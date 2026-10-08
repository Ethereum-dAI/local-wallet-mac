//! The interim executor end to end: scripted model → Rig → dry run → review → real send, on
//! anvil. Skips when `edw` or `anvil` is missing.
//!
//! The Sepolia-fork test is ignored by default because it needs the network:
//! `cargo test --test interim -- --ignored` (RPC: `EDW_TUI_SEPOLIA_RPC`, default a
//! no-tracking endpoint from chainlist).

mod common;

use alloy_node_bindings::{Anvil, AnvilInstance};
use alloy_primitives::{Address, B256, U256, address, keccak256};
use alloy_provider::{Provider, ProviderBuilder};
use common::{Harness, TempWallet, edw_binary};
use edw_tui::{interim::Interim, scripted::ScriptedModel};
use rig_agent::ModelHandle;

const BEEF: Address = address!("0x000000000000000000000000000000000000bEEF");
const SEPOLIA_USDC: Address = address!("0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238");
const ETHER: u128 = 1_000_000_000_000_000_000;

fn anvil(fork: Option<String>) -> Option<AnvilInstance> {
    let anvil = match fork {
        Some(url) => Anvil::new().fork(url),
        None => Anvil::new(),
    };
    match anvil.try_spawn() {
        Ok(instance) => Some(instance),
        Err(error) => {
            eprintln!("skipping: cannot start anvil ({error})");
            None
        }
    }
}

/// A wallet unlocked on `network`, and a harness whose interim tools use `rpc`.
async fn start(
    name: &str,
    network: &str,
    rpc: Option<String>,
    allow_sepolia: bool,
) -> Option<Harness> {
    let binary = edw_binary().or_else(|| {
        eprintln!("skipping: edw is not installed");
        None
    })?;
    let wallet = TempWallet::new(binary, name);
    wallet.edw(&["unlock", "--network", network]).await;
    let interim = wallet.interim(rpc, allow_sepolia);
    Some(Harness::start_with(
        wallet,
        ModelHandle::named("scripted", ScriptedModel::default()),
        Some(interim),
    ))
}

async fn sender(h: &Harness, rpc: &str, allow_sepolia: bool) -> Address {
    Interim::new(h.wallet.interim(Some(rpc.into()), allow_sepolia))
        .address(None)
        .await
        .unwrap()
}

async fn fund(rpc: &str, who: Address, wei: U256) {
    let provider = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    let _: () = provider
        .raw_request("anvil_setBalance".into(), (who, wei))
        .await
        .unwrap();
}

async fn eth(rpc: &str, who: Address) -> U256 {
    ProviderBuilder::new()
        .connect_http(rpc.parse().unwrap())
        .get_balance(who)
        .await
        .unwrap()
}

#[tokio::test]
async fn sends_eth_only_after_a_reviewed_dry_run() {
    let Some(node) = anvil(None) else { return };
    let rpc = node.endpoint();
    let Some(mut h) = start("interim-eth", "local", Some(rpc.clone()), false).await else {
        return;
    };
    let from = sender(&h, &rpc, false).await;
    fund(&rpc, from, U256::from(10 * ETHER)).await;

    let turn = h.turn("what is my balance", true).await;
    assert!(
        turn.outputs[0].contains("default (0/0)") && turn.outputs[0].contains("10 ETH"),
        "{turn:?}"
    );

    // Declined: the dry run was shown, nothing was sent.
    let send = format!("send 0.1 ETH to {BEEF}");
    let turn = h.turn(&send, false).await;
    let preview = &turn.previews[0];
    for needle in [
        "Send     0.1 ETH",
        &BEEF.to_string(),
        "chain 31337",
        "Max fee",
    ] {
        assert!(preview.contains(needle), "missing {needle:?} in {preview}");
    }
    assert!(turn.confirms[0].starts_with("interim transfer --to"));
    assert_eq!(eth(&rpc, BEEF).await, U256::ZERO);

    // Approved: exactly 0.1 ETH arrives.
    let turn = h.turn(&send, true).await;
    assert!(
        turn.outputs.last().unwrap().contains("succeeded"),
        "{turn:?}"
    );
    assert_eq!(eth(&rpc, BEEF).await, U256::from(ETHER / 10));

    // Guards and failed dry runs never reach the confirmation.
    for (prompt, reason) in [
        (
            "send 1 ETH to 0x000000000000000000000000000000000000dEaD",
            "burn",
        ),
        (
            "send 1 ETH to 0x0000000000000000000000000000000000000000",
            "burn",
        ),
        (
            "send 100 ETH to 0x000000000000000000000000000000000000bEEF",
            "not enough ETH",
        ),
        (
            "send -1 ETH to 0x000000000000000000000000000000000000bEEF",
            "positive number",
        ),
        ("send 1 ETH to vitalik.eth", "ENS"),
        (
            "send 1 DAI to 0x000000000000000000000000000000000000bEEF",
            "does not know DAI",
        ),
    ] {
        let turn = h.turn(prompt, true).await;
        assert!(turn.confirms.is_empty(), "{prompt}: {turn:?}");
        assert!(turn.outputs[0].contains(reason), "{prompt}: {turn:?}");
    }

    // A contract that rejects ETH (code starting with INVALID, like an ERC-5202 blueprint)
    // fails the dry run with an explanation, and nothing is asked or sent.
    let blueprint = address!("0xbFcF63294aD7105dEa65aA58F8AE5BE2D9d0952A");
    let provider = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    let _: () = provider
        .raw_request("anvil_setCode".into(), (blueprint, "0xfe71"))
        .await
        .unwrap();
    let turn = h.turn(&format!("send 0.1 ETH to {blueprint}"), true).await;
    assert!(turn.confirms.is_empty(), "{turn:?}");
    assert!(
        turn.outputs[0].contains("has contract code")
            && turn.outputs[0].contains("nothing was sent"),
        "{turn:?}"
    );

    // "all" leaves only dust: the fee reserve that was not spent.
    let turn = h.turn(&format!("send all ETH to {BEEF}"), true).await;
    assert!(
        turn.outputs.last().unwrap().contains("succeeded"),
        "{turn:?}"
    );
    assert!(eth(&rpc, from).await < U256::from(ETHER / 1000));
}

#[tokio::test]
async fn sends_from_the_profile_the_harness_selected() {
    let Some(node) = anvil(None) else { return };
    let rpc = node.endpoint();
    let Some(mut h) = start("interim-profile", "local", Some(rpc.clone()), false).await else {
        return;
    };
    h.wallet
        .edw(&["profile", "add", "--next", "--name", "bob"])
        .await;
    let default = sender(&h, &rpc, false).await;
    fund(&rpc, default, U256::from(ETHER)).await;

    assert!(
        h.set_profile("carol").await.is_err(),
        "unknown profiles are refused"
    );
    let bob = h.set_profile("bob").await.unwrap();
    assert_ne!(bob, default.to_string());

    // Real addresses come from a tool, never from the model's imagination.
    let turn = h.turn("show my addresses", true).await;
    let listing = &turn.outputs[0];
    assert!(
        listing.contains(&format!("default (0/0)  {default}")),
        "{listing}"
    );
    assert!(
        listing.contains(&format!("bob (0/1)  {bob}  (sends transfers)")),
        "{listing}"
    );

    let turn = h.turn("balance", true).await;
    assert!(
        turn.outputs[0].contains("bob (0/1)") && turn.outputs[0].contains("0 ETH"),
        "{turn:?}"
    );
    let turn = h.turn(&format!("send 0.1 ETH to {BEEF}"), true).await;
    assert!(
        turn.confirms.is_empty() && turn.outputs[0].contains("not enough ETH"),
        "{turn:?}"
    );

    h.set_profile("0/0").await.unwrap();
    let turn = h.turn(&format!("send 0.1 ETH to {BEEF}"), true).await;
    assert!(turn.confirms[0].ends_with("--from 0/0"), "{turn:?}");
    assert_eq!(eth(&rpc, BEEF).await, U256::from(ETHER / 10));

    // The model switches the sender when the user names one; it sticks until changed.
    let turn = h.turn("use bob", true).await;
    assert_eq!(turn.switched, ["bob"], "{turn:?}");
    let turn = h.turn(&format!("send 0.1 ETH to {BEEF}"), true).await;
    assert!(
        turn.outputs[0].contains("--from bob") && turn.outputs[0].contains("not enough ETH"),
        "{turn:?}"
    );
    let turn = h.turn("use carol", true).await;
    assert!(
        turn.switched.is_empty() && turn.outputs[0].contains("still bob"),
        "{turn:?}"
    );
    let turn = h.turn("switch to 0/0", true).await;
    assert_eq!(turn.switched, ["0/0"], "{turn:?}");
}

#[tokio::test]
async fn refuses_mainnet_and_sepolia_unless_allowed() {
    let send = format!("send 0.1 ETH to {BEEF}");
    let Some(mut h) = start("interim-mainnet", "mainnet", None, true).await else {
        return;
    };
    let turn = h.turn(&send, true).await;
    assert!(
        turn.confirms.is_empty() && turn.outputs[0].contains("mainnet is disabled"),
        "{turn:?}"
    );

    let Some(mut h) = start("interim-sepolia", "sepolia", None, false).await else {
        return;
    };
    let turn = h.turn(&send, true).await;
    assert!(
        turn.outputs[0].contains("EDW_TUI_INTERIM_SEPOLIA=1"),
        "{turn:?}"
    );
}

/// Gives `who` `amount` of Sepolia USDC by writing Circle's FiatToken v2.2 balance slot (9).
async fn deal_usdc(rpc: &str, who: Address, amount: U256) {
    let provider = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    let mut key = [0u8; 64];
    key[12..32].copy_from_slice(who.as_slice());
    key[63] = 9;
    let _: bool = provider
        .raw_request(
            "anvil_setStorageAt".into(),
            (SEPOLIA_USDC, keccak256(key), B256::from(amount)),
        )
        .await
        .unwrap();
    assert_eq!(
        usdc(rpc, who).await,
        amount,
        "USDC's balance slot moved; update deal_usdc"
    );
}

async fn usdc(rpc: &str, who: Address) -> U256 {
    let provider = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    let mut data = vec![0x70, 0xa0, 0x82, 0x31]; // balanceOf(address)
    data.extend_from_slice(&[0u8; 12]);
    data.extend_from_slice(who.as_slice());
    let tx = alloy_rpc_types_eth::TransactionRequest::default()
        .to(SEPOLIA_USDC)
        .input(data.into());
    U256::from_be_slice(&provider.call(tx).await.unwrap())
}

#[tokio::test]
#[ignore = "forks Sepolia over the network"]
async fn sends_usdc_on_a_sepolia_fork() {
    let upstream = std::env::var("EDW_TUI_SEPOLIA_RPC")
        .unwrap_or_else(|_| "https://ethereum-sepolia-rpc.publicnode.com".into());
    let Some(node) = anvil(Some(upstream)) else {
        return;
    };
    let rpc = node.endpoint();
    let Some(mut h) = start("interim-usdc", "sepolia", Some(rpc.clone()), true).await else {
        return;
    };
    let from = sender(&h, &rpc, true).await;
    fund(&rpc, from, U256::from(ETHER)).await;
    deal_usdc(&rpc, from, U256::from(5_000_000u64)).await;
    let before = usdc(&rpc, BEEF).await;

    let turn = h.turn("balance", true).await;
    assert!(
        turn.outputs[0].contains("chain 11155111") && turn.outputs[0].contains("5 USDC"),
        "{turn:?}"
    );

    let turn = h.turn(&format!("send 1.5 USDC to {BEEF}"), true).await;
    let preview = &turn.previews[0];
    assert!(
        preview.contains("Send     1.5 USDC  (1500000 base units)")
            && preview.contains(&format!("Token    {SEPOLIA_USDC}")),
        "{preview}"
    );
    assert!(
        turn.outputs.last().unwrap().contains("succeeded"),
        "{turn:?}"
    );
    assert_eq!(usdc(&rpc, BEEF).await - before, U256::from(1_500_000u64));
    assert_eq!(usdc(&rpc, from).await, U256::from(3_500_000u64));

    // The same token by address, and more decimals than USDC has.
    let turn = h
        .turn(&format!("send 0.5 {SEPOLIA_USDC} to {BEEF}"), true)
        .await;
    assert!(turn.previews[0].contains("0.5 USDC"), "{turn:?}");
    let turn = h
        .turn(&format!("send 0.0000001 USDC to {BEEF}"), true)
        .await;
    assert!(
        turn.confirms.is_empty() && turn.outputs[0].contains("decimal places"),
        "{turn:?}"
    );
    let turn = h.turn(&format!("send 1 WETH to {BEEF}"), true).await;
    assert!(
        turn.confirms.is_empty() && turn.outputs[0].contains("not enough WETH"),
        "{turn:?}"
    );
    // PR #98 review: "all" of a token the profile does not hold is refused, not a 0-token send.
    let turn = h.turn(&format!("send all WETH to {BEEF}"), true).await;
    assert!(
        turn.confirms.is_empty() && turn.outputs[0].contains("holds no WETH"),
        "{turn:?}"
    );
}

#[tokio::test]
#[ignore = "forks Sepolia over the network"]
async fn swaps_on_a_sepolia_fork() {
    let upstream = std::env::var("EDW_TUI_SEPOLIA_RPC")
        .unwrap_or_else(|_| "https://ethereum-sepolia-rpc.publicnode.com".into());
    let Some(node) = anvil(Some(upstream)) else {
        return;
    };
    let rpc = node.endpoint();
    let Some(mut h) = start("interim-swap", "sepolia", Some(rpc.clone()), true).await else {
        return;
    };
    let from = sender(&h, &rpc, true).await;
    fund(&rpc, from, U256::from(ETHER)).await;

    // ETH in: one transaction, ETH sent as msg.value to the router.
    let turn = h.turn("swap 0.01 ETH for USDC", true).await;
    let preview = &turn.previews[0];
    assert!(
        preview.contains("Swap     0.01 ETH → about")
            && preview.contains("USDC")
            && preview.contains("Route    WETH"),
        "{preview}"
    );
    assert!(
        turn.outputs.last().unwrap().contains("succeeded"),
        "{turn:?}"
    );
    assert!(usdc(&rpc, from).await > U256::ZERO, "no USDC arrived");

    // ERC-20 in and ETH out: an exact approval first, then multicall(exactInput, unwrapWETH9).
    deal_usdc(&rpc, from, U256::from(5_000_000u64)).await;
    let eth_before = eth(&rpc, from).await;
    let turn = h.turn("swap 1 USDC for ETH", true).await;
    let preview = &turn.previews[0];
    assert!(
        preview.contains("Sends    2 transactions: 1. approve 1 USDC for the router  2. swap"),
        "{preview}"
    );
    assert!(
        turn.outputs
            .last()
            .unwrap()
            .contains("Sent 2 transactions, all succeeded"),
        "{turn:?}"
    );
    assert_eq!(
        usdc(&rpc, from).await,
        U256::from(4_000_000u64),
        "exactly 1 USDC was spent"
    );
    assert!(
        eth(&rpc, from).await > eth_before - U256::from(ETHER / 100),
        "ETH came back, less gas"
    );

    // PR #98 review: with a smaller allowance already set, the swap resets it to 0, approves the
    // exact amount, then swaps. The approval is estimated only after the reset is mined, so it
    // has the gas a zero-to-non-zero write needs.
    let router = edw_tui::interim::swap::contracts(11_155_111)
        .unwrap()
        .router;
    let mut approve = vec![0x09, 0x5e, 0xa7, 0xb3]; // approve(address,uint256)
    approve.extend_from_slice(&[0u8; 12]);
    approve.extend_from_slice(router.as_slice());
    approve.extend_from_slice(&U256::from(100_000u64).to_be_bytes::<32>()); // 0.1 USDC
    let provider = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    let _: () = provider
        .raw_request("anvil_impersonateAccount".into(), (from,))
        .await
        .unwrap();
    let tx = alloy_rpc_types_eth::TransactionRequest::default()
        .from(from)
        .to(SEPOLIA_USDC)
        .input(approve.into());
    let hash: alloy_primitives::B256 = provider
        .raw_request("eth_sendTransaction".into(), (tx,))
        .await
        .unwrap();
    assert!(
        provider
            .get_transaction_receipt(hash)
            .await
            .unwrap()
            .is_some_and(|r| r.status()),
        "the setup approval landed"
    );
    let _: () = provider
        .raw_request("anvil_stopImpersonatingAccount".into(), (from,))
        .await
        .unwrap();
    let turn = h.turn("swap 2 USDC for ETH", true).await;
    let preview = &turn.previews[0];
    assert!(
        preview.contains("Sends    3 transactions: 1. reset the USDC allowance to 0  2. approve 2 USDC for the router  3. swap"),
        "{preview}"
    );
    assert!(
        turn.outputs
            .last()
            .unwrap()
            .contains("Sent 3 transactions, all succeeded"),
        "{turn:?}"
    );
    assert_eq!(
        usdc(&rpc, from).await,
        U256::from(2_000_000u64),
        "exactly 2 more USDC were spent"
    );

    // Guards: unknown token, "all", and the same token twice.
    for (prompt, reason) in [
        (
            "swap 1 USDC for 0x000000000000000000000000000000000000bEEF",
            "known tokens",
        ),
        ("swap all ETH for USDC", "exact amount"),
        ("swap 1 USDC for USDC", "two different tokens"),
    ] {
        let turn = h.turn(prompt, true).await;
        assert!(
            turn.confirms.is_empty() && turn.outputs[0].contains(reason),
            "{prompt}: {turn:?}"
        );
    }
}

/// PR #98 review: "all" ETH to a contract that accepts ETH but costs more than 21 000 gas used
/// to be refused as "not enough ETH". The amount is now the balance less the real fee.
#[tokio::test]
async fn sends_all_eth_to_a_contract_that_accepts_it() {
    let Some(node) = anvil(None) else { return };
    let rpc = node.endpoint();
    let Some(mut h) = start("interim-all-contract", "local", Some(rpc.clone()), false).await else {
        return;
    };
    let from = sender(&h, &rpc, false).await;
    fund(&rpc, from, U256::from(ETHER)).await;
    // PUSH1 1, PUSH1 0, SSTORE, STOP: accepts ETH and writes a fresh slot (~22k extra gas).
    let vault = address!("0x00000000000000000000000000000000000Ca5e5");
    let provider = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    let _: () = provider
        .raw_request("anvil_setCode".into(), (vault, "0x600160005500"))
        .await
        .unwrap();

    let turn = h.turn(&format!("send all ETH to {vault}"), true).await;
    assert!(
        turn.outputs.last().unwrap().contains("succeeded"),
        "{turn:?}"
    );
    let left = eth(&rpc, from).await;
    assert!(left < U256::from(ETHER / 1000), "only dust is left: {left}");
    let received = eth(&rpc, vault).await;
    assert!(
        received > U256::from(ETHER * 999 / 1000),
        "the contract got the balance less the fee: {received}"
    );
}

/// A skill's checked plan goes through the same dry run → review → send path as transfers:
/// simulated as a whole, described from the simulation, sent in order.
#[tokio::test]
async fn a_checked_skill_plan_is_simulated_reviewed_and_sent_in_order() {
    use edw_tui::skills::plan::{CheckedPlan, CheckedStep};
    let Some(node) = anvil(None) else { return };
    let rpc = node.endpoint();
    let Some(h) = start("interim-plan", "local", Some(rpc.clone()), false).await else {
        return;
    };
    let interim = Interim::new(h.wallet.interim(Some(rpc.clone()), false));
    let context = interim.skill_context().await.unwrap();
    assert_eq!(context.chain_id, 31337);
    fund(&rpc, context.me, U256::from(10 * ETHER)).await;

    let send = |wei: u128, label: &str| CheckedStep {
        label: label.into(),
        to: BEEF,
        value: U256::from(wei),
        data: Default::default(),
        approval: None,
        details: Vec::new(),
        binding: None,
    };
    let plan = |steps: Vec<CheckedStep>| CheckedPlan {
        total_value: steps.iter().map(|s| s.value).sum(),
        steps,
        notes: Vec::new(),
    };
    let header = vec!["Skill    demo 1 (sha256 abc)".to_owned()];
    let names = Default::default();

    let mut detailed = plan(vec![
        send(ETHER / 5, "first"),
        send(ETHER * 3 / 10, "second"),
    ]);
    detailed.steps[0].details = vec!["does: pays someone 0.2 ETH".into()];
    detailed.notes = vec!["it is only a test".into()];
    let prepared = interim
        .prepare_plan(
            "skill demo_send".into(),
            header.clone(),
            detailed,
            &names,
            &context,
        )
        .await
        .unwrap();
    for needle in [
        "Step 1   first\n           does: pays someone 0.2 ETH",
        "Skill says (not checked): it is only a test",
        "Skill    demo 1",
        "Step 1   first",
        "Step 2   second",
        "Changes  −0.5 ETH (simulated)",
        "Max fee",
    ] {
        assert!(
            prepared.preview.contains(needle),
            "missing {needle:?} in\n{}",
            prepared.preview
        );
    }
    assert_eq!(eth(&rpc, BEEF).await, U256::ZERO, "a dry run sends nothing");
    let result = interim.broadcast(prepared).await;
    assert!(result.ok(), "{result:?}");
    assert_eq!(eth(&rpc, BEEF).await, U256::from(ETHER / 2));

    let error = interim
        .prepare_plan(
            "skill demo_send".into(),
            header.clone(),
            plan(vec![send(100 * ETHER, "too much")]),
            &names,
            &context,
        )
        .await
        .err()
        .unwrap();
    assert!(error.contains("not enough ETH"), "{error}");

    // The plan was checked for one sender; if the wallet's sender changed while the skill ran,
    // `$self` in it means someone else, so nothing is built.
    let mut stale = context.clone();
    stale.me = BEEF;
    let error = interim
        .prepare_plan(
            "skill demo_send".into(),
            header,
            plan(vec![send(ETHER / 5, "first")]),
            &names,
            &stale,
        )
        .await
        .err()
        .unwrap();
    assert!(error.contains("changed while the skill ran"), "{error}");
}
