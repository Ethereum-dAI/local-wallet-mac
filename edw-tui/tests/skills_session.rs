//! The agent session behind the Skills tab: startup asks about new skills through the TUI, and
//! every add, disable, enable or delete re-runs that and rebuilds the agent, keeping the chat.
//! Needs edw (for the wallet config); no Docker, no network.

mod common;

use std::{collections::BTreeMap, fs, path::Path, time::Duration};

use common::{TempWallet, edw_binary, recorder::Recorder};
use edw_tui::{
    agent::{self, AgentEvent, ModelSource, Request, Session, SkillOp},
    skills::{Origin, Paths},
};
use rig_core::message::AssistantContent;
use tokio::sync::mpsc;

fn knowledge_skill(root: &Path, name: &str) {
    let dir = root.join(name);
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: about {name}\n---\nbody\n"),
    )
    .unwrap();
}

struct Running {
    requests: mpsc::UnboundedSender<Request>,
    events: mpsc::UnboundedReceiver<AgentEvent>,
}

impl Running {
    async fn next(&mut self) -> AgentEvent {
        tokio::time::timeout(Duration::from_secs(60), self.events.recv())
            .await
            .expect("timed out")
            .expect("session gone")
    }

    /// The next card round or the ready event, skipping log lines.
    async fn settle(&mut self) -> AgentEvent {
        loop {
            match self.next().await {
                AgentEvent::ToolStarted { .. } | AgentEvent::ToolFinished(_) => {}
                other => return other,
            }
        }
    }

    fn send(&self, request: Request) {
        self.requests.send(request).unwrap();
    }
}

fn names(rows: &[edw_tui::skills::SkillRow]) -> Vec<(String, String)> {
    rows.iter()
        .map(|r| (r.name.clone(), r.state.clone()))
        .collect()
}

fn start(wallet: &TempWallet, paths: Paths, model: Recorder) -> Running {
    let (event_tx, events) = mpsc::unbounded_channel();
    let (requests, request_rx) = mpsc::unbounded_channel();
    let session = Session {
        model_name: "recorder".into(),
        model: Some(rig_agent::ModelHandle::named("recorder", model)),
        source: ModelSource {
            ollama_url: common::ollama_url(),
            nudge: false,
        },
        config: wallet.config.clone(),
        interim: wallet.interim(None, false),
        paths: Some(paths),
    };
    tokio::spawn(agent::run_session(session, request_rx, event_tx));
    Running { requests, events }
}

