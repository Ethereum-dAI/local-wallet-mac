//! End-to-end test of the daemon's real send pipeline against a forked Sepolia
//! chain, driving a passkey UserOperation signed with `usePrecompiled=true`.
//!
//! Unlike `mainnet_fork_kernel` (which calls the EntryPoint directly), this spawns
//! the actual `wallet-node` binary in its production fd/unix-socket mode (ready +
//! alive + secret pipes, bundler EOA installed over the secret pipe) and drives
//! `eth_estimateUserOperationGas` + `eth_sendUserOperation` +
//! `eth_getUserOperationReceipt` over the authenticated socket, exercising
//! probe -> health -> effective-flag estimation -> policy -> simulation ->
//! self-relay -> receipt watcher. Fusaka is live on Sepolia, so the on-chain
//! P-256 precompile at 0x100 is available on the fork.
//!
//! Run: scripts/run-sepolia-fork-daemon-e2e.sh

mod common;

use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::io::{AsRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Duration;

use alloy_primitives::{Address, Bytes, B256, U256};
use alloy_sol_types::SolCall;
use nix::unistd::pipe;
use p256::ecdsa::SigningKey;
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use wallet_bundler::{
    PINNED_KERNEL_FACTORY_ADDRESS, PINNED_KERNEL_IMPLEMENTATION_ADDRESS,
    PINNED_WEBAUTHN_VALIDATOR_ADDRESS,
};

use common::*;

const SEPOLIA_CHAIN_ID: u64 = 11_155_111;
const RECIPIENT: &str = "0x2000000000000000000000000000000000000002";
const BUNDLER_KEY_REF: &str = "bundler-eoa:default:11155111:1";
const BUNDLER_SECRET: &str = "0x0101010101010101010101010101010101010101010101010101010101010101";
const ENTRY_POINT: &str = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
// Comfortably under the daemon's default policy gas-price caps (10 gwei / 1 gwei).
const MAX_FEE_PER_GAS: u64 = 8_000_000_000;
const MAX_PRIORITY_FEE_PER_GAS: u64 = 500_000_000;
// A verificationGasLimit the RIP-7212 precompile path fits within (~175k observed
// pre-op gas) but the Daimo verifier path (~330k+ just for the P-256 verify) cannot.
// Submitting and executing a UserOp under this budget is itself proof the precompile
// path is active and load-bearing.
const TIGHT_VERIFICATION_GAS_LIMIT: &str = "0x3d090"; // 250_000

#[tokio::test]
#[ignore = "requires an Anvil Sepolia fork; run scripts/run-sepolia-fork-daemon-e2e.sh"]
async fn sepolia_fork_daemon_sends_userop_via_p256_precompile() {
    let fork_url = std::env::var("WALLET_SEPOLIA_FORK_RPC_URL")
        .expect("set WALLET_SEPOLIA_FORK_RPC_URL to an Anvil Sepolia-fork RPC URL");
    let client = reqwest::Client::new();
    let recipient: Address = RECIPIENT.parse().unwrap();

    // 1. Deploy a Kernel account whose P-256 root validator is a key we control.
    let signing_key = SigningKey::from_bytes(&TEST_P256_PRIVATE_KEY.into()).unwrap();
    let (pubkey_x, pubkey_y) = p256_public_key_coordinates(signing_key.verifying_key());
    let salt = B256::ZERO;
    let init_data = wallet_kernel::encode_initialize_call(
        PINNED_WEBAUTHN_VALIDATOR_ADDRESS,
        U256::from_be_slice(&pubkey_x),
        U256::from_be_slice(&pubkey_y),
        B256::ZERO,
    );
    let factory_data = Bytes::from(
        createAccountCall {
            initData: Bytes::from(init_data.clone()),
            salt,
        }
        .abi_encode(),
    );
    let init_code_hash =
        wallet_kernel::erc1967_init_code_hash(PINNED_KERNEL_IMPLEMENTATION_ADDRESS);
    let actual_salt = wallet_kernel::compute_actual_salt(&init_data, salt);
    let sender = wallet_kernel::predict_create2_address(
        PINNED_KERNEL_FACTORY_ADDRESS,
        actual_salt,
        init_code_hash,
    );

    let deploy_tx = eth_send_transaction(
        &client,
        &fork_url,
        ANVIL_DEFAULT_SENDER,
        PINNED_KERNEL_FACTORY_ADDRESS,
        factory_data,
    )
    .await;
    wait_for_successful_receipt(&client, &fork_url, &deploy_tx).await;

    // 2. Deposit to the EntryPoint for the account (prefund) and fund its balance
    //    so the ETH transfer can execute.
    let deposit_amount = U256::from(50_000_000_000_000_000_u64); // 0.05 ETH
    let deposit_tx = eth_send_transaction_with_value(
        &client,
        &fork_url,
        ANVIL_DEFAULT_SENDER,
        wallet_bundler::ENTRY_POINT_V07,
        Bytes::from(depositToCall { account: sender }.abi_encode()),
        Some(deposit_amount),
    )
    .await;
    wait_for_successful_receipt(&client, &fork_url, &deposit_tx).await;

    let transfer_amount = U256::from(12_345_u64);
    let fund_tx = eth_send_transaction_with_value(
        &client,
        &fork_url,
        ANVIL_DEFAULT_SENDER,
        sender,
        Bytes::new(),
        Some(transfer_amount),
    )
    .await;
    wait_for_successful_receipt(&client, &fork_url, &fund_tx).await;

    // 3. Spawn wallet-node against the fork (execution_rpc mode, use_precompiled
    //    auto) with the bundler EOA installed over the secret pipe.
    let home = TempHome::new();
    let config_path = home.path().join("config.toml");
    std::fs::write(&config_path, daemon_config_toml(&fork_url)).expect("write daemon config");
    let daemon = Daemon::spawn(&config_path, home.path());
    let socket = daemon.socket_path.clone();
    let token = daemon.token.clone();

    // 4. Wait until the bundler EOA is installed (its address is reported by
    //    health before it is funded), then fund it on the fork.
    let bundler_eoa = wait_for_bundler_eoa(&socket, &token).await;
    anvil_set_balance(
        &client,
        &fork_url,
        bundler_eoa,
        U256::from(1_000_000_000_000_000_000_u64),
    )
    .await;

    // 5. Wait for full readiness and assert the daemon resolved the precompile path.
    let health = wait_for_bundler_ready(&socket, &token).await;
    assert_eq!(
        health["p256Precompile"]["usePrecompiled"], true,
        "daemon should route through the RIP-7212 precompile on a Fusaka Sepolia fork: {health}"
    );
    assert_eq!(health["p256Precompile"]["status"], "available");

    // 6. Exercise the daemon's gas-estimation path (the daemon returns a conservative
    //    verificationGasLimit ceiling, so this is a pipeline smoke check; the gas win
    //    is proven by the tight-budget on-chain execution in the next step).
    let estimate = daemon_rpc(
        &socket,
        &token,
        "eth_estimateUserOperationGas",
        json!([
            unsigned_transfer_op(sender, recipient, transfer_amount),
            ENTRY_POINT
        ]),
    )
    .await;
    assert!(
        hex_u128(&estimate["verificationGasLimit"]) > 0,
        "estimate should return a verificationGasLimit: {estimate}"
    );

    // 7. Build + sign the transfer with usePrecompiled=true and submit it through the
    //    daemon's self-relaying send pipeline. The op carries a verificationGasLimit
    //    (TIGHT_VERIFICATION_GAS_LIMIT) that the precompile path fits within but the
    //    Daimo verifier path (~330k+) cannot — so an on-chain success is itself proof
    //    the RIP-7212 precompile path is active and load-bearing.
    let op_json = unsigned_transfer_op(sender, recipient, transfer_amount);
    let op = wallet_bundler::UserOperation::parse(op_json.clone()).unwrap();
    let user_op_hash = entry_point_user_op_hash(&client, &fork_url, &op).await;
    let signed = sign_user_op_for_test(op, user_op_hash, &signing_key, true);
    let mut signed_json = op_json;
    signed_json["signature"] = json!(bytes_hex(&signed.op.signature));

    let recipient_before = eth_get_balance(&client, &fork_url, recipient).await;
    let sent_hash = daemon_rpc(
        &socket,
        &token,
        "eth_sendUserOperation",
        json!([signed_json, ENTRY_POINT]),
    )
    .await;
    let sent_hash = sent_hash
        .as_str()
        .expect("sendUserOperation returns a hash");

    // 8. Poll the receipt through the daemon and assert on-chain success.
    let receipt = wait_for_user_op_receipt(&socket, &token, sent_hash).await;
    assert_eq!(
        receipt["success"], true,
        "UserOperation must succeed on-chain via the precompile: {receipt}"
    );
    assert_eq!(
        eth_get_balance(&client, &fork_url, recipient).await,
        recipient_before + transfer_amount,
        "recipient balance should increase by the transferred amount"
    );
}

fn unsigned_transfer_op(sender: Address, recipient: Address, amount: U256) -> Value {
    json!({
        "sender": address_hex(sender),
        "nonce": "0x0",
        "callData": bytes_hex(&wallet_bundler::encode_erc7579_single_execution(
            recipient,
            amount,
            Bytes::new(),
        )),
        "callGasLimit": "0x186a0",
        "verificationGasLimit": TIGHT_VERIFICATION_GAS_LIMIT,
        "preVerificationGas": "0xd80d",
        "maxFeePerGas": u256_hex(U256::from(MAX_FEE_PER_GAS)),
        "maxPriorityFeePerGas": u256_hex(U256::from(MAX_PRIORITY_FEE_PER_GAS)),
        "signature": "0x"
    })
}

fn daemon_config_toml(fork_url: &str) -> String {
    format!(
        r#"[network]
chain_id = {SEPOLIA_CHAIN_ID}
execution_rpc = "{fork_url}"
consensus_rpc = ""
read_verification = "execution_rpc"

[bundler]
entry_points = ["{ENTRY_POINT}"]
submit_rpcs = ["{fork_url}"]
use_precompiled = true
"#
    )
}

fn hex_u128(value: &Value) -> u128 {
    let raw = value.as_str().expect("gas value is a hex string");
    u128::from_str_radix(raw.strip_prefix("0x").unwrap_or(raw), 16).expect("gas value parses")
}

async fn daemon_rpc(socket_path: &Path, token: &str, method: &str, params: Value) -> Value {
    let response = daemon_rpc_raw(socket_path, token, method, params).await;
    if let Some(error) = response.get("error") {
        if !error.is_null() {
            panic!("{method} daemon RPC error: {error}");
        }
    }
    response["result"].clone()
}

async fn daemon_rpc_raw(socket_path: &Path, token: &str, method: &str, params: Value) -> Value {
    let body = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params }).to_string();
    let request = format!(
        "POST / HTTP/1.1\r\nHost: wallet-node.local\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len(),
    );
    let mut stream = connect_with_retry(socket_path, method).await;
    stream
        .write_all(request.as_bytes())
        .await
        .unwrap_or_else(|error| panic!("{method} write failed: {error}"));
    let mut bytes = Vec::new();
    stream
        .read_to_end(&mut bytes)
        .await
        .unwrap_or_else(|error| panic!("{method} read failed: {error}"));
    let text = String::from_utf8(bytes).expect("response is UTF-8");
    let (_, body) = text
        .split_once("\r\n\r\n")
        .unwrap_or_else(|| panic!("{method} response has no body: {text}"));
    serde_json::from_str(body)
        .unwrap_or_else(|error| panic!("{method} decode failed: {error}; body: {body}"))
}

