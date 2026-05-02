# Local Wallet

Local Wallet is a native macOS wallet prototype plus reusable Rust and Swift tooling for Kernel smart accounts, WebAuthn/P-256 signatures, and a local ERC-4337 bundler daemon.

The repository currently contains two active tracks:

- a signed macOS demo app for Secure Enclave signing and Sepolia workbench flows
- a Rust daemon stack for Ethereum mainnet verified reads, local bundling, Kernel allowlisting, EntryPoint simulation, raw `handleOps` submission, and receipt watching

This is not the final product wallet UX yet. Treat it as a working implementation repo with reusable protocol crates and a demo/reference app.

## Repository Map

| Path | Purpose |
|---|---|
| `rust-core/` | Rust workspace for signature helpers, Kernel helpers, FFI, chain access, bundler logic, daemon API, SQLite store, and `wallet-node`. |
| `rust-core/crates/wallet-node/` | Local wallet daemon binary. It serves authenticated JSON-RPC over Unix sockets or loopback HTTP. |
| `rust-core/crates/wallet-bundler/` | ERC-4337 policy, UserOperation parsing, EntryPoint v0.7 helpers, Kernel allowlist, simulations, raw tx helpers, and watcher logic. |
| `rust-core/crates/wallet-chain/` | Helios-backed verified chain adapter plus a mock adapter for tests. |
| `rust-core/crates/wallet-node-api/` | Shared JSON-RPC method/error/body definitions and generated API version header. |
| `rust-core/crates/wallet-node-store/` | SQLite persistence for UserOps, raw transactions, nonce reservations, receipts, bundler EOAs, and daemon metadata. |
| `rust-core/crates/signature/` | Reusable WebAuthn/P-256 and EntryPoint v0.7 UserOperation hashing crate. |
| `rust-core/crates/kernel/` | Reusable Kernel account initialization and CREATE2 prediction helpers. |
| `rust-core/crates/ffi/` | Internal C ABI bridge used by Swift. |
| `swift-bridge/` | Swift package wrapping the internal Rust FFI bridge. |
| `wallet-macos/` | Signed macOS demo app and daemon spawn helper. |
| `website/` | Vite site for the demo/download page and developer docs. |
| `scripts/` | Build, packaging, fork-test, and signing-spike helper scripts. |
| `tools/keychain-spike/` | Focused macOS Keychain entitlement spike. |

## Current Scope

The daemon path is currently scoped to:

- Ethereum mainnet
- EntryPoint v0.7 at `0x0000000071727De22E5E9d8BAf0edAc6f37da032`
- the app's fixed Kernel factory, implementation, and WebAuthn validator addresses
- no paymaster support
- no user-facing EntryPoint deposit management or reclaim UX
- ETH transfer execution as the fork-tested transaction shape
- a development Keychain fallback for the bundler EOA secret on macOS

Future chains, EntryPoint versions, Kernel module permutations, live signed-manifest promotion, recovery flows, ERC20/batch/delegate/executor paths, and production Keychain access-group validation are tracked separately in `docs/wallet-node-open-items.md`.

## Fresh Clone Setup

Install the usual platform tools first:

- Rust toolchain matching `rust-core/Cargo.toml`
- Xcode and command-line tools for Swift/macOS work
- `cbindgen` for generating the Swift bridge header
- Foundry (`anvil`, `cast`) for mainnet-fork checks
- Node.js/npm for the website

Build and test the Rust workspace:

```bash
cd rust-core
cargo test --workspace
```

Build the Swift FFI bridge artifacts:

```bash
./scripts/build-ffi.sh
```

Then test Swift consumers:

```bash
cd swift-bridge
swift test

cd ../wallet-macos
swift test
```

Build the daemon:

```bash
cd rust-core
cargo build -p wallet-node --release --locked
```

## Daemon Quick Start

The daemon can run in loopback HTTP mode for manual development:

```bash
cd rust-core
cargo run -p wallet-node -- --http 127.0.0.1:0 --print-ready --debug
```

It prints a ready JSON object containing the bound address, API version, and bearer token. Requests must use:

```text
Authorization: Bearer <token>
```

The macOS app integration path uses the Unix-socket mode through `wallet-macos/Sources/Spawn`:

```text
wallet-node --ready-fd 3 --alive-fd 4
```

See `rust-core/crates/wallet-node/README.md` for daemon configuration, supported methods, lifecycle, and operational notes.

## Mainnet Fork Check

The deterministic Kernel/EntryPoint fork fixture lives in `rust-core/crates/wallet-node/tests/mainnet_fork_kernel.rs`.

Run it with an archive-capable Ethereum mainnet RPC:

```bash
ETH_RPC_URL=https://your-mainnet-rpc.example \
WALLET_FORK_BLOCK_NUMBER=25001071 \
scripts/run-kernel-mainnet-fork-check.sh
```

The script also reads `.env` by default. Use `.env.example` as a template. Do not commit live RPC secrets.

The fixture validates pinned Kernel bytecode, deployed proxy behavior, EntryPointSimulations state override, deterministic WebAuthn signing, a real ETH-transfer `handleOps`, and a 50-send bundler EOA flatness run.

## Generated Artifacts

`swift-bridge` depends on generated files from `scripts/build-ffi.sh`:

- `swift-bridge/Sources/WalletFFI/wallet_ffi.h`
- `swift-bridge/Sources/WalletFFI/wallet_node_api_version.h`
- `swift-bridge/lib/libwallet_ffi.a`

The generated C header and static library are build artifacts. Regenerate them after Rust FFI or API-version changes.

## macOS Demo

Open `LocalWallet.xcodeproj` in Xcode and run the `LocalWalletApp` scheme. The demo app currently exercises Secure Enclave key creation, Keychain-backed metadata, Kernel address prediction, Sepolia account inspection, local UserOperation building, and hosted Sepolia bundler submission when configured.

See `wallet-macos/README.md` for signing and packaging details.

## Website

```bash
cd website
npm install
npm run dev
```

See `website/README.md` for release-page details.

## Documentation Index

- `rust-core/README.md` - Rust workspace overview
- `rust-core/crates/wallet-node/README.md` - daemon implementation and operation
- `rust-core/crates/wallet-bundler/README.md` - bundler library
- `rust-core/crates/wallet-chain/README.md` - Helios chain adapter
- `rust-core/crates/wallet-node-api/README.md` - JSON-RPC API crate
- `rust-core/crates/wallet-node-store/README.md` - SQLite store
- `rust-core/crates/signature/README.md` - WebAuthn/P-256 helpers
- `rust-core/crates/kernel/README.md` - Kernel account helpers
- `rust-core/crates/ffi/README.md` - internal C ABI
- `swift-bridge/README.md` - Swift wrapper
- `wallet-macos/README.md` - macOS demo app
- `wallet-macos/Sources/Spawn/README.md` - daemon spawn shim
- `scripts/README.md` - local helper scripts
- `tools/keychain-spike/README.md` - Keychain entitlement spike

## Licensing

Unless noted otherwise, the Rust tooling in this repo is dual-licensed under:

- Apache-2.0
- MIT
