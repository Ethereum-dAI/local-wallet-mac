//! The `safe-multisig` skill end to end through the real terminal, on an anvil fork of Ethereum
//! mainnet: approve the shipped skills on their cards, then ask about a real Safe (one that
//! pays out COW tokens): who controls it, what is waiting for signatures, what it recently paid out.
//! A second question reaches a Gnosis Chain Safe by name. Those reads mine nothing, and the test
//! checks that. Then the one write: the sending profile is made an owner of that Safe on the fork
//! (a storage edit, since nobody holds an owner's key), and asked to approve a transaction that is
//! really waiting in its queue. The test checks the single transaction mined: `approveHash` on the
//! Safe, from the profile. Uses the scripted model, the pinned edw, and Docker.
//!
//! Needs the network (the fork, the Safe Transaction Service):
//! `cargo test --test e2e_safe -- --ignored`.
//! `EDW_TUI_E2E_RECORD=1` also records `target/e2e-screenshots/safe.mp4`.

mod common;

use alloy_primitives::{Address, B256, U256, keccak256};
use alloy_provider::{Provider, ProviderBuilder};
use alloy_sol_types::{SolCall, sol};
use common::scenario::{Chain, ETHER, Scenario};
use edw_tui::skills::sandbox;
use serde_json::Value;

sol! {
    function nonce() returns (uint256);
    function approvedHashes(address owner, bytes32 hash) returns (uint256);
    function approveHash(bytes32 hashToApprove);
}

/// `owners` is the Safe's mapping at storage slot 2; slot of `owners[key]`.
fn owner_slot(key: Address) -> B256 {
    let mut word = [0u8; 64];
    word[12..32].copy_from_slice(key.as_slice());
    word[63] = 2;
    keccak256(word)
}

/// Makes `me` an owner of `safe` on the fork by taking over the first owner's place in the list.
async fn become_owner(rpc: &str, safe: Address, me: Address) {
    let provider = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    let sentinel = Address::with_last_byte(1);
    let head = provider
        .get_storage_at(safe, owner_slot(sentinel).into())
        .await
        .unwrap();
    let first = Address::from_word(head.into());
    let after_first = provider
        .get_storage_at(safe, owner_slot(first).into())
        .await
        .unwrap();
    for (slot, value) in [
        (owner_slot(sentinel), B256::from(me.into_word())),
        (owner_slot(me), B256::from(after_first)),
        (owner_slot(first), B256::ZERO),
    ] {
        let _: serde_json::Value = provider
            .raw_request("anvil_setStorageAt".into(), (safe, slot, value))
            .await
            .unwrap();
    }
}

/// A 4-of-11 mainnet Safe with a standing queue and many executed payouts.
const MAINNET_SAFE: &str = "0xA03be496e67Ec29bC62F01a428683D7F9c204930";
/// A 3-of-5 Safe on Gnosis Chain.
const GNOSIS_SAFE: &str = "0x9cFA3e01d3E093D5ADAcf08f9A391EFF42C40D86";

