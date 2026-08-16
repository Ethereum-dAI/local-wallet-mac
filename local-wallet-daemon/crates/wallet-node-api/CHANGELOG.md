# Changelog

All notable changes to this crate are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `localwallet_resolveName` for ENS resolution, including CCIP Read support.
- `localwallet_quoteSwap` for exact-input Uniswap v3 swap quotes using on-chain factory/pool/quoter calls.
- `localwallet_getUserOperationStatus` so the macOS app can reconcile locally failed, dropped, or still-pending UserOperations even when no receipt exists yet.
- `wallet_speedUpPendingOperation` to bump the gas of a pending UserOperation's relayer transaction using live gas.
- Daemon-side `[network] read_verification` config (`"helios"` default, or `"execution_rpc"` to serve reads without light-client verification). This is a daemon configuration option and does not change the wire API surface defined by this crate.

### Changed

- `localwallet_sendUserOperation` now rejects sends before persistence when the active bundler EOA cannot cover the estimated `handleOps` gas budget.
- `localwallet_sendUserOperation` now requires a third `{chainId, keyRef, address}` parameter binding the request to the exact active relayer. Missing, malformed, stale, or non-canonical bindings fail before nonce reservation, signing, and persistence. The deprecated `eth_sendUserOperation` daemon alias inherits this hardened contract.
- Relayer submission persistence is now atomic across the UserOperation, submitted transaction, and nonce state. Startup recovers only provably unbroadcast pre-bundle reservations, including the legacy crash window where a UserOperation existed without any transaction evidence.

## [0.1.0] - 2026-05-11

### Added

- Initial public CHANGELOG.
- Public Surface And Stability section in README documenting the stable JSON-RPC method list, error codes, and versioning policy.

### Changed

- Renamed bundler-shaped JSON-RPC methods from the `eth_*` and `pimlico_*`
  namespaces to the `localwallet_*` namespace. Old names accepted as aliases
  for one release; they will be removed in the next breaking release that
  bumps `API_VERSION` to 2.

### Deprecated

- `eth_sendUserOperation` is deprecated; use `localwallet_sendUserOperation`.
- `eth_estimateUserOperationGas` is deprecated; use `localwallet_estimateUserOperationGas`.
- `eth_getUserOperationReceipt` is deprecated; use `localwallet_getUserOperationReceipt`.
- `eth_supportedEntryPoints` is deprecated; use `localwallet_supportedEntryPoints`.
- `pimlico_getUserOperationGasPrice` is deprecated; use `localwallet_getUserOperationGasPrice`.
