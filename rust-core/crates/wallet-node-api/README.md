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
