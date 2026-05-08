# wallet-node

`wallet-node` is the Local Wallet daemon. It exposes a small authenticated JSON-RPC surface for wallet health, verified Ethereum reads, ERC-4337 UserOperation estimation/submission, bundler EOA management, pending-operation inspection, cancellation, and shutdown.

The daemon is designed to run locally beside the macOS app. The app owns the durable bundler EOA secret in its Keychain; the daemon only holds app-provided relayer secrets in process RAM while it handles Helios verified reads, policy checks, SQLite persistence, raw `handleOps` submission, and receipt watching.

## Current Scope

Supported now:

- Ethereum mainnet and Ethereum Sepolia by explicit mode
- EntryPoint v0.7
- app-pinned Kernel factory, implementation, and WebAuthn validator addresses
- chain-scoped account-code allowlist for the current Kernel path
- no paymasters
- local smart-account funding checks using account balance plus EntryPoint deposit
- ETH-transfer execution path in fork coverage
- app-owned Keychain storage for the bundler EOA secret on macOS, with daemon RAM-only signing after startup/install

Not supported in V1:

- user-configurable chains beyond mainnet/Sepolia, EntryPoints, Kernel modules, or account addresses
- paymaster UserOperations
- EntryPoint deposit management or reclaim UX
- recovery after Secure Enclave/WebAuthn key loss
- live signed-manifest promotion
- generic Kernel permission/hook/executor/fallback module enumeration

## Run Modes

Loopback HTTP for manual development:

```bash
cd rust-core
cargo run -p wallet-node -- --http 127.0.0.1:0 --print-ready --debug
```

The daemon prints a ready JSON object with:

- `apiVersion`
- `token`
- `httpAddr`

Use the token as a bearer token:

```bash
curl -s \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","id":1,"method":"wallet_health","params":[]}' \
  http://<httpAddr>
```

Unix-socket app integration:

```text
wallet-node --ready-fd 3 --alive-fd 4
```

The app launches this mode through `wallet-macos/Sources/Spawn`. The daemon writes its ready JSON to fd `3` and watches fd `4` for EOF so it exits when the parent app dies.

Other useful flags:

```text
--config <PATH>              Load TOML config from a custom path
--print-api-version          Print wallet-node-api version and exit
--debug                      Enable debug logging
--manifest-url <URL>         Debug-only manifest URL override; promotion is disabled in this build
```

`--print-ready` requires `--http`; the inverse is not enforced — `--http` runs without `--print-ready`.

## Admin Subcommand

The same daemon binary exposes an operator-facing CLI under the `admin` subcommand, which talks to a running daemon over the existing JSON-RPC surface (HTTP or Unix socket) using the bearer token:

```text
wallet-node admin --socket <PATH> --token <TOKEN> audit [--persist]
wallet-node admin --socket <PATH> --token <TOKEN> audit-history [--limit N]
wallet-node admin --socket <PATH> --token <TOKEN> audit-report --run-id <ID>
wallet-node admin --socket <PATH> --token <TOKEN> repair --action <ACTION> [...]
wallet-node admin --socket <PATH> --token <TOKEN> pending
```

Either `--http <URL>` or `--socket <PATH>` selects transport; `--token <STRING>` or `--token-file <PATH>` provides the bearer token; `--json` opts into machine-readable output. Repair actions and their gating to specific findings are documented under "Audit and Repair" below.

## Configuration

If no config file exists, defaults are used.

Minimal example:

```toml
[network]
chain_id = 1
execution_rpc = "https://ethereum-rpc.publicnode.com"
consensus_rpc = "https://lodestar-mainnet.chainsafe.io"

[bundler]
entry_points = ["0x0000000071727De22E5E9d8BAf0edAc6f37da032"]
submit_rpcs = ["https://ethereum-rpc.publicnode.com"]
use_precompiled = false
beneficiary = ""

[policy]
max_user_ops_per_bundle = 1
max_call_gas_limit = "0x989680"
max_verification_gas_limit = "0x4c4b40"
max_pre_verification_gas = "0x0f4240"
max_fee_per_gas = "0x2540be400"
max_priority_fee_per_gas = "0x3b9aca00"
min_replacement_bump_pct = 12.5
max_request_body_bytes = 262144
```

Notes:

- `bundler.beneficiary` must be empty or omitted. The beneficiary is implicit and must equal the active bundler EOA.
- `[chain]` can optionally override `[network]` for Helios internals during tests or compatibility work.
- fee caps are safety caps. Recheck them against live mainnet before release.
- default bundler EOA cushion/threshold values are development defaults. Recheck before release.
- `policy.max_request_body_bytes` (default `262144`) is enforced by the transport handler before JSON-RPC parsing; bodies above the cap are rejected with `PAYLOAD_TOO_LARGE`.
- `[rate_limits]` configures token-bucket rate limits per method bucket. Defaults: `eth_sendUserOperation` 3 burst @ 0.166/sec, `eth_estimateUserOperationGas` 10 burst @ 1/sec, `read_methods_total` 20 burst @ 1.66/sec. Methods without a bucket bypass the limiter.

## JSON-RPC Methods

Wallet methods:

- `wallet_health`
- `wallet_networkStatus`
- `wallet_bundlerStatus`
- `wallet_walletStatus`
- `wallet_pendingOperations`
- `wallet_auditStore`
- `wallet_auditHistory`
- `wallet_auditReport`
- `wallet_repairStore`
- `wallet_cancelPendingOperation`
- `wallet_beginAdminAction`
- `wallet_rotateBundlerEOA`
- `wallet_installBundlerEOA`
- `wallet_deleteBundlerEOA`
- `wallet_shutdown`

