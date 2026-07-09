# wallet-chain

> **Status:** Open source under MIT/Apache-2.0. App-coupled, pre-1.0. The public JSON-RPC surface and stability policy for the daemon stack are documented in `crates/wallet-node-api/README.md`. Internal types in this crate may move between releases.

`wallet-chain` is the daemon's chain-access abstraction.

It provides a trait used by `wallet-node`, a Helios-backed implementation for verified Ethereum reads, an execution-RPC-backed implementation for unverified direct reads (when Helios verification is toggled off), and a mock implementation for deterministic daemon tests.

## What It Provides

- `ChainAdapter` trait for daemon handlers.
- `HeliosChainAdapter` for real chain reads.
- `ExecutionRpcChainAdapter` for unverified reads served directly from the execution RPC, used when Helios read verification is toggled off (`ReadVerificationMode::ExecutionRpc`). It bypasses Helios verification entirely: reads are trust-the-RPC, not light-client-verified.
- `MockChainAdapter` for tests.
- shared chain/RPC wire types.
- `ChainConfig` for chain id, execution RPC, consensus RPC, data directory, and a max-Helios-lag threshold (`max_helios_lag_blocks`).
- `run_smoke_test` (`src/smoke.rs`) — stateOverride smoke that replaces WETH code at a fixed mainnet address and confirms storage behavior, used by the daemon to fail closed on simulation-dependent sends if state-override semantics cannot be trusted.
- `ChainError` and preservation of raw `eth_call` revert bytes when available.
- **Checkpoint auto-refresh** — at startup, `HeliosChainAdapter` fetches the current finalized checkpoint from the configured beacon (consensus) RPC. If the fetch fails, it falls back to the bundled/cached checkpoint freshness logic. This keeps the light client bootstrappable on any supported network (including Sepolia, which ships no bundled checkpoint) and avoids resuming from a stale root the beacon node may have already pruned.

The public types re-exported from `lib.rs` are: `ChainAdapter`, `HeliosChainAdapter`, `ExecutionRpcChainAdapter`, `MockChainAdapter`, `ChainConfig`, `ChainError`, `BlockTag`, `CallRequest`, `run_smoke_test`.

## Current Scope

The production paths are Ethereum mainnet and Sepolia. The daemon can use `[chain]` config overrides for Helios internals, but the accepted UserOperation/account policy remains mainnet, Sepolia, and EntryPoint v0.7 scoped.

Helios is pinned by the workspace to:

```text
204c998a927348e1c000a664f08d5b37b1b0d924
```

Do not routine-bump Helios. Future changes should be deliberate and must rerun the real stateOverride smoke plus the mainnet-fork Kernel fixture.

## Tests

Default tests:

```bash
cargo test -p wallet-chain
```

Ignored real-network smoke:

```bash
cargo test -p wallet-chain -- --include-ignored
```

The real smoke depends on public Ethereum execution/consensus RPC availability and can fail for provider rate limits or stale checkpoint data.

## Relationship To wallet-node

`wallet-chain` does not expose JSON-RPC itself. `wallet-node` calls it to serve verified read methods and EntryPoint simulation calls.

If the fresh checkpoint fetch fails AND the bundled Helios checkpoint is too old AND no on-disk Helios database exists locally, `wallet-node` falls back to an offline chain adapter so authenticated control APIs (status, lifecycle, audit/repair) remain available while verified reads and simulation-dependent sends fail closed.