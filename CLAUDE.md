# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **Scope:** This file lives in `local-wallet-mac` (the macOS app) but is written to guide work across the **three** repositories that make up Local Wallet. The daemon and protocol repos gitignore their own `CLAUDE.md`, so treat this as the shared entry point and read it from the app checkout when working in a sibling repo.

## What Local Wallet is

A self-custodial, privacy-first Ethereum wallet for macOS (v0.1 **alpha**, pre-1.0, not audited). Key custody lives in the Secure Enclave + Keychain; chain reads are light-client-verified; ERC-4337 bundling runs **on-device**; and an on-device LLM turns natural language into reviewable transaction intents — no hosted backend on the core path.

The product is split across three GitHub repos under the `Ethereum-dAI` org. The split is intentional and load-bearing — **put code in the right repo** (see [Repo boundaries](#repo-boundaries--where-code-goes)):

| Repo (clone name) | Contains | Stability |
|---|---|---|
| **`local-wallet-mac`** (this repo) | macOS SwiftUI app, the `wallet-ffi` C-ABI bridge, Swift packages, on-device LLM, Xcode project, build/packaging scripts | pre-1.0 |
| **`local-wallet-protocol`** | Pure Rust SDK: `wallet-signature`, `wallet-kernel`, `wallet-addresses` — deterministic ZeroDev Kernel v3.3 / ERC-4337 encoding + signing. No FFI, no networking, no secrets. | **semver** |
| **`local-wallet-daemon`** | `wallet-node` daemon + `wallet-bundler`, `wallet-chain`, `wallet-node-api`, `wallet-node-store` — self-relaying bundler, Helios reads, SQLite, JSON-RPC | pre-1.0 |

The macOS app **spawns `wallet-node` as a child process** and talks to it over a local authenticated transport. Both the app's `wallet-ffi` and the daemon depend on the protocol crates, so the two sides agree on UserOp encoding **byte-for-byte**.

## The local monorepo (sibling checkouts + the local↔remote dependency swap)

The three repos stay separate on GitHub but must be cloned as **siblings under one parent** for local development — Rust path overrides, the Xcode daemon-binary path, and daemon spawn discovery all resolve relative to that layout.

```
parent/
  local-wallet-mac/        ← this repo (Xcode scheme points at ../local-wallet-daemon)
  local-wallet-protocol/   ← wallet-signature / wallet-kernel / wallet-addresses
  local-wallet-daemon/     ← wallet-node + supporting crates
```

> Do **not** nest the protocol or daemon repos inside `local-wallet-mac`. The full first-clone walkthrough (prereqs, Xcode signing, model download) is in [`LOCAL_MONOREPO_SETUP.md`](LOCAL_MONOREPO_SETUP.md).

### Pinned git rev (remote) vs. path override (local) — the key mechanism

This is the most important cross-repo concept. The protocol crates are consumed two different ways depending on whether you're building a release or doing live development:

- **Remote (committed, reproducible):** `rust-core/Cargo.toml` (app) and `Cargo.toml` (daemon) depend on the protocol crates as a **git dependency pinned to an exact rev** (e.g. `wallet-signature = { git = "…/local-wallet-protocol.git", rev = "ea28622a…" }`). The app additionally pins `wallet-node-api` to a daemon rev — a version-header-only dep that forces cbindgen to materialize `wallet_node_api_version.h` during the FFI build. **These pinned revs are the release contract.**
- **Local (gitignored, live):** copying the example Cargo config installs a **path override** that transparently redirects those git deps to your sibling working copies — it behaves like a symlink from the pinned remote rev to local source, so edits in `local-wallet-protocol` / `local-wallet-daemon` are picked up immediately without re-pinning:

  ```bash
  # in local-wallet-mac (overrides BOTH protocol and daemon):
  cp rust-core/.cargo/config.toml.example rust-core/.cargo/config.toml   # paths = ["../../local-wallet-protocol", "../../local-wallet-daemon"]
  # in local-wallet-daemon (overrides protocol only):
  cp .cargo/config.toml.example .cargo/config.toml                       # paths = ["../local-wallet-protocol"]
  ```

  `.cargo/config.toml` is **gitignored in every repo — never commit it.** Paths are resolved from the directory containing `.cargo/` (so `../../` from `rust-core/`, `../` from the daemon root → the siblings). Verify Cargo sees the local crates with `cargo metadata --manifest-path rust-core/Cargo.toml --format-version 1 >/dev/null`.

### Bumping the protocol pin (shipping a protocol/daemon change end-to-end)

Because the path override masks the rev locally, a protocol change only ships once the pin is bumped in the consumers:

1. Land the change in `local-wallet-protocol` (branch off fresh `main`, PR — see [etiquette](#conventions--etiquette)), get the merged commit SHA.
2. Update `rev = "<new-sha>"` for **all three** protocol crates in **both** `local-wallet-mac/rust-core/Cargo.toml` and `local-wallet-daemon/Cargo.toml` (and the `wallet-node-api` rev in the app if a daemon API change is needed).
3. Refresh each consumer's lockfile: `cargo update -p wallet-signature -p wallet-kernel -p wallet-addresses`.
4. Verify in a build **with the path override disabled** (rename `.cargo/config.toml`) or rely on CI, since overrides hide the rev locally.

## Common commands

### `local-wallet-mac` (app) — Swift + Rust FFI

The app repo has **no CI**; the sequence below (from `CONTRIBUTING.md`) is the local gate. **`build-ffi.sh` is mandatory before any Swift build/test.**

```bash
./scripts/build-ffi.sh        # builds wallet-ffi for aarch64-apple-darwin, runs cbindgen,
                              # stages wallet_ffi.h + wallet_node_api_version.h + libwallet_ffi.a into swift-bridge/ (NOT committed)
cd rust-core && cargo test    # FFI crate tests (crate name: wallet-ffi)
cd ../swift-bridge && swift test
cd ../wallet-macos && swift build      # or `swift test` (SpawnHelperTests need the daemon binary built first)

xcodegen generate             # regenerate LocalWallet.xcodeproj after editing project.yml (do NOT hand-edit the project)
```

- **Run the app:** open `LocalWallet.xcodeproj`, select the **`LocalWalletApp`** scheme, choose an Apple Development team, build & run. **Never `swift run` the app** — Secure Enclave / Keychain persistence fails with `OSStatus -34018` outside a signed bundle. (`swift run wallet-eval …` is fine; it has no Keychain entitlement.)
- **Local Xcode signing gotcha:** Automatic Signing uses a developer-account-specific App ID and a Mac Team Provisioning Profile, and those local profiles can expire or disappear. If Xcode reports `No profiles for 'ai.ethereum.localwallet.demo' were found` or `Failed Registering Bundle Identifier`, treat it as local signing/account state: refresh signing in Xcode, regenerate the profile, or use a local-only project override. Do **not** commit a personal `PRODUCT_BUNDLE_IDENTIFIER` or signing-team workaround; changing the bundle id changes the app's Keychain/Secure Enclave access group and can make an existing local wallet look broken.
- **Single Swift test:** `cd <package> && swift test --filter <Suite>/<test>` (e.g. `cd wallet-macos && swift test --filter SpawnHelperTests`). Test targets: `WalletSignatureTests` (swift-bridge); `SpawnHelperTests`, `WalletToolLayerTests`, `WalletMacOSAppTests` (wallet-macos); `LocalLLMTests` (local-llm).
- **Single FFI Rust test:** `cd rust-core && cargo test -p wallet-ffi <filter>` (also `cargo build -p wallet-ffi --release --target aarch64-apple-darwin`, `cargo clippy -p wallet-ffi`).
- **Package a signed demo:** `LOCAL_WALLET_SEPOLIA_BUNDLER_URL="https://…" ./scripts/package-macos-demo.sh` (embeds `wallet-node` + llama.cpp/ggml dylibs; `LOCAL_WALLET_EMBED_MODEL=1` to embed the GGUF; `LOCAL_WALLET_NOTARIZE=1` + a Developer ID identity for external distribution). See `scripts/README.md`.

### `local-wallet-daemon` — Rust (CI: `fmt --check` → `clippy -- -D warnings` → `test --workspace`)

```bash
cargo build -p wallet-node --release          # the app's Xcode scheme runs ../local-wallet-daemon/target/release/wallet-node
cargo run -p wallet-node -- --http 127.0.0.1:0 --print-ready --debug   # local HTTP dev mode (prints bearer token + httpAddr)
cargo test --workspace                        # default suite
cargo test -p wallet-node -- --include-ignored   # host/socket integration tests (opt-in)
cargo fmt --check && cargo clippy --workspace -- -D warnings
```

- **Single test — `wallet-node` has NO `[lib]` target** (only `[[bin]]`). Unit tests compile into the binary and integration tests live in `crates/wallet-node/tests/`. Use `cargo test -p wallet-node --bin wallet-node <filter>` (unit) or `cargo test -p wallet-node --test <file> <filter>` (integration, e.g. `--test mainnet_fork_kernel`). Other crates have libs: `cargo test -p wallet-node-api <filter>`.
- **Canonical end-to-end check (not in CI):** the mainnet-fork Kernel fixture — `ETH_RPC_URL=<archive-rpc> WALLET_FORK_BLOCK_NUMBER=25001071 ./scripts/run-kernel-mainnet-fork-check.sh`. It exercises pinned Kernel bytecode, EntryPointSimulations state override, deterministic WebAuthn signing, a real ETH-transfer `handleOps`, and a 50-send bundler-EOA flatness run. **If `cargo test --workspace` passes but the fork fixture breaks, the fork fixture is right.** Run it for any change to policy, allowlist, simulation, or signing.

### `local-wallet-protocol` — Rust (CI: same three commands as the daemon)

```bash
cargo build --workspace
cargo test --workspace
cargo test -p wallet-signature <filter>       # single test, e.g. cargo test -p wallet-kernel enable_digest
cargo fmt --check && cargo clippy --workspace -- -D warnings
```

- **Golden vectors:** `tooling/golden-vectors` is a TypeScript harness that drives the ZeroDev SDK to emit deterministic permission/session-key fixtures; the Rust suites assert **byte-for-byte parity** against them. Regenerate with `cd tooling/golden-vectors && npm install && npm run emit`, then copy `out/permission.json` into `crates/kernel/testdata/permission/` and `crates/signature/testdata/permission/`. Run this after changing any permission/session-key encoding.

> CI for the two Rust repos runs on `ubuntu-latest` with `dtolnay/rust-toolchain@stable`. The daemon's private protocol git deps need the `LW_CI_REPO_READ_TOKEN` secret (`CARGO_NET_GIT_FETCH_WITH_CLI=true`); locally your own git credentials cover it. Toolchain baseline is **Rust 1.91+** (known-good 1.95); macOS 14+, Apple Silicon, Xcode 16, Swift 6.

## High-level architecture

### Two app→outside-world paths

Everything the Swift app does crosses one of two boundaries. Knowing which is which tells you where a feature belongs:

1. **In-process FFI (deterministic crypto, no network, no secrets):**
   `Swift (WalletSignature) → WalletFFI (cbindgen header) → wallet-ffi (extern "C") → wallet-signature / wallet-kernel`.
   Covers counterfactual Kernel address prediction, EntryPoint v0.7 UserOp hashing, the WebAuthn 69-byte preimage, and the 6-field Kernel WebAuthn signature encoding. **Private keys never cross the FFI** — Rust sees only public coordinates, hashes, and 64-byte `(r, s)`. Buffers returned across the FFI must be freed exactly once with `wallet_free_buffer`.
2. **JSON-RPC to the daemon (network / chain state / persistence):**
   `Swift (WalletNodeClient) → wallet-node` over a Unix socket (spawned) or loopback HTTP (dev), authenticated by a **per-launch bearer token** the daemon emits at ready time. Covers Helios-verified reads, ERC-4337 gas estimation + submission, bundler-EOA admin, audit/repair, and receipt polling.

### Who signs what (the signing split)

A transaction is an ERC-4337 **UserOperation** on **EntryPoint v0.7** (`0x0000000071727De22E5E9d8BAf0edAc6f37da032`):

- **The app signs the inner UserOp** with the **Secure Enclave P-256 passkey** (the Kernel account's WebAuthn root). Swift signs the preimage (not a pre-hashed digest); `wallet-ffi` low-s-normalizes and ABI-wraps it.
- **The daemon signs the outer transaction.** It validates the op against policy + on-chain state, wraps it into EntryPoint `handleOps([op], beneficiary)`, signs that EIP-1559 tx with the **relayer/bundler EOA**, and self-relays it. The daemon **never** signs UserOps.
- The protocol SDK provides the deterministic encoding used on **both** sides, which is why the daemon can re-encode and validate exactly what the app signed.

Send path order inside the daemon: parse → policy/allowlist/gas-cap → same-block balance + EntryPoint deposit read → funding check → `EntryPointSimulations.simulateValidation` → ensure active bundler EOA → encode `handleOps` → sign EIP-1559 raw tx → persist UserOp/nonce/raw-tx in SQLite → submit → background watcher reconciles receipts and decodes `UserOperationEvent`.

### Account model

- **ZeroDev Kernel v3.3** smart account, **WebAuthn/passkey (P-256) root validator** (Secure Enclave). Generic Kernel addresses live in `local-wallet-protocol/crates/wallet-addresses`; the **app-pinned** factory/impl/validator allowlist lives in `local-wallet-daemon/crates/wallet-bundler/src/allowlist.rs`.
- **Session keys** = the `permission(0x02)` modular-permission module: a local ECDSA key (Keychain, used by the LLM agent) granted a scoped, time/budget-bounded permission. Encoding (policy helpers, `permission_id`, `encode_enable_data`, `enable_digest`, nonce-key, revocation) is in `wallet-kernel`/`wallet-signature` `permission.rs`.
- **Chains: Ethereum Mainnet (1) and Sepolia (11155111) only.** No paymasters; `nonce key = 0`; ETH transfer is the only fork-tested execution path. Enforced in both `wallet-node` config and Swift `SmartAccountConfiguration`.

### Daemon internals worth knowing

- **Crates:** `wallet-node` (binary: RPC handlers, transport, auth, admin challenge, in-RAM bundler-key store, receipt watcher, lifecycle) · `wallet-bundler` (policy, allowlist, gas estimation, simulations, `handleOps` encoding, submit, watcher) · `wallet-chain` (`ChainAdapter` trait: Helios / execution-RPC / mock + stateOverride smoke) · `wallet-node-api` (wire types — the only stable surface) · `wallet-node-store` (SQLite via `rusqlite`).
- **RPC surface:** the bundler/UserOp methods are canonically `localwallet_*` with `eth_*` / `pimlico_*` accepted as aliases (e.g. `localwallet_sendUserOperation` ≡ `eth_sendUserOperation`), while standard chain reads keep their own `eth_*` names (`eth_chainId`, `eth_getBalance`, `eth_call`, …). Also exposed: `localwallet_resolveName` (ENS), `localwallet_quoteSwap` (Uniswap v3), and the admin/audit methods. The method-name source of truth is `wallet-node-api/src/method.rs`.
- **Helios verification toggle** (`config.rs` `ReadVerificationMode`, set via `[network] read_verification`): `helios` (default) verifies execution reads against signed consensus state via a beacon `consensus_rpc`; `execution_rpc` trusts the execution RPC directly (unverified). The send path still gates on `chain.is_synced()` regardless of mode, and the daemon **fails closed** when the stateOverride smoke fails.
- **Store operations go through audit/repair RPCs**, never direct SQLite edits: `wallet_auditStore/History/Report` and `wallet_repairStore` (a fixed set of explicitly gated repair actions). The `wallet-node admin …` subcommand calls these via the bearer token.

### App internals worth knowing

- **Packages → products consumed by the `LocalWalletApp` target:** `swift-bridge` (`WalletSignature`, wrapping `wallet-ffi`) · `local-llm` (`LocalLLM`, vendored llama.cpp/ggml) · `wallet-macos` (`WalletMacOSApp` the SwiftUI app, `WalletToolLayer` tool-intent recognition, `SpawnHelper`/`CSpawn` the daemon launcher, `wallet-eval` benchmark CLI). The Xcode project is generated from `project.yml`.
- **On-device LLM:** Gemma 4 E4B via llama.cpp/ggml (Metal, no network at inference), model at `~/Library/Application Support/LocalWallet/Models/`, chat history in `chat.sqlite`. `WalletToolLayer` turns natural language / `/transfer` / `/swap` into reviewable, Secure-Enclave-signed, daemon-submitted intents.
- **Daemon spawn + lifecycle contract** (`WalletNodeDaemon.swift` + `Sources/Spawn`): the daemon is always launched `wallet-node --ready-fd 3 --alive-fd 4 --secret-fd 5` via `posix_spawn` over three inherited pipes (fd 3 = ready pipe the daemon writes the bearer token + socket path to; fd 4 = alive pipe whose EOF tells the daemon to exit; fd 5 = secret pipe the app writes the bundler-EOA secret to at startup). The daemon also self-exits when `getppid() == 1` (orphan backstop). **Do not change the fd contract without updating `Sources/Spawn` and `SpawnHelperTests`.** Daemon binary resolution order: `LOCAL_WALLET_NODE_BIN` → `WALLET_NODE_BIN` → bundled `bin/wallet-node` → bundled top-level `wallet-node`. The Xcode scheme sets both env vars to `$(SRCROOT)/../local-wallet-daemon/target/release/wallet-node`.

## Repo boundaries — where code goes

- **`wallet-ffi` must stay a thin, synchronous C-ABI bridge** over the protocol SDK. Do **not** introduce daemon types, Helios, SQLite, or Tokio into it.
- **`local-wallet-protocol` is the pure, reusable SDK** — no app-specific pins, no daemon types, no networking, no secrets. App-pinned addresses and runtime concerns belong in the daemon.
- The daemon is the **app-coupled stack**; its only stable surface is the JSON-RPC API documented in `wallet-node-api`. Don't leak app addresses/daemon types back into the protocol crates.

## Conventions & gotchas

**Generated / local-only artifacts (never commit):** `swift-bridge/lib/libwallet_ffi.a`, `swift-bridge/Sources/WalletFFI/wallet_ffi.h`, `wallet_node_api_version.h` (all from `build-ffi.sh`); `LocalWallet.xcodeproj` is regenerated by `xcodegen` (don't hand-edit; discard Xcode's scheme rewrites); every `.cargo/config.toml`; `.env`, RPC/bundler URLs, signing identities. The hosted Sepolia bundler URL is injected at packaging time via `LOCAL_WALLET_SEPOLIA_BUNDLER_URL`.

**Protocol-correctness invariants** (asserted against on-chain Kernel behavior — get these wrong and signatures silently fail validation):
- EntryPoint v0.7 UserOp hash is **`keccak256(abi.encode(...))`, NOT EIP-712** — no `\x19\x01` prefix, no domain separator, signature field excluded. (By contrast, the permission `enable_digest` **is** EIP-712.)
- Kernel WebAuthn signature is the **6-field** ABI struct `(bytes authData, string clientDataJSON, uint256 responseTypeLocation, uint256 r, uint256 s, bool usePrecompiled)`. The validator **rejects high-s**, so `normalise_low_s` is mandatory.
- The gas-estimation dummy signature uses `responseTypeLocation = uint256.max` (sentinel).
- `usePrecompiled = true` → RIP-7212 precompile (~3.4k gas); `false` → Daimo P256 verifier (~330k gas). This drives `verificationGasLimit` sizing.

**Security boundary (do not break):** mutating admin RPCs (`wallet_installBundlerEOA`, `wallet_rotateBundlerEOA`, `wallet_deleteBundlerEOA`) require a single-use challenge from `wallet_beginAdminAction` bound to `(action, ownerScope, chainId, keyRef)`. The bundler EOA secret lives **only in process RAM** in the daemon (durable copy in the app Keychain). Status/RPC responses must never expose key material.

**Do NOT routine-bump the Helios pin** (`helios-ethereum`/`helios-core` in the daemon). Only bump for an explicit security/correctness/compat reason, and re-run the stateOverride smoke (`cargo test -p wallet-chain -- --include-ignored`) and the mainnet-fork fixture before merging.

**Etiquette:** all three repos are dual-licensed **MIT OR Apache-2.0** (new crates inherit `license.workspace = true`). `cargo fmt --check` and `clippy -- -D warnings` are required for the Rust repos. Never commit to `main` in any repo — branch off fresh `main` and open a PR; for anything beyond a typo/small test/doc fix, open an issue first (especially changes to the policy/allowlist or signing surface). Protocol crates follow **semver**; breaking changes ship as a major version.
