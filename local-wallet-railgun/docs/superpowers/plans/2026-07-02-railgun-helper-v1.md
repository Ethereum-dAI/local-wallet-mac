# Railgun Helper v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `railgun-helper`, a Rust sidecar that exposes `balance` and `prepareShield` over a Unix-socket JSON-RPC API, wrapping Kohaku's `crates/railgun` to shield ETH into Railgun on Sepolia.

**Architecture:** A standalone Rust binary spawned by the macOS app (same fd-3 ready / fd-4 alive / fd-5 secret contract as `wallet-node`). It derives Railgun spending+viewing keys from the fd-5 entropy, builds a `RailgunProvider` (Subsquid sync + POI on), and forwards all chain reads to the `wallet-node` daemon by implementing the crate's `Eip1193Provider` trait over authenticated HTTP. Shield transactions are returned to the app for self-submission via the daemon's normal send path.

**Tech Stack:** Rust (edition 2021), `tokio`, `hyper` + `hyper-util` (Unix-socket JSON-RPC server), `reqwest` (daemon HTTP client), `serde`/`serde_json`, `bip32` (HD key derivation), `alloy` (Address/Bytes/U256), and the Kohaku `railgun` crate (git dep) with its transitive `eip-1193-provider` / `userop-kit` crates.

## Global Constraints

- **Kohaku dep:** `railgun = { git = "https://github.com/ethereum/kohaku.git", rev = "877026e1775a333c556c6fea54dc270009aac978", default-features = false }`. Never enable the `js` feature. Bump the rev deliberately, never casually.
- **License:** every crate is `MIT OR Apache-2.0`.
- **Chain:** Sepolia only, `chain_id = 11155111`. Testnet only — **no mainnet funds**.
- **Rust:** edition 2021 for this crate; toolchain **Rust 1.85+** (the `railgun` dep is edition 2024).
- **Secrets:** the spending key and viewing key are derived in-process from fd-5 entropy and never logged, never written to disk, never returned over RPC.
- **State file:** `~/Library/Application Support/LocalWallet/railgun-sepolia.json`, mode `0o600`.
- **Auth:** every sidecar RPC request must carry `Authorization: Bearer <token>` matching the fd-5 daemon token.
- **Spec:** `docs/design/2026-07-02-railgun-helper-v1.md` is the source of truth.

---

## File Structure

```
Cargo.toml            binary crate `railgun-helper`; pinned Kohaku git dep
src/main.rs           #[tokio::main]; fd-3/4/5 lifecycle, wiring
src/secret.rs         SecretPayload struct + read_secret_payload(fd) parser
src/provider.rs       DaemonProvider: impl railgun's Eip1193Provider over daemon HTTP
src/keys.rs           derive_railgun_signer(entropy_hex, chain_id) -> Arc<dyn RailgunSigner>
src/railgun.rs        RailgunHelper: balance() + prepare_shield(); balance-split + tx-map logic
src/rpc.rs            serve_rpc(): Unix-socket JSON-RPC server + bearer auth
docs/design/…         spec (exists)
docs/superpowers/…    this plan
```

Boundaries: `secret`/`keys`/`railgun` are pure-logic + unit-testable; `provider`/`rpc` are I/O adapters; `main` only wires them. Files that change together (RPC method → handler) live together in `railgun.rs`.

---

### Task 1: Repo scaffold + pinned dependency + API-lock build spike

Establishes the crate compiles against the pinned Kohaku dep and **confirms the two internal signatures not yet pinned** (`AssetId` shape, `PoiStatus` variants, `HexKey` ctor). This task's deliverable is a compiling skeleton + a short `NOTES.md` recording the confirmed signatures that later tasks depend on.

**Files:**
- Create: `Cargo.toml`
- Create: `src/main.rs` (temporary stub)
- Create: `rust-toolchain.toml`
- Create: `NOTES.md` (confirmed-signatures scratchpad)

**Interfaces:**
- Produces: a buildable crate with `railgun`, `eip-1193-provider`, `userop-kit` resolvable; `NOTES.md` recording exact `AssetId`/`PoiStatus`/`HexKey`/`fs::` names for Tasks 4–5.

- [ ] **Step 1: Create `rust-toolchain.toml`**

```toml
[toolchain]
channel = "1.85"
```

- [ ] **Step 2: Create `Cargo.toml`**

```toml
[package]
name = "railgun-helper"
version = "0.0.0"
edition = "2021"
license = "MIT OR Apache-2.0"
publish = false

[dependencies]
railgun = { git = "https://github.com/ethereum/kohaku.git", rev = "877026e1775a333c556c6fea54dc270009aac978", default-features = false }
eip-1193-provider = { git = "https://github.com/ethereum/kohaku.git", rev = "877026e1775a333c556c6fea54dc270009aac978" }
alloy = { version = "1.8", features = ["std"] }
tokio = { version = "1", features = ["macros", "rt-multi-thread", "net", "io-util", "signal"] }
hyper = { version = "1", features = ["server", "http1"] }
hyper-util = { version = "0.1", features = ["tokio"] }
reqwest = { version = "0.12", features = ["json"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
bip32 = "0.5"
rand = "0.8"
thiserror = "1"
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }

[dev-dependencies]
tempfile = "3"
```

