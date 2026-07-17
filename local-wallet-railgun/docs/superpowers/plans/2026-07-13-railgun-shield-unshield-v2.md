# Railgun Helper v2 — Shield + Unshield + Local Broadcaster (Implementation Plan)

> TDD, task-by-task. Steps use `- [ ]`. Source of truth: `docs/design/2026-07-13-railgun-shield-unshield-v2-design.md`.
> Reference implementation (verbatim working sequence): Kohaku `crates/railgun/tests/integration/transact_utxo.rs` @ rev `877026e`.

**Goal:** A Rust crate at `local-wallet-railgun/` with a `lib` + two bins — `railgun-helper`
(sidecar: `balance`/`prepareShield`/`prepareUnshield`) and `railgun-broadcaster` (local
broadcaster: `relay`/`address`, own EOA) — that shields ETH into RAILGUN on Sepolia and
unshields it, the unshield relayed by the locally-run broadcaster. Verified by an
anvil-Sepolia-fork e2e that confirms both txs on-chain.

## Global constraints
- Kohaku dep: `railgun = { git = "https://github.com/ethereum/kohaku.git", rev = "877026e1775a333c556c6fea54dc270009aac978", default-features = false }`. Never enable `js`.
- `rand = "0.9"`, `rand_chacha = "0.9"` (match the crate's rand major so `SpendingKey/ViewingKey: Distribution` and the `Rng` bound on `build()` line up).
- Chain: Sepolia only, `chain_id 11155111`. Testnet only.
- POI: **never call `.with_poi()`** for the fork e2e.
- Secrets (RAILGUN spending+viewing keys, broadcaster EOA key) never logged / persisted / returned over RPC.
- Toolchain: rustc ≥ 1.85 (crate is edition 2024); this crate edition 2021.

## Confirmed API (from spike / clone)
```
ChainConfig::sepolia() -> { id, railgun_smart_wallet, unshield_fee_bps=25, relay_adapt_contract,
    wrapped_base_token (WETH 0xfFf9…6B14), deployment_block, subsquid_endpoint, poi_endpoint, ... }
provider = ProviderBuilder::new().network::<Ethereum>().wallet(signer).connect(url).await?.erased() // DynProvider: IntoEip1193Provider
syncer = ChainedSyncer::new().then(SubsquidSyncer::new(&chain.subsquid_endpoint).with_latest_block(fork_block))
                             .then(RpcSyncer::new(chain.clone(), provider.clone()).with_batch_size(1000))
railgun = RailgunBuilder::new(chain, provider).with_utxo_syncer(Arc::new(syncer)).build().await?
acct = railgun::account::signer::PrivateKeySigner::new_evm(spending_key, viewing_key, chain.id) // Arc<PrivateKeySigner>
railgun.register(acct.clone()).await?
railgun.shield().shield_native(acct.address(), amount_u128).build(&mut rng)? -> Vec<TxData{to,data,value}>
railgun.sync().await?; railgun.balance(acct.address()).await -> Vec<BalanceEntry{asset:AssetId, poi_status:Option<PoiStatus>, amount:u128}>
tb = TransactionBuilder::new().unshield(acct.clone(), to_addr, AssetId::Erc20(chain.wrapped_base_token), amount_u128)?
proved = railgun.build(tb, &mut rng).await? -> ProvedTx{ tx_data: TxData, .. }
// submit: provider.send_transaction(tx.into()).await?.get_receipt().await?
```
Keys: `SpendingKey([u8;32])`, `ViewingKey([u8;32])`; derive deterministically by seeding
`ChaCha20Rng::from_seed(entropy32)` then `rng.random()` (same path the crate tests use).
Unshield delivers WETH to `to`, minus 25 bps.

---

### Task 1 — Scaffold: crate, pinned dep, build spike, NOTES.md
**Files:** `Cargo.toml`, `rust-toolchain.toml`, `src/lib.rs` (empty mods), `src/bin/railgun-helper.rs` + `src/bin/railgun-broadcaster.rs` (stubs), `NOTES.md`.
- [ ] `Cargo.toml`: `[package] name="railgun-helper" edition="2021" license="MIT OR Apache-2.0" publish=false`; `[lib] name="railgun_helper"`; two `[[bin]]`. Deps: railgun (pinned, default-features=false), alloy 1.8, tokio, hyper+hyper-util, http-body-util, serde, serde_json, hex, thiserror, tracing, tracing-subscriber, rand 0.9, rand_chacha 0.9, sha2. dev: tempfile, serial_test.
- [ ] `cargo build` — **primary feasibility gate** (resolves railgun + circom-compat/ruint git forks + arkworks). PASS expected (spike proved it).
- [ ] Record in `NOTES.md`: confirmed `ChainConfig` fields, `AssetId::Erc20`, `PoiStatus` variants, key ctor path, `ProvedTx.tx_data`.
- [ ] Commit.

### Task 2 — `secret.rs`: fd-5 payload parser (TDD, pure)
- [ ] Failing test: `parse_secret_payload(bytes)` → `SecretPayload{ entropy_hex, sidecar_socket_path, provider: ProviderConn{ url|socket, token } }`; rejects missing entropy / bad hex length.
- [ ] Implement minimal; test passes. Commit.

### Task 3 — `keys.rs`: deterministic RAILGUN key derivation (TDD, pure)
- [ ] Failing test: `derive_railgun_signer(entropy_hex, chain_id)` returns a signer whose `address()` is **stable** across calls for the same entropy and **differs** for different entropy. (Seed ChaCha20Rng from 32-byte entropy → `SpendingKey`/`ViewingKey` via `rng.random()` → `PrivateKeySigner::new_evm`.)
- [ ] Implement; test passes. Also derive an EVM EOA key helper `derive_eoa_key(entropy, label)` for the broadcaster. Commit.

### Task 4 — `provider.rs`: build the alloy DynProvider (I/O adapter)
- [ ] `connect_provider(url, Option<signer>) -> DynProvider` (wallet optional; reads need none). Small test: connect to a local anvil, `get_chain_id()==11155111`. (Marked `#[ignore]` if it needs anvil.)
- [ ] Commit.

### Task 5 — `railgun.rs`: RailgunHelper wiring (balance split + shield + unshield)
**Interfaces:** `RailgunHelper::new(chain, provider, fork_block, signer).await` (builds RailgunBuilder + ChainedSyncer, registers signer, no POI). Methods: `sync()`, `balance_split() -> BalanceSplit{valid,pending,total}` (hex-wei strings, keyed on wrapped_base_token; POI None ⇒ valid), `prepare_shield_native(amount) -> Vec<TxData>`, `prepare_unshield(to, amount) -> TxData` (proof).
- [ ] TDD the **pure** bits first: `split_balance(entries, weth) -> BalanceSplit` unit test (None→valid; Valid→valid; others→pending; total=valid+pending; hex format). 
- [ ] Wire the async methods against the crate. (Exercised on-chain by the Task 10 e2e, not a unit test — proving/sync need the fork + network.)
- [ ] Commit.

### Task 6 — `broadcaster.rs`: LocalBroadcaster (own EOA → submit)
**Interfaces:** `LocalBroadcaster::new(rpc_url, eoa_key)`; `address() -> Address`; `relay(tx: TxData) -> RelayReceipt{ tx_hash, block_number, status }` (signs with its own EOA, `send_transaction`, `get_receipt`).
- [ ] TDD: `address()` derived from key is stable/correct (pure). `relay` exercised on-chain by e2e.
- [ ] Commit.

### Task 7 — `rpc.rs`: Unix-socket JSON-RPC server + bearer auth (shared)
- [ ] TDD pure `check_auth(header, token) -> bool`.
- [ ] `serve_rpc(socket_path, token, handlers)` — hyper over UnixListener; 401 without bearer; dispatch `{method,params}` → handler → `{result|error}`; `Connection: close`. Integration test: bind a temp socket, call over it, assert 401 then 200.
- [ ] Commit.

### Task 8 — `railgun-helper` bin: fd lifecycle + wiring
- [ ] `main`: read fd-5 (or env for standalone/e2e: `LOCAL_WALLET_PRIVACY_RPC_URL`, `RAILGUN_ENTROPY_HEX`, `RAILGUN_FORK_BLOCK`, `RAILGUN_SOCKET`, `RAILGUN_TOKEN`), build RailgunHelper, serve `balance`/`prepareShield`/`prepareUnshield`. fd-3 ready (writes token+socket), fd-4 alive EOF→exit — reuse the wallet-node contract but keep an env path for the e2e.
- [ ] Manual/`#[ignore]` gate documented in README. Commit.

### Task 9 — `railgun-broadcaster` bin: local broadcaster process
- [ ] `main`: read broadcaster EOA key + rpc url + socket + token (env for e2e / fd-5 later), serve `relay`/`address`. Prints its EOA address on ready.
- [ ] Commit.

### Task 10 — e2e: anvil Sepolia-fork shield→unshield, broadcaster relays (the acceptance test)
**Files:** `tests/e2e_fork.rs` (`#[ignore]`, `#[serial]`), `scripts/e2e-fork.sh`.
- [ ] `scripts/e2e-fork.sh`: require `RPC_URL_SEPOLIA`; `export FOUNDRY_DISABLE_NIGHTLY_WARNING=1`; run `cargo test --test e2e_fork -- --ignored --nocapture`.
- [ ] `e2e_fork.rs`:
  1. Spawn anvil `--fork-url $RPC_URL_SEPOLIA --fork-block-number <FORK_BLOCK> --port <p> --silent`; wait ready.
  2. Owner EOA = anvil key[0] (funded); broadcaster EOA = anvil key[1] (funded).
  3. Spawn the **`railgun-broadcaster` binary** as a real local process (broadcaster EOA, its own socket+token). ← runs a broadcaster locally.
  4. Build `RailgunHelper` (owner-wallet provider for reads/shield-submit), register a fresh RAILGUN account (deterministic from test entropy).
  5. `prepareShieldNative(0.01 ETH-equiv small amount)` → owner submits each tx → receipts `success`.
  6. `sync` + `balance_split` → shielded amount present.
  7. `prepareUnshield(recipient, amount)` (Groth16 proof; generous timeout) → proved `TxData`.
  8. Send the proved tx to the running **broadcaster process** over its `relay` socket → broadcaster submits with its own EOA → receipt `success`.
  9. Assert: shield receipt success, unshield receipt success, recipient **WETH** balance increased by ~amount−25bps, and the unshield `from` == broadcaster EOA (proves the local broadcaster relayed it).
- [ ] Run it green against live Sepolia RPC (fork). Fix until it passes. Commit.

### Task 11 — README + docs
- [ ] `README.md`: what it is, the two bins, the local-broadcaster model + anonymity-set-of-one tradeoff, how to run the e2e, POI-off note, artifact-download/network caveats. Commit.

## Self-review checklist
- No `.with_poi()` in the fork path. Keys never logged/persisted/returned. Broadcaster EOA ≠ owner ≠ RAILGUN account. e2e asserts on-chain confirmation + broadcaster-as-submitter. rand version matches crate.