/// Busy mainnet Safes, to find one with a transaction waiting right now (queues come and go).
const BUSY_SAFES: [&str; 80] = [
    "0x8a25A24EDE9482C4Fc0738F99611BE58F1c839AB",
    "0x4D2fB5F8Ec243fde4DF1A9678b82238570c7E0E4",
    "0xcA6817DAb36850D58375A10c78703CE49d41D25a",
    "0x5F2876944247f302DFF857431E26951C2B8Dfa33",
    "0x5637a7552003411c8953Feba6E38951a32Ab9c49",
    "0xddb901e4E9A2e659aa1d6476d5D7A2833E7c3dFa",
    "0x72dce6fA22ebA1F0abCb28629A3918c6C88269Da",
    "0xB1748C79709f4Ba2Dd82834B8c82D4a505003f27",
    "0xAA13eC1fbC3a180a2eB5c5F8c34D22956F94e94A",
    "0xc613B5C2bff2955761c27FC3BFC4E91Ce12472A7",
    "0x4504dB1ca6659fa04b5BC9C96deEe4691c58f034",
    "0x1FBd9538112540AC2314Cd6f23A5a8d192Ac4789",
    "0xD8C0edD02D5d377A7E355c10c160fc5E0743442D",
    "0x32a0eE82a7CDee2E1E1Ccb6fcAD333C134A27588",
    "0xF2900ED955194668afA92c08274d604C5aB7D652",
    "0xb7f09490d5E7cdd2F045bD4Fca06D60B13c680f9",
    "0xc705E757591b8f86C6bb67543CD274b48aD008e9",
    "0xA90f96b5fcD5BDc0AaE788c0485786B0E546D950",
    "0xC67aAD57ea006fDA2E1B3E5E6497895fc30E50AA",
    "0xf40bcc0845528873784F36e5C105E62a93ff7021",
    "0x386DE0C673b494317e720637984Fc744235Ade7A",
    "0xF5C68954bc3aF7fe0A453493C976313E7284D589",
    "0xBf41C0DC65ea4879D8A74E0a69737AF7B3e0Fa13",
    "0x5D0C187f4e1a4C6f07Fb41F16c0452c95DE4EB9F",
    "0x260915385D24468036789843121e7c8B8c5AB8e9",
    "0x7A800c8504686118633549409644C7f63D11Af68",
    "0xB3C80F62C182875592aAB71704F7C3B9D152512E",
    "0x7E2966eb0750a9270e28570adC213Aeb5286596e",
    "0xf905f1D9324930EA51180f455c029E8B841a6b52",
    "0x058B5Eeb9e89e8192995199B2F79f65293C771C3",
    "0xDE8fa8585df818e8cD9346117f574a0cd9567175",
    "0x4A2FbE06004e37dE6Fe7Da59a53D14a407Def0ed",
    "0xE83BF54F0Ebd70Caa64224Ecfd24A62d569BE13e",
    "0x5108aEAf373D004d2372be82C206Ec9aA7f1872F",
    "0x8035D75bbCAE1D574A387F58d87519cdf56069C5",
    "0x9187807e07112359C481870feB58f0c117a29179",
    "0xdE2A16119fA58966d50e1BB718391CD984e30a1a",
    "0x2b95F3d0b89b24B432DAcC5d1E9a621a9A79e687",
    "0xaB05c0DB9D26e96A9dcEDCAFCA23341316F6fe6F",
    "0x224A1019C39CE671221bfd5f64Af28d0513d0A11",
    "0x4371e7eC29BbB60872E15C5123C3CaC948967Eb7",
    "0xcCA96aDC132731979B96253C74eB2431FaD2D752",
    "0xd63E6A63706eE25587DAb2F173ABdC80f97BE391",
    "0x6F7648dF7291E6D718fFB7357920559B3a31414E",
    "0x429a56A319Ef01bA4BFD97c45fB88312CaB35962",
    "0xC340d79861dce76BE434ec57b88b3CDDb40B9FA7",
    "0x9Ae62E364046f3A0fb5dd1d0eA3f6bb763451e37",
    "0x366D6561Adb89ff1AB5635838FBFC51E514656d2",
    "0x6e13e93a9Cf41c5185f72936e6199065031796e4",
    "0x73B5f6D0dB35e6Af11308D96634aFb9652ca7251",
    "0x3e9fAEDC16947961246f3cf5d980558d0702A002",
    "0x663b1458eeF21E6d2575C4a5085D43E0CbeA874e",
    "0xde50643d28DeC441ea185A85D69885149AFa9012",
    "0x2DC7FBBc0634Afbc57cAe1b052E482C67CA9377d",
    "0xB7133f46b713e808253cb13d315aAC15ef134BAb",
    "0xD78a8051B3dD36caA1b90D47c3bB93B327EC2C64",
    "0x6B790e2b5173bFBc01226a50bAc82085b3266b6B",
    "0x10EC9E5a9B6EB940fE5077112C7E8CfAbA966b15",
    "0x1A7fEA39D94de24df87B35853ed3b6AF82CF22E7",
    "0x7cC835597EADFa3C5A5d9f0B90c0491C289B8Eee",
    "0x73704eC6eec1563609f78F2Bf49f391CAB2B0a01",
    "0x3887d605A519253f3a8cd29A062C71A13D0D7F1C",
    "0x7B42E8F9dD4d077672d5B72a11D637F3706fc81c",
    "0x73853832B3446b860Cb499Ce402B8cab8be9e1AA",
    "0x928EeEd9915D7b53FE43f083Da52D564D0DaC04D",
    "0xA03be496e67Ec29bC62F01a428683D7F9c204930",
    "0xbc215A726ebf3BcC8Ba97a832Fd3c3bEbCa57300",
    "0x93782fdC9ba656035A0c4cbC1b5878Ad5AD256df",
    "0xaFbf278e06D2269abA2a4898AfbAB2ECb2584924",
    "0x332a9022237cdc3E575D12f71363289Dc8507048",
    "0x86FD88308CF324024033c0833552cfAdFDb674D6",
    "0x0c711e267a25dCCC882265772acD554119757A6f",
    "0x0BA2e84Ad8EEAa9D94447601C6a7ec7235287A2F",
    "0xf816B77f22BBd13688868E8143f56B7c4ff06D88",
    "0xAA088dfF3dcF619664094945028d44E779F19894",
    "0x29065a4C1f2F20d1E263930088890d6F49Fe715a",
    "0x6260D4Bf86b3802D5F5f881925Db2c3a96f42D23",
    "0x5BeE0a99681796088f3b9023b7372EFE7e454746",
    "0x16C8Bb734f59875F00C4e09f535946E237c8258C",
    "0x1d7783D227eE3d7940924a314686034a8557EC69",
];

