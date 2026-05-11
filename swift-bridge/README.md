# swift-bridge

Swift wrapper over the internal `wallet-ffi` C ABI.

This package is the Apple-facing layer for:

- UserOperation hashing
- WebAuthn signing-preimage construction
- P-256 low-s normalization
- Kernel/WebAuthn signature encoding
- dummy Kernel/WebAuthn signature encoding for gas estimation
- Kernel account initialization helpers and address prediction

## Important Setup

This package depends on generated bridge artifacts and does not commit them to git.

Before building or testing the package from a fresh clone, run:

```bash
./scripts/build-ffi.sh
```

That script generates:

- `Sources/WalletFFI/wallet_ffi.h`
- `Sources/WalletFFI/wallet_node_api_version.h`
- `lib/libwallet_ffi.a`

After that, you can run:

```bash
swift test
```

## Boundary

`swift-bridge` is the intended Apple-platform entry point.

It is built on top of:

- `rust-core/crates/ffi` (local — internal C ABI bridge)
- `wallet-signature` and `wallet-kernel` — protocol SDK crates that resolve via git dependency from [`local-wallet-protocol`](https://github.com/Ethereum-dAI/local-wallet-protocol)
- `wallet-node-api` — version header only; resolves via git dependency from [`local-wallet-daemon`](https://github.com/Ethereum-dAI/local-wallet-daemon)

It does not launch or manage the daemon directly. Daemon process spawning lives in `wallet-macos/Sources/Spawn` and `wallet-macos/Sources/SpawnHelper`.

## Local Development

For monorepo-style local development, copy `rust-core/.cargo/config.toml.example` to `rust-core/.cargo/config.toml` and ensure `local-wallet-protocol` and `local-wallet-daemon` are checked out as siblings of this repo. The example config file contains `[patch.crates-io]` overrides that redirect the git dependencies to your local checkouts.

## Call Flow

Address prediction and UserOperation signing across the FFI boundary, including buffer ownership:

```mermaid
sequenceDiagram
    autonumber
    participant App as Swift app
    participant Bridge as WalletFFI (Swift)
    participant Hdr as wallet_ffi.h (C ABI)
    participant FFI as wallet-ffi (Rust)
    participant Sig as wallet-signature
    participant Krn as wallet-kernel

    App->>Bridge: predictAccountAddress(owner, salt)
    Bridge->>Hdr: wallet_kernel_predict_address(...)
    Hdr->>FFI: extern "C" entry
    FFI->>Krn: derive CREATE2 salt + init-code hash
    Krn-->>FFI: predicted address
    FFI-->>Hdr: WalletBuffer { ptr, len }
    Hdr-->>Bridge: WalletBuffer
    Bridge->>Bridge: copy bytes into Swift Data
    Bridge->>Hdr: wallet_buffer_free(buf)
    Hdr->>FFI: drop owned bytes
    Bridge-->>App: Address

    App->>Bridge: signUserOperation(packedOp, p256Key)
    Bridge->>Hdr: wallet_signature_userop_preimage(...)
    Hdr->>FFI: extern "C"
    FFI->>Sig: build EntryPoint v0.7 hash + WebAuthn message
    Sig-->>FFI: 69-byte preimage
    FFI-->>Bridge: WalletBuffer (preimage)
    Bridge->>Bridge: SecureEnclave sign over preimage, low-s normalize
    Bridge->>Hdr: wallet_signature_kernel_webauthn_encode(...)
    Hdr->>FFI: extern "C"
    FFI->>Sig: encode 6-field Kernel WebAuthn signature
    Sig-->>FFI: encoded signature
    FFI-->>Bridge: WalletBuffer (signature)
    Bridge->>Hdr: wallet_buffer_free(buf)
    Bridge-->>App: signed UserOperation
```
