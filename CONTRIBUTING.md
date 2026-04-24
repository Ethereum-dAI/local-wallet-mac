# Contributing

Local Wallet is currently in early-stage development. The repository is being opened so developers can inspect the architecture, follow progress, and experiment with the Rust and Swift building blocks.

Broad external contributions are not fully open yet. APIs, crate boundaries, app UX, and release workflows are still changing quickly, so large unsolicited PRs may be hard to review or merge right now.

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
