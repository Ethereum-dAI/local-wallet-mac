//! The shipped `private-aave-borrow` skill. Offline: what its manifest lets a plan do. With
//! `-- --ignored` (network, Docker, anvil): its script plans against Aave's Sepolia market on an
//! anvil fork (`EDW_TUI_SEPOLIA_RPC`, default a public endpoint), and the calls it plans run there
//! from an account that holds only the supplied ETH, as the fresh account would, followed by a
//! prepared 200 DAI shield's approvals and deposits into Tornado's Sepolia DAI pool.

use std::{path::Path, sync::Arc};

use alloy_network::TransactionBuilder;
use alloy_node_bindings::Anvil;
use alloy_primitives::{Address, Bytes, U256, address};
use alloy_provider::{Provider, ProviderBuilder};
use alloy_rpc_types_eth::TransactionRequest;
use alloy_sol_types::{SolCall, sol};
use edw_core::{
    network::NetworkPreset,
    vault::tornadocash::{resolve_asset, token_address},
};
use edw_tui::{
    edw,
    interim::SkillContext,
    skills::{
        author,
        catalog::{self, Catalog, SkillState},
        manifest::{self, Approval, RunsFrom, Skill},
        plan::{self, Account},
        sandbox::{self, Output, Runner},
        tools::SkillSet,
    },
    tornado::borrow::Request,
};
use serde_json::{Value, json};

const SEPOLIA: u64 = 11_155_111;
/// edw's preparation of a 200 DAI shield on Sepolia, recorded from edw: two approvals of 100
/// DAI to the Tornado DAI pool, each followed by a deposit.
const SHIELD_DAI_200: &str = include_str!("fixtures/shield_prepared_dai_200.json");

fn load(name: &str) -> Skill {
    manifest::load(
        &Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("skills")
            .join(name),
    )
    .unwrap()
}

#[test]
fn it_pins_aave_v3_lends_sepolia_addresses_and_the_tornado_dai() {
    let (skill, aave) = (load("private-aave-borrow"), load("aave-v3-lend"));
    assert_eq!(skill.manifest.requires, ["aave-v3-lend"]);
    for id in ["pool", "gateway"] {
        let pinned = &skill.manifest.contract(id).unwrap().address;
        assert_eq!(pinned.keys().collect::<Vec<_>>(), [&SEPOLIA], "{id}");
        assert_eq!(
            pinned[&SEPOLIA],
            aave.manifest.contract(id).unwrap().address[&SEPOLIA],
            "{id}"
        );
    }
    for id in ["dai", "weth"] {
        let token = skill.manifest.token(id).unwrap();
        assert_eq!(token.approval, Approval::Never, "{id}");
        assert_eq!(
            token.address[&SEPOLIA],
            aave.manifest.token(id).unwrap().address[&SEPOLIA],
            "{id}"
        );
    }
    let tornado_dai = token_address(&resolve_asset("DAI", SEPOLIA).unwrap()).unwrap();
    assert_eq!(
        skill.manifest.token("dai").unwrap().address[&SEPOLIA],
        tornado_dai
    );
}

#[test]
fn its_one_action_runs_from_the_fresh_account_and_approves_nothing() {
    let skill = load("private-aave-borrow");
    let [action] = skill.manifest.actions.as_slice() else {
        panic!("one action");
    };
    assert_eq!(action.tool.name, "private_aave_borrow");
    assert_eq!(action.account, RunsFrom::Fresh);
    assert!(action.approves.is_empty());
    let functions: Vec<String> = skill
        .manifest
        .contracts
        .iter()
        .flat_map(|c| c.functions.iter().map(|f| format!("{}.{}", c.id, f.name)))
        .collect();
    assert_eq!(functions, ["pool.borrow", "gateway.depositETH"]);
    let report = author::check(&skill.dir);
    assert!(report.errors.is_empty(), "{:?}", report.errors);
}

sol! {
    function balanceOf(address owner) returns (uint256);
}