- [ ] **Step 3: Create `src/main.rs` stub**

```rust
fn main() {
    println!("railgun-helper skeleton");
}
```

- [ ] **Step 4: Build against the pinned dep**

Run: `cargo build`
Expected: PASS. This resolves the whole Kohaku Rust workspace (`common`, `crypto`, `userop-kit`) transitively. If `ark-circom`/`ark-groth16` fail to build, STOP and report — this is the primary feasibility gate. (Shield-only never invokes proving at runtime, but the crate still compiles it.)

- [ ] **Step 5: Confirm the unpinned signatures from the vendored source**

Run: `cargo doc -p railgun --no-deps` then open `target/doc/railgun/index.html`, OR read the checked-out source under `~/.cargo/git/checkouts/kohaku-*/877026e/crates/railgun/src/`. Record in `NOTES.md` the exact:
- `AssetId` definition (expected an enum with an ERC-20 variant carrying an `alloy::primitives::Address`; note the exact variant name + how to read the contract address).
- `PoiStatus` variants (confirm `Valid` exists; list the others).
- The `HexKey` trait ctor on `SpendingKey`/`ViewingKey` (`from_bytes([u8;32])` is confirmed at `crypto/keys.rs:62`; confirm whether `from_hex` also exists).
- Whether `railgun::database::fs` exposes a ready file-backed `Database` we can reuse (path + options), vs. needing a custom impl (Task 6 decision).

- [ ] **Step 6: Commit**

```bash
git add Cargo.toml Cargo.lock rust-toolchain.toml src/main.rs NOTES.md
git commit -m "chore: scaffold railgun-helper crate + pin Kohaku dep (API-lock spike)"
```

---

### Task 2: fd-5 secret payload parser (`secret.rs`)

**Files:**
- Create: `src/secret.rs`
- Modify: `src/main.rs` (add `mod secret;`)
- Test: inline `#[cfg(test)]` in `src/secret.rs`

**Interfaces:**
- Produces: `pub struct DaemonConn { pub socket_path: Option<String>, pub token: String, pub url: Option<String> }`, `pub struct SecretPayload { pub entropy_hex: String, pub sidecar_socket_path: String, pub daemon: DaemonConn }`, and `pub fn parse_secret_payload(bytes: &[u8]) -> Result<SecretPayload, serde_json::Error>`.

