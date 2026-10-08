//! `safe_execute` against a real Safe 1.5.0 on a mainnet fork.
//!
//! Safe 1.5.0 changed `checkNSignatures`, which `safe_execute` asks before it proposes anything.
//! The Docker tests only have recorded answers, so this one runs the shipped script (in Docker,
//! with the Safe service answered from a canned page) against the real 1.5.0 contract:
//! the sender is made the Safe's only owner, approves a transaction on chain, and the script must
//! build the approved-hash signature, get the Safe to accept it, and the plan must then run.
//!
//! Needs the network (the fork), anvil and Docker: `cargo test --test fork_safe_150 -- --ignored`.

mod common;

use std::{collections::BTreeMap, sync::Arc, time::Duration};

use alloy_node_bindings::Anvil;
use alloy_primitives::{Address, B256, U256, address};
use alloy_provider::{Provider, ProviderBuilder};
use alloy_sol_types::{SolCall, sol};
use common::safe_fork::become_owner;
use edw_tui::skills::{
    host::{Host, HostConfig, SharedCache},
    manifest, plan,
    sandbox::{self, Output, Runner},
};
use serde_json::{Value, json};

sol! {
    function getTransactionHash(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, uint256 _nonce) returns (bytes32);
    function approveHash(bytes32 hashToApprove);
    function nonce() returns (uint256);
    function masterCopy() returns (address);
    function VERSION() returns (string);
    function checkNSignatures(address executor, bytes32 dataHash, bytes signatures, uint256 requiredSignatures);
    function checkNSignaturesOld(bytes32 dataHash, bytes data, bytes signatures, uint256 requiredSignatures);
}

/// A 1-of-1 Safe 1.5.0 on Ethereum, picked from the live service (checked on the fork below).
const SAFE: Address = address!("0x4D2fB5F8Ec243fde4DF1A9678b82238570c7E0E4");
const SINGLETON_150: Address = address!("0xFf51A5898e281Db6DfC7855790607438dF2ca44b");
const ME: Address = address!("0x00000000000000000000000000000000000000A1");
const PAYEE: Address = address!("0x000000000000000000000000000000000000bEEF");

