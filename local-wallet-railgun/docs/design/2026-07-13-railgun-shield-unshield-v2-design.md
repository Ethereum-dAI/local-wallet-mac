# Railgun Helper v2 — Shield + Unshield + Local Broadcaster (Design Spec)

**Status:** Approved for implementation (Kohaku `crates/railgun` spike complete 2026-07-13; API sections finalized against rev `877026e`)
**Date:** 2026-07-13
**Session:** kohaku-v2
**Supersedes scope of:** `docs/design/2026-07-02-railgun-helper-v1.md` (v1 = shield + balance only)
**Location:** `local-wallet-mac/local-wallet-railgun/` (folded into the monorepo; the previously-separate sibling repo has been removed — its history remains on `origin/Ethereum-dAI/local-wallet-railgun`).

---

## 1. Goal & scope

Deliver a **Kohaku/RAILGUN shield + unshield** round-trip for Local Wallet on **Sepolia**
(chain id `11155111`), where the **unshield is relayed by a broadcaster the wallet runs
itself, locally** — not delegated to any third-party/Waku broadcaster. Verified by an
**e2e script** that shields ETH and then unshields it against an **anvil fork of Sepolia**,
asserting both transactions confirm on-chain (live-Sepolia mode optional).

This is **v2** of the `railgun-helper` Rust sidecar. v1 (docs-only) specified shield +
balance; v2 implements shield + balance **and adds unshield + the local broadcaster**.
Because v1 was never implemented, v2 builds the whole sidecar, front-loaded by a
feasibility spike of Kohaku's `crates/railgun`.

### In scope (v2)

- Read the account's RAILGUN shielded balance (split by POI status: valid / pending).
- Build a **shield** (deposit) tx for native ETH — self-submitted by the owner's account.
- Build an **unshield** (withdraw) op for native ETH to a recipient — including the
  Groth16 proof generation the spend requires.
- A **local broadcaster**: a per-wallet process holding its **own relayer EOA** that
  submits the unshield transaction on-chain. No Waku, no P2P, no third-party broadcaster.
- An **e2e** that runs shield → unshield end-to-end on an anvil Sepolia fork and confirms
  both txs.

### Out of scope (v2)

- Shielded→shielded **transfer** (private transfer within the pool) — a later version.
- **Waku broadcaster network** integration (the classic RAILGUN anonymity set) — see §6.
- Full **macOS app spawn** wiring (fd contract into `SpawnHelper`, bundling the binary in
  the .app). The sidecar is exercised by the e2e harness + a manual gate, mirroring v1's
  deferral of app-spawn. The RPC + fd contract are built to be app-spawnable later.
- **Mainnet.** Testnet only; unaudited alpha (`crates/railgun` 0.1.0).

---

## 2. What "run a broadcaster locally" means here (decided)

**Decision (locked round 1):** the broadcaster is a **local relayer service that owns its
own EOA** and submits the unshield tx on-chain. `relayerUrl`/relay path points at
`localhost`. No Waku/P2P.

### 2.1 Why this shape

RAILGUN unshield/transfer return (or can be turned into) a transaction that **any EOA can
submit**; the submitter is linked to the recipient. The classic privacy answer is a
**shared broadcaster network (Waku)** so the submitter is an unrelated third party. The
user's directive is the opposite trust model, and a deliberate one: **self-sufficiency
over maximal anonymity.** Every wallet runs its own broadcaster and never depends on
external broadcaster infrastructure — mirroring how the daemon already **self-relays the
user's ERC-4337 UserOps through its own on-device bundler EOA** rather than a shared
bundler.

### 2.2 The accepted tradeoff (stated plainly)

A per-wallet broadcaster yields an **anonymity set of one**: the broadcaster EOA submits
only this user's unshields, is funded by this user, and is therefore linkable to them.
This is **not** the RAILGUN privacy guarantee — it is a **functional / self-custody
milestone** (the wallet can unshield without any external relayer) with the privacy upgrade
(Waku, or a genuinely shared bundler) deferred. The recipient-linkage cost is identical to
"self-submit," made explicit rather than hidden. The one privacy property still retained:
the broadcaster EOA is **separate from the user's Kernel/main account**, so on-chain the
unshield is not submitted by the shielding account itself.

### 2.3 Broadcaster ≠ the daemon bundler, ≠ the shielding account

