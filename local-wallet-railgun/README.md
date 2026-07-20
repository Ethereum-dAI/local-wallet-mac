# local-wallet-railgun

RAILGUN **shield + unshield** for Local Wallet, with a **broadcaster the wallet runs
itself, locally** — a Rust sidecar wrapping Kohaku's `crates/railgun`, targeting Sepolia.

> Part of the `local-wallet-mac` monorepo (mirrors `local-wallet-daemon/` and
> `local-wallet-protocol/`). Alpha, unaudited, **testnet only — no mainnet funds.**

## What's here

Two runnable processes (one crate, `lib` + two bins). In normal operation you launch
**only the helper** — it spawns and owns the broadcaster as a child:

- **`railgun-helper`** — the sidecar. Serves `balance` / `prepareShield` / `unshield` /
  `unshieldStatus` / `broadcasterStatus` over a bearer-authenticated Unix-socket JSON-RPC
  API. Wraps the RAILGUN Rust SDK: derives the shielded account from entropy, syncs
  (Subsquid + RPC), builds shield txs, and **proves** unshield txs (Groth16). It also
  **spawns and owns** the `railgun-broadcaster` child (secret delivered over fd 5), so the
  app talks to a single socket; an orphan backstop (`getppid()==1`) + `ChildGuard` clean it
  up.
- **`railgun-broadcaster`** — the **local broadcaster**. Owns its **own EOA** and submits
  the proved unshield tx on-chain (`relay` / `relayUnshieldNative` / `address`). No Waku, no
  third-party/shared broadcaster. Every wallet runs its own.

### Unshield is asynchronous

Groth16 proving is slow, so unshield is a background job, not a blocking call:

- `unshield {amountWei, to}` → returns `{jobId}` **immediately**; proving + the broadcaster
  relay run in the background (the RAILGUN provider is `!Send`, so proving runs on a
  current-thread + `LocalSet` runtime).
- `unshieldStatus {jobId}` → `{status: pending | done | error, result? | error?}`.

### fd-5 spawn contract

Secrets (RAILGUN entropy; broadcaster EOA key) travel on **fd 5**, never argv/env —
matching how the app spawns `wallet-node`. `spawn.rs` handles delivery (pipe + `dup2`, with
an explicit `CLOEXEC` clear so fd 5 survives even when the pipe read end already *is* fd 5)
and raw-libc `read_fd5`. Env vars remain a standalone/dev fallback.

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

## From the macOS app

`/shield 0.01` and `/unshield 0.01 to 0x…` are available as slash commands (with
autocomplete) and as LLM-callable tools in the chat layer via `WalletToolLayer`;
`key=value` forms are also parsed. Shield builds a Kernel `execute` UserOp signed with the
Secure Enclave passkey (`prepareShield` → `executeBatch`); unshield requires device-owner
authentication, then calls the sidecar's async `unshield` and polls `unshieldStatus`,
relayed by the local broadcaster, showing a submitted→confirmed card while it refreshes the
shielded balance until it settles. `RailgunHelperClient` is the typed Unix-socket JSON-RPC
client (mirrors the `wallet-node` transport).

The app **spawns and owns the sidecar itself** — `RailgunHelperDaemon` mirrors
`WalletNodeDaemon`'s fd-3 ready / fd-4 alive / fd-5 secret contract (readiness detected by
polling the socket, since the helper doesn't emit an fd-3 token) and points it at the app's
active-chain RPC. Setting `LOCAL_WALLET_PRIVACY_SOCKET` / `LOCAL_WALLET_PRIVACY_TOKEN`
instead attaches to a manually-run sidecar (e.g. an anvil fork). The one piece still
pending is **ENS/contact resolution for unshield recipients** — they must currently be `0x`
addresses (the `unshield` tool schema tells the LLM to ask for a `0x` address if given an
ENS/contact name).

## Build & test

```bash
cargo build                 # both bins (syncs to head; no fork cap)
cargo test --lib            # unit tests (secret/fd-5 parse, key derivation, RPC
                            # auth/round-trip, async job state, native-relay helpers)
cargo clippy --lib --bins
```

## End-to-end (the acceptance check)

Shields native ETH then runs the **async** unshield on an **anvil fork of Sepolia**, with
the unshield relayed by the local broadcaster. It spawns **only the helper** via fd-5 (the
helper brings up the broadcaster), and asserts the recipient's **native-ETH** delta
(the sent amount minus RAILGUN's unshield fee), with the forward tx submitted by the
broadcaster EOA. Needs `foundry`
(anvil) and outbound network (RAILGUN Subsquid indexer + a one-time Groth16
circuit-artifact download). It has a hard overall wall-clock cap + per-operation timeouts so
it can never hang, and strips the broadcaster's EIP-7702 delegation on the fork
(`anvil_setCode`) so unshield-to-broadcaster works.

```bash
RPC_URL_SEPOLIA="https://sepolia.infura.io/v3/<key>" ./scripts/e2e-fork.sh
```

Runs in ~60–70s (most of it Groth16 proving). Live-Sepolia is possible by pointing the
bins at a real RPC with a funded broadcaster EOA, but the fork is the default check.

## Key facts / caveats

- **Unshield delivers native ETH.** The Kohaku crate's unshield only delivers the wrapped
  base token (WETH), so the broadcaster unshields WETH to *itself*, `WETH.withdraw()`s
  (unwrap), and forwards **native ETH** to the recipient (`relayUnshieldNative`) — minus
  RAILGUN's unshield fee.
- **POI is OFF on the fork** (`.with_poi()` not called). POI validity comes from the live
  `ppoi.fdi.network` aggregator, which validates against real chain state — a note freshly
  shielded on a local fork can never become POI-`Valid`. Without POI a note is spendable
  right after sync (see the crate's own `transact_utxo.rs`). POI-on is a live-Sepolia
  concern, out of scope here.
- **`fork-sync` feature** caps Subsquid sync at the fork block (Subsquid indexes *live*
  Sepolia); required for the e2e, off for live deployments.
- Kohaku `railgun` dep is pinned to rev `877026e…`; the `js` feature is never enabled.
- **Config:** secrets arrive over the fd-5 spawn contract (see above); the remaining knobs
  are env for now (`RAILGUN_RPC_URL`, `RAILGUN_SOCKET`, `RAILGUN_TOKEN`,
  `RAILGUN_BROADCASTER_BIN` / `_SOCKET` / `_TOKEN`, …). The env-provided secret
  (`RAILGUN_ENTROPY_HEX`) remains a standalone/dev fallback; the broadcaster key is
  derived from it (m/44'/60'/0'/0/0), so `RAILGUN_BROADCASTER_KEY` is no longer read
  by the helper.

## License

MIT OR Apache-2.0.