#[tokio::test]
async fn the_skills_tab_adds_disables_enables_and_deletes_live() {
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return;
    };
    let wallet = TempWallet::new(binary, "skills-session");
    let root = tempfile::tempdir().unwrap();
    knowledge_skill(&root.path().join("skills"), "alpha");
    knowledge_skill(&root.path().join("downloads"), "gamma");
    let paths = Paths {
        dirs: vec![root.path().join("skills")],
        user_dir: root.path().join("user"),
        lock: root.path().join("skills.lock"),
        drafts: root.path().join("drafts"),
    };
    let model = Recorder::new(vec![
        AssistantContent::text("hello"),
        AssistantContent::text("still here"),
    ]);
    let offered = model.offered.clone();
    let mut s = start(&wallet, paths.clone(), model);

    // Startup: a card for alpha, then ready.
    match s.settle().await {
        AgentEvent::Consents(cards) => assert_eq!(cards[0].name, "alpha"),
        other => panic!("expected cards, got {other:?}"),
    }
    s.send(Request::SkillsAnswered(BTreeMap::from([(
        "alpha".into(),
        true,
    )])));
    match s.settle().await {
        AgentEvent::SkillsReady { rows, .. } => {
            assert_eq!(names(&rows), [("alpha".into(), "ready".into())])
        }
        other => panic!("{other:?}"),
    }
    s.send(Request::Prompt("hi".into()));
    assert!(matches!(s.settle().await, AgentEvent::Reply(r) if r == "hello"));
    assert!(offered.lock().unwrap()[0].contains(&"load_skill".to_owned()));

    // Disable: no card, and the agent no longer offers skills.
    s.send(Request::Skill(SkillOp::Disable("alpha".into())));
    match s.settle().await {
        AgentEvent::SkillsReady { rows, .. } => {
            assert_eq!(names(&rows), [("alpha".into(), "disabled".into())])
        }
        other => panic!("{other:?}"),
    }
    s.send(Request::Prompt("again".into()));
    assert!(matches!(s.settle().await, AgentEvent::Reply(r) if r == "still here"));
    let last = offered.lock().unwrap().last().unwrap().clone();
    assert!(!last.contains(&"load_skill".to_owned()), "{last:?}");

    // Add, declined: the copy is deleted again.
    s.send(Request::Skill(SkillOp::Add(
        root.path().join("downloads/gamma"),
    )));
    match s.settle().await {
        AgentEvent::Consents(cards) => assert_eq!(cards[0].name, "gamma"),
        other => panic!("{other:?}"),
    }
    s.send(Request::SkillsAnswered(BTreeMap::from([(
        "gamma".into(),
        false,
    )])));
    match s.settle().await {
        AgentEvent::SkillsReady { rows, notes, .. } => {
            assert!(!rows.iter().any(|r| r.name == "gamma"), "{rows:?}");
            assert!(
                notes
                    .iter()
                    .any(|n| n.contains("gamma") && n.contains("not added")),
                "{notes:?}"
            );
        }
        other => panic!("{other:?}"),
    }
    assert!(!paths.user_dir.join("gamma").exists());

    // Add, approved; enable alpha again (approved on its card); then delete gamma.
    s.send(Request::Skill(SkillOp::Add(
        root.path().join("downloads/gamma"),
    )));
    assert!(matches!(s.settle().await, AgentEvent::Consents(_)));
    s.send(Request::SkillsAnswered(BTreeMap::from([(
        "gamma".into(),
        true,
    )])));
    match s.settle().await {
        AgentEvent::SkillsReady { rows, .. } => {
            let gamma = rows.iter().find(|r| r.name == "gamma").unwrap();
            assert_eq!(
                (gamma.state.as_str(), gamma.origin),
                ("ready", Origin::Added)
            );
        }
        other => panic!("{other:?}"),
    }
    s.send(Request::Skill(SkillOp::Enable("alpha".into())));
    match s.settle().await {
        AgentEvent::Consents(cards) => assert_eq!(cards[0].name, "alpha"),
        other => panic!("{other:?}"),
    }
    s.send(Request::SkillsAnswered(BTreeMap::from([(
        "alpha".into(),
        true,
    )])));
    assert!(matches!(s.settle().await, AgentEvent::SkillsReady { .. }));
    s.send(Request::Skill(SkillOp::Delete("gamma".into())));
    match s.settle().await {
        AgentEvent::SkillsReady { rows, .. } => {
            assert_eq!(names(&rows), [("alpha".into(), "ready".into())])
        }
        other => panic!("{other:?}"),
    }
    assert!(!paths.user_dir.join("gamma").exists());

    // A shipped skill is not deleted: the session says why.
    s.send(Request::Skill(SkillOp::Delete("alpha".into())));
    match s.settle().await {
        AgentEvent::Error(e) => assert!(e.contains("shipped"), "{e}"),
        other => panic!("{other:?}"),
    }
}

/// A skill declined this session is not asked about again on every Skills-tab change, only
/// when the user enables it.
#[tokio::test]
async fn a_declined_skill_is_not_asked_again_until_enabled() {
    let Some(binary) = edw_binary() else {
        eprintln!("skipping: edw is not installed");
        return;
    };
    let wallet = TempWallet::new(binary, "skills-declined");
    let root = tempfile::tempdir().unwrap();
    knowledge_skill(&root.path().join("skills"), "alpha");
    knowledge_skill(&root.path().join("skills"), "beta");
    let paths = Paths {
        dirs: vec![root.path().join("skills")],
        user_dir: root.path().join("user"),
        lock: root.path().join("skills.lock"),
        drafts: root.path().join("drafts"),
    };
    let mut s = start(&wallet, paths, Recorder::new(vec![]));
    assert!(matches!(s.settle().await, AgentEvent::Consents(c) if c.len() == 2));
    s.send(Request::SkillsAnswered(BTreeMap::from([
        ("alpha".into(), true),
        ("beta".into(), false),
    ])));
    assert!(matches!(s.settle().await, AgentEvent::SkillsReady { .. }));

    s.send(Request::Skill(SkillOp::Disable("alpha".into())));
    match s.settle().await {
        AgentEvent::SkillsReady { rows, .. } => assert_eq!(
            names(&rows),
            [
                ("alpha".into(), "disabled".into()),
                ("beta".into(), "declined".into())
            ]
        ),
        other => panic!("beta must not be asked about again: {other:?}"),
    }
    s.send(Request::Skill(SkillOp::Enable("beta".into())));
    match s.settle().await {
        AgentEvent::Consents(cards) => assert_eq!(cards[0].name, "beta"),
        other => panic!("enabling asks: {other:?}"),
    }
}
