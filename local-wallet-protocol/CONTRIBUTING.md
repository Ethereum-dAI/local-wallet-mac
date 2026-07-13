# Contributing

The Local Wallet Protocol crates are open source under MIT/Apache-2.0. External contributions are welcome.

All crates in this repository (`wallet-signature`, `wallet-kernel`, `wallet-addresses`) are pre-1.0 libraries; semver is honoured from the first tagged release, so breaking changes ship as a major version.

For non-trivial changes — new methods, breaking behavior, anything touching the signing surface or ABI encoding — please open an issue first to align on direction. Crate boundaries and release workflows are still settling, so large unsolicited PRs that don't match an existing direction may be hard to merge.

## What Is Useful Today

- bug reports with clear reproduction steps
- documentation fixes
- small test improvements
- issues describing integration needs for the protocol crates
- focused questions about the current API surface

## Before Opening A PR

For anything larger than a typo or small test/doc fix, please open an issue first. Explain the problem, the proposed direction, and which crate is affected.

## Local Checks

Run the following before submitting changes:

```bash
cargo fmt --check
cargo clippy --workspace -- -D warnings
cargo test --workspace
```

Changes to ABI or signature encoding require regenerating the golden vectors, otherwise the byte-for-byte parity tests will fail. Run `npm install && npm run emit` in [`tooling/golden-vectors`](tooling/golden-vectors/README.md), then copy `out/permission.json` into both `crates/kernel/testdata/permission/permission.json` and `crates/signature/testdata/permission/permission.json`.

## Licensing

By contributing, you agree that your contributions are dual-licensed under MIT and Apache-2.0, matching the rest of this repository.

Contributions must be your own original work or covered by a compatible open-source license. By submitting a pull request you affirm that you have the right to contribute the code under these terms (Developer Certificate of Origin).