- [ ] **Step 1: Write the failing test**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_payload_with_url_and_socket() {
        let json = br#"{
            "entropyHex":"0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
            "sidecarSocketPath":"/tmp/rg.sock",
            "daemon":{"socketPath":"/tmp/daemon.sock","token":"abc","url":"http://127.0.0.1:8545"}
        }"#;
        let p = parse_secret_payload(json).unwrap();
        assert_eq!(p.entropy_hex, "0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20");
        assert_eq!(p.sidecar_socket_path, "/tmp/rg.sock");
        assert_eq!(p.daemon.token, "abc");
        assert_eq!(p.daemon.url.as_deref(), Some("http://127.0.0.1:8545"));
    }

    #[test]
    fn rejects_missing_token() {
        let json = br#"{"entropyHex":"0x00","sidecarSocketPath":"/s","daemon":{"url":"http://x"}}"#;
        assert!(parse_secret_payload(json).is_err());
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --lib secret`
Expected: FAIL (module/functions not defined).

- [ ] **Step 3: Write minimal implementation**

```rust
use serde::Deserialize;

#[derive(Debug, Deserialize)]
pub struct DaemonConn {
    #[serde(rename = "socketPath")]
    pub socket_path: Option<String>,
    pub token: String,
    pub url: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SecretPayload {
    #[serde(rename = "entropyHex")]
    pub entropy_hex: String,
    #[serde(rename = "sidecarSocketPath")]
    pub sidecar_socket_path: String,
    pub daemon: DaemonConn,
}

pub fn parse_secret_payload(bytes: &[u8]) -> Result<SecretPayload, serde_json::Error> {
    serde_json::from_slice(bytes)
}
```

Add `mod secret;` to `src/main.rs`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test --lib secret`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add src/secret.rs src/main.rs
git commit -m "feat: fd-5 secret payload parser"
```

---

### Task 3: Railgun key derivation (`keys.rs`)

Derive the spending + viewing keys from the fd-5 entropy at Railgun's BIP-32 paths and build a `PrivateKeySigner`. Mirrors the TS `createRailgunPlugin` flow (entropy → mnemonic → seed → BIP-32 derive at `spending_key_path`/`viewing_key_path` → key bytes).

**Files:**
- Create: `src/keys.rs`
- Modify: `src/main.rs` (add `mod keys;`)
- Test: inline `#[cfg(test)]` in `src/keys.rs`

**Interfaces:**
- Consumes: `railgun::account::signer::{spending_key_path, viewing_key_path, PrivateKeySigner, RailgunSigner}` (confirmed: paths `m/44'/1984'/0'/0'/{i}'` and `m/420'/1984'/0'/0'/{i}'`; `PrivateKeySigner::new_evm(SpendingKey, ViewingKey, u64) -> Arc<Self>`); `railgun::crypto::keys::{SpendingKey, ViewingKey}` with `HexKey::from_bytes([u8;32])`.
- Produces: `pub fn derive_signer(entropy_hex: &str, chain_id: u64, index: u32) -> Result<Arc<dyn RailgunSigner>, KeyError>` and `pub enum KeyError`.

- [ ] **Step 1: Write the failing test**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    const ENTROPY: &str = "0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";

    #[test]
    fn derivation_is_deterministic() {
        let a = derive_signer(ENTROPY, 11155111, 0).unwrap();
        let b = derive_signer(ENTROPY, 11155111, 0).unwrap();
        assert_eq!(a.address().to_string(), b.address().to_string());
    }

    #[test]
    fn spending_and_viewing_differ() {
        let s = derive_signer(ENTROPY, 11155111, 0).unwrap();
        assert_ne!(
            format!("{:?}", s.spending_key()),
            format!("{:?}", s.viewing_key())
        );
    }

    #[test]
    fn address_is_a_0zk_string() {
        // Characterization test: capture the derived address on first green run and
        // paste it here to lock derivation. 0zk addresses are bech32-ish strings.
        let s = derive_signer(ENTROPY, 11155111, 0).unwrap();
        let addr = s.address().to_string();
        assert!(addr.starts_with("0zk"), "got {addr}");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --lib keys`
Expected: FAIL (functions not defined).

- [ ] **Step 3: Write minimal implementation**

```rust
use std::sync::Arc;
use bip32::{Mnemonic, XPrv, DerivationPath};
use railgun::account::signer::{spending_key_path, viewing_key_path, PrivateKeySigner, RailgunSigner};
use railgun::crypto::keys::{SpendingKey, ViewingKey, HexKey};

#[derive(Debug, thiserror::Error)]
pub enum KeyError {
    #[error("bad entropy hex: {0}")]
    Entropy(String),
    #[error("bip32 error: {0}")]
    Bip32(#[from] bip32::Error),
}

fn derive_bytes(seed: &bip32::Seed, path: &str) -> Result<[u8; 32], KeyError> {
    let path: DerivationPath = path.parse()?;
    let xprv = XPrv::derive_from_path(seed, &path)?;
    Ok(xprv.private_key().to_bytes().into())
}

pub fn derive_signer(
    entropy_hex: &str,
    chain_id: u64,
    index: u32,
) -> Result<Arc<dyn RailgunSigner>, KeyError> {
    let clean = entropy_hex.strip_prefix("0x").unwrap_or(entropy_hex);
    let entropy = hex_to_32(clean)?;
    // entropy -> BIP-39 mnemonic -> seed (empty passphrase), matching the TS keystore.
    let mnemonic = Mnemonic::from_entropy(entropy, bip32::Language::English);
    let seed = mnemonic.to_seed("");
    let spending = SpendingKey::from_bytes(derive_bytes(&seed, &spending_key_path(index))?);
    let viewing = ViewingKey::from_bytes(derive_bytes(&seed, &viewing_key_path(index))?);
    Ok(PrivateKeySigner::new_evm(spending, viewing, chain_id) as Arc<dyn RailgunSigner>)
}

fn hex_to_32(s: &str) -> Result<[u8; 32], KeyError> {
    let bytes = (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16))
        .collect::<Result<Vec<u8>, _>>()
        .map_err(|e| KeyError::Entropy(e.to_string()))?;
    bytes.try_into().map_err(|_| KeyError::Entropy("need 32 bytes".into()))
}
```

Add `mod keys;` to `src/main.rs`. If `HexKey` is not the trait exposing `from_bytes` (confirm via Task 1 `NOTES.md`), adjust the `use` and call accordingly.

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test --lib keys`
Expected: FAIL first on `address_is_a_0zk_string` if the prefix differs — read the printed `got …`, confirm it is the real address form, and update the assertion to the actual prefix. Then PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/keys.rs src/main.rs
git commit -m "feat: derive Railgun spending/viewing keys from fd-5 entropy"
```

---

### Task 4: Daemon-backed Eip1193Provider (`provider.rs`)

Implement the crate's `Eip1193Provider` by forwarding JSON-RPC to the daemon over authenticated HTTP (the daemon dev `url` mode; Unix-socket transport is added with the deferred app-spawn task). This is what `RailgunBuilder` binds to for chain reads and the Subsquid syncer's RPC fallback.

**Files:**
- Create: `src/provider.rs`
- Modify: `src/main.rs` (add `mod provider;`)
- Test: inline `#[cfg(test)]` using a `tokio` test + a local mock HTTP server (hyper).

**Interfaces:**
- Consumes: `eip_1193_provider::provider::{Eip1193Provider, Eip1193Error, RawLog}` (trait methods confirmed: `get_chain_id -> u64`, `get_block_number -> u64`, `logs(..) -> Vec<RawLog>`, `eth_call(Address, Bytes) -> Bytes`, `estimate_gas(..) -> u64`, `gas_price -> u128`, `transaction_count(..) -> u64`); `alloy::primitives::{Address, Bytes, U256}`.
- Produces: `pub struct DaemonProvider { url: String, token: String, http: reqwest::Client }` with `pub fn new(url: String, token: String) -> Self`, implementing `Eip1193Provider`. Confirm the exact `logs()` and `transaction_count()` argument lists against `NOTES.md`/rustdoc before writing the impl bodies.

- [ ] **Step 1: Write the failing test (mock daemon returns a chain id)**

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use eip_1193_provider::provider::Eip1193Provider;

    async fn spawn_mock(response_body: &'static str) -> String {
        use hyper::{body::Bytes, service::service_fn, Response};
        use hyper_util::rt::TokioIo;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let io = TokioIo::new(stream);
            let svc = service_fn(move |_req| async move {
                Ok::<_, hyper::Error>(Response::new(http_body_util::Full::new(Bytes::from(response_body))))
            });
            let _ = hyper::server::conn::http1::Builder::new().serve_connection(io, svc).await;
        });
        format!("http://{addr}")
    }

    #[tokio::test]
    async fn forwards_get_chain_id() {
        let url = spawn_mock(r#"{"jsonrpc":"2.0","id":1,"result":"0xaa36a7"}"#).await;
        let p = DaemonProvider::new(url, "tok".into());
        let id = p.get_chain_id().await.unwrap();
        assert_eq!(id, 11155111);
    }
}
```

Add `http-body-util = "0.1"` to `[dev-dependencies]`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --lib provider`
Expected: FAIL (type not defined).

- [ ] **Step 3: Write minimal implementation**

```rust
use alloy::primitives::{Address, Bytes, U256};
use eip_1193_provider::provider::{Eip1193Provider, Eip1193Error, RawLog};
use serde_json::json;

pub struct DaemonProvider {
    url: String,
    token: String,
    http: reqwest::Client,
}

impl DaemonProvider {
    pub fn new(url: String, token: String) -> Self {
        Self { url, token, http: reqwest::Client::new() }
    }

    async fn call(&self, method: &str, params: serde_json::Value) -> Result<serde_json::Value, Eip1193Error> {
        let body = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
        let resp = self.http.post(&self.url)
            .bearer_auth(&self.token)
            .json(&body)
            .send().await.map_err(|e| Eip1193Error::from_msg(e.to_string()))?
            .json::<serde_json::Value>().await.map_err(|e| Eip1193Error::from_msg(e.to_string()))?;
        if let Some(err) = resp.get("error") {
            return Err(Eip1193Error::from_msg(format!("{method}: {err}")));
        }
        Ok(resp.get("result").cloned().unwrap_or(serde_json::Value::Null))
    }
}

fn hex_u64(v: &serde_json::Value) -> u64 {
    u64::from_str_radix(v.as_str().unwrap_or("0x0").trim_start_matches("0x"), 16).unwrap_or(0)
}
```

Then implement `Eip1193Provider` for `DaemonProvider`, mapping each trait method to `self.call(...)` with the JSON-RPC method name (`eth_chainId`, `eth_blockNumber`, `eth_getLogs`, `eth_call`, `eth_estimateGas`, `eth_gasPrice`, `eth_getTransactionCount`) and decoding the result. **Copy the exact method signatures and `RawLog` fields from rustdoc** (fields recorded in Task 1). Bigints in params must be serialized as `0x`-hex quantities (mirror the pp `daemon-provider.ts` note). `Eip1193Error::from_msg` — use whatever constructor rustdoc shows (adjust name if different).

> `eth_getTransactionCount` may not be served by the daemon yet; it is only used by the relay/UserOp path (out of v1 scope), so a v1 `transaction_count` that returns `Eip1193Error` is acceptable if the daemon lacks it — but implement the real forward and note it.

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test --lib provider`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/provider.rs src/main.rs Cargo.toml
git commit -m "feat: daemon-backed Eip1193Provider (HTTP + bearer)"
```

---

### Task 5: Railgun wiring — balance split + shield mapping (`railgun.rs`)

The core logic. Builds the `RailgunProvider`, exposes `balance()` (POI-split into valid/pending/total) and `prepare_shield()` (native ETH → `Vec<TxData>`). Split/mapping logic is unit-tested with hand-built inputs; the network path is covered by the manual gate (Task 7).

**Files:**
- Create: `src/railgun.rs`
- Modify: `src/main.rs` (add `mod railgun;`)
- Test: inline `#[cfg(test)]` for `split_balance` and `map_shield_txs` (pure fns).

**Interfaces:**
- Consumes: `railgun::builder::RailgunBuilder`, `railgun::chain_config::ChainConfig::sepolia()`, `railgun::provider::{RailgunProvider, BalanceEntry}` (`BalanceEntry { asset: AssetId, poi_status: Option<PoiStatus>, amount: u128 }`, confirmed), `ShieldBuilder::{shield_native, build}` (`build<R: Rng>(rng) -> Result<Vec<TxData>, _>`, confirmed), `eip_1193_provider::tx_data::TxData { to: Address, data: Bytes, value: U256 }`; `AssetId`/`PoiStatus` exact forms from Task 1 `NOTES.md`; `DaemonProvider` (Task 4); `derive_signer` (Task 3).
- Produces: `pub struct RailgunHelper` with `pub async fn new(entropy_hex, provider: DaemonProvider, db_path: PathBuf) -> Result<Self, HelperError>`, `pub async fn balance_hex(&mut self) -> Result<BalanceReply, HelperError>`, `pub async fn prepare_shield(&mut self, amount_wei: U256) -> Result<Vec<TxJson>, HelperError>`; `pub struct BalanceReply { valid: String, pending: String, total: String }`; `pub struct TxJson { to: String, data: String, value: String }`.

- [ ] **Step 1: Write the failing test (pure logic)**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    // Build BalanceEntry values via the crate constructors confirmed in NOTES.md.
    // Pseudocode shape — replace `weth()`, `erc20(addr)`, `valid()`/`pending()` with the
    // real AssetId/PoiStatus constructors from Task 1.
    #[test]
    fn split_sums_by_poi_status() {
        let weth = super::tests_support::weth_asset();
        let entries = vec![
            super::tests_support::entry(weth.clone(), super::tests_support::valid(), 100),
            super::tests_support::entry(weth.clone(), super::tests_support::pending(), 40),
            super::tests_support::entry(weth.clone(), super::tests_support::valid(), 60),
        ];
        let r = split_balance(&entries, super::tests_support::weth_contract());
        assert_eq!(r.valid, "0xa0");    // 160
        assert_eq!(r.pending, "0x28");  // 40
        assert_eq!(r.total, "0xc8");    // 200
    }

    #[test]
    fn map_shield_txs_serializes_fields() {
        use alloy::primitives::{address, bytes, U256};
        let txs = vec![TxData::new(
            address!("0x00000000000000000000000000000000000000aa"),
            bytes!("deadbeef"),
            U256::from(5u64),
        )];
        let out = map_shield_txs(txs);
        assert_eq!(out[0].to, "0x00000000000000000000000000000000000000aa");
        assert_eq!(out[0].data, "0xdeadbeef");
        assert_eq!(out[0].value, "5");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --lib railgun`
Expected: FAIL (functions not defined).

- [ ] **Step 3: Write minimal implementation**

```rust
use std::path::PathBuf;
use std::sync::Arc;
use alloy::primitives::{Address, U256};
use rand::rngs::OsRng;
use railgun::builder::RailgunBuilder;
use railgun::chain_config::ChainConfig;
use railgun::provider::{RailgunProvider, BalanceEntry};
use eip_1193_provider::tx_data::TxData;
use serde::Serialize;
use crate::keys::derive_signer;
use crate::provider::DaemonProvider;

#[derive(Debug, thiserror::Error)]
pub enum HelperError { /* wrap KeyError, provider/build errors, unsupported chain */ }

#[derive(Serialize)]
pub struct BalanceReply { pub valid: String, pub pending: String, pub total: String }

#[derive(Serialize)]
pub struct TxJson { pub to: String, pub data: String, pub value: String }

pub struct RailgunHelper {
    provider: RailgunProvider,
    signer_address: railgun::account::address::RailgunAddress, // exact path per NOTES.md
    weth: Address,
}

// Pure: sum WETH-contract entries by POI status. `is_valid` compares against the
// confirmed PoiStatus::Valid variant (Task 1).
fn split_balance(entries: &[BalanceEntry], weth: Address) -> BalanceReply {
    let (mut valid, mut pending) = (0u128, 0u128);
    for e in entries {
        if !asset_is(e, weth) { continue; }
        if poi_is_valid(&e.poi_status) { valid += e.amount; } else { pending += e.amount; }
    }
    BalanceReply {
        valid: format!("0x{valid:x}"),
        pending: format!("0x{pending:x}"),
        total: format!("0x{:x}", valid + pending),
    }
}

fn map_shield_txs(txs: Vec<TxData>) -> Vec<TxJson> {
    txs.into_iter().map(|t| TxJson {
        to: format!("{:#x}", t.to),
        data: format!("0x{}", hex::encode(t.data.as_ref())),
        value: t.value.to_string(),
    }).collect()
}
```

Then add the async methods:
- `new(...)`: `derive_signer` → `ChainConfig::sepolia()` → `RailgunBuilder::new(chain, Arc::new(provider)).with_database(db).with_poi().build().await?` (default syncer = Subsquid + RPC) → `provider.register(signer).await?`; store `signer.address()` and `chain.wrapped_base_token`.
  - `db`: use `railgun::database::fs` if Task 1 confirmed it accepts a path + gives `Arc<dyn Database>`; otherwise implement the 3-method `Database` trait (`get/set/delete` over `&[u8]`) backed by a `0o600` JSON file (see Task 6 note). **Decide in Task 1.**
- `balance_hex(&mut self)`: `self.provider.sync().await?; let e = self.provider.balance(self.signer_address).await; Ok(split_balance(&e, self.weth))`.
- `prepare_shield(&mut self, amount_wei)`: `self.provider.sync().await?; let txs = self.provider.shield().shield_native(self.signer_address, amount_wei.to::<u128>()).build(&mut OsRng)?; Ok(map_shield_txs(txs))`.

Add `hex = "0.4"` to `[dependencies]`. Replace `asset_is`/`poi_is_valid`/`tests_support` helpers with the real `AssetId`/`PoiStatus` accessors from `NOTES.md`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test --lib railgun`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add src/railgun.rs src/main.rs Cargo.toml
git commit -m "feat: railgun balance-split + shield tx mapping"
```

---

### Task 6: Unix-socket JSON-RPC server (`rpc.rs`)

Serve `balance` and `prepareShield` over the sidecar Unix socket with bearer auth and `Connection: close` semantics (matching the pp `rpc.ts` so the Swift client's read-to-EOF terminates).

**Files:**
- Create: `src/rpc.rs`
- Modify: `src/main.rs` (add `mod rpc;`)
- Test: inline `#[cfg(test)]` — a `tokio` test that connects a client to the served Unix socket.

**Interfaces:**
- Consumes: `RailgunHelper` (Task 5); `tokio::net::UnixListener`; `hyper`/`hyper-util`.
- Produces: `pub async fn serve_rpc(socket_path: &str, token: String, helper: RailgunHelper) -> std::io::Result<()>`. The helper is `&mut` inside handlers, so wrap it in `Arc<tokio::sync::Mutex<RailgunHelper>>` internally (serializes sync/balance — correct for a single-writer sidecar).

- [ ] **Step 1: Write the failing test (auth rejected without token)**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn rejects_missing_bearer() {
        // Start serve_rpc on a temp socket with a dummy helper, then POST without the
        // Authorization header and assert HTTP 401. (Construct a helper via a mock
        // DaemonProvider that never gets called because auth fails first.)
        // See executing notes: build the request with hyper client over UnixStream.
        assert!(true); // replace with the real 401 assertion once serve_rpc exists
    }
}
```

> Note for the implementer: the meaningful assertion is "unauthenticated request → 401 before any handler runs." Because building a full `RailgunHelper` needs a live daemon, gate the auth check *before* helper access so the test can pass a helper that would panic if called. If wiring a real helper in a unit test is impractical, promote this to the Task 7 manual gate and keep only a synchronous `is_authorized(headers, token) -> bool` unit test here.

- [ ] **Step 2: Extract and test the pure auth check first**

```rust
pub fn is_authorized(auth_header: Option<&str>, token: &str) -> bool {
    auth_header == Some(&format!("Bearer {token}")).as_deref()
}
```

```rust
#[test]
fn auth_check() {
    assert!(is_authorized(Some("Bearer t"), "t"));
    assert!(!is_authorized(Some("Bearer x"), "t"));
    assert!(!is_authorized(None, "t"));
}
```

Run: `cargo test --lib rpc::tests::auth_check`
Expected: FAIL then PASS after adding `is_authorized`.

- [ ] **Step 3: Implement `serve_rpc`**

```rust
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio::net::UnixListener;
use hyper::{Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use serde_json::{json, Value};
use crate::railgun::RailgunHelper;

pub async fn serve_rpc(socket_path: &str, token: String, helper: RailgunHelper) -> std::io::Result<()> {
    let _ = std::fs::remove_file(socket_path);
    let listener = UnixListener::bind(socket_path)?;
    let shared = Arc::new(Mutex::new(helper));
    let token = Arc::new(token);
    loop {
        let (stream, _) = listener.accept().await?;
        let (shared, token) = (shared.clone(), token.clone());
        tokio::spawn(async move {
            let io = TokioIo::new(stream);
            let svc = hyper::service::service_fn(move |req: Request<hyper::body::Incoming>| {
                let (shared, token) = (shared.clone(), token.clone());
                async move { Ok::<_, hyper::Error>(handle(req, shared, token).await) }
            });
            let _ = hyper::server::conn::http1::Builder::new()
                .serve_connection(io, svc).await;
        });
    }
}

async fn handle(
    req: Request<hyper::body::Incoming>,
    helper: Arc<Mutex<RailgunHelper>>,
    token: Arc<String>,
) -> Response<Full<Bytes>> {
    let auth = req.headers().get("authorization").and_then(|v| v.to_str().ok()).map(|s| s.to_string());
    if !is_authorized(auth.as_deref(), &token) {
        return resp(StatusCode::UNAUTHORIZED, Full::new(Bytes::new()));
    }
    let body = req.into_body().collect().await.map(|b| b.to_bytes()).unwrap_or_default();
    let parsed: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
    let id = parsed.get("id").cloned().unwrap_or(Value::Null);
    let method = parsed.get("method").and_then(|m| m.as_str()).unwrap_or("");
    let out = dispatch(method, parsed.get("params").cloned(), &helper).await;
    let payload = match out {
        Ok(result) => json!({ "jsonrpc":"2.0","id":id,"result":result }),
        Err(e) => json!({ "jsonrpc":"2.0","id":id,"error":{"code":-32000,"message":e} }),
    };
    resp(StatusCode::OK, Full::new(Bytes::from(serde_json::to_vec(&payload).unwrap())))
}

async fn dispatch(method: &str, params: Option<Value>, helper: &Arc<Mutex<RailgunHelper>>) -> Result<Value, String> {
    let mut h = helper.lock().await;
    match method {
        "balance" => serde_json::to_value(h.balance_hex().await.map_err(|e| e.to_string())?).map_err(|e| e.to_string()),
        "prepareShield" => {
            let amt = params.and_then(|p| p.get("amountWei").and_then(|v| v.as_str().map(String::from)))
                .ok_or("missing amountWei")?;
            let wei = alloy::primitives::U256::from_str_radix(amt.trim_start_matches("0x"), if amt.starts_with("0x") {16} else {10})
                .map_err(|e| e.to_string())?;
            serde_json::to_value(h.prepare_shield(wei).await.map_err(|e| e.to_string())?).map_err(|e| e.to_string())
        }
        other => Err(format!("unknown method: {other}")),
    }
}

fn resp(status: StatusCode, body: Full<Bytes>) -> Response<Full<Bytes>> {
    Response::builder().status(status).header("connection", "close")
        .header("content-type", "application/json").body(body).unwrap()
}
```

Add `http-body-util = "0.1"` to `[dependencies]` (promote from dev-deps). Add `mod rpc;` to `main.rs`.

- [ ] **Step 4: Run tests**

Run: `cargo test --lib rpc`
Expected: PASS (the `is_authorized` unit test; the socket-level 401 test if you wired it).

- [ ] **Step 5: Commit**

```bash
git add src/rpc.rs src/main.rs Cargo.toml
git commit -m "feat: unix-socket JSON-RPC server (balance, prepareShield)"
```

---

### Task 7: Main wiring + fd lifecycle + manual Sepolia gate

Wire everything under the fd-3/4/5 contract and add the manual end-to-end gate (mirrors the pp `privacy-helper` README gate). Network correctness is verified here, not in CI.

**Files:**
- Modify: `src/main.rs` (full implementation)
- Create: `README.md` "Manual Sepolia gate" section (append)

**Interfaces:**
- Consumes: `secret`, `keys`, `provider`, `railgun`, `rpc` modules.

- [ ] **Step 1: Implement `main.rs`**

```rust
mod secret; mod keys; mod provider; mod railgun; mod rpc;

use std::io::{Read, Write};
use std::os::unix::io::FromRawFd;
use std::path::PathBuf;

const READY_FD: i32 = 3;
const ALIVE_FD: i32 = 4;
const SECRET_FD: i32 = 5;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt().with_env_filter(
        tracing_subscriber::EnvFilter::from_default_env()).init();
    if let Err(e) = run().await {
        eprintln!("railgun-helper fatal: {e}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    // fd-5: read the secret payload to EOF.
    let mut secret_bytes = Vec::new();
    unsafe { std::fs::File::from_raw_fd(SECRET_FD) }.read_to_end(&mut secret_bytes)?;
    let payload = secret::parse_secret_payload(&secret_bytes)?;

    let url = payload.daemon.url.clone()
        .ok_or("v1 requires daemon.url (loopback HTTP); socket transport lands with app-spawn")?;
    let dp = provider::DaemonProvider::new(url, payload.daemon.token.clone());

    let state = PathBuf::from(std::env::var("HOME").unwrap_or_default())
        .join("Library/Application Support/LocalWallet/railgun-sepolia.json");
    std::fs::create_dir_all(state.parent().unwrap())?;

    let helper = railgun::RailgunHelper::new(&payload.entropy_hex, dp, state).await?;

    // Serve on the sidecar socket; signal ready on fd-3; exit when fd-4 hits EOF.
    let socket = payload.sidecar_socket_path.clone();
    let token = payload.daemon.token.clone();
    let server = tokio::spawn(async move { rpc::serve_rpc(&socket, token, helper).await });

    unsafe { std::fs::File::from_raw_fd(READY_FD) }.write_all(b"ready\n")?;

    // fd-4 EOF => exit(0).
    tokio::task::spawn_blocking(|| {
        let mut alive = unsafe { std::fs::File::from_raw_fd(ALIVE_FD) };
        let mut buf = [0u8; 64];
        while let Ok(n) = alive.read(&mut buf) { if n == 0 { break; } }
    }).await.ok();
    server.abort();
    std::process::exit(0);
}
```

- [ ] **Step 2: Build**

Run: `cargo build`
Expected: PASS.

- [ ] **Step 3: Add the manual Sepolia gate to `README.md`**

Append a section documenting: start the daemon in dev mode (`cargo run -p wallet-node -- --http 127.0.0.1:0 --print-ready --debug` in `../local-wallet-daemon`, needs a **Sepolia archive RPC**), note its `token`/`httpAddr`, build a throwaway fd-5 payload JSON (throwaway entropy, `daemon.url` = the httpAddr, a `sidecarSocketPath`), launch `railgun-helper` with fds 3/4/5 wired (reuse the pp gate's `bash` fd-redirection recipe), then `curl --unix-socket <sidecar.sock>` a `balance` and a `prepareShield` request with the bearer token.

- [ ] **Step 4: Run the manual gate**

Expected: `balance` returns `{ valid, pending, total }`; after submitting the `prepareShield` txs via the daemon and waiting, `balance` shows a non-zero `pending` (then `valid` once POI clears — verified live in the spec §4.1).

- [ ] **Step 5: Commit**

```bash
git add src/main.rs README.md
git commit -m "feat: fd lifecycle wiring + manual Sepolia gate"
```

---

### Task 8: (Deferred) App-side spawn wiring — NOT in v1

Documented so it isn't forgotten; **do not implement in this plan**. When picked up: teach the macOS app's `SpawnHelper`/`CSpawn` to spawn `railgun-helper` with fds 3/4/5 (as it does `wallet-node`), decide where the built binary is bundled/discovered, and add **Unix-socket transport** to `DaemonProvider` (v1 uses only the daemon `url`). Its own spec/plan cycle.

- [ ] **Step 1: Create `docs/design/backlog-app-spawn.md`** capturing the above as the next work item, then commit.

```bash
git add docs/design/backlog-app-spawn.md
git commit -m "docs: backlog app-spawn + unix-socket transport (post-v1)"
```

---

## Self-Review

**Spec coverage:**
- §2.1 Rust sidecar + fd contract → Tasks 6–7. §2.2 Kohaku no-WASM dep → Task 1. §2.4 Subsquid default → Task 5 (`build()` default syncer). §4 RPC (`balance`, `prepareShield` array) → Tasks 5–6. §4.1 POI-split → Task 5 `split_balance`. §6.1 secrets never persisted/logged → Global Constraints + Task 3. §7.1 relay → out of scope (self-submit; Task 7 step 4 submits via daemon). §8 rev pin → Task 1; app-spawn deferred → Task 8. ✅ covered.

**Placeholder scan:** The only intentional "confirm against NOTES.md" points are the two genuinely-unpinned internal types (`AssetId`, `PoiStatus`) and the `fs::Database` reuse decision — all resolved by Task 1's deliverable before they're used. Test bodies for the network-dependent server are honestly downgraded to a pure `is_authorized` unit test + the manual gate, rather than faked.

**Type consistency:** `derive_signer` (Task 3) → used in `RailgunHelper::new` (Task 5). `DaemonProvider::new` (Task 4) → `main` (Task 7). `RailgunHelper::{balance_hex, prepare_shield}` (Task 5) → `dispatch` (Task 6). `BalanceReply`/`TxJson` serialize to the §4 RPC shapes. `TxData { to, data, value }` fields match Task 4's confirmed struct. ✅ consistent.