async fn connect_with_retry(socket_path: &Path, method: &str) -> UnixStream {
    for _ in 0..200 {
        match UnixStream::connect(socket_path).await {
            Ok(stream) => return stream,
            Err(_) => tokio::time::sleep(Duration::from_millis(50)).await,
        }
    }
    panic!(
        "{method}: socket {} never became connectable within 10s",
        socket_path.display()
    );
}

async fn health(socket_path: &Path, token: &str) -> Value {
    daemon_rpc(socket_path, token, "wallet_health", Value::Null).await
}

async fn wait_for_bundler_eoa(socket_path: &Path, token: &str) -> Address {
    for _ in 0..120 {
        let health = health(socket_path, token).await;
        if let Some(eoa) = health["bundler"]["eoa"].as_str() {
            if let Ok(address) = eoa.parse() {
                return address;
            }
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    panic!("bundler EOA was not reported by health within 30s");
}

async fn wait_for_bundler_ready(socket_path: &Path, token: &str) -> Value {
    let mut last = Value::Null;
    for _ in 0..240 {
        let health = health(socket_path, token).await;
        if health["status"] == "bundler_ready" {
            return health;
        }
        last = health;
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    panic!("daemon did not reach bundler_ready within 60s; last health: {last}");
}

async fn wait_for_user_op_receipt(socket_path: &Path, token: &str, user_op_hash: &str) -> Value {
    for _ in 0..240 {
        let receipt = daemon_rpc(
            socket_path,
            token,
            "eth_getUserOperationReceipt",
            json!([user_op_hash]),
        )
        .await;
        if !receipt.is_null() {
            return receipt;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    panic!("UserOperation receipt for {user_op_hash} did not settle within 60s");
}

/// A spawned `wallet-node` process serving its authenticated unix socket, with the
/// bundler EOA installed over the secret pipe (fd 5). Killed on drop; dropping the
/// held alive-pipe write end also signals the daemon to exit.
struct Daemon {
    child: Child,
    token: String,
    socket_path: PathBuf,
    _alive_write: OwnedFd,
}

impl Daemon {
    fn spawn(config_path: &Path, home: &Path) -> Self {
        let (ready_read, ready_write) = pipe().expect("ready pipe");
        let (alive_read, alive_write) = pipe().expect("alive pipe");
        let (secret_read, secret_write) = pipe().expect("secret pipe");

        let ready_read_raw = ready_read.as_raw_fd();
        let ready_write_raw = ready_write.as_raw_fd();
        let alive_read_raw = alive_read.as_raw_fd();
        let alive_write_raw = alive_write.as_raw_fd();
        let secret_read_raw = secret_read.as_raw_fd();
        let secret_write_raw = secret_write.as_raw_fd();

        let mut command = Command::new(env!("CARGO_BIN_EXE_wallet-node"));
        command
            .args([
                "--ready-fd",
                "3",
                "--alive-fd",
                "4",
                "--secret-fd",
                "5",
                "--config",
                config_path.to_str().expect("config path is UTF-8"),
            ])
            .env("HOME", home)
            .env_remove("XDG_DATA_HOME")
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());

        // SAFETY: pre_exec runs after fork, before exec, and only calls
        // async-signal-safe libc functions.
        unsafe {
            command.pre_exec(move || -> std::io::Result<()> {
                if ready_write_raw != 3 && libc::dup2(ready_write_raw, 3) == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                if alive_read_raw != 4 && libc::dup2(alive_read_raw, 4) == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                if secret_read_raw != 5 && libc::dup2(secret_read_raw, 5) == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                for fd in [
                    ready_read_raw,
                    ready_write_raw,
                    alive_read_raw,
                    alive_write_raw,
                    secret_read_raw,
                    secret_write_raw,
                ] {
                    if fd != 3 && fd != 4 && fd != 5 {
                        libc::close(fd);
                    }
                }
                Ok(())
            });
        }

        let child = command.spawn().expect("spawn wallet-node");
        drop(ready_write);
        drop(alive_read);
        drop(secret_read);

        let mut secret_writer = File::from(secret_write);
        secret_writer
            .write_all(
                format!(
                    r#"{{"keys":[{{"keyRef":"{BUNDLER_KEY_REF}","secret":"{BUNDLER_SECRET}"}}]}}"#
                )
                .as_bytes(),
            )
            .expect("write bundler secret");
        drop(secret_writer);

        let mut ready_reader = BufReader::new(File::from(ready_read));
        let mut ready_line = String::new();
        ready_reader
            .read_line(&mut ready_line)
            .expect("read ready line from fd");
        assert!(!ready_line.is_empty(), "ready fd closed without data");
        let ready: Value = serde_json::from_str(ready_line.trim_end()).expect("ready event JSON");
        let token = ready["token"].as_str().expect("ready token").to_string();
        let socket_path = PathBuf::from(
            ready["socketPath"]
                .as_str()
                .expect("ready socketPath")
                .to_string(),
        );

        Self {
            child,
            token,
            socket_path,
            _alive_write: alive_write,
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

struct TempHome {
    path: PathBuf,
}

impl TempHome {
    fn new() -> Self {
        // Keep this short: the daemon nests
        // `Library/Application Support/Local Wallet/wallet-node/wallet-node.sock`
        // under $HOME, and the resulting unix socket path must fit in SUN_LEN (104).
        let path = PathBuf::from("/tmp").join(format!("wnse-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("create temp HOME");
        Self { path }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempHome {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}