Three distinct EOAs/keys, kept separate:
- **Passkey / Kernel account** — shields (public deposit), owns shielded funds.
- **Daemon bundler EOA** — self-relays 4337 UserOps (EntryPoint v0.7 / Kernel). Not reused
  here (RAILGUN's 4337 path, if used, targets a different EntryPoint).
- **Local broadcaster EOA** — new; submits unshield txs. Funded with a little Sepolia ETH
  for gas; in the e2e, an anvil pre-funded account.

### 2.4 Relay mechanics (finalized — spike-confirmed)

**Chosen: plain-tx self-submit.** `RailgunProvider::build(txBuilder) → ProvedTx { tx_data,
proved_operations }` yields a proved, plain `tx_data = {to,data,value}` that **any EOA can
submit**. The local broadcaster signs+sends that tx with **its own EOA**. No bundler, no
paymaster, no Waku. This is exactly what the crate's own `transact_utxo.rs` integration
test does. (The heavier `prepare_userop` + `PimlicoBundler` + Privacy-Paymaster 4337 path
exists but is not used in v2 — it buys sponsorship we don't need and adds a bundler
dependency.)

Concretely the local broadcaster exposes a `relay({to,data,value})` endpoint: it receives
the proved unshield tx from the sidecar, signs it with the broadcaster EOA, submits it,
waits for the receipt, and returns the tx hash. That endpoint **is** "the wallet's own
broadcaster."

---

## 3. Architecture

```
┌───────────────── e2e harness / (later) macOS app ─────────────────┐
│                                                                    │
│   anvil (Sepolia fork)  ◀───────────────┐  eth_call/eth_getLogs    │
│        ▲   ▲                             │  (chain reads)           │
│        │   │ submit shield tx            │                          │
│        │   │ (owner EOA)        ┌────────┴─────────┐               │
│        │   └────────────────────│  railgun-helper  │  Unix-socket   │
│        │                        │  (Rust sidecar)  │  JSON-RPC      │
│        │  submit unshield tx    │  balance         │◀──────────────│
│        │  (broadcaster EOA)     │  prepareShield   │  (bearer)      │
│        │                        │  prepareUnshield │               │
│        │                        │  (Groth16 prove) │               │
│        │                        └────────┬─────────┘               │
│        │                                 │ proved unshield tx       │
│   ┌────┴───────────────┐                 ▼                          │
│   │ local broadcaster  │◀── relay(payload) ── returns tx to submit  │
│   │ (own EOA + service)│                                            │
│   └────────────────────┘                                            │
└────────────────────────────────────────────────────────────────────┘
```

- **Provider:** for the e2e the sidecar's `Eip1193Provider` talks **directly to the anvil
  fork RPC** (env `LOCAL_WALLET_PRIVACY_RPC_URL`-style), not the daemon. The daemon-socket
  provider is the app-integration path (deferred, but the trait impl is written so either
  backend plugs in).
- **Sync source:** the crate's default syncer (Subsquid + RPC fallback) OR RPC-only,
  pinned by the spike. On a fork, sync must work from the fork's logs/state (RPC-only is the
  safe default for a fork; Subsquid indexes live Sepolia, not the fork).

---

## 4. Components & module layout

```
local-wallet-railgun/
  Cargo.toml               single crate, lib + two bins; pinned Kohaku git dep
  rust-toolchain.toml
  NOTES.md                 confirmed API signatures from the spike
  src/lib.rs               shared modules
  src/secret.rs            fd-5 SecretPayload parser (entropy, socket, provider conn)
  src/keys.rs              derive RAILGUN spending+viewing keys (+ EOA keys) from entropy
  src/provider.rs          build the alloy DynProvider (fork RPC now; daemon backend later)
  src/railgun.rs           RailgunBuilder wiring: balance split, prepare_shield, prepare_unshield
  src/broadcaster.rs       LocalBroadcaster: own EOA, relay(tx)->submit->receipt
  src/rpc.rs               Unix-socket JSON-RPC server + bearer auth (shared by both bins)
  src/bin/railgun-helper.rs        sidecar: balance/prepareShield/prepareUnshield
  src/bin/railgun-broadcaster.rs   local broadcaster: relay/address
  tests/e2e_fork.rs        anvil Sepolia-fork shield+unshield round-trip (ignored by default)
  scripts/e2e-fork.sh      wrapper: sets RPC_URL, runs the e2e test
  docs/design/…            this spec + v1 spec
  docs/superpowers/…       v1 plan + v2 plan
```

Boundaries: `secret`/`keys`/`railgun`(pure mapping) are unit-testable; `provider`/`rpc`/
`broadcaster` are I/O adapters; each `bin` only wires. RPC method ↔ handler live together.
A single crate with a `lib` + two `[[bin]]` targets maximizes code reuse (shared `rpc`,
types) while keeping the two runnable processes distinct.

---

## 5. RPC surface (v2)

### `railgun-helper` (sidecar)

| Method | Params | Returns | Notes |
|--------|--------|---------|-------|
| `balance` | — | `{ valid, pending, total }` (0x hex wei) | From `railgun.balance(addr)` → `Vec<BalanceEntry{ asset, poi_status: Option<PoiStatus>, amount:u128 }>`, keyed on `chain.wrapped_base_token` (WETH). POI off on the fork ⇒ `poi_status==None` ⇒ all counted as `valid`; `pending` = notes with a non-`Valid` status; `total = valid + pending`. |
| `prepareShield` | `{ amountWei }` | `[{ to, data, value }]` | `railgun.shield().shield_native(acct, amount).build(&mut rng)` → `Vec<TxData>`. No proof. Owner EOA self-submits. |
| `prepareUnshield` | `{ amountWei, to }` | `{ to, data, value }` (proved tx) | `TransactionBuilder::new().unshield(signer, to, AssetId::Erc20(wrapped_base_token), amount)?` → `railgun.build(builder,&mut rng).await` → `ProvedTx.tx_data`. **Generates a Groth16 proof** (downloads artifacts on first call; tens of seconds) — run with a long timeout; async job model deferred. Delivers **WETH** to `to` (minus 0.25% unshield fee). |

