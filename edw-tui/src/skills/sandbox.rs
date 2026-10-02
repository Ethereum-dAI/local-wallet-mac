//! Runs one skill script in a throwaway, locked-down Docker container and speaks the JSON-lines
//! protocol with it: `invoke` in, host requests out and replies in, then one `result`, `plan`
//! or `error`.
//!
//! The container has no network, a read-only root, the skill folder and the SDK mounted
//! read-only, no capabilities, an unprivileged user, and none of the host's environment. If
//! Docker is missing, scripts do not run at all; there is no unsandboxed fallback.

use std::{
    process::Stdio,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    process::Command,
};

use super::{host::Host, manifest::Skill};

/// Pinned by digest, so every run gets the same interpreter. Override with
/// `EDW_TUI_SKILL_IMAGE`.
pub const DEFAULT_IMAGE: &str =
    "python:3.12-slim@sha256:f77ac9e44ae96ef2c90b8053ea08c31f8be030f824196b0ae4db6d462c84e51f";
pub const TIMEOUT: Duration = Duration::from_secs(20);
/// Everything a script prints on stdout, protocol lines included.
pub const MAX_STDOUT: u64 = 1024 * 1024;
const MAX_STDERR: u64 = 64 * 1024;

#[derive(Debug)]
pub enum Output {
    /// From a read tool: handed to the model.
    Result(Value),
    /// From an action: handed to the plan checker.
    Plan(Value),
}

#[derive(Clone, Debug)]
pub struct Runner {
    pub image: String,
    /// `skills/_sdk`, mounted at `/sdk` and put on `PYTHONPATH`.
    pub sdk: std::path::PathBuf,
    pub timeout: Duration,
    /// Container names start with this, then the process id and a counter.
    pub name_prefix: String,
}

static RUNS: AtomicU64 = AtomicU64::new(0);

/// The protocol helper every script imports. Compiled into edw-tui, so no skills folder can
/// replace it for the other skills; it is not part of any skill's hash because it is not the
/// skill's code.
pub const SDK: &str = include_str!("../../skills/_sdk/edw_skill.py");

/// [`SDK`] written once per process to a folder of its own, for mounting at `/sdk`.
fn embedded_sdk() -> std::path::PathBuf {
    static DIR: std::sync::OnceLock<std::path::PathBuf> = std::sync::OnceLock::new();
    DIR.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("edw-tui-sdk-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(dir.join("edw_skill.py"), SDK);
        // Docker needs an absolute mount source (see `manifest::load`).
        std::fs::canonicalize(&dir).unwrap_or(dir)
    })
    .clone()
}

impl Runner {
    /// The image from `EDW_TUI_SKILL_IMAGE` (or the pinned default) and edw-tui's own SDK.
    pub fn from_env() -> Self {
        Self {
            image: std::env::var("EDW_TUI_SKILL_IMAGE").unwrap_or_else(|_| DEFAULT_IMAGE.into()),
            sdk: embedded_sdk(),
            timeout: TIMEOUT,
            name_prefix: "edw-skill".into(),
        }
    }

    /// The `docker` argv for one run of `run` (a path inside the skill folder).
    pub fn docker_args(&self, skill: &Skill, run: &str, name: &str) -> Vec<String> {
        let mount = |from: &std::path::Path, to: &str| format!("{}:{to}:ro", from.display());
        let mut args: Vec<String> = [
            "run",
            "--rm",
            "-i",
            "--name",
            name,
            "--network",
            "none",
            "--read-only",
            "--cap-drop",
            "ALL",
            "--security-opt",
            "no-new-privileges",
            "--user",
            "65534:65534",
            "--pids-limit",
            "64",
            "--memory",
            "256m",
            "--cpus",
            "1",
            "--tmpfs",
            "/tmp:rw,size=16m",
        ]
        .map(str::to_owned)
        .into();
        args.extend([
            "-v".into(),
            mount(&skill.dir, "/skill"),
            "-v".into(),
            mount(&self.sdk, "/sdk"),
            "-e".into(),
            "PYTHONPATH=/sdk".into(),
            "-e".into(),
            "PYTHONDONTWRITEBYTECODE=1".into(),
            "-w".into(),
            "/skill".into(),
            self.image.clone(),
        ]);
        let script = format!("/skill/{run}");
        if run.ends_with(".py") {
            args.extend(["python3".into(), "-u".into(), script]);
        } else {
            args.push(script);
        }
        args
    }

