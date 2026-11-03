//! Everything that exercises the Tornado tools and the private borrow, as one test target (one
//! link, one `common`). `shield`, `borrow` and `fork` are files; `held_notes`, `skill` and `live` are inline below:
//! - `shield`: shield, unshield and prepare_shield through the agent and the review.
//! - `held_notes`: the held-notes check against the pinned edw.
//! - `borrow`: the private borrow through the card and the pinned edw.
//! - `skill`: the shipped `private-aave-borrow` skill.
//! - `fork`: the whole borrow on a Sepolia fork (ignored).
//! - `live`: the borrow through the real TUI on Sepolia (ignored).

#[path = "../common/mod.rs"]
mod common;

mod borrow;
mod fork;
mod shield;

mod held_notes {
    //! The held-notes check against the pinned `edw`, on the anvil that answers as Sepolia
    //! (`common::fake_sepolia`) with notes mined there by `common::mine_eth_notes`. For every amount,
    //! the check passes exactly when edw's own `unshield` gets past picking notes and goes on to
    //! prove; when it refuses, edw refused for the same rule. Skips without edw or anvil.

    use std::time::Duration;

    use crate::common::{edw_binary, fake_sepolia, mine_eth_notes};
    use edw_core::{network::NetworkPreset, vault::tornadocash::parse_amount};
    use edw_tui::{
        edw::{self, EdwConfig, EdwResult},
        tornado::{
            Command,
            held::{HeldEth, Refusal},
        },
    };
    use serde_json::Value;

    const BALANCE: &str = include_str!("../fixtures/balance_detailed_tornado_notes.json");

    async fn run(config: &EdwConfig, argv: Vec<String>) -> EdwResult {
        edw::run_with_timeout(config, &argv, Duration::from_secs(120)).await
    }

    async fn held(config: &EdwConfig) -> (Value, HeldEth) {
        let balance = run(config, Command::PrivateBalance.argv("0/0")).await;
        let held = HeldEth::read(&balance, NetworkPreset::Sepolia).unwrap();
        (balance.document().unwrap(), held)
    }

    /// The rule edw refused `eth` for while picking notes, or `None` when it went on to prove.
    async fn edw_refusal(config: &EdwConfig, eth: &str) -> Option<Refusal> {
        let argv = [
            "unshield",
            "--token",
            "ETH",
            "--amount-formatted",
            eth,
            "--yes",
            "--profile",
            "0/0",
        ];
        let result = run(config, argv.map(str::to_owned).to_vec()).await;
        assert!(
            !result.ok(),
            "this chain has no EntryPoint, so nothing can be sent: {result:?}"
        );
        if result.output.contains("proving the sponsoring") {
            return None;
        }
        let message = result.document().unwrap()["message"].clone();
        match message.as_str().unwrap_or_default() {
            m if m.starts_with("held notes cannot make") => Some(Refusal::CannotMake),
            "the selected ETH notes have no paymaster" => Some(Refusal::NoSponsor),
            _ => panic!("{eth} ETH failed before picking notes: {result:?}"),
        }
    }

    async fn compare(config: &EdwConfig, held: &HeldEth, amounts: &[&str]) {
        for &eth in amounts {
            let ours = held
                .unshield(parse_amount(eth, 18).unwrap(), "0/0")
                .err()
                .map(|refused| refused.reason);
            // edw has no word for "not mined yet": it says the held notes cannot make the amount.
            let ours = ours.map(|reason| match reason {
                Refusal::NotMined => Refusal::CannotMake,
                other => other,
            });
            assert_eq!(ours, edw_refusal(config, eth).await, "{eth} ETH");
        }
    }

    #[tokio::test]
    async fn the_check_refuses_exactly_what_edw_refuses() {
        let Some(binary) = edw_binary() else {
            eprintln!("skipping: edw is not installed");
            return;
        };
        let Some((wallet, chain)) = fake_sepolia(binary, "held-notes").await else {
            return;
        };
        let config = &wallet.config;
        let (_, none) = held(config).await;
        assert!(none.notes.is_empty(), "{none:?}");
        compare(config, &none, &["1"]).await;

        mine_eth_notes(&wallet, &chain, "11").await;
        wallet
            .edw(&[
                "shield",
                "--prepare",
                "--token",
                "ETH",
                "--amount-formatted",
                "0.1",
                "--profile",
                "0/0",
            ])
            .await;
        let (document, notes) = held(config).await;
        let fixture: Value = serde_json::from_str(BALANCE).unwrap();
        assert_eq!(
            document["tornado_notes"], fixture["tornado_notes"],
            "the fixture is what the pinned edw lists for these notes"
        );
        compare(
            config,
            &notes,
            &["0.1", "1", "1.1", "2", "10", "11", "11.1"],
        )
        .await;

        // Ten 1 ETH notes could make 10 ETH with a paymaster, but edw takes the 10 ETH note first.
        mine_eth_notes(&wallet, &chain, "9").await;
        let (_, more) = held(config).await;
        compare(config, &more, &["9", "10", "20"]).await;
    }
}

