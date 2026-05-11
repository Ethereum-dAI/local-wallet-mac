# rust-core

`rust-core` is the Rust workspace for the macOS app's FFI layer.

After the repository split, this workspace contains a single crate:

| Crate | Purpose |
|---|---|
| `wallet-ffi` | C ABI bridge consumed by `swift-bridge` and the macOS app. |

The other crates that were previously here have moved to sibling repositories:

- **`local-wallet-protocol`** — `wallet-signature`, `wallet-kernel`, `wallet-addresses`. Stable, semver-managed libraries. No networking, no secrets, no FFI.
- **`local-wallet-daemon`** — `wallet-node`, `wallet-bundler`, `wallet-chain`, `wallet-node-api`, `wallet-node-store`. App-coupled daemon stack, pre-1.0.

`wallet-ffi` depends on `wallet-signature` and `wallet-kernel` via git deps (with optional path overrides for local development). See `Cargo.toml` for the pinned revisions.

## Build And Test

Run the full default test suite (currently only `wallet-ffi`):

```bash
cargo test --workspace
```

Or focused:

```bash
cargo test -p wallet-ffi
```

Build the static library for Swift consumption:

```bash
./scripts/build-ffi.sh
```

That script builds `wallet-ffi` for `aarch64-apple-darwin`, runs `cbindgen`, and stages the header and `.a` under `swift-bridge/`. The generated artifacts are not committed.

## Mainnet-Fork Fixture

The mainnet-fork Kernel fixture (`tests/mainnet_fork_kernel.rs`) now lives in `local-wallet-daemon`. Run it from that repo:

```bash
# From this repo's rust-core/, the sibling daemon checkout is two levels up.
ETH_RPC_URL=https://your-mainnet-rpc.example \
WALLET_FORK_BLOCK_NUMBER=25001071 \
../../local-wallet-daemon/scripts/run-kernel-mainnet-fork-check.sh
```

## Integration With Sibling Repos

```
local-wallet-protocol          local-wallet-daemon
  wallet-signature  ──────────►  wallet-bundler
  wallet-kernel     ──────────►  wallet-node
                                 wallet-node-api
                    ──────────►  wallet-ffi (this repo)
                                     │
                                     ▼ C ABI
                                 swift-bridge
                                     │
                                     ▼
                                 macOS app
```

Path overrides in `rust-core/.cargo/config.toml` (not committed) let you point `wallet-ffi`'s git deps at local checkouts of `local-wallet-protocol` during development.

## Boundaries

`wallet-ffi` is open source under MIT/Apache-2.0, app-coupled, and pre-1.0. Its C ABI is internal to the Swift bridge and may move between releases. Private-key material never crosses the FFI — Rust only sees public coordinates, hashes, and signatures.
