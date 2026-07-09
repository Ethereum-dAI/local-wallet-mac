# Contributing

`local-wallet-daemon` is open source under MIT/Apache-2.0. External contributions are welcome.

This workspace is the app-coupled daemon stack. It is pre-1.0; the public JSON-RPC surface is documented in `crates/wallet-node-api/README.md`. APIs outside that documented surface may move between releases.

The reusable protocol crates (`wallet-signature`, `wallet-kernel`, `wallet-addresses`) live in [`local-wallet-protocol`](https://github.com/Ethereum-dAI/local-wallet-protocol) and follow their own semver. Contributions to the protocol surface belong there.

For non-trivial changes — new JSON-RPC methods, breaking behavior, anything touching policy/allowlist or signing surface — please open an issue first to align on direction. Crate boundaries and release workflows are still settling, so large unsolicited PRs that don't match an existing direction may be hard to merge.

## What Is Useful Today

- bug reports with clear reproduction steps
- documentation fixes
- small test improvements
- issues describing integration needs for the daemon JSON-RPC surface
- focused questions about the current protocol/daemon split

## Before Opening A PR

For anything larger than a typo or small test/doc fix, please open an issue first. Explain the problem, the proposed direction, and whether the change affects the daemon binary, an internal crate, or the wire API types.

## Local Checks

Run the relevant checks before submitting changes:

```bash
cargo test --workspace
cargo clippy --workspace -- -D warnings
cargo fmt --check
```

For the mainnet fork fixture (requires an archive-capable RPC):

```bash
ETH_RPC_URL=https://your-mainnet-rpc.example \
WALLET_FORK_BLOCK_NUMBER=25001071 \
./scripts/run-kernel-mainnet-fork-check.sh
```

The fork fixture exercises the full send path — pinned Kernel bytecode, EntryPointSimulations state override, deterministic WebAuthn signing, and a 50-send bundler flatness run. If your change touches policy, allowlist, simulation, or signing, run the fork fixture before submitting.
