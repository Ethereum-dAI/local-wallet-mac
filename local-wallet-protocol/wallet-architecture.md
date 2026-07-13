# Local Wallet — System Architecture

The full **cross-system** architecture (privacy model, three-key/three-role design, Kernel ERC-4337 account model, and the session-key design) is maintained in a single canonical location to prevent it from drifting independently across the three repos:

- **Canonical design doc:** [`wallet-architecture.md` in `local-wallet-mac`](https://github.com/Ethereum-dAI/local-wallet-mac/blob/main/wallet-architecture.md) — or, in a sibling checkout, `../local-wallet-mac/wallet-architecture.md`.

For the **protocol SDK surface** (crates, encoding conventions, public APIs) provided by this repo, see [`README.md`](README.md) and the per-crate READMEs under `crates/`.
