# Changelog

All notable changes to this crate are documented here.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial public CHANGELOG.
- Modular-permission / session-key encoding (Kernel v3.3): policy builders
  (`gas_policy`, `rate_limit_policy`, `timestamp_policy`, `call_policy`,
  `sudo_policy`), `permission_id`, `encode_enable_data`, `enable_digest`
  (EIP-712), `encode_permission_nonce_key`, revocation calldata
  (`invalidate_nonce_calldata`, `uninstall_permission_calldata`), and the
  Kernel v3.3 install builders `install_validations_calldata` and
  `grant_access_calldata`.

## [0.1.0]

Initial release.
