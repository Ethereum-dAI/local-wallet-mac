# Local Wallet Daemon

> **Status:** v0.1 alpha, app-coupled, and under active development. This is not a production wallet, is not independently audited, and should be treated as experimental software. Public API is stable across patch releases; minor releases may break public surface but document migrations in CHANGELOG.md.

`local-wallet-daemon` is the Rust daemon that powers the [Local Wallet](https://github.com/Ethereum-dAI/local-wallet-mac) macOS app. It is a self-contained ERC-4337 v0.7 + Kernel WebAuthn-root account reference implementation with narrow Kernel permission/session-key relay support, designed to run locally beside a trusted host application.

The v0.1 line is intended for early testers and development use. Do not present it as production-ready custody software.

The daemon handles Helios-verified Ethereum reads, ENS resolution, Uniswap v3 swap quotes, ERC-4337 policy enforcement, EntryPoint simulation, raw `handleOps` submission, receipt reconciliation, and bundler EOA lifecycle — all on-device, no hosted bundler required for the core path.

## Architecture

```
   macOS app  ──spawn──►  wallet-node (this daemon)
       │                    ▲
       │ Swift              │ JSON-RPC over Unix socket / loopback HTTP
       ▼                    │ (Bearer token from --print-ready / fd-3 ready)
   swift-bridge             │
       │                    │
       ▼                    ▼
   wallet-ffi (C ABI) ──►  wallet-bundler ──► wallet-signature (protocol)
                            wallet-chain (Helios)        wallet-kernel (protocol)
                            wallet-node-store (SQLite)   wallet-addresses (protocol)
                            wallet-node-api (wire types)
```

The protocol crates (`wallet-signature`, `wallet-kernel`, `wallet-addresses`) are published separately in [`local-wallet-protocol`](https://github.com/Ethereum-dAI/local-wallet-protocol) and consumed here via pinned git deps.

## Crates in This Workspace

| Crate | Role |
|---|---|
| `wallet-node` | Daemon binary: JSON-RPC handler, transport, watcher, lifecycle |
| `wallet-bundler` | Policy, allowlist, gas estimation, `handleOps` encoding |
| `wallet-chain` | Helios adapter, Ethereum read surface, stateOverride smoke |
| `wallet-node-api` | Wire types, method names, API version header |
| `wallet-node-store` | SQLite persistence: UserOps, nonces, EOA records, receipts |

## Documentation

- [`documentation/architecture.md`](documentation/architecture.md) — full design rationale, privacy/security boundary, threat model, and implementation decisions
- [`documentation/forking-for-your-wallet.md`](documentation/forking-for-your-wallet.md) — guide for adapting this daemon to a different smart-account stack
- [`documentation/whats-not-here.md`](documentation/whats-not-here.md) — intentional omissions and V1 scope limits
- [`crates/wallet-node/README.md`](crates/wallet-node/README.md) — full daemon threat model, run modes, JSON-RPC methods, configuration reference

## Threat Model Summary

The daemon runs locally beside a trusted host app. It assumes a single-user, single-machine environment where the OS process boundary is the security boundary. The bundler EOA private key is held only in process RAM after install — the durable copy lives in the macOS app's Keychain. Mutating admin RPCs require a single-use challenge bound to `(action, ownerScope, chainId, keyRef)`. Verified Ethereum reads via Helios constrain what a hostile execution RPC can lie about.

The daemon does not protect against a compromised host app, a compromised parent process, or a hostile execution+consensus RPC pair with a stale checkpoint. See [`crates/wallet-node/README.md`](crates/wallet-node/README.md) for the full threat model and [`documentation/architecture.md`](documentation/architecture.md) for design rationale.

## Public Surface and Stability

This repo is pre-1.0 and app-coupled. The public JSON-RPC surface is documented in `crates/wallet-node-api/README.md`:

- **Stable across patch releases:** wire method names, parameter shapes, error codes in `wallet-node-api`
- **May change on minor releases:** internal crate APIs, configuration keys, SQLite schema (with migration)
- **Internal only (no stability guarantee):** anything not in `wallet-node-api`

The protocol crates (`wallet-signature`, `wallet-kernel`, `wallet-addresses`) follow their own semver in the [`local-wallet-protocol`](https://github.com/Ethereum-dAI/local-wallet-protocol) repo.

## What You Need

To run the daemon you need:

- **macOS or Linux** with **Rust 1.91+**.
- An **execution RPC URL** for the target chain (mainnet or Sepolia). Used for Helios-verified reads, direct swap-quote `eth_call`s, and raw `handleOps` submission.
- A **consensus RPC URL** (beacon-chain endpoint). Helios verifies execution data against signed consensus state.
- Optional: a separate **submit RPC** if you want to decouple submission from reads.
- Optional: an **archive-capable RPC** for the mainnet-fork test fixture.
- A **bundler EOA secret** for any path that actually sends UserOperations. The daemon holds it in process RAM only — it is provided either by the parent app via `--secret-fd` at startup, or at runtime via `wallet_installBundlerEOA` (admin-challenge gated).

The bearer token used to authenticate JSON-RPC requests is **generated by the daemon at startup** and printed on the ready channel (`--print-ready` for HTTP, fd-3 for the spawn-with-fd contract). You do not provision or rotate it.

Public RPC endpoints work for development. For production, use endpoints with rate limits and SLAs that match your throughput.

## Quick Start

Build and run in HTTP development mode:

```bash
cargo build -p wallet-node --release
./target/release/wallet-node --http 127.0.0.1:0 --print-ready --debug
```

Override the defaults with a config file when you have your own RPC URLs:

```bash
./target/release/wallet-node --config wallet-node.toml --http 127.0.0.1:0 --print-ready --debug
```

Minimal `wallet-node.toml`:

```toml
[network]
chain_id = 1
execution_rpc = "https://your-execution-rpc.example"
consensus_rpc = "https://your-consensus-rpc.example"
read_verification = "helios"   # or "execution_rpc" to disable Helios verification of reads

[bundler]
entry_points = ["0x0000000071727De22E5E9d8BAf0edAc6f37da032"]
submit_rpcs = ["https://your-execution-rpc.example"]
```

With `read_verification = "helios"` (the default) the daemon runs a Helios light client and verifies execution-layer reads against signed beacon consensus state; switching to `"execution_rpc"` serves reads straight from the execution RPC with no light-client verification, which is faster but means you trust that RPC.

The daemon prints a ready JSON object with `apiVersion`, `token`, and `httpAddr`. Use the token as a bearer:

```bash
# 1. Auth + version smoke test
curl -s \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","id":1,"method":"wallet_apiVersion","params":[]}' \
  http://<httpAddr>

# 2. Network / chain sync state
curl -s \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","id":2,"method":"wallet_networkStatus","params":[]}' \
  http://<httpAddr>

# 3. Standard eth_ read methods are available too
curl -s \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","id":3,"method":"eth_chainId","params":[]}' \
  http://<httpAddr>
```

See [`crates/wallet-node/README.md`](crates/wallet-node/README.md) for the full JSON-RPC method list, RPC quickstart per category, common error codes, and configuration reference.

## Tests

```bash
cargo test --workspace                          # default suite
cargo test -p wallet-node -- --include-ignored  # host/socket integration tests
```

Mainnet fork fixture (requires archive-capable RPC):

```bash
ETH_RPC_URL=https://your-mainnet-rpc.example \
WALLET_FORK_BLOCK_NUMBER=25001071 \
./scripts/run-kernel-mainnet-fork-check.sh
```

The fork fixture validates the app-pinned Kernel path, EntryPointSimulations state override, deterministic WebAuthn signing, ETH-transfer `handleOps`, and a 50-send bundler flatness run.

## Local Development with Protocol Crates

Protocol crates are consumed via pinned git deps. To develop against a local sibling checkout:

```bash
cp .cargo/config.toml.example .cargo/config.toml
# Edit paths[] to point at your local-wallet-protocol checkout
```

`.cargo/config.toml` is gitignored so the path override stays local.

## Related Repositories

- [`local-wallet-protocol`](https://github.com/Ethereum-dAI/local-wallet-protocol) — reusable protocol SDK (`wallet-signature`, `wallet-kernel`, `wallet-addresses`)
- [`local-wallet-mac`](https://github.com/Ethereum-dAI/local-wallet-mac) — reference macOS app that spawns this daemon

## License

Licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT License ([LICENSE-MIT](LICENSE-MIT))

at your option.
