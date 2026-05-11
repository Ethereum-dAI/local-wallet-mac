# wallet-kernel

> **Status:** Open source under MIT/Apache-2.0. Stable public API; breaking changes ship as a major version per semver.

Kernel-specific helpers for WebAuthn-root smart accounts.

This crate is intentionally narrower than a wallet SDK and more specific than
`wallet-signature`. It handles the deterministic Kernel account pieces that are
useful to wallets, scripts, and infrastructure code:

- `ValidationId` construction for a WebAuthn root validator
- ABI encoding for `WebAuthnValidatorData`
- `Kernel.initialize(...)` calldata generation
- CREATE2 salt derivation for the Kernel factory flow
- Solady ERC-1967 clone init-code hashing
- counterfactual Kernel account address prediction
- Kernel v3 nonce decoding via `KernelNonce::decode` (validation mode, validation type, validation id, parallel key, sequence)

It does **not** handle:

- Secure Enclave / Keychain access
- WebAuthn signing-message construction
- P-256 signature parsing or low-s normalization
- bundler or RPC transport
- deployed Kernel module enumeration
- live allowlist manifest promotion

Those runtime checks live in the daemon stack, primarily `wallet-bundler` and `wallet-node`.

The pinned Kernel factory, implementation, and WebAuthn validator addresses used by the daemon's app-shaped path live in [`wallet-bundler/src/allowlist.rs`](../wallet-bundler/src/allowlist.rs), not here. This crate is generic over those addresses.

## Example

```rust
use alloy_primitives::{address, B256, U256};
use wallet_kernel::predict_kernel_account_address;

let predicted = predict_kernel_account_address(
    address!("2577507b78c2008Ff367261CB6285d44ba5eF2E9"),
    address!("d6CEDDe84be40893d153Be9d467CD6aD37875b28"),
    address!("7ab16Ff354AcB328452F1D445b3Ddee9a91e9e69"),
    U256::from(1u64),
    U256::from(2u64),
    B256::ZERO,
    B256::ZERO,
);

assert_eq!(predicted, address!("ea18d505d23f0b73a91409cd468aecf3beab03ba"));
```

## Testing

```bash
cd rust-core
cargo test -p wallet-kernel
```

The app-pinned deployed Kernel path is also covered by the mainnet-fork fixture:

```bash
ETH_RPC_URL=https://your-mainnet-rpc.example \
WALLET_FORK_BLOCK_NUMBER=25001071 \
scripts/run-kernel-mainnet-fork-check.sh
```
