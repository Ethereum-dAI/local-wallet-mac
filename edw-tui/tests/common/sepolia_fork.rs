//! A Sepolia fork edw can really send on: anvil forked from a public Sepolia RPC, a local
//! [alto](https://github.com/pimlicolabs/alto) bundler for the EntryPoint v0.8 deployed there, and
//! a new wallet whose only RPC and only bundler are those two. The pools, the paymaster, the
//! adapters, Aave and the EntryPoint are Sepolia's own contracts, at the fork block.

use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

use alloy_node_bindings::{Anvil, AnvilInstance};
use alloy_primitives::{Address, U256, address, hex};
use alloy_provider::{Provider, ProviderBuilder};
use serde_json::{Value, json};

use super::TempWallet;

pub const ENTRY_POINT: Address = address!("0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108");
const PIMLICO: &str = "https://public.pimlico.io/v2/11155111/rpc";
const PUBLIC_SEPOLIA: &str = "https://ethereum-sepolia-rpc.publicnode.com";
/// Blocks mined right after forking. edw reads pool history from its indexer (Saga), which
/// publishes real Sepolia up to the real head whenever it updates; Sepolia makes a block every
/// 12 s, so for 20 minutes Saga cannot reach the fork's own blocks, and edw reads those from
/// the fork.
const AHEAD: u64 = 100;

/// anvil forked from `EDW_TUI_SEPOLIA_RPC` (default a public endpoint) at its latest block, then
/// [`AHEAD`] blocks on, with the fork block's base fee restored (empty blocks drain it).
/// `None`, with why, when anvil or the network is missing.
pub async fn fork_sepolia() -> Option<(AnvilInstance, u64)> {
    let upstream = std::env::var("EDW_TUI_SEPOLIA_RPC").unwrap_or_else(|_| PUBLIC_SEPOLIA.into());
    let chain = match Anvil::new().fork(upstream.clone()).try_spawn() {
        Ok(chain) => chain,
        Err(error) => {
            eprintln!("skipping: cannot fork Sepolia from {upstream} ({error})");
            return None;
        }
    };
    let provider = ProviderBuilder::new().connect_http(chain.endpoint_url());
    let fork_block = provider.get_block_number().await.unwrap();
    let base_fee = provider
        .get_block_by_number(fork_block.into())
        .await
        .unwrap()
        .and_then(|block| block.header.base_fee_per_gas)
        .unwrap_or_default();
    let _: Value = provider
        .raw_request("anvil_mine".into(), (U256::from(AHEAD), U256::from(12)))
        .await
        .unwrap();
    let _: Value = provider
        .raw_request(
            "anvil_setNextBlockBaseFeePerGas".into(),
            (U256::from(base_fee),),
        )
        .await
        .unwrap();
    Some((chain, fork_block))
}

/// `ALTO_BIN`, or `alto` on PATH; `None` when it does not run.
pub fn alto_binary() -> Option<PathBuf> {
    let binary = PathBuf::from(std::env::var_os("ALTO_BIN").unwrap_or_else(|| "alto".into()));
    Command::new(&binary)
        .arg("--version")
        .output()
        .ok()?
        .status
        .success()
        .then_some(binary)
}

/// A running alto, killed on drop. Its output goes to `log`.
pub struct Alto {
    process: Child,
    pub url: String,
    pub log: PathBuf,
}

impl Alto {
    /// alto for the fork's EntryPoint v0.8, executing and refilling with anvil's dev accounts 1
    /// and 2 (account 0 is left to the test). `--safe-mode false` as kohaku's fork kit runs it:
    /// no ERC-7562 tracing, so no stake or reputation rules.
    pub async fn start(binary: &Path, chain: &AnvilInstance, log: PathBuf) -> Self {
        let port = std::net::TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let key = |n: usize| hex::encode_prefixed(chain.keys()[n].to_bytes());
        let output = fs::File::create(&log).unwrap();
        let process = Command::new(binary)
            .args(["--rpc-url", chain.endpoint().as_str()])
            .args(["--entrypoints", ENTRY_POINT.to_string().as_str()])
            .args(["--executor-private-keys", key(1).as_str()])
            .args(["--utility-private-key", key(2).as_str()])
            .args(["--port", port.to_string().as_str()])
            .args(["--safe-mode", "false"])
            .stdout(output.try_clone().unwrap())
            .stderr(output)
            .stdin(Stdio::null())
            .spawn()
            .unwrap();
        let mut alto = Self {
            process,
            url: format!("http://127.0.0.1:{port}"),
            log,
        };
        let deadline = Instant::now() + Duration::from_secs(60);
        while alto
            .call("eth_supportedEntryPoints", json!([]))
            .await
            .is_err()
        {
            if let Some(status) = alto.process.try_wait().unwrap() {
                panic!("alto exited ({status}):\n{}", alto.log_tail());
            }
            assert!(
                Instant::now() < deadline,
                "alto did not answer in 60 s:\n{}",
                alto.log_tail()
            );
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        alto
    }

    /// One JSON-RPC call to the bundler: its `result`, or the error it answered with.
    pub async fn call(&self, method: &str, params: Value) -> Result<Value, String> {
        let response = reqwest::Client::new()
            .post(&self.url)
            .json(&json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}))
            .send()
            .await
            .map_err(|e| e.to_string())?;
        let body: Value = response.json().await.map_err(|e| e.to_string())?;
        match body.get("result") {
            Some(result) => Ok(result.clone()),
            None => Err(body.to_string()),
        }
    }

    pub fn log_tail(&self) -> String {
        let text = fs::read_to_string(&self.log).unwrap_or_default();
        let lines: Vec<&str> = text.lines().collect();
        lines[lines.len().saturating_sub(40)..].join("\n")
    }
}

