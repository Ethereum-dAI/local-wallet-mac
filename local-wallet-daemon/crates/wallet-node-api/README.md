# wallet-node-api

> **Status:** Open source under MIT/Apache-2.0. App-coupled, pre-1.0. This crate centralizes the public wire surface for the daemon. Stability policy and the explicit list of stable methods/error codes/wire shapes are defined in the "Public Surface And Stability" section below (added in Phase 2 of the open-source-readiness work).

`wallet-node-api` contains the shared JSON-RPC API definitions for `wallet-node` and its Swift/FFI consumers.

It is intentionally small and dependency-light. It centralizes the method names, error-code namespace, request body parsing limits, JSON-RPC structs, and API version value.

## Contents

| Module | Purpose |
|---|---|
| `method` | Supported JSON-RPC method names and wire-name round trips. |
| `errors` | JSON-RPC error codes and response helpers. |
| `rpc` | Request/response structs. |
| `body` | Request body parser with configurable maximum size. |
| `version` | API and spawn-protocol version constants. |

## Supported Methods

Wallet methods:

- `wallet_health`
- `wallet_apiVersion`
- `wallet_networkStatus`
- `wallet_bundlerStatus`
- `wallet_walletStatus`
- `wallet_pendingOperations`
- `wallet_auditStore`
- `wallet_auditHistory`
- `wallet_auditReport`
- `wallet_repairStore`
- `wallet_cancelPendingOperation`
- `wallet_speedUpPendingOperation`
- `wallet_beginAdminAction`
- `wallet_rotateBundlerEOA`
- `wallet_installBundlerEOA`
- `wallet_deleteBundlerEOA`
- `localwallet_resolveName`
- `localwallet_quoteSwap`
- `wallet_shutdown`

`wallet_bundlerStatus` includes the active relayer address, lifecycle, balance,
rotation state, recent relayer-key audit events, and non-secret `keyHistory`
entries for current/retired/deleted relayer metadata. Private key material is
never returned by status or any daemon RPC; human export is handled app-side
from the app-owned Keychain entry.

`localwallet_resolveName` resolves ENS names to EVM addresses on the active
chain and supports CCIP Read gateway continuations. `localwallet_quoteSwap`
quotes exact-input Uniswap v3 swaps on supported chains using on-chain
factory/pool/quoter calls; it does not submit transactions or use aggregator
APIs.

Helper method parameter shapes:

- `localwallet_resolveName`: one object param `{ "name": "vitalik.eth", "sendChainId": 1 }`. `sendChainId` is optional, but if present must match the active daemon chain.
- `localwallet_quoteSwap`: one object param with `tokenIn`, `tokenOut`, and `amountIn` required. Optional fields are `sendChainId`, `owner`, `tokenInIsNative`, `slippageBps`, and `intermediates`. Token addresses are `0x` EVM addresses, `amountIn` is a raw-unit hex quantity, and `intermediates` is a client-supplied list of one-hop candidate token addresses.

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

- `localwallet_supportedEntryPoints`
- `localwallet_estimateUserOperationGas`
- `localwallet_sendUserOperation`
- `localwallet_getUserOperationReceipt`
- `localwallet_getUserOperationStatus`
- `localwallet_getUserOperationGasPrice`

### Deprecated Aliases

The following legacy bundler-shaped method names remain accepted on the wire for
one release. New clients should use the `localwallet_*` names above.

| Deprecated alias | Replacement |
|---|---|
| `eth_supportedEntryPoints` | `localwallet_supportedEntryPoints` |
| `eth_estimateUserOperationGas` | `localwallet_estimateUserOperationGas` |
| `eth_sendUserOperation` | `localwallet_sendUserOperation` |
| `eth_getUserOperationReceipt` | `localwallet_getUserOperationReceipt` |
| `pimlico_getUserOperationGasPrice` | `localwallet_getUserOperationGasPrice` |

## Public Surface And Stability

The following surface is considered public and follows semver within this crate's major version:

