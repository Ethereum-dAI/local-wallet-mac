# Changelog

All notable changes to this crate are documented here.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

## [0.1.0]

Initial release.