async fn send(rpc: &str, from: Address, to: Address, data: Vec<u8>) {
    let provider = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    let hash: B256 = provider
        .raw_request(
            "eth_sendTransaction".into(),
            [json!({"from": from, "to": to, "data": format!("0x{}", alloy_primitives::hex::encode(data)), "gas": "0x100000"})],
        )
        .await
        .unwrap();
    let mut receipt = None;
    for _ in 0..50 {
        receipt = provider.get_transaction_receipt(hash).await.unwrap();
        if receipt.is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    let receipt = receipt.unwrap_or_else(|| panic!("transaction {hash} was never mined"));
    assert!(receipt.status(), "transaction {hash} reverted");
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "forks mainnet over the network; needs anvil and Docker"]
async fn safe_execute_works_against_a_real_safe_1_5_0() {
    if !sandbox::docker_available().await {
        eprintln!("skipping: Docker is not running");
        return;
    }
    let fork = std::env::var("ETH_RPC_URL")
        .unwrap_or_else(|_| "https://ethereum-rpc.publicnode.com".into());
    let Ok(anvil) = Anvil::new().fork(fork).try_spawn() else {
        eprintln!("skipping: cannot start anvil");
        return;
    };
    let rpc = anvil.endpoint();
    let provider = ProviderBuilder::new().connect_http(rpc.parse().unwrap());
    let call = |to: Address, data: Vec<u8>| {
        alloy_rpc_types_eth::TransactionRequest::default()
            .to(to)
            .input(data.into())
    };
    // It really is a Safe 1.5.0.
    let singleton = masterCopyCall::abi_decode_returns(
        &provider
            .call(call(SAFE, masterCopyCall {}.abi_encode()))
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        singleton, SINGLETON_150,
        "the chosen Safe is no longer a 1.5.0; pick another"
    );
    let version = VERSIONCall::abi_decode_returns(
        &provider
            .call(call(SAFE, VERSIONCall {}.abi_encode()))
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(version, "1.5.0");

    // Prepare: the sender is the only owner (threshold is already 1), the Safe holds some ETH, and
    // the sender approves a payment on chain.
    for who in [ME, SAFE] {
        let _: Value = provider
            .raw_request(
                "anvil_setBalance".into(),
                (who, U256::from(10u64).pow(U256::from(18))),
            )
            .await
            .unwrap();
    }
    let _: Value = provider
        .raw_request("anvil_impersonateAccount".into(), [ME])
        .await
        .unwrap();
    become_owner(&rpc, SAFE, ME, &[]).await;
    let next = nonceCall::abi_decode_returns(
        &provider
            .call(call(SAFE, nonceCall {}.abi_encode()))
            .await
            .unwrap(),
    )
    .unwrap();
    let hash_call = getTransactionHashCall {
        to: PAYEE,
        value: U256::from(1234u64),
        data: Default::default(),
        operation: 0,
        safeTxGas: U256::ZERO,
        baseGas: U256::ZERO,
        gasPrice: U256::ZERO,
        gasToken: Address::ZERO,
        refundReceiver: Address::ZERO,
        _nonce: next,
    };
    let hash = getTransactionHashCall::abi_decode_returns(
        &provider
            .call(call(SAFE, hash_call.abi_encode()))
            .await
            .unwrap(),
    )
    .unwrap();
    send(
        &rpc,
        ME,
        SAFE,
        approveHashCall {
            hashToApprove: hash,
        }
        .abi_encode(),
    )
    .await;

    // Which form of `checkNSignatures` this contract takes, said out loud: 1.5.0 takes the
    // executor and no `data`.
    let approved_by_me = format!(
        "0x{}{}{}01",
        "00".repeat(12),
        alloy_primitives::hex::encode(ME),
        "00".repeat(32)
    );
    let signatures = alloy_primitives::hex::decode(&approved_by_me[2..]).unwrap();
    let with_executor = checkNSignaturesCall {
        executor: ME,
        dataHash: hash,
        signatures: signatures.clone().into(),
        requiredSignatures: U256::from(1),
    };
    let old = checkNSignaturesOldCall {
        dataHash: hash,
        data: Default::default(),
        signatures: signatures.into(),
        requiredSignatures: U256::from(1),
    };
    let new_form = provider.call(call(SAFE, with_executor.abi_encode())).await;
    let old_form = provider.call(call(SAFE, old.abi_encode())).await;
    eprintln!("1.5.0 checkNSignatures(executor, hash, signatures, n): {new_form:?}");
    eprintln!("1.3.0/1.4.1 form (hash, data, signatures, n): {old_form:?}");
    assert!(
        new_form.is_ok(),
        "the 1.5.0 form with an executor must be accepted by the real contract"
    );
    // Control: with no signatures the real function reverts. A selector the contract does not
    // have would fall through to the fallback and answer "ok" to anything, so `Ok` above proves
    // nothing until this is an error.
    let no_signatures_new = checkNSignaturesCall {
        executor: ME,
        dataHash: hash,
        signatures: Default::default(),
        requiredSignatures: U256::from(1),
    };
    let no_signatures_old = checkNSignaturesOldCall {
        dataHash: hash,
        data: Default::default(),
        signatures: Default::default(),
        requiredSignatures: U256::from(1),
    };
    let new_control = provider
        .call(call(SAFE, no_signatures_new.abi_encode()))
        .await;
    let old_control = provider
        .call(call(SAFE, no_signatures_old.abi_encode()))
        .await;
    eprintln!("control, new form with no signatures: {new_control:?}");
    eprintln!("control, old form with no signatures: {old_control:?}");
    assert!(new_control.is_err(), "the 1.5.0 form is a real check");
    assert!(
        old_control.is_ok(),
        "the old form does not exist on 1.5.0: it falls through to the fallback, so it must never be trusted there"
    );

    // The shipped script, against this chain, with the service answered from a canned page.
    let service = format!(
        "GET https://api.safe.global/tx-service/eth/api/v1/safes/{SAFE}/multisig-transactions/?executed=false&nonce={next}&limit=20"
    );
    let row = json!({
        "safe": SAFE.to_string(), "to": PAYEE.to_string(), "value": "1234", "data": null, "operation": 0,
        "gasToken": Address::ZERO.to_string(), "safeTxGas": 0, "baseGas": 0, "gasPrice": "0",
        "refundReceiver": Address::ZERO.to_string(), "nonce": next.to::<u64>(), "safeTxHash": hash.to_string(),
        "confirmations": [], "confirmationsRequired": 1, "dataDecoded": null,
    });
    let fixtures: BTreeMap<String, String> =
        BTreeMap::from([(service, json!({"count": 1, "results": [row]}).to_string())]);
    let skill = manifest::load(
        &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("skills/safe-multisig"),
    )
    .unwrap();
    let action = skill.action("safe_execute").unwrap();
    let host = Host::new(
        HostConfig {
            skill: skill.name.clone(),
            hosts: skill.manifest.hosts.clone(),
            cache: Default::default(),
            rpc: Some(rpc.parse().unwrap()),
            fixtures: Some(Arc::new(fixtures)),
            log: Arc::new(|_| {}),
        },
        SharedCache::default(),
    );
    let runner = Runner {
        timeout: Duration::from_secs(120),
        ..Runner::from_env()
    };
    let input = json!({"address": SAFE.to_string(), "nonce": next.to::<u64>()});
    let context = json!({"chain_id": 1, "me": ME.to_string()});
    let invoke = sandbox::invoke_message("safe_execute", &input, context);
    let Output::Plan(proposed) = runner
        .run(&skill, &action.tool.run, invoke, &host)
        .await
        .expect("the script proposes a plan")
    else {
        panic!("expected a plan")
    };
    let checked = plan::check(&proposed, &skill, action, 1, ME, &input).unwrap();
    let step = &checked.steps[0];
    assert_eq!(step.to, SAFE);
    eprintln!("review lines: {:#?}", step.details);

    // And the plan runs on the real contract: the payment arrives and the nonce moves on.
    let before = provider.get_balance(PAYEE).await.unwrap();
    send(&rpc, ME, step.to, step.data.to_vec()).await;
    assert_eq!(
        provider.get_balance(PAYEE).await.unwrap(),
        before + U256::from(1234u64)
    );
    let after = nonceCall::abi_decode_returns(
        &provider
            .call(call(SAFE, nonceCall {}.abi_encode()))
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(after, next + U256::from(1));
}
