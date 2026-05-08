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
| `version` | API version constant. |

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
- `wallet_beginAdminAction`
- `wallet_rotateBundlerEOA`
- `wallet_installBundlerEOA`
- `wallet_deleteBundlerEOA`
- `wallet_shutdown`

`wallet_bundlerStatus` includes the active relayer address, lifecycle, balance,
rotation state, recent relayer-key audit events, and non-secret `keyHistory`
entries for current/retired/deleted relayer metadata. Private key material is
never returned by status or any daemon RPC; human export is handled app-side
from the app-owned Keychain entry.

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

- `WALLET_NODE_API_VERSION` (in `version.rs`) is incremented on every breaking change to the public surface.
- `WALLET_NODE_API_SUPPORTED_MINIMUM_VERSION` (in `version.rs`) is the lowest API version a current daemon will accept from a client. Clients with `apiVersion < supportedMinimum` are rejected with `APIVERSION_MISMATCH`.
- New public methods, new public error codes, and new optional fields in responses are NOT breaking — they bump nothing.
- Removing a public method, renaming a public method, removing or renumbering a public error code, or changing the type of an existing response field IS breaking — it bumps `WALLET_NODE_API_VERSION` and may bump `WALLET_NODE_API_SUPPORTED_MINIMUM_VERSION` after a deprecation window.

Pre-1.0 caveat: while `WALLET_NODE_API_VERSION < 1000` (current value: 1), breaking changes are tolerated within this crate's `0.x` major. After the crate hits `1.0.0`, the rules above are strict.

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

`scripts/build-ffi.sh` copies that header into `swift-bridge/Sources/WalletFFI/` so Swift code can check compatibility with the daemon.

## Tests

```bash
cd rust-core
cargo test -p wallet-node-api
```
