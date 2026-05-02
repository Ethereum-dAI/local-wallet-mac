# wallet-ffi

`wallet-ffi` is the internal C ABI bridge between Rust and the Swift package in `swift-bridge`.

It is not the intended stable public SDK. The public-facing Apple API is the Swift wrapper, and the reusable Rust APIs are `wallet-signature` and `wallet-kernel`.

## Exports

The C ABI currently exposes helpers for:

- EntryPoint v0.7 UserOperation hash computation
- WebAuthn signing preimage construction
- P-256 low-s normalization
- Kernel WebAuthn signature ABI encoding
- dummy WebAuthn signature ABI encoding for gas estimation
- Kernel account address prediction
- Kernel `initialize(...)` calldata encoding
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

All fixed-size pointer arguments must point to buffers of the documented sizes in `src/lib.rs`.

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