`wallet_bundlerStatus` reports the active relayer, balance/threshold, lifecycle,
rotation state, recent relayer-key audit events, and non-secret `keyHistory`
metadata for current and historical relayer keys. It does not expose private key
material.

`wallet_rotateBundlerEOA`, `wallet_installBundlerEOA`, and `wallet_deleteBundlerEOA` require an admin challenge issued by `wallet_beginAdminAction`. Challenges have a 60-second TTL, are single-use, and are bound to `(action, ownerScope, chainId, keyRef)`. The daemon does not itself prompt for user presence — the app is expected to gate the admin call behind a local user-presence check before forwarding the authorization.

Ethereum read methods:

- `eth_chainId`
- `eth_getBalance`
- `eth_getCode`
- `eth_getTransactionCount`
- `eth_call`
- `eth_getTransactionReceipt`
- `eth_getBlockByNumber`
- `eth_estimateGas`
- `eth_maxPriorityFeePerGas`
- `eth_gasPrice`

ERC-4337/bundler methods:

- `eth_supportedEntryPoints`
- `eth_estimateUserOperationGas`
- `eth_sendUserOperation`
- `eth_getUserOperationReceipt`
- `pimlico_getUserOperationGasPrice`

The wire method list lives in `wallet-node-api`.

## Internal Flow

`eth_sendUserOperation` roughly follows this path:

1. authenticate and parse JSON-RPC
2. validate EntryPoint, chain, no-paymaster policy, request size, rate limits, gas caps, and fixed Kernel allowlist
3. read same-block account balance and EntryPoint deposit
4. reject smart-account gas/value shortfalls before submission
5. run EntryPointSimulations when verified reads are available
6. ensure an active funded bundler EOA exists
7. sign an EIP-1559 `handleOps([op], beneficiary)` raw transaction
8. persist the UserOp, nonce reservation, and submitted tx
9. submit the raw transaction
10. watcher reconciles receipts, retries persisted submissions, and records UserOperationEvent outcomes

```mermaid
sequenceDiagram
    autonumber
    participant Client
    participant Node as wallet-node
    participant Bundler as wallet-bundler
    participant Chain as wallet-chain (Helios)
    participant Store as wallet-node-store
    participant EOA as Bundler EOA signer
    participant RPC as Submit RPC
    participant Watcher as Receipt watcher

    Client->>Node: eth_sendUserOperation (Bearer token)
    Node->>Node: authenticate, parse JSON-RPC
    Node->>Bundler: validate EntryPoint, policy, gas caps, Kernel allowlist
    Bundler-->>Node: ok / reject
    Node->>Chain: same-block balance + EntryPoint deposit
    Chain-->>Node: balances
    Node->>Bundler: funding check (shortfall?)
    Bundler-->>Node: ok / reject
    Node->>Chain: EntryPointSimulations.simulateValidation
    Chain-->>Node: ValidationResult / revert
    Node->>Store: ensure active funded bundler EOA
    Store-->>Node: EOA record
    Node->>Bundler: encode handleOps([op], beneficiary)
    Bundler-->>Node: EIP-1559 tx + signing payload
    Node->>EOA: sign raw tx
    EOA-->>Node: signed raw tx
    Node->>Store: persist UserOp, nonce reservation, raw tx
    Node->>RPC: eth_sendRawTransaction
    RPC-->>Node: tx hash
    Node-->>Client: userOpHash
    Watcher->>RPC: poll receipt
    RPC-->>Watcher: receipt
    Watcher->>Bundler: decode UserOperationEvent
    Watcher->>Store: record outcome, retry or finalize
```

## Persistence

The daemon uses `wallet-node-store` with SQLite. It persists:

- bundler EOA records and lifecycle state
- UserOperations
- raw submitted transactions
- nonce reservations
- verified UserOperation receipts
- daemon metadata, including compromise-detection markers

## Tests

Default daemon tests:

```bash
cd rust-core
cargo test -p wallet-node
```

Host/socket ignored tests:

```bash
cargo test -p wallet-node -- --include-ignored
```

Mainnet fork fixture from repository root:

```bash
ETH_RPC_URL=https://your-mainnet-rpc.example \
WALLET_FORK_BLOCK_NUMBER=25001071 \
scripts/run-kernel-mainnet-fork-check.sh
```

The fork fixture validates the app-pinned Kernel path, real EntryPointSimulations state override, deterministic WebAuthn signing, ETH-transfer `handleOps`, and 50-send bundler flatness.

## Operational Notes

- Helios is pinned in the workspace and should not be routine-bumped.
- The daemon fails closed when stateOverride smoke fails for simulation-dependent sends. The smoke check is one-shot per process: it runs after the chain becomes synced and is not re-run periodically — appropriate for a session-scoped daemon.
- If Helios checkpoint data is stale, the daemon can start with an offline chain adapter for authenticated control APIs while verified reads are degraded.
- Production Keychain access-group entitlement and provisioning validation remain outside the development fallback until Apple Developer Program setup is available.
- Signed-manifest scaffolding exists in `wallet-bundler::manifest` (Ed25519 signature verification, 30-day max lifetime, denylist precedence) but no production trust roots are embedded; runtime promotion is disabled in non-debug builds, and the runtime allowlist consults only the static, chain-scoped pinned set.