impl Drop for Alto {
    fn drop(&mut self) {
        let _ = self.process.kill();
        let _ = self.process.wait();
    }
}

/// A new Sepolia wallet whose RPC is the fork and whose only bundler is `bundler`, configured
/// before any profile so nothing reaches public endpoints, with profile 0/0 on a new phrase
/// holding `funds` on the fork. edw runs with `RUST_LOG=info`, its stderr copied to [`edw_log`].
/// Returns the wallet and the profile's address.
pub async fn wallet_on(
    binary: &Path,
    name: &str,
    chain: &AnvilInstance,
    bundler: &str,
    funds: U256,
) -> (TempWallet, Address) {
    let mut wallet = TempWallet::new(binary.to_owned(), name);
    let dir = wallet.config.data_dir.parent().unwrap().to_owned();
    fs::create_dir_all(&dir).unwrap();
    let logging = dir.join("edw-info");
    let log = edw_log(&wallet);
    // The agent keeps only the JSON of a Tornado command, so its log is read from the copy.
    fs::write(
        &logging,
        format!(
            "#!/bin/bash\nprintf '=== edw %.100s\\n' \"$*\" >> '{log}'\nexec 2> >(tee -a '{log}' >&2)\nRUST_LOG=info exec '{edw}' \"$@\"\n",
            log = log.display(),
            edw = binary.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&logging, fs::Permissions::from_mode(0o755)).unwrap();
    wallet.config.binary = logging;

    let rpc = chain.endpoint();
    for step in [
        &["unlock", "--network", "sepolia"][..],
        &[
            "network",
            "rpc-config",
            "add",
            "fork",
            "--url",
            &rpc,
            "--use",
        ],
        &["network", "bundler-config", "add", "--url", bundler],
        &["network", "bundler-config", "remove", "--url", PIMLICO],
    ] {
        wallet.edw(step).await;
    }
    let list = wallet
        .edw(&["network", "bundler-config", "list"])
        .await
        .document()
        .unwrap();
    let urls: Vec<&str> = list["urls"]
        .as_array()
        .unwrap()
        .iter()
        .map(|url| url.as_str().unwrap().trim_end_matches('/'))
        .collect();
    assert_eq!(urls, [bundler], "edw's only bundler is the local one");
    wallet.edw(&["profile", "new", "--new-phrase"]).await;

    let balance = wallet
        .edw(&["balance", "--detailed", "--", "0/0"])
        .await
        .document()
        .unwrap();
    let profile: Address = balance["vaults"]
        .as_array()
        .unwrap()
        .iter()
        .find(|vault| vault["tag"] == "address")
        .and_then(|vault| vault["vault"].as_str()?.strip_prefix("addr:")?.parse().ok())
        .unwrap_or_else(|| panic!("no address vault in {balance}"));
    let provider = ProviderBuilder::new().connect_http(chain.endpoint_url());
    let _: Value = provider
        .raw_request("anvil_setBalance".into(), (profile, funds))
        .await
        .unwrap();
    (wallet, profile)
}

/// Every edw command a [`wallet_on`] wallet ran, each under a `=== edw <args>` line, with its
/// stderr.
pub fn edw_log(wallet: &TempWallet) -> PathBuf {
    wallet.config.data_dir.parent().unwrap().join("edw.log")
}

/// The stderr of the last edw command in [`edw_log`] whose arguments contain `command`.
pub fn last_run(wallet: &TempWallet, command: &str) -> String {
    let log = fs::read_to_string(edw_log(wallet)).unwrap_or_default();
    log.split("=== edw ")
        .filter(|run| {
            run.lines()
                .next()
                .is_some_and(|args| args.contains(command))
        })
        .last()
        .unwrap_or_default()
        .to_owned()
}

/// The timestamped lines of an edw log (`RUST_LOG=info`), each with its seconds after the first,
/// and edw's untimed progress lines in place with no time.
pub fn timeline(output: &str) -> Vec<(Option<f64>, String)> {
    let mut first = None;
    output
        .lines()
        .map(|line| match seconds_of_day(line) {
            Some(at) => {
                let start = *first.get_or_insert(at);
                let after = if at < start { at + 86_400.0 } else { at } - start;
                let message = line.split_once("Z ").map_or(line, |(_, rest)| rest.trim());
                (Some(after), message.to_owned())
            }
            None => (None, line.trim().to_owned()),
        })
        .collect()
}

/// `2026-10-28T12:31:11.764872Z …` as seconds since that day's midnight.
fn seconds_of_day(line: &str) -> Option<f64> {
    let time = line.get(11..26)?;
    if line.get(10..11)? != "T" {
        return None;
    }
    let mut parts = time.split(':');
    let hours: f64 = parts.next()?.parse().ok()?;
    let minutes: f64 = parts.next()?.parse().ok()?;
    let seconds: f64 = parts.next()?.parse().ok()?;
    Some(hours * 3600.0 + minutes * 60.0 + seconds)
}
