# swift-bridge

Swift wrapper over the internal `wallet-ffi` C ABI.

This package is the Apple-facing layer for:

- UserOperation hashing
- WebAuthn signing-preimage construction
- P-256 low-s normalization
- Kernel/WebAuthn signature encoding
- Kernel account initialization helpers and address prediction

## Important Setup

This package depends on generated bridge artifacts and does not commit them to git.

Before building or testing the package from a fresh clone, run:

```bash
./scripts/build-ffi.sh
```

That script generates:

- `Sources/WalletFFI/wallet_ffi.h`
- `lib/libwallet_ffi.a`

After that, you can run:

```bash
swift test
```

## Boundary

`swift-bridge` is the intended Apple-platform entry point.

It is built on top of:

- `rust-core/crates/signature`
- `rust-core/crates/kernel`
- `rust-core/crates/ffi` (internal bridge only)
