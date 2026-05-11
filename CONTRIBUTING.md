# Contributing

Local Wallet is open source under MIT/Apache-2.0. External contributions are welcome.

The Rust workspace splits into two stability tiers:

- **Stable libraries** (`wallet-signature`, `wallet-kernel`) follow semver. Breaking changes ship as a major version.
- **App-coupled crates** (the daemon stack) are pre-1.0; the public JSON-RPC surface is documented in `rust-core/crates/wallet-node-api/README.md`. APIs outside that documented surface may move between releases.

For non-trivial changes — new methods, breaking behavior, anything touching the policy/allowlist or signing surface — please open an issue first to align on direction. Crate boundaries, app UX, and release workflows are still settling, so large unsolicited PRs that don't match an existing direction may be hard to merge.

## What Is Useful Today

- bug reports with clear reproduction steps
- documentation fixes
- small test improvements
- issues describing integration needs for the Rust crates or Swift bridge
- focused questions about the current SDK boundary

## Before Opening A PR

For anything larger than a typo or small test/doc fix, please open an issue first. Explain the problem, the proposed direction, and whether the change affects the demo app, Rust crates, Swift bridge, or website.

## Local Checks

Run the relevant checks before submitting changes:

```bash
./scripts/build-ffi.sh
cd rust-core && cargo test
cd ../swift-bridge && swift test
cd ../wallet-macos && swift build
cd ../website && npm install && npm run build
```

For release packaging:

```bash
LOCAL_WALLET_SEPOLIA_BUNDLER_URL="https://..." ./scripts/package-macos-demo.sh
```

The bundled app is a non-notarized demo build unless a release process explicitly says otherwise.
