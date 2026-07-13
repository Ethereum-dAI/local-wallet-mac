# Local Wallet Protocol — Rust SDK

> **Status:** Stable library surface of the Local Wallet project. Pre-1.0; published as open source under MIT/Apache-2.0. Semver is honoured from the first tagged release — breaking changes ship as major versions.

This repository contains the reusable, pure Rust protocol crates extracted from the [Local Wallet](https://github.com/Ethereum-dAI/local-wallet-mac) project. These crates are intentionally narrow in scope: synchronous, dependency-light, no networking, no FFI, and no key storage — they never generate, persist, or read key material (no Secure Enclave, no Keychain, no files). The one exception is signing: `sign_session_userop_hash` accepts a caller-provided secp256k1 secret to sign a session-key UserOp in-process, and the caller owns that secret's lifetime (it is not zeroized). They are designed to be consumed by wallets, scripts, and infrastructure code that needs ERC-4337 + Kernel + WebAuthn primitives without pulling in the full daemon stack.

---

## Crates

### `wallet-signature`

Cryptographic foundation for WebAuthn/P-256 signing flows used with ERC-4337 smart accounts.

Given a `PackedUserOperation` and a P-256 signature from a Secure Enclave (or any P-256 signer), this crate produces the exact byte sequence that the [Kernel WebAuthn validator](https://github.com/zerodevapp/kernel-7579-plugins/tree/master/validators/webauthn) expects on-chain.

Pipeline: `PackedUserOperation` -> `compute_userop_hash` (EntryPoint v0.7 scheme, not EIP-712) -> `compute_signing_message` (final 32-byte sha256 digest) -> `[Secure Enclave signs]` -> `normalise_low_s` (mandatory — validator rejects high-s) -> `build_signature` -> `abi_encode_webauthn_signature`.

Key exports: `compute_userop_hash`, `compute_signing_message`, `build_signature`, `normalise_low_s`, `der_to_raw`, `abi_encode_webauthn_signature`, `abi_encode_dummy_signature`.

**Session-key / permission signing:** `sign_session_userop_hash` produces an Ethereum personal-sign (secp256k1) signature for session-key UserOps. `wrap_installed_signature` and `wrap_enable_signature` build the outer wrappers the Kernel permission validator expects. Dummy variants are provided for gas estimation.

See [`crates/signature/README.md`](crates/signature/README.md) for full API documentation.

### `wallet-kernel`

Kernel-specific helpers for WebAuthn-root smart accounts.

Handles the deterministic Kernel account pieces useful to wallets, scripts, and infrastructure:

- `ValidationId` construction for a WebAuthn root validator
- ABI encoding for `WebAuthnValidatorData`
- `Kernel.initialize(...)` calldata generation
- CREATE2 salt derivation for the Kernel factory flow
- Solady ERC-1967 clone init-code hashing
- Counterfactual Kernel account address prediction
- Kernel v3 nonce decoding via `KernelNonce::decode`

**Modular-permission / session-key encoding** (Kernel v3.3):

- Policy construction helpers: `gas_policy`, `rate_limit_policy`, `timestamp_policy`, `call_policy`, `sudo_policy`
- `permission_id` — deterministic 4-byte permission identifier from policies + signer
- `encode_enable_data` — ABI-encoded payload for on-chain permission installation
- `enable_digest` — EIP-712 typed-data hash the root key signs to authorise a new permission
- `encode_permission_nonce_key` — EntryPoint nonce with the permission key in the upper bits
- `invalidate_nonce_calldata` / `uninstall_permission_calldata` — revocation calldata

This crate is generic over the factory/implementation/validator addresses — you can pass your own. The shared/pinned Kernel addresses (factory, implementation, WebAuthn validator) and the verifier/module addresses live in the `wallet-addresses` crate in this repo. The authoritative app-*enforced* allowlist (policy) lives in the daemon repo.

See [`crates/kernel/README.md`](crates/kernel/README.md) for full API documentation.

### `wallet-addresses`

Shared pinned Ethereum addresses and bytecode hashes used across the protocol crates. Includes Kernel factory/implementation addresses, the WebAuthn validator, the Daimo P-256 verifier, and ZeroDev modular-permission module addresses (ECDSA signer, gas/rate-limit/timestamp/sudo/call policies). A thin constants crate with no logic.

---

## Quick Install

Add to your `Cargo.toml` using a git dependency pinned to a specific revision:

```toml
[dependencies]
wallet-signature = { git = "https://github.com/Ethereum-dAI/local-wallet-protocol.git", rev = "<rev>" }
wallet-kernel    = { git = "https://github.com/Ethereum-dAI/local-wallet-protocol.git", rev = "<rev>" }
```

Replace `<rev>` with the commit SHA or tag you want to pin. Once crates are published to crates.io, a version-based dependency will also be available.

---

## Reference Consumer

[`local-wallet-daemon`](https://github.com/Ethereum-dAI/local-wallet-daemon) is the reference implementation that consumes these crates. It adds Helios-verified chain reads, ERC-4337 policy enforcement, EntryPoint simulation, `handleOps` submission, receipt reconciliation, and a JSON-RPC server — everything that requires networking, persistence, and runtime secrets.

---

## Tooling

### `tooling/golden-vectors`

A TypeScript script that drives the ZeroDev SDK to emit golden test vectors (JSON fixtures) for the permission/session-key encoding. The Rust test suites in `wallet-kernel` and `wallet-signature` assert byte-for-byte parity against these fixtures.

```bash
cd tooling/golden-vectors
npm install
npm run emit   # writes out/permission.json
```

---

## Building and Testing

```bash
cargo test --workspace        # run all tests
cargo clippy --workspace      # lint
cargo build --workspace       # build all crates
```

Focused:

```bash
cargo test -p wallet-signature
cargo test -p wallet-kernel
cargo clippy -p wallet-signature -- -D warnings
```

---

## Open-Source Boundary

These crates are the **reusable, public SDK surface** of Local Wallet. They have no app-specific pins, no daemon types, and no runtime concerns. The split is intentional:

- **This repo (protocol):** `wallet-signature`, `wallet-kernel`, `wallet-addresses`. Pure, synchronous, no FFI, no networking, no stored or persisted secrets (a session-key secret may be passed in for in-process signing). Generic over Kernel addresses.
- **Daemon repo** (`local-wallet-daemon`): `wallet-node`, `wallet-bundler`, `wallet-chain`, `wallet-node-api`, `wallet-node-store`. App-specific pins, Helios, SQLite, Tokio, transports.
- **Mac repo** (`local-wallet-mac`): `wallet-ffi` (C ABI bridge), `swift-bridge` Swift package, macOS app, build/packaging scripts.

---

## License

Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE) at your option.