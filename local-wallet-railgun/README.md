# local-wallet-railgun

RAILGUN **shield + unshield** for Local Wallet, with a **broadcaster the wallet runs
itself, locally** — a Rust sidecar wrapping Kohaku's `crates/railgun`, targeting Sepolia.

> Part of the `local-wallet-mac` monorepo (mirrors `local-wallet-daemon/` and
> `local-wallet-protocol/`). Alpha, unaudited, **testnet only — no mainnet funds.**

## What's here

Two runnable processes (one crate, `lib` + two bins):

- **`railgun-helper`** — the sidecar. Serves `balance` / `prepareShield` /
  `prepareUnshield` over a bearer-authenticated Unix-socket JSON-RPC API. Wraps the
  RAILGUN Rust SDK: derives the shielded account from entropy, syncs (Subsquid + RPC),
  builds shield txs, and **proves** unshield txs (Groth16).
- **`railgun-broadcaster`** — the **local broadcaster**. Owns its **own EOA** and submits
  the proved unshield tx on-chain (`relay` / `address`). No Waku, no third-party/shared
  broadcaster. Every wallet runs its own.

### The local-broadcaster model (and its tradeoff)

RAILGUN's classic privacy relies on a *shared* broadcaster network (Waku) so the tx
submitter is an unrelated third party. This wallet deliberately does the opposite: it runs
its **own** broadcaster and never delegates — self-sufficiency over maximal anonymity,
mirroring how the daemon already self-relays ERC-4337 UserOps through its on-device bundler
EOA. The cost, stated plainly: a per-wallet broadcaster is an **anonymity-set-of-one** (its
EOA submits only your unshields and is funded by you, so it is linkable to you). The one
property kept: the broadcaster EOA is **separate** from your Kernel/main account and from
the RAILGUN account, so the unshield is not submitted by the shielding account itself.
Three distinct keys: RAILGUN account (spend+view) · shield submitter (owner) · broadcaster.

## Design & plan

- Spec: [`docs/design/2026-07-13-railgun-shield-unshield-v2-design.md`](docs/design/2026-07-13-railgun-shield-unshield-v2-design.md)
- Plan: [`docs/superpowers/plans/2026-07-13-railgun-shield-unshield-v2.md`](docs/superpowers/plans/2026-07-13-railgun-shield-unshield-v2.md)
- v1 (shield-only) predecessor: [`docs/design/2026-07-02-railgun-helper-v1.md`](docs/design/2026-07-02-railgun-helper-v1.md)

## Build & test

```bash
cargo build                 # both bins (syncs to head; no fork cap)
cargo test --lib            # 15 unit tests (secret parse, key derivation, RPC auth/round-trip)
cargo clippy --lib --bins
```

## End-to-end (the acceptance check)

Shields native ETH then unshields it on an **anvil fork of Sepolia**, with the unshield
relayed by the local broadcaster, asserting both txs confirm on-chain (recipient receives
WETH; the unshield's signer is the broadcaster EOA). Needs `foundry` (anvil) and outbound
network (RAILGUN Subsquid indexer + a one-time Groth16 circuit-artifact download).

```bash
RPC_URL_SEPOLIA="https://sepolia.infura.io/v3/<key>" ./scripts/e2e-fork.sh
```

Runs in ~60–70s (most of it Groth16 proving). Live-Sepolia is possible by pointing the
bins at a real RPC with a funded broadcaster EOA, but the fork is the default check.

## Key facts / caveats

- **POI is OFF on the fork** (`.with_poi()` not called). POI validity comes from the live
  `ppoi.fdi.network` aggregator, which validates against real chain state — a note freshly
  shielded on a local fork can never become POI-`Valid`. Without POI a note is spendable
  right after sync (see the crate's own `transact_utxo.rs`). POI-on is a live-Sepolia
  concern, out of scope here.
- **`fork-sync` feature** caps Subsquid sync at the fork block (Subsquid indexes *live*
  Sepolia); required for the e2e, off for live deployments.
- **Unshield delivers WETH** (the wrapped base token) to the recipient, minus a 0.25%
  unshield fee — not native ETH (native would need a RelayAdapt unwrap step).
- Kohaku `railgun` dep is pinned to rev `877026e…`; the `js` feature is never enabled.
- Config is via env for now (`RAILGUN_RPC_URL`, `RAILGUN_ENTROPY_HEX`, `RAILGUN_SOCKET`,
  `RAILGUN_TOKEN`, `RAILGUN_BROADCASTER_KEY`, …); the fd-5 app-spawn contract + async
  proving job model are the next step.

## License

MIT OR Apache-2.0.