mod live {
    //! The private borrow on real Sepolia, through the real terminal: the compiled `edw-tui` in a
    //! pseudo-terminal, the scripted model, the pinned edw, Docker for the skill's script, and the
    //! public bundler. Moves real Sepolia funds.
    //!
    //! Needs a wallet whose profile 0/0 holds a mined 0.1 ETH shielded note (one in a pool with a
    //! paymaster): `EDW_TUI_LIVE_DATA_DIR` is its edw data dir, with the Sepolia RPC already set
    //! (`edw network rpc-config add … --use`). `EDW_DECRYPTION_PASSWORD` defaults to the demo one and
    //! `EDW_TUI_LIVE_RUNTIME_DIR` to `<data dir>/../runtime`. `EDW_TUI_E2E_RECORD=1` also records
    //! `target/e2e-screenshots/private_borrow_live.mp4`.
    //!
    //! `EDW_TUI_LIVE_DATA_DIR=… EDW_TUI_E2E_RECORD=1 cargo test --test tornado live:: -- --ignored --nocapture`

    use std::path::PathBuf;

    use crate::common::{
        edw_binary,
        pty::Tui,
        scenario::{recording, screenshots_dir},
    };

    const ROWS: u16 = 50;
    const COLS: u16 = 240;
    const PROMPT: &str = "privately borrow 100 DAI against 0.1 ETH";

    #[test]
    #[ignore = "moves real Sepolia funds; needs EDW_TUI_LIVE_DATA_DIR, edw, Docker and the network"]
    fn the_private_borrow_on_real_sepolia() {
        let Ok(data_dir) = std::env::var("EDW_TUI_LIVE_DATA_DIR") else {
            eprintln!("skipping: EDW_TUI_LIVE_DATA_DIR is not set");
            return;
        };
        let Some(binary) = edw_binary() else {
            eprintln!("skipping: edw is not installed");
            return;
        };
        let data_dir = PathBuf::from(data_dir);
        let runtime_dir = std::env::var("EDW_TUI_LIVE_RUNTIME_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| data_dir.join("../runtime"));
        let state =
            std::env::temp_dir().join(format!("edw-tui-live-skills-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&state);
        let env = vec![
            ("EDW_TUI_MODEL", "scripted".to_owned()),
            ("EDW_BIN", binary.display().to_string()),
            ("EDW_DATA_DIR", data_dir.display().to_string()),
            ("EDW_RUNTIME_DIR", runtime_dir.display().to_string()),
            (
                "EDW_DECRYPTION_PASSWORD",
                std::env::var("EDW_DECRYPTION_PASSWORD").unwrap_or_else(|_| "edw-tui-demo".into()),
            ),
            (
                "EDW_TUI_SKILLS_DIR",
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("skills")
                    .display()
                    .to_string(),
            ),
            (
                "EDW_TUI_SKILLS_DRAFTS_DIR",
                state.join("drafts").display().to_string(),
            ),
            (
                "EDW_TUI_SKILLS_LOCK",
                state.join("skills.lock").display().to_string(),
            ),
            (
                "EDW_TUI_SKILLS_USER_DIR",
                state.join("added").display().to_string(),
            ),
        ];
        let mut tui = Tui::spawn(
            &PathBuf::from(env!("CARGO_BIN_EXE_edw-tui")),
            &env,
            ROWS,
            COLS,
        );
        if recording() {
            tui.start_recording();
        }
        tui.wait_for("Ask in plain language");
        tui.linger(800);

        loop {
            let screen = tui.wait_for_within("the skills to settle", 180, |s| {
                s.contains("Allow skill") || !s.contains("Preparing skills")
            });
            if !screen.contains("Allow skill") {
                break;
            }
            tui.hold(4000);
            tui.answer(b"y");
            tui.wait_for_within("the card to close", 30, |s| s != screen);
        }

        tui.submit("unlock sepolia");
        tui.wait_for_within("the unlock confirmation", 120, |s| s.contains("[y] run"));
        tui.hold(3000);
        tui.answer(b"y");
        tui.wait_for_within("the unlock", 120, |s| s.contains("edw: Done"));
        tui.wait_for_within("the agent to finish", 120, |s| !s.contains("thinking…"));
        tui.linger(1500);

        tui.submit(PROMPT);
        tui.wait_for_within("the review card", 900, |s| {
            s.contains("[y] ") || s.contains("nothing was sent")
        });
        tui.hold(10_000);
        let card = tui.screen();
        assert!(card.contains("[y] "), "no review card:\n{card}");
        std::fs::write(
            screenshots_dir().join("private_borrow_live_card.txt"),
            &card,
        )
        .unwrap();
        tui.answer(b"y");

        let end = tui.wait_for_within("the unshield to land", 900, |s| {
            s.contains("✓ send") || s.contains("nothing was sent")
        });
        tui.wait_for_within("the agent to finish", 300, |s| !s.contains("thinking…"));
        std::fs::write(
            screenshots_dir().join("private_borrow_live_end.txt"),
            tui.screen(),
        )
        .unwrap();
        tui.linger(1500);
        if let Some(video) = tui.finish_recording(&screenshots_dir(), "private_borrow_live") {
            eprintln!("recorded {}", video.display());
        }
        assert!(end.contains("✓ send"), "the borrow did not land:\n{end}");
    }
}

mod skill {
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
    const SHIELD_DAI_200: &str = include_str!("../fixtures/shield_prepared_dai_200.json");

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
        let mut installed =
            catalog::discover(&[Path::new(env!("CARGO_MANIFEST_DIR")).join("skills")]);
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
                &request.script_args(request.trial_supply()),
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
            &json!({"eth": "0.1", "amount": "500"}),
            NetworkPreset::Sepolia,
        )
        .unwrap();
        let refused = run(too_much).await.unwrap_err();
        assert!(
            refused.contains("Unshield more ETH or borrow less"),
            "{refused}"
        );
        let args = request.script_args(request.trial_supply());
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
        let aave = request
            .aave(checked.clone(), fresh, request.trial_supply())
            .unwrap();
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
}
