//! Skills inside the Rig loop: a skill's tools are offered only after `load_skill`, run in
//! Docker, and refuse made-up addresses. Needs edw and anvil; the Docker part skips without
//! Docker.

mod common;

use std::{path::Path, sync::Arc};

use alloy_node_bindings::Anvil;
use common::{
    Harness, TempWallet, edw_binary,
    recorder::{Recorder, call},
};
use edw_tui::skills::{
    catalog::{self, Catalog, SkillState},
    sandbox::{self, Runner},
    tools::SkillSet,
};
use rig_agent::ModelHandle;
use serde_json::json;

fn probe_skills() -> Arc<SkillSet> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut installed = catalog::discover(&[root.join("tests/fixtures/skills")]);
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

async fn start(
    name: &str,
    model: Recorder,
) -> Option<(Harness, alloy_node_bindings::AnvilInstance)> {
    start_with(name, model, true).await
}

async fn start_with(
    name: &str,
    model: Recorder,
    unlock: bool,
) -> Option<(Harness, alloy_node_bindings::AnvilInstance)> {
    let binary = edw_binary().or_else(|| {
        eprintln!("skipping: edw is not installed");
        None
    })?;
    let node = Anvil::new().try_spawn().ok().or_else(|| {
        eprintln!("skipping: anvil is not installed");
        None
    })?;
    let wallet = TempWallet::new(binary, name);
    if unlock {
        wallet.edw(&["unlock", "--network", "local"]).await;
    }
    let interim = wallet.interim(Some(node.endpoint()), false);
    let h = Harness::start_with_skills(
        wallet,
        ModelHandle::named("recorder", model),
        Some(interim),
        probe_skills(),
    );
    Some((h, node))
}

#[tokio::test]
async fn a_skills_tools_are_offered_only_after_it_is_loaded() {
    let docker = sandbox::docker_available().await;
    let model = Recorder::new(vec![
        call("load_skill", json!({"name": "probe"})),
        call("probe_echo", json!({"mode": "echo"})),
    ]);
    let offered = model.offered.clone();
    let Some((mut h, _node)) = start("skills-gate", model).await else {
        return;
    };
    let turn = h.turn("probe something", true).await;
    let offered = offered.lock().unwrap().clone();
    assert!(offered[0].contains(&"load_skill".to_owned()), "{offered:?}");
    assert!(offered[0].contains(&"transfer".to_owned()), "{offered:?}");
    assert!(
        !offered[0].contains(&"probe_echo".to_owned()),
        "{offered:?}"
    );
    assert!(offered[1].contains(&"probe_echo".to_owned()), "{offered:?}");
    // The log says what was loaded; the SKILL.md text is for the model, not the log.
    assert!(
        turn.outputs[0].contains("Loaded probe (tools: probe_echo, probe_act)"),
        "{turn:?}"
    );
    assert!(
        !turn.outputs[0].contains("call probe_echo with a mode"),
        "{turn:?}"
    );
    if docker {
        assert!(
            turn.outputs
                .iter()
                .any(|o| o.contains("\"chain_id\":31337")),
            "{turn:?}"
        );
    }
}

#[tokio::test]
async fn an_unknown_skill_lists_the_catalog_and_unloaded_tools_are_refused() {
    let model = Recorder::new(vec![
        call("load_skill", json!({"name": "nope"})),
        call("probe_echo", json!({"mode": "echo"})),
    ]);
    let Some((mut h, _node)) = start("skills-unknown", model).await else {
        return;
    };
    let turn = h.turn("go", true).await;
    assert!(turn.outputs[0].contains("probe"), "{turn:?}");
    assert!(
        turn.outputs[0].contains("no skill named `nope`"),
        "{turn:?}"
    );
    // The gate never offered probe_echo, so Rig rejects the call before any tool runs.
    assert_eq!(
        turn.outputs.len(),
        1,
        "a tool of an unloaded skill never runs: {turn:?}"
    );
}

#[tokio::test]
async fn a_made_up_address_never_reaches_a_skill() {
    let model = Recorder::new(vec![
        call("load_skill", json!({"name": "probe"})),
        call(
            "probe_echo",
            json!({"mode": "echo", "to": "0x1111111111111111111111111111111111111111"}),
        ),
    ]);
    let Some((mut h, _node)) = start("skills-invented", model).await else {
        return;
    };
    let turn = h.turn("probe 0x2222", true).await;
    assert!(
        turn.outputs.iter().any(|o| o.contains("Refused")
            && o.contains("made up")
            && o.contains("nothing was run")),
        "{turn:?}"
    );
}

/// For an action the refusal reads like a transfer's: nothing was sent.
#[tokio::test]
async fn a_made_up_address_never_reaches_a_skill_action() {
    let model = Recorder::new(vec![
        call("load_skill", json!({"name": "probe"})),
        call(
            "probe_act",
            json!({"mode": "plan", "to": "0x1111111111111111111111111111111111111111"}),
        ),
    ]);
    let Some((mut h, _node)) = start("skills-invented-act", model).await else {
        return;
    };
    let turn = h.turn("act", true).await;
    assert!(turn.confirms.is_empty(), "{turn:?}");
    assert!(
        turn.outputs
            .iter()
            .any(|o| o.contains("made up") && o.contains("nothing was sent")),
        "{turn:?}"
    );
}

/// Looking things up needs no wallet: a read tool runs while the wallet is locked, with no
/// sender or RPC in its context. An action still needs the wallet unlocked.
#[tokio::test]
async fn read_tools_run_with_the_wallet_locked_and_actions_do_not() {
    if !sandbox::docker_available().await {
        eprintln!("skipping: Docker is not running");
        return;
    }
    let model = Recorder::new(vec![
        call("load_skill", json!({"name": "probe"})),
        call("probe_echo", json!({"mode": "echo"})),
        call("probe_act", json!({"mode": "plan"})),
    ]);
    let Some((mut h, _node)) = start_with("skills-locked", model, false).await else {
        return;
    };
    let turn = h.turn("look something up", true).await;
    let read = turn
        .outputs
        .iter()
        .find(|o| o.contains("probe/probe_echo"))
        .unwrap_or_else(|| panic!("{turn:?}"));
    assert!(read.contains("=> 0:"), "the read tool ran: {read}");
    assert!(
        read.contains("\"chain_id\":null"),
        "no wallet context: {read}"
    );
    let act = turn
        .outputs
        .iter()
        .find(|o| o.contains("probe/probe_act"))
        .unwrap_or_else(|| panic!("{turn:?}"));
    assert!(act.contains("locked"), "an action needs the wallet: {act}");
    assert!(turn.confirms.is_empty(), "{turn:?}");
}