#[tokio::test]
#[ignore = "forks Sepolia over the network; needs anvil and Docker"]
async fn its_plan_for_a_fresh_account_borrows_dai_that_the_shield_deposits_on_a_sepolia_fork() {
    if !sandbox::docker_available().await {
        eprintln!("skipping: Docker is not running");
        return;
    }
    let rpc = std::env::var("EDW_TUI_SEPOLIA_RPC")
        .unwrap_or_else(|_| "https://ethereum-sepolia-rpc.publicnode.com".into());
    let fork = Anvil::new().fork(rpc).try_spawn().expect("anvil fork");
    let mut installed = catalog::discover(&[Path::new(env!("CARGO_MANIFEST_DIR")).join("skills")]);
    for i in &mut installed {
        i.state = SkillState::Ready;
    }
    catalog::resolve(&mut installed, &edw::tool_names(), true);
    let set = SkillSet::new(
        Catalog::from_installed(&installed),
        &installed,
        Runner::from_env(),
    );
    let skill = set.catalog.get("private-aave-borrow").unwrap().clone();
    let action = skill.action("private_aave_borrow").unwrap();
    let fresh = address!("0x00000000000000000000000000000000F5E5F5E5");
    let at = SkillContext {
        chain_id: SEPOLIA,
        me: fresh,
        network: "sepolia".into(),
        rpc: fork.endpoint().parse().unwrap(),
    };
    let request = Request::from_call(
        &json!({"eth": "1", "amount": "200"}),
        NetworkPreset::Sepolia,
    )
    .unwrap();
    let run = |request: Request| {
        let invoke = sandbox::invoke_message(
            &action.tool.name,
            &request.script_args(),
            set.context(&skill, Some(&at)),
        );
        let host = set.host(&skill, Some(at.rpc.clone()), Arc::new(|_| {}));
        let (snapshot, run_dir) = set.prepare_run(&skill).unwrap();
        let run = action.tool.run.clone();
        let runner = &set.runner;
        async move {
            let output = runner.run(&snapshot, &run, invoke, &host).await;
            drop(run_dir);
            output
        }
    };
    let too_much = Request::from_call(
        &json!({"eth": "0.1", "amount": "1000"}),
        NetworkPreset::Sepolia,
    )
    .unwrap();
    let refused = run(too_much).await.unwrap_err();
    assert!(
        refused.contains("Unshield more ETH or borrow less"),
        "{refused}"
    );
    let args = request.script_args();
    let Output::Plan(proposed) = run(request.clone()).await.unwrap() else {
        panic!("a plan");
    };
    eprintln!("{proposed}");
    let checked = plan::check(
        &proposed,
        &skill,
        action,
        SEPOLIA,
        Account::Fresh(fresh),
        &args,
    )
    .unwrap();
    let aave = request.aave(checked.clone(), fresh).unwrap();
    assert_eq!(aave.supply, U256::from(900_000_000_000_000_000u64));
    assert_eq!(aave.borrow, U256::from(200u128 * 10u128.pow(18)));

    let provider = ProviderBuilder::new().connect_http(at.rpc.clone());
    let _: () = provider
        .raw_request(
            "anvil_setBalance".into(),
            (fresh, aave.supply * U256::from(2)),
        )
        .await
        .unwrap();
    let _: () = provider
        .raw_request("anvil_impersonateAccount".into(), (fresh,))
        .await
        .unwrap();
    let shield: Value = serde_json::from_str(SHIELD_DAI_200).unwrap();
    let shield_calls = shield["calls"].as_array().unwrap().iter().map(|call| {
        (
            call["target"].as_str().unwrap().parse::<Address>().unwrap(),
            U256::ZERO,
            call["data"].as_str().unwrap().parse::<Bytes>().unwrap(),
        )
    });
    let calls: Vec<(Address, U256, Bytes)> = checked
        .steps
        .iter()
        .map(|step| (step.to, step.value, step.data.clone()))
        .chain(shield_calls)
        .collect();
    let dai: Address = skill.manifest.token("dai").unwrap().address[&SEPOLIA];
    let tornado_dai: Address = shield["calls"][1]["target"]
        .as_str()
        .unwrap()
        .parse()
        .unwrap();
    let balance = |owner: Address| {
        let provider = provider.clone();
        async move {
            let raw = provider
                .call(
                    TransactionRequest::default()
                        .with_to(dai)
                        .with_input(balanceOfCall { owner }.abi_encode()),
                )
                .await
                .unwrap();
            U256::from_be_slice(&raw)
        }
    };
    let pool_before = balance(tornado_dai).await;
    for (n, (to, value, data)) in calls.into_iter().enumerate() {
        let tx = TransactionRequest::default()
            .with_from(fresh)
            .with_to(to)
            .with_value(value)
            .with_input(data)
            // An exact estimate can run out: Aave's borrow costs more in a later block.
            .with_gas_limit(3_000_000);
        let receipt = provider
            .send_transaction(tx)
            .await
            .unwrap()
            .get_receipt()
            .await
            .unwrap();
        assert!(receipt.status(), "call {}: {receipt:?}", n + 1);
    }
    assert_eq!(
        balance(fresh).await,
        U256::ZERO,
        "the shield took all the DAI"
    );
    assert_eq!(balance(tornado_dai).await - pool_before, aave.borrow);
}
