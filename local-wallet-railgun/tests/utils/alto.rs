//! Spawn a local Alto bundler for the fork fixture.
//!
//! A PUBLIC bundler cannot see an anvil fork, so the fixture needs a local one. Alto speaks
//! `pimlico_getUserOperationGasPrice`, which is what `PimlicoBundler` requires — a
//! vendor-neutral bundler would NOT work with the pinned client, and neither would one without
//! EntryPoint-v0.8 + EIP-7702 support, which the privacy-paymaster exit depends on.
//!
//! Resolution order: `LOCAL_WALLET_ALTO_BIN`, then `npx --yes @pimlico/alto@0.0.20`. The npm
//! version is PINNED rather than floating on `latest` because 0.0.20 is the version upstream
//! Kohaku pins and runs its own EntryPoint-v0.8 + 7702 integration test against, so it is the
//! one combination known to work with this rev of the SDK.
//!
//! Failure is always an error, never a skip: a fixture that quietly reports success without a
//! bundler proves nothing, which is worse than no fixture at all.

use std::io::Read;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// EntryPoint v0.8 as a CLI argument — the version the privacy paymaster path targets.
///
/// Formatted from the SDK's own constant rather than re-typed, so the EntryPoint Alto is told to
/// serve and the one the UserOperations are built against cannot silently diverge.
fn entry_point_arg() -> String {
    format!("{:?}", userop_kit::entry_point::ENTRY_POINT_08)
}

/// Anvil dev keys for Alto's executor and utility roles (testnet only). Same pair upstream
/// Kohaku's `broadcast_utxo.rs` funds, so a stale fork state from either fixture is
/// interchangeable.
pub const ALTO_EXECUTOR_KEY: &str =
    "0x4a3a02862ddcb260ed52d40ef03f8e3d78fa3d174b0ef333afdf1ffb4a648cd5";
pub const ALTO_UTILITY_KEY: &str =
    "0xdd4b2564c83ff7de602c39ffda1146055dc1814b07c083d7971722384f1f01a6";

/// Pinned npm spec — see the module header for why it is not `latest`.
const ALTO_NPM_SPEC: &str = "@pimlico/alto@0.0.20";

/// The env var that overrides `npx`. Named in every failure message so a broken npm/network
/// path is actionable rather than mysterious.
const ALTO_BIN_ENV: &str = "LOCAL_WALLET_ALTO_BIN";

/// Generous: on a cold cache `npx` downloads the whole bundler before Alto even starts, and
/// Alto then deploys its simulation contracts against the fork.
const READY_TIMEOUT: Duration = Duration::from_secs(240);

/// How much of Alto's log to quote when it fails to come up. Enough to carry a stack trace or
/// an npm resolution error without burying the assertion.
const LOG_TAIL_BYTES: u64 = 4000;

pub struct Alto {
    child: Child,
    log_path: PathBuf,
}

impl Alto {
    /// The tail of Alto's combined stdout/stderr, for failure messages.
    pub fn log_tail(&self) -> String {
        let mut file = match std::fs::File::open(&self.log_path) {
            Ok(f) => f,
            Err(e) => return format!("(no alto log at {}: {e})", self.log_path.display()),
        };
        let len = file.metadata().map(|m| m.len()).unwrap_or(0);
        if len > LOG_TAIL_BYTES {
            use std::io::Seek;
            let _ = file.seek(std::io::SeekFrom::Start(len - LOG_TAIL_BYTES));
        }
        let mut s = String::new();
        let _ = file.read_to_string(&mut s);
        s
    }
}

impl Drop for Alto {
    fn drop(&mut self) {
        // Under `npx` the bundler is a GRANDCHILD: npm exec spawns node. Killing only the npx
        // wrapper would orphan the bundler, which keeps the port bound and makes the next run
        // fail for an unrelated-looking reason. `spawn` therefore puts the child in its own
        // session (setsid), so killing the whole process group reaches node too.
        let pgid = self.child.id() as libc::pid_t;
        unsafe { libc::kill(-pgid, libc::SIGKILL) };
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Spawn Alto against `rpc_url` on `port`, logging to `log_path`, and wait until it actually
/// answers `pimlico_getUserOperationGasPrice`.
///
/// Readiness is probed with the sidecar's own [`railgun_helper::exit::fetch_max_fee_per_gas`]
/// rather than a bare TCP connect, because that is the exact call the exit path makes: an Alto
/// that has bound the port but cannot price gas yet would otherwise be reported ready and then
/// fail the exit with a confusing `bundlerUnavailable`.
pub async fn spawn(rpc_url: &str, port: u16, log_path: &Path) -> Result<Alto, String> {
    if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
        return Err(format!(
            "port {port} is already bound — a leftover Alto (or another service) is still \
             running; kill it before re-running the fixture"
        ));
    }

    let args = [
        "--port".to_string(),
        port.to_string(),
        "--entrypoints".to_string(),
        entry_point_arg(),
        "--executor-private-keys".to_string(),
        ALTO_EXECUTOR_KEY.to_string(),
        "--utility-private-key".to_string(),
        ALTO_UTILITY_KEY.to_string(),
        "--rpc-url".to_string(),
        rpc_url.to_string(),
        // anvil lacks the tracers safe mode needs.
        "--safe-mode".to_string(),
        "false".to_string(),
    ];

    let log = std::fs::File::create(log_path)
        .map_err(|e| format!("create alto log {}: {e}", log_path.display()))?;
    let log_err = log
        .try_clone()
        .map_err(|e| format!("clone alto log handle: {e}"))?;

    let mut cmd = match std::env::var(ALTO_BIN_ENV) {
        Ok(bin) => {
            let mut c = Command::new(bin);
            c.args(&args);
            c
        }
        Err(_) => {
            let mut c = Command::new("npx");
            c.arg("--yes").arg(ALTO_NPM_SPEC).args(&args);
            c
        }
    };
    cmd.stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err));
    // Own session/process group, so Drop can reap the node grandchild (see Drop).
    unsafe {
        cmd.pre_exec(|| {
            // Already a group leader is fine; nothing else is actionable here.
            libc::setsid();
            Ok(())
        });
    }

    let child = cmd.spawn().map_err(|e| {
        format!(
            "could not start Alto ({e}); the fork fixture REQUIRES a local bundler — install \
             npx (node) or point {ALTO_BIN_ENV} at an alto binary"
        )
    })?;
    let mut alto = Alto {
        child,
        log_path: log_path.to_path_buf(),
    };

    let url = format!("http://127.0.0.1:{port}");
    let deadline = Instant::now() + READY_TIMEOUT;
    let mut last_err = "not probed yet".to_string();
    while Instant::now() < deadline {
        // Exited already → no amount of waiting helps; report with the log.
        if let Ok(Some(status)) = alto.child.try_wait() {
            return Err(format!(
                "Alto exited before becoming ready ({status}); set {ALTO_BIN_ENV} to override \
                 the npx path.\n--- alto log tail ---\n{}",
                alto.log_tail()
            ));
        }
        match railgun_helper::exit::fetch_max_fee_per_gas(&url).await {
            Ok(max_fee) => {
                eprintln!("[alto] ready on {url}; slow-tier maxFeePerGas = {max_fee} wei");
                return Ok(alto);
            }
            Err(e) => last_err = e,
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    Err(format!(
        "Alto did not answer pimlico_getUserOperationGasPrice on {url} within {READY_TIMEOUT:?} \
         (last error: {last_err}); set {ALTO_BIN_ENV} to override the npx \
         path.\n--- alto log tail ---\n{}",
        alto.log_tail()
    ))
}
