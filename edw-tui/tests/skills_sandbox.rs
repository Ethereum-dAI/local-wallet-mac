//! Skill scripts in Docker: the protocol, and what the container can and cannot do.
//! Skips when Docker is not running.

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use edw_tui::skills::{
    host::{Host, HostConfig, SharedCache},
    manifest::{self, Skill},
    sandbox::{self, Output, Runner},
};
use serde_json::{Value, json};

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).to_owned()
}

fn probe() -> Skill {
    manifest::load(&root().join("tests/fixtures/skills/probe")).unwrap()
}

fn runner(timeout: Duration) -> Runner {
    Runner {
        timeout,
        ..Runner::from_env()
    }
}

fn host(fixtures: &[(&str, &str)]) -> Host {
    Host::new(
        HostConfig {
            skill: "probe".into(),
            hosts: vec!["yields.llama.fi".into()],
            cache: BTreeMap::new(),
            rpc: None,
            fixtures: Some(Arc::new(
                fixtures
                    .iter()
                    .map(|(k, v)| (k.to_string(), v.to_string()))
                    .collect(),
            )),
            log: Arc::new(|_| {}),
        },
        SharedCache::default(),
    )
}

async fn docker() -> bool {
    let ok = sandbox::docker_available().await;
    if !ok {
        eprintln!("skipping: Docker is not running");
    }
    ok
}

async fn run(mode: &str, timeout: Duration, fixtures: &[(&str, &str)]) -> Result<Output, String> {
    run_with(json!({ "mode": mode }), timeout, fixtures).await
}

async fn run_with(
    args: Value,
    timeout: Duration,
    fixtures: &[(&str, &str)],
) -> Result<Output, String> {
    let invoke = json!({"type": "invoke", "tool": "probe_echo", "args": args, "context": {"chain_id": 11155111}});
    runner(timeout)
        .run(&probe(), "scripts/probe.py", invoke, &host(fixtures))
        .await
}

fn result(output: Result<Output, String>) -> Value {
    match output {
        Ok(Output::Result(value)) => value,
        other => panic!("expected a result, got {other:?}"),
    }
}

#[test]
fn every_lockdown_flag_is_passed() {
    let skill = probe();
    let args =
        runner(Duration::from_secs(20)).docker_args(&skill, "scripts/probe.py", "edw-skill-test");
    let joined = args.join(" ");
    for flag in [
        "--rm",
        "-i",
        "--network none",
        "--read-only",
        "--cap-drop ALL",
        "--security-opt no-new-privileges",
        "--user 65534:65534",
        "--pids-limit 64",
        "--memory 256m",
        "--cpus 1",
        "--tmpfs /tmp:rw,size=16m",
        "--name edw-skill-test",
    ] {
        assert!(joined.contains(flag), "missing `{flag}` in {joined}");
    }
    let mounts: Vec<&String> = args.iter().filter(|a| a.contains(":/")).collect();
    assert!(
        mounts
            .iter()
            .all(|m| m.ends_with(":ro") || m.starts_with("/tmp:")),
        "{mounts:?}"
    );
    let envs: Vec<&str> = args
        .windows(2)
        .filter(|w| w[0] == "-e")
        .map(|w| w[1].as_str())
        .collect();
    assert!(
        envs.iter()
            .all(|e| e.starts_with("PYTHONPATH=") || e.starts_with("PYTHONDONTWRITEBYTECODE=")),
        "{envs:?}"
    );
    assert!(args.last().unwrap().ends_with("/skill/scripts/probe.py"));
}

/// The README's defaults are relative (`skills`, `skills/_sdk`); Docker reads a relative `-v`
/// source as a volume name, so every mount must be absolute by the time it is passed.
#[tokio::test]
async fn relative_skill_and_sdk_paths_still_mount_the_real_folders() {
    // cargo runs integration tests from the crate root.
    let skill = manifest::load(Path::new("tests/fixtures/skills/probe")).unwrap();
    let runner = Runner::from_env();
    let args = runner.docker_args(&skill, "scripts/probe.py", "edw-skill-test");
    let mounts: Vec<&String> = args
        .windows(2)
        .filter(|w| w[0] == "-v")
        .map(|w| &w[1])
        .collect();
    assert_eq!(mounts.len(), 2, "{args:?}");
    assert!(mounts.iter().all(|m| m.starts_with('/')), "{mounts:?}");
    if !docker().await {
        return;
    }
    let invoke =
        json!({"type": "invoke", "tool": "probe_echo", "args": {"mode": "echo"}, "context": {}});
    let value = result(
        runner
            .run(&skill, "scripts/probe.py", invoke, &host(&[]))
            .await,
    );
    assert_eq!(value["args"]["mode"], "echo");
}