fn get(url: &str) -> Value {
    let body = std::process::Command::new("curl")
        .args(["-s", "--max-time", "30", url])
        .output()
        .expect("curl");
    serde_json::from_slice(&body.stdout).unwrap_or(Value::Null)
}

/// A busy Safe with one plain call waiting at its next nonce (nobody else is proposing there,
/// and it is not a call to the Safe itself), from the live Safe service: (Safe, nonce, hash).
fn waiting_transaction() -> (Address, u64, B256) {
    let base = "https://api.safe.global/tx-service/eth/api/v1/safes";
    for safe in BUSY_SAFES {
        let current = get(&format!("{base}/{safe}/"))["nonce"]
            .as_str()
            .and_then(|n| n.parse::<u64>().ok());
        let Some(current) = current else { continue };
        let page = get(&format!(
            "{base}/{safe}/multisig-transactions/?executed=false&nonce__gte={current}&ordering=nonce&limit=20"
        ));
        let rows = page["results"].as_array().cloned().unwrap_or_default();
        if let Some(row) = rows.iter().find(|r| {
            rows.iter().filter(|o| o["nonce"] == r["nonce"]).count() == 1
                && r["operation"] == 0
                && r["to"]
                    .as_str()
                    .is_some_and(|to| !to.eq_ignore_ascii_case(safe))
        }) {
            return (
                safe.parse().unwrap(),
                row["nonce"].as_u64().unwrap(),
                row["safeTxHash"].as_str().unwrap().parse().unwrap(),
            );
        }
    }
    panic!("none of the busy Safes has a transaction waiting; try again later");
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "forks mainnet and calls the Safe service over the network; needs anvil, edw and Docker"]
async fn safe_questions_are_answered_from_the_chain_and_the_service() {
    if !sandbox::docker_available().await {
        eprintln!("skipping: Docker is not running");
        return;
    }
    // Looked up first, so the recording does not sit through the search.
    let (safe, waiting, hash) = waiting_transaction();
    let Some(mut s) = Scenario::start_with_skills("safe", Chain::MainnetFork).await else {
        return;
    };
    s.confirmed("unlock mainnet", "Unlocked");
    let provider = ProviderBuilder::new().connect_http(s.rpc.parse().unwrap());
    let before = provider.get_block_number().await.unwrap();

    // Who controls it: read from the Safe service and checked against the chain's own getOwners.
    s.ask(
        &format!("who controls safe {MAINNET_SAFE}?"),
        "match the chain",
    );
    s.screenshot("safe_info");
    let screen = s.tui.screen();
    assert!(screen.contains("4 of 11 owners must sign"), "{screen}");

    // What is waiting: plain English, signatures so far, and warnings.
    s.ask(
        &format!("what is waiting for signatures on safe {MAINNET_SAFE}?"),
        "waiting",
    );
    s.screenshot("safe_queue");

    // What it did: executed batches, summarised as payouts.
    s.ask(
        &format!("what did safe {MAINNET_SAFE} do recently?"),
        "Recently executed",
    );
    s.screenshot("safe_activity");
    assert!(s.tui.screen().contains("Pays"), "{}", s.tui.screen());

    // Another chain by name: the wallet is on Ethereum, so there is no on-chain cross-check.
    s.ask(
        &format!("who controls safe {GNOSIS_SAFE} on gnosis?"),
        "not checked: the wallet is not on Gnosis Chain",
    );
    s.screenshot("safe_gnosis");

    // Every question was a read: the fork did not mine a block.
    assert_eq!(provider.get_block_number().await.unwrap(), before);

    // The write. The profile becomes an owner of the Safe on the fork, then approves a waiting
    // transaction: the skill checks the Safe's own hash against the service's, the checker pins
    // the call to this Safe and to approveHash, and the user confirms the review.
    let me = s.address("0/0").await;
    s.fund(me, U256::from(10 * ETHER)).await;
    become_owner(&s.rpc, safe, me).await;
    let call = |data: Vec<u8>| {
        alloy_rpc_types_eth::TransactionRequest::default()
            .to(safe)
            .input(data.into())
    };
    let mined = provider.get_block_number().await.unwrap();
    s.confirmed(
        &format!("approve nonce {waiting} on safe {safe}"),
        "approval for that transaction",
    );
    s.screenshot("safe_approve");

    let latest = provider.get_block_number().await.unwrap();
    let mut sent = Vec::new();
    for number in mined + 1..=latest {
        let block = provider
            .get_block_by_number(number.into())
            .await
            .unwrap()
            .unwrap();
        for tx in block.transactions.hashes() {
            let receipt = provider.get_transaction_receipt(tx).await.unwrap().unwrap();
            let input = provider.get_transaction_by_hash(tx).await.unwrap().unwrap();
            let data = serde_json::to_value(&input).unwrap()["input"]
                .as_str()
                .unwrap()
                .to_owned();
            sent.push((receipt.from, receipt.to, receipt.status(), data));
        }
    }
    assert_eq!(
        sent,
        [(
            me,
            Some(safe),
            true,
            format!(
                "0x{}",
                alloy_primitives::hex::encode(
                    approveHashCall {
                        hashToApprove: hash
                    }
                    .abi_encode()
                )
            )
        )],
        "exactly one approveHash to the Safe"
    );
    let approved = approvedHashesCall::abi_decode_returns(
        &provider
            .call(call(approvedHashesCall { owner: me, hash }.abi_encode()))
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(approved, U256::from(1), "the Safe recorded the approval");

    // Read again: the queue now says the profile has approved it.
    s.ask(
        &format!("what is waiting for signatures on safe {safe}?"),
        // Only the queue's new line has this word, lower case (the panel wraps longer phrases).
        "approved",
    );
    s.screenshot("safe_queue_after");
    assert!(
        s.tui.screen().contains(&format!("#{waiting}")),
        "{}",
        s.tui.screen()
    );
    s.finish("safe");
}