- All methods listed above (method names and request/response shapes)
- Error codes listed in `errors.rs` and re-published in this README's "Error Codes" section
- The `ReadyEvent` JSON shape (see `wallet-node/src/ready.rs`)
- The `wallet_apiVersion` handshake response shape (added in Phase 3)

The following are NOT public and may move between any two releases without notice:

- Internal Rust types in this crate (handler signatures, request body internals)
- The set of supported chains
- The set of admin actions accepted by `wallet_beginAdminAction`
- The set of repair actions accepted by `wallet_repairStore`
- The exact wording of error `message` fields (use `code` to switch on)
- Anything not explicitly listed in this section.

### Versioning

- `API_VERSION` (in `version.rs`; exported to C as the `WALLET_NODE_API_VERSION` macro in the generated header) is incremented on every breaking change to the public surface.
- `SUPPORTED_MINIMUM_API_VERSION` (in `version.rs`) is the lowest API version a current daemon will accept from a client. Clients with `apiVersion < supportedMinimum` are rejected with `APIVERSION_MISMATCH`.
- `DAEMON_SPAWN_PROTOCOL` (in `version.rs`) versions the parent/child spawn contract (CLI args, inherited fds, the ready handshake) between the app and the daemon process it launches, independent of the wire `API_VERSION`.
- New public methods, new public error codes, and new optional fields in responses are NOT breaking — they bump nothing.
- Removing a public method, renaming a public method, removing or renumbering a public error code, or changing the type of an existing response field IS breaking — it bumps `API_VERSION` and may bump `SUPPORTED_MINIMUM_API_VERSION` after a deprecation window.

Pre-1.0 caveat: while `API_VERSION < 1000` (current value: 1), breaking changes are tolerated within this crate's `0.x` major. After the crate hits `1.0.0`, the rules above are strict.

## Error Codes

Standard JSON-RPC range:

- `-32700` PARSE_ERROR
- `-32600` INVALID_REQUEST
- `-32601` METHOD_NOT_FOUND
- `-32603` INTERNAL_ERROR

Wallet-node range (`-32001` through `-32099`):

- `-32001` UNAUTHORIZED — bearer token missing or invalid
- `-32002` NOT_READY — daemon not ready (chain not synced, etc.)
- `-32003` ENTRYPOINT_NOT_ALLOWLISTED — UserOp targets an EntryPoint the daemon does not support
- `-32004` CHAIN_MISMATCH — UserOp's `chainId` differs from the daemon's configured chain
- `-32005` RATE_LIMITED — method bucket exceeded
- `-32006` POLICY_CAP_EXCEEDED — gas/fee field exceeds configured cap; `data.field` names the offending field
- `-32007` SIMULATION_FAILED — `simulateValidation` reverted; `data.reason` carries the decoded reason
- `-32008` DUMMY_SIGNATURE_UNSUPPORTED
- `-32009` INSUFFICIENT_SMART_ACCOUNT_BALANCE
- `-32010` HELIOS_STALE
- `-32011` REPLACEMENT_NOT_POSSIBLE — `data.reason` carries the reason
- `-32012` BODY_TOO_LARGE — `data.actual` and `data.max` are bytes
- `-32013` APIVERSION_MISMATCH — `data.current` and `data.supportedMinimum` from the daemon
- `-32014` WITHDRAW_AMOUNT_EXCEEDS_RECLAIMABLE
- `-32015` HELIOS_STATE_OVERRIDE_UNSUPPORTED
- `-32016` ACCOUNT_CODE_NOT_ALLOWLISTED — `data.codeHash` carries the offending account's code hash
- `-32099` SERVICE_UNAVAILABLE

Codes not listed here are internal and may change. The full structured `data` shapes for each public code land in Phase 3.

## Generated Version Header

The crate has a build script that emits:

```text
wallet_node_api_version.h
```

In the app repo (local-wallet-mac), `scripts/build-ffi.sh` copies that header into `swift-bridge/Sources/WalletFFI/` so Swift code can check compatibility with the daemon (https://github.com/Ethereum-dAI/local-wallet-mac). Neither of those paths exists in this (daemon) repo.

## Tests

```bash
cargo test -p wallet-node-api
```