#[tokio::test]
async fn a_script_round_trips_invoke_and_result() {
    if !docker().await {
        return;
    }
    let value = result(run("echo", Duration::from_secs(20), &[]).await);
    assert_eq!(value["args"]["mode"], "echo");
    assert_eq!(value["chain_id"], 11155111);
}

#[tokio::test]
async fn a_script_has_no_network() {
    if !docker().await {
        return;
    }
    let value = result(run("net", Duration::from_secs(20), &[]).await);
    assert_eq!(value["connected"], false, "{value}");
}

#[tokio::test]
async fn a_script_sees_no_host_env_or_files() {
    if !docker().await {
        return;
    }
    let env = result(run("env", Duration::from_secs(20), &[]).await);
    let env = env["env"].as_object().unwrap();
    assert!(
        env.keys()
            .all(|k| !k.starts_with("EDW") && k != "OLLAMA_HOST"),
        "{env:?}"
    );
    assert_ne!(
        env.get("HOME").and_then(Value::as_str),
        std::env::var("HOME").ok().as_deref()
    );
    // The image has an empty /home of its own; what matters is that nothing of the host's
    // shows up: not its home folder, not the edw data next to this crate.
    let home = std::env::var("HOME").unwrap();
    let data = root().join(".edw").display().to_string();
    let files = result(
        run_with(
            json!({"mode": "files", "paths": [home, data, "/Users", "/root/.ssh"]}),
            Duration::from_secs(20),
            &[],
        )
        .await,
    );
    for path in files["exists"].as_object().unwrap().keys() {
        if path != "/skill/SKILL.md" {
            assert_eq!(files["exists"][path], false, "{path} is visible: {files}");
        }
    }
    assert_eq!(files["home_entries"], json!([]), "{files}");
    assert_eq!(files["exists"]["/skill/SKILL.md"], true, "{files}");
    assert_eq!(files["skill_writable"], false, "{files}");
    assert_eq!(files["tmp_writable"], true, "{files}");
}

#[tokio::test]
async fn data_comes_through_the_host_and_undeclared_hosts_are_refused() {
    if !docker().await {
        return;
    }
    let value = result(
        run(
            "host",
            Duration::from_secs(20),
            &[("GET https://yields.llama.fi/pools", "{\"data\":[1]}")],
        )
        .await,
    );
    assert_eq!(value["body"], "{\"data\":[1]}");
    let value = result(run("refused", Duration::from_secs(20), &[]).await);
    assert_eq!(value["refused"], true, "{value}");
}

#[tokio::test]
async fn an_action_script_returns_a_plan() {
    if !docker().await {
        return;
    }
    match run("plan", Duration::from_secs(20), &[]).await {
        Ok(Output::Plan(plan)) => assert_eq!(plan["steps"][0]["approve"]["token"], "usdc"),
        other => panic!("expected a plan, got {other:?}"),
    }
}

#[tokio::test]
async fn a_script_that_hangs_is_killed_and_its_container_removed() {
    if !docker().await {
        return;
    }
    let started = std::time::Instant::now();
    let error = run("sleep", Duration::from_secs(3), &[]).await.unwrap_err();
    assert!(error.contains("timed out"), "{error}");
    assert!(started.elapsed() < Duration::from_secs(15));
    // Other tests in this binary run containers too; wait for all of ours to be gone.
    let filter = format!("name=edw-skill-{}-", std::process::id());
    let mut left = String::from("?");
    for _ in 0..20 {
        let ps = std::process::Command::new("docker")
            .args(["ps", "-aq", "--filter", &filter])
            .output()
            .unwrap();
        left = String::from_utf8_lossy(&ps.stdout).trim().to_owned();
        if left.is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert!(left.is_empty(), "left a container behind: {left}");
}

#[tokio::test]
async fn a_script_that_floods_stdout_is_cut_off() {
    if !docker().await {
        return;
    }
    let error = run("flood", Duration::from_secs(20), &[])
        .await
        .unwrap_err();
    assert!(
        error.contains("1 MiB") || error.contains("protocol"),
        "{error}"
    );
}

#[tokio::test]
async fn a_failing_script_reports_why() {
    if !docker().await {
        return;
    }
    let error = run("nonsense", Duration::from_secs(20), &[])
        .await
        .unwrap_err();
    assert!(error.contains("unknown mode"), "{error}");
}
