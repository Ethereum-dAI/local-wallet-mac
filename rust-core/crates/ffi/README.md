# wallet-ffi

> **Status:** Open source under MIT/Apache-2.0. App-coupled, pre-1.0. The public JSON-RPC surface and stability policy for the daemon stack are documented in the [`local-wallet-daemon` wallet-node-api README](https://github.com/Ethereum-dAI/local-wallet-daemon/blob/main/crates/wallet-node-api/README.md). This crate's C ABI is internal to the Swift bridge and may move between releases.

`wallet-ffi` is the C ABI bridge between Rust and the Swift package in `swift-bridge`.

It is not the intended stable public SDK. The public-facing Apple API is the Swift wrapper, and the stable Rust APIs are `wallet-signature` and `wallet-kernel` (both in `local-wallet-protocol`).

## Privacy Boundary

Private-key material never crosses the FFI. Rust only sees public coordinates, hashes, and signatures. Secure Enclave and Keychain access remain entirely on the Swift side.

## Exports

The C ABI currently exposes helpers for:

- EntryPoint v0.7 UserOperation hash computation
- WebAuthn signing preimage construction
- P-256 low-s normalization
- Kernel WebAuthn signature ABI encoding
- dummy WebAuthn signature ABI encoding for gas estimation
- Kernel account address prediction
- Kernel `initialize(...)` calldata encoding
- Kernel session-permission construction
- Kernel session signature wrapping and session dummy signatures
- Kernel session nonce invalidation, empty permission deinit data, and permission uninstall calldata
- freeing buffers allocated by Rust

The ABI uses integer result codes:

| Code | Meaning |
|---|---|
| `0` | success |
| `-1` | invalid input |
| `-2` | internal error |

## Generated Header

The header is generated with `cbindgen`:

```bash
./scripts/build-ffi.sh
```

That script writes:

```text
swift-bridge/Sources/WalletFFI/wallet_ffi.h
swift-bridge/lib/libwallet_ffi.a
```

## Memory Rules

Functions that return variable-length data allocate a Rust buffer and return `(ptr, len)`. The caller must call:

```c
wallet_free_buffer(ptr, len)
```

exactly once for each returned buffer.

The buffer-returning functions are:

- `wallet_abi_encode_signature` — Kernel/WebAuthn signature ABI bytes
- `wallet_abi_encode_dummy_signature` — gas-estimation dummy signature ABI bytes
- `wallet_encode_kernel_initialize_call` — Kernel `initialize(...)` calldata
- `wallet_session_build_permission` — Kernel session permission enable and selector data
- `wallet_session_sign_and_wrap` — Kernel session signature bytes for installed or enable mode
- `wallet_session_dummy_signature` — gas-estimation dummy session signature bytes
- `wallet_session_invalidate_nonce_calldata` — Kernel `invalidateNonce(...)` calldata
- `wallet_session_empty_permission_deinit_data` — deinit data for empty session permissions
- `wallet_session_uninstall_permission_calldata` — Kernel permission uninstall calldata

Fixed-size pointer arguments use these buffer sizes:

| Argument | Size (bytes) |
|---|---|
| sender / address output | 20 |
| user-op nonce (BE) | 32 |
| user-op hash output | 32 |
| signing preimage output | 69 |
| P-256 `r` / `s` scalar | 32 |
| session secret / user-op hash | 32 |
| permission id | 4 |
| nonce key output | 32 |

See `src/lib.rs` for the canonical per-function size contracts.

## Tests

```bash
cd rust-core
cargo test -p wallet-ffi
```

For Swift consumers, regenerate the bridge artifacts and run:

```bash
./scripts/build-ffi.sh
cd swift-bridge
swift test
```