    /// Runs `run` with `invoke` as its first input line, serving its host requests, until it
    /// answers or the timeout passes.
    pub async fn run(
        &self,
        skill: &Skill,
        run: &str,
        invoke: Value,
        host: &Host,
    ) -> Result<Output, String> {
        let name = format!(
            "{}-{}-{}-{}",
            self.name_prefix,
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |d| d.as_millis()),
            RUNS.fetch_add(1, Ordering::Relaxed)
        );
        let mut child = Command::new("docker")
            .args(self.docker_args(skill, run, &name))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| format!("cannot start docker: {e}"))?;
        // Removes the container if this future is dropped before the end (a cancelled turn).
        let mut guard = Container {
            name: name.clone(),
            removed: false,
        };
        let mut stdin = child.stdin.take().expect("piped");
        let stdout = child.stdout.take().expect("piped");
        let stderr = child.stderr.take().expect("piped");
        let stderr_task = tokio::spawn(async move {
            let mut text = String::new();
            let _ = stderr.take(MAX_STDERR).read_to_string(&mut text).await;
            text
        });

        let conversation = async {
            write_line(&mut stdin, &invoke).await?;
            let mut lines = BufReader::new(stdout.take(MAX_STDOUT + 1));
            let mut seen: u64 = 0;
            let mut line = String::new();
            loop {
                line.clear();
                let n = lines
                    .read_line(&mut line)
                    .await
                    .map_err(|e| format!("reading the script's output: {e}"))?;
                seen += n as u64;
                if seen > MAX_STDOUT {
                    return Err("the script printed more than 1 MiB".to_owned());
                }
                if n == 0 {
                    return Err("the script exited without an answer".to_owned());
                }
                let message: Value = serde_json::from_str(line.trim()).map_err(|_| {
                    format!(
                        "the script printed something that is not a protocol message: {}",
                        line.trim().chars().take(120).collect::<String>()
                    )
                })?;
                match message.get("type").and_then(Value::as_str) {
                    Some("result") => {
                        return Ok(Output::Result(
                            message.get("value").cloned().unwrap_or(Value::Null),
                        ));
                    }
                    Some("plan") => {
                        return Ok(Output::Plan(
                            message.get("plan").cloned().unwrap_or(Value::Null),
                        ));
                    }
                    Some("error") => {
                        return Err(message
                            .get("message")
                            .and_then(Value::as_str)
                            .unwrap_or("the script failed")
                            .to_owned());
                    }
                    _ => {
                        let reply = host.handle(&message).await;
                        write_line(&mut stdin, &reply).await?;
                    }
                }
            }
        };

        let outcome = match tokio::time::timeout(self.timeout, conversation).await {
            Ok(outcome) => outcome,
            Err(_) => Err(format!(
                "the script timed out after {}s",
                self.timeout.as_secs()
            )),
        };
        // Whatever happened, the container goes, even when the script answered and kept
        // running: killing the `docker` client alone leaves the container up.
        let _ = Command::new("docker")
            .args(["rm", "-f", &name])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await;
        guard.removed = true;
        let _ = child.kill().await;
        let _ = child.wait().await;
        match outcome {
            Ok(output) => Ok(output),
            Err(error) => {
                let stderr = stderr_task.await.unwrap_or_default();
                let tail: Vec<&str> = stderr.lines().rev().take(5).collect();
                if tail.is_empty() {
                    Err(error)
                } else {
                    let tail: Vec<&str> = tail.into_iter().rev().collect();
                    Err(format!("{error}; stderr: {}", tail.join(" | ")))
                }
            }
        }
    }
}

/// A running container's name; `docker rm -f` on drop unless the run already removed it.
struct Container {
    name: String,
    removed: bool,
}

impl Drop for Container {
    fn drop(&mut self) {
        if !self.removed {
            // Drop cannot await: start the removal and let it finish on its own.
            let _ = std::process::Command::new("docker")
                .args(["rm", "-f", &self.name])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
        }
    }
}

async fn write_line(stdin: &mut tokio::process::ChildStdin, message: &Value) -> Result<(), String> {
    let mut text = message.to_string();
    text.push('\n');
    stdin
        .write_all(text.as_bytes())
        .await
        .map_err(|e| format!("writing to the script: {e}"))?;
    stdin
        .flush()
        .await
        .map_err(|e| format!("writing to the script: {e}"))
}

/// `docker version` answers within 5 s: the CLI is installed and the daemon is up.
pub async fn docker_available() -> bool {
    let probe = Command::new("docker")
        .args(["version", "--format", "{{.Server.Version}}"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .status();
    matches!(
        tokio::time::timeout(Duration::from_secs(5), probe).await,
        Ok(Ok(status)) if status.success()
    )
}

/// Pulls the image if it is not present yet, so a first script call does not spend its timeout
/// downloading it.
pub async fn ensure_image(image: &str) -> Result<(), String> {
    let present = Command::new("docker")
        .args(["image", "inspect", image])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await
        .is_ok_and(|s| s.success());
    if present {
        return Ok(());
    }
    let pulled = Command::new("docker")
        .args(["pull", "--quiet", image])
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|e| format!("docker pull {image}: {e}"))?;
    if pulled.status.success() {
        Ok(())
    } else {
        Err(format!(
            "docker pull {image}: {}",
            String::from_utf8_lossy(&pulled.stderr).trim()
        ))
    }
}

/// The context every script call carries, besides its arguments.
pub fn invoke_message(tool: &str, args: &Value, context: Value) -> Value {
    json!({"type": "invoke", "tool": tool, "args": args, "context": context})
}