### `railgun-broadcaster` (local broadcaster)

| Method | Params | Returns | Notes |
|--------|--------|---------|-------|
| `relay` | `{ to, data, value }` | `{ txHash, blockNumber, status }` | Signs the proved unshield tx with the **broadcaster's own EOA**, submits to the chain, waits for the receipt, returns it. This is the wallet's own broadcaster; `relayerUrl` points at its localhost socket. |
| `address` | — | `{ address }` | The broadcaster EOA address (so the sidecar/UI can fund it / display it). |

All requests require `Authorization: Bearer <token>`. `balance`/`prepare*` call
`railgun.sync()` first so state is current. Keys are never returned over any method.

---

## 6. POI & proving — the feasibility crux (finalized — spike-confirmed)

1. **Groth16 proving.** Unshield spend requires a zk proof. `railgun.build()` generates it
   in-process; on first call it **downloads multi-MB circuit artifacts** (proving key,
   matrices, wasm witness calc) from a public GitHub repo
   (`github.com/Robert-MacWha/privacy-protocol-artifacts`), brotli-decompressed into a
   64 MB in-RAM cache (no disk persistence, no public injection point). Cost: tens of
   seconds on the first proof of a given circuit shape, then cached for the process. The
   e2e drives this with a generous timeout; the app-facing async job model is deferred.
   Needs outbound HTTPS to the artifact host.
2. **POI is OPT-IN and is kept OFF for the fork.** `.with_poi()` is not called. Confirmed:
   with POI off, a note is spendable immediately after `sync()` (the crate's own
   `transact_utxo.rs` does exactly this on an anvil Sepolia fork). POI validity comes from
   the external `ppoi.fdi.network` aggregator, which validates against **real** chain state
   — a note freshly shielded on a local fork would never become `Valid`, so POI-on cannot
   work on a fork (the crate's `transact_poi.rs` is explicitly marked live-Sepolia-only).
   Keeping POI off is the correct, spike-validated choice for the fork e2e; POI-on is a
   live-Sepolia-only concern and out of v2 scope.
3. **Sync network dependency.** Building the note/merkle state for the fork block uses the
   crate's default-style `ChainedSyncer` = RAILGUN **Subsquid** GraphQL indexer (capped at
   the fork block) with an **RPC fallback** through the fork. Read-only; a network
   dependency, not a fund/verification risk.

---

## 7. Security boundary (do not break)

- **Spending key + viewing key** are derived in-process from the fd-5/entropy seed, **never
  logged, never written to disk, never returned over RPC.** Leaking the **viewing key**
  exposes the whole tx graph + amounts (funds safe, privacy not).
- **Broadcaster EOA key** lives only in the broadcaster process (in the e2e, an anvil test
  key; in production, a Keychain-backed key, biometric-gated, separate from the bundler and
  Kernel keys). Never exposed over RPC/status.
- **Shielded seed at rest** (app integration): macOS Keychain, `.biometryCurrentSet` +
  `WhenUnlockedThisDeviceOnly`, testnet-tagged.
- **State file** `railgun-sepolia.json` mode `0o600`; single-writer sidecar contains races.
- Unaudited alpha; **testnet only, no mainnet funds.** Pin the exact Kohaku git rev.

---

## 8. Verification

- **Unit:** pure logic (secret parse, key derivation vectors, balance split, tx mapping)
  test-first (TDD).
- **Provider:** mock RPC returns a chain id / call result; sidecar routes reads through it.
- **RPC:** request without bearer → 401; with bearer → dispatch.
- **e2e (`scripts/e2e-fork.sh`) — the goal's acceptance test:**
  1. Start anvil forking Sepolia (funded default accounts).
  2. Sidecar `prepareShield 0.01` → owner EOA submits → shield tx confirms on the fork.
  3. `balance` shows the deposit (pending/total).
  4. Sidecar `prepareUnshield 0.01 → recipient` (proof generated) → **local broadcaster
     EOA** submits → unshield tx confirms on the fork; recipient balance increases.
  5. Assert both tx receipts are `status: success` and print block numbers.
  - Live-Sepolia mode (`E2E_LIVE=1` + a funded key) optional.
- **Regression:** the sidecar builds against the pinned dep; `cargo test` green.

---

## 9. Roadmap (post-v2)

- **Async proving job model** + app-spawn wiring (fd contract into `SpawnHelper`, bundle the
  binary, biometric gate).
- **Private relay:** Waku broadcaster network (real anonymity set) or a shared,
  unstaked-paymaster-tolerant 4337 bundler — replacing the anonymity-set-of-one broadcaster.
- **Shielded transfer** (proof-gated; private relay strongly preferred).
- **Mainnet** after audit + mnemonic backup UI.
