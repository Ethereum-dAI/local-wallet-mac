# rust-core

`rust-core` is the Rust workspace for the macOS app's FFI layer.

After the repository split, this workspace contains a single crate:

| Crate | Purpose |
|---|---|
| `wallet-ffi` | C ABI bridge consumed by `swift-bridge` and the macOS app. |

The other crates that were previously here have moved to sibling repositories:

- **`local-wallet-protocol`** — `wallet-signature`, `wallet-kernel`, `wallet-addresses`. Stable, semver-managed libraries. No networking, no secrets, no FFI.
- **`local-wallet-daemon`** — `wallet-node`, `wallet-bundler`, `wallet-chain`, `wallet-node-api`, `wallet-node-store`. App-coupled daemon stack, pre-1.0.

`wallet-ffi` depends on `wallet-signature` and `wallet-kernel` from `local-wallet-protocol`, plus `wallet-node-api` from `local-wallet-daemon` (a build-materialization dep that `build-ffi.sh` uses to emit its cbindgen version header), all via git deps (with optional path overrides for local development). See `Cargo.toml` for the pinned revisions. Besides passkey UserOperation helpers, it exposes the Kernel session-permission helpers consumed by the macOS app for session-key enable, signing, estimation, and revoke flows.

## Build And Test

Run the full default test suite (currently only `wallet-ffi`):

```bash
cargo test --workspace
```

Or focused:

```bash
cargo test -p wallet-ffi
```

Build the static library for Swift consumption (the script lives at the repo root, one level above `rust-core/`):

```bash
../scripts/build-ffi.sh
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

Path overrides in `rust-core/.cargo/config.toml` (not committed; copy the committed `.cargo/config.toml.example` template) let you point `wallet-ffi`'s git deps at local checkouts of `local-wallet-protocol` and `local-wallet-daemon` during development.

## Boundaries

`wallet-ffi` is open source under MIT/Apache-2.0, app-coupled, and pre-1.0. Its C ABI is internal to the Swift bridge and may move between releases. The root credential is a non-extractable Secure Enclave P-256 key that never crosses the FFI — Swift signs inside the enclave and passes only the `(r, s)` signature across the boundary. Software signing keys do cross the FFI, however: the bundler secret (`wallet_generate_bundler_secret` / `wallet_bundler_address_from_secret`) and the session-key secret (consumed by `wallet_session_sign_and_wrap`) are ordinary 32-byte secp256k1 values handled by Rust.
