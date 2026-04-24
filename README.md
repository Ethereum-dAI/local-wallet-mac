# Local Wallet

Native macOS demo wallet plus reusable signing/tooling for Kernel smart accounts and WebAuthn P-256 flows.

This repository is not the final product wallet yet. It currently contains:

- a signed macOS demo app that exercises the intended key-management and account-abstraction flow end to end
- reusable Rust and Swift layers that are intended to outlive the demo app and become open-source developer tooling

## Repo Layers

- `wallet-macos/`
  - Real signed macOS app target used as a demo/reference consumer
  - Secure Enclave + Keychain persistence
  - Local wallet metadata
  - Demo UI for account inspection, funding, local UserOperation building, signing, and Sepolia submission
- `swift-bridge/`
  - Narrow Swift package that wraps the Rust FFI layer
  - Candidate Apple SDK surface once the API stabilizes
- `rust-core/crates/signature`
  - Reusable Rust protocol/signature crate
  - Intended public surface for WebAuthn/P-256 signing primitives
- `rust-core/crates/kernel`
  - Reusable Rust crate for Kernel-specific account initialization and address prediction
  - Intended public surface for Kernel helper logic
- `rust-core/crates/ffi`
  - Internal C ABI bridge used by the Swift package and app
  - Not intended as the primary public SDK yet
- `website/`
  - Minimal Vite website package for the demo project page and download link
  - Placeholder UI until the final project page is designed

## Repo Overview

The repository is organized as a layered stack:

1. `wallet-macos`
   - Signed macOS demo/reference app
   - Owns Secure Enclave access, Keychain persistence, local metadata, UI, RPC orchestration, and hosted bundler submission
   - Proves the end-to-end flow on Apple platforms

2. `swift-bridge`
   - Apple-facing Swift wrapper over the internal C ABI
   - Gives Swift code a cleaner API for hashing, signing-preimage construction, signature encoding, and Kernel prediction helpers

3. `rust-core/crates/ffi`
   - Internal C ABI bridge between Swift and Rust
   - Exists to support the Apple bridge layer
   - Stays internal because its pointer/buffer ABI is tuned for this repo's Swift consumer, not for a stable public multi-language SDK

4. `rust-core/crates/signature`
   - Reusable Rust crate for deterministic signature/protocol primitives
   - Owns UserOperation hashing, WebAuthn message construction, P-256 DER parsing, low-s normalization, and validator signature encoding

5. `rust-core/crates/kernel`
   - Reusable Rust crate for Kernel-specific account helpers
   - Owns ValidationId construction, `Kernel.initialize(...)` calldata, CREATE2 salt derivation, and counterfactual address prediction

6. `website`
   - Vite site for the public demo/download page
   - Lives in this repo for now so the website copy and downloadable demo can evolve together

The intended public developer surfaces are:

- Rust developers: `wallet-signature` and `wallet-kernel`
- Apple developers: `swift-bridge`
- Internal plumbing only: `wallet-ffi`

## Open-Source Plan

This repo serves two products in parallel:

1. `wallet-macos` as the demo/reference app for the wallet architecture
2. reusable developer tooling from `rust-core`

The current release posture is:

- `wallet-signature` is the first publishable Rust crate
- `wallet-kernel` is the second publishable Rust crate
- `wallet-ffi` remains internal for now
- `WalletBridge` stays available as the app-facing Swift wrapper, but is not yet treated as a stable SDK contract

## OSS Release Hygiene

For the open-source repo, the intended source-of-truth split is:

- commit source code, tests, public markdown, and release metadata
- ignore local editor state, OS noise, and build outputs
- do not commit generated Rust build outputs or prebuilt bridge binaries
- do not commit internal planning docs under `docs/` or `ARCHITECTURE.md`

The repo now follows a generated-bridge policy:

- `swift-bridge/Package.swift` expects a generated C header plus a static library from `scripts/build-ffi.sh`
- those artifacts are intentionally ignored:
  - `swift-bridge/Sources/WalletFFI/wallet_ffi.h`
  - `swift-bridge/lib/libwallet_ffi.a`

That means fresh clones should run:

```bash
./scripts/build-ffi.sh
```

before building Swift consumers such as `swift-bridge` tests or the macOS demo app.

For local-only files and build products, see [`.gitignore`](.gitignore).

## Setup

Typical contributor bootstrap:

```bash
./scripts/build-ffi.sh
cd rust-core && cargo test
cd ../swift-bridge && swift test
```

Website bootstrap:

```bash
cd website
npm install
npm run dev
```

## Current SDK Boundary

Reusable/public:

- UserOperation hashing
- WebAuthn signing-preimage construction
- P-256 low-s normalization
- ABI encoding for Kernel WebAuthn validator signatures
- Kernel validator-data encoding and `initialize(...)` calldata
- Kernel CREATE2 salt derivation and counterfactual address prediction

App-specific/internal:

- Secure Enclave key lifecycle
- Keychain access policy
- biometrics and user presence UX
- wallet metadata persistence
- macOS UI and onboarding

## Developer Entry Points

Choose the layer based on what you are building:

- Rust service, CLI, wallet backend, or test harness:
  - use `wallet-signature` and `wallet-kernel` directly
- Swift/macOS consumer:
  - use `swift-bridge`
- C ABI / other languages:
  - technically possible through `wallet-ffi`, but not yet the intended stable public SDK

## Demo Scope

`wallet-macos` currently demonstrates:

- Secure Enclave P-256 key creation, loading, and signing
- Keychain-backed persistence of the wallet root key
- precomputed Kernel smart-account address derivation
- public-RPC inspection of deployment state and balance
- local ERC-4337 UserOperation draft construction
- hosted bundler gas estimation and submission on Ethereum Sepolia
- in-app debug logging for bootstrap, inspection, signing, and submission

It does not yet represent the final wallet product surface. Missing product layers still include:

- broader onboarding and account lifecycle UX
- richer transaction types and batching
- production network/bundler/paymaster strategy
- Helios/local infra integration
- the eventual final UI/architecture decisions for the wallet app

## Licensing

Unless noted otherwise, the Rust tooling in this repo is dual-licensed under:

- Apache-2.0
- MIT
