# Railgun Helper (Kohaku Railgun sidecar) — v1 Design

**Status:** Draft for review
**Date:** 2026-07-02
**Repo:** `local-wallet-railgun` (new, sibling to `local-wallet-daemon`)
**Binary:** `railgun-helper`

> Companion to the Privacy Pools reference (`privacy-helper`, on branch
> `kohaku-shield-v1-impl` in `local-wallet-mac`). This spec adapts that shield-only
> pattern to Railgun via Kohaku's `crates/railgun` Rust library.

---

## 1. Goal & scope

Provide a **shield (deposit) + balance** integration with the **Railgun** shielded pool
for Local Wallet on **Sepolia** (chain id `11155111`), mirroring the deliberately
minimal scope of the Privacy Pools reference (which exposes only `balance` and
`prepareShield`).

**In scope (v1):**

- Read the account's Railgun shielded balance (split by POI status).
- Build a **shield** transaction (or transactions) that the existing daemon submits from
  the user's own account.

> **Shielding is a public act, not a private one.** The shield tx is visible and linkable
> to the depositor ("address X deposited N ETH into Railgun at time T") — that is
> inherent and unavoidable. Self-submitting it therefore leaks **nothing beyond** what
> shielding already reveals, because *you* are the natural submitter of your own public
> deposit; there is no hideable actor. Privacy is realized on the **spend** side (transfer
> between shielded addresses, and unshield to a fresh address within the pool's anonymity
> set) — and only there does the submitter's identity matter (see §2.3, §6.2).

**Explicitly out of scope (see §7 Roadmap):**

- **Unshield / transfer.** These require Groth16 zk-proof generation (circuit-artifact
  download + heavy CPU/memory). Relay is *not* strictly required (see §2.3), but proof
  generation is, and it cannot run inside an RPC timeout.

---

## 2. Architecture (decided)

### 2.1 Rust sidecar, in a new sibling repo

`railgun-helper` is a standalone **Rust binary** in this new repo (`local-wallet-railgun`),
a sibling to `local-wallet-daemon`. It reuses the daemon's spawn/transport contract
exactly:

- **fd-3** (ready) / **fd-4** (alive, EOF ⇒ exit) / **fd-5** (secret payload).
- **Unix-socket JSON-RPC**, authenticated by the per-launch **bearer token** from fd-5.
- Forwards all chain reads to `wallet-node` (reuses the daemon as its Ethereum provider),
  exactly as `privacy-helper`'s `daemon-provider.ts` does today.

**Why a sidecar (not folded into the daemon):** it isolates the shielded **spending +
viewing keys** (and, in v2/v3, heavy Groth16 proving) in a separate short-lived process,
away from the long-lived daemon that holds the bundler-EOA secret, and keeps
`wallet-node`'s dependency/CI surface free of the arkworks proving stack.

**Shape relative to existing Rust:** it is a small sibling of `wallet-node` — a spawned,
socket-serving, network-capable binary using the daemon's own fd + socket + token
contract. It is *not* like the pure protocol `rlib`s (no I/O) or the `wallet-ffi`
static lib (in-process, no network/secrets). It is the first *Rust* sidecar;
`privacy-helper` is its predecessor in role (but TS/Bun).

### 2.2 Kohaku dependency (no WASM)

`crates/railgun` (`ethereum/kohaku`) is a Rust `rlib` with a clean public API:

```rust
RailgunBuilder::new(chain, provider)
    .with_database(db)          // Arc<dyn Database> — file-backed impl
    // default UTXO syncer = Subsquid + RPC chained (see §2.4); omit with_utxo_syncer to use it
    .with_poi()                 // Proof-of-Innocence on (real on Sepolia — §4.1)
    .build()                    // -> RailgunProvider
```

`pub mod builder | provider | account | chain_config | database | indexer | poi | crypto`.
The `wasm-bindgen`/`tsify` bindings are behind the `js` feature, so we consume it with
**`default-features = false`** and never touch WASM. Pinned as a **git-rev dependency**
(not on crates.io; drags Kohaku's workspace-internal crates `common`, `crypto`,
`eip-1193-provider`, `userop-kit`) — the same pin pattern the daemon uses for the
protocol crates.

### 2.3 Relay: self-submit (simplest), no broadcaster infra

Confirmed via the Kohaku + Railgun docs:

- There is **no hosted HTTP RPC/broadcaster** to point at. The public broadcaster network
  is **Waku (community P2P)**, integrated via the *Railgun-community* SDK
  (`@railgun-community/waku-broadcaster-client`) — **not** Kohaku. Kohaku's own
  relayer/broadcaster docs are `TODO` stubs; its plugin `broadcast()` needs a 4337
  bundler + smart account you configure yourself.
- **Simplest path, explicitly documented by Kohaku:** shield/unshield/transfer each
  return a plain `{ to, data, value }` tx that **any EOA can submit**. Kohaku's unshield
  doc: *"This transaction can be sent from an EOA … Do note that this EOA will be the
  submitter of the tx, and thus linked to the recipient."*

**Decision:** self-submit every Railgun tx through the existing daemon send path — no
Waku, no broadcaster, no 4337 relay, no new service. For **v1 (shield only)** there is
**no additional privacy cost** (shielding is inherently public — see §1). For
unshield/transfer later, self-submit links the submitter to the recipient — a conscious
tradeoff, with the private-relay path deferred (§7).

**Waku is not a quick add (verified).** There is no production-ready Rust Waku
broadcaster client. The reference (`@railgun-community/waku-broadcaster-client`) is
TypeScript; Kohaku's Rust crate has none (broadcaster docs are `TODO` stubs). Adding it
means either FFI into a native Waku node (nwaku/go-waku — heavy native interop) or
reimplementing the Railgun broadcaster protocol (fee-token discovery, `findBestBroadcaster`,
encrypted request/reply over Waku content topics). It is a substantial project → v3. A
lighter alternative if private relay is wanted sooner is Kohaku's 4337 UserOp relay path
(via `userop-kit`), but it still requires a *shared/third-party* bundler to provide any
privacy.

### 2.4 Sync source: Subsquid (default) for simplicity & speed

Use the crate's **default syncer** — Subsquid GraphQL primary with an RPC fallback
(`ChainedSyncer`) — by omitting `with_utxo_syncer`. Rationale: fastest sync and the least
code (no batch-size tuning, no full `eth_getLogs` history walk). This is the pragmatic
choice given the sidecar only needs to find and track the user's own notes.

- **Endpoint:** `https://rail-squid.squids.live/squid-railgun-eth-sepolia-v2/v/v1/graphql`
  (live and near-real-time — §4.1). The RPC fallback still routes through the daemon.
- **Accepted tradeoff (see §6.3):** Subsquid is a **centralized, unverified** indexer
  reached by a direct outbound HTTPS call that bypasses Helios, and querying it leaks that
  the device uses Railgun. It can omit commitments (under-count) but cannot steal funds.
- **RPC-only remains a documented alternative** (`with_utxo_syncer(RpcSyncer…)`,
  Helios-verified, no indexer) if verification/egress concerns outweigh speed later; it is
  feasible on Sepolia (only ~7,800 events ever) but needs a large `with_batch_size` and an
  archive RPC. Not the default.

> Note: spending (unshield/transfer, v2+) needs the full commitment Merkle tree to build
> inclusion proofs. Subsquid returns the full tree quickly, which is another reason to
> prefer it for the eventual v2 path.

### 2.5 Relaying — complexity vs. privacy (decision)

Only unshield/transfer need relaying; **shield is public** and self-submitted with no privacy
loss. Weighing the options (detail in §7.1):

| Option | Complexity | Privacy preserved | Notes |
|---|---|---|---|
| **B. Self-submit via daemon** | **Low** | **None** — submitter links to recipient | No relay infra; only sane for "unshield to self" |
| **A. Native 4337 + Privacy Paymaster** | **Medium** | **High** *iff* a shared 3rd-party bundler | Client exists (`PimlicoBundler`); blocked today by unstaked paymaster + no public shared bundler |
| **D. Hybrid TS Waku co-process** | **Med–High** | **Highest** (Waku anon set) | Isolates TS to the relay leg |
| **C. Native Rust Waku** | **High** | **Highest** | No Rust client → FFI/reimplement |

**Decision (now):** ship **v1 = shield + balance with self-submit (Option B)** — zero privacy
cost because shield is inherently public, zero relay infra. **Private relay is deferred**; when
unshield/transfer is built (v2+), pursue **Option A first** (lowest complexity for real
privacy), falling back to D only if a shared, unstaked-paymaster-tolerant bundler proves
unavailable.

---

## 3. Repo & component layout

```
local-wallet-railgun/                 (this repo)
  Cargo.toml            single binary crate `railgun-helper` (grow to a workspace later)
  src/main.rs           fd contract (3/4/5), lifecycle, wiring
  src/secret.rs         read + parse fd-5 JSON payload
  src/rpc.rs            Unix-socket JSON-RPC server + bearer auth
  src/provider.rs       Eip1193Provider impl forwarding to the daemon socket
  src/database.rs       file-backed railgun::database::Database impl (0o600)
  src/railgun.rs        RailgunBuilder wiring + balance/prepareShield handlers
  docs/design/…         this spec
  LICENSE-MIT, LICENSE-APACHE, README.md
```

**fd-5 payload** (same shape as `privacy-helper`):

```json
{
  "entropyHex": "0x<64-hex>",
  "sidecarSocketPath": "/path/to/railgun-sidecar.sock",
  "daemon": { "socketPath": "…", "token": "…", "url": "http://127.0.0.1:<port>" }
}
```

**Persistent state:** `~/Library/Application Support/LocalWallet/railgun-sepolia.json`
(mode 0o600), separate from the Privacy Pools state file.

---

## 4. RPC surface (v1)

| Method | Params | Returns | Notes |
|--------|--------|---------|-------|
| `balance` | — | `{ valid, pending, total }` (0x hex wei) | ETH shields to WETH; balance keyed on `wrapped_base_token`. Split by `poiStatus`: `"Valid"` → `valid`, else → `pending`; `total = valid + pending`. Direct analog of pp's `approved/pending/total`. |
| `prepareShield` | `{ amountWei }` | `[{ to, data, value }]` (**array**) | ERC-20 shields can be approve + shield (2 txs); native ETH shield (`shield_native`, wraps to WETH) is typically 1 tx. Daemon submits in order. **Differs from pp**, which returned a single tx. |

All requests require `Authorization: Bearer <token>` (the fd-5 daemon token, reused for
app↔sidecar auth). `balance`/`prepareShield` call `provider.sync()` first (Subsquid +
RPC fallback, §2.4) so reads/deposits derive from current on-chain state.

### 4.1 Verified on Sepolia (2026-07-02)

- **POI is real, not a placeholder.** `ppoi.fdi.network` serves `Ethereum_Sepolia` under
  the configured list key `efc6ddb…`, fully validated (`currentTxidIndex ==
  validatedTxidIndex`, `pendingTransactProofs: 0`), with real activity: Shield 3275 /
  Transact 3149 / Unshield 1348. So `valid` can be non-zero on Sepolia — notes genuinely
  clear POI (contrast the pp ASP, which never approves on testnet).
- **Subsquid Sepolia** is live and near-real-time (not used by default; see §2.4).
- **`eth_getLogs`** works; historical windows need an archive RPC (the daemon has one).

---

## 5. Data flow (shield)

1. App → sidecar: `prepareShield { amountWei }`.
2. Sidecar: `provider.sync()`, then build via `provider.shield().shield_native(addr,
   amount).build()` → `Vec<TxData>`.
3. Sidecar → app: `[{ to, data, value }, …]`.
4. App signs each tx with the Secure-Enclave passkey and submits via the daemon's normal
   ERC-4337 send path (unchanged).
5. Later `balance` calls show the deposit as `pending` until POI marks it `Valid`.

---

## 6. Security gotchas (the sharp edges)

1. **Viewing key is the privacy-critical secret.** Railgun derives a **spending key +
   viewing key** (`keystore.deriveAt(spendingKeyPath/viewingKeyPath)`). Leaking the
   **viewing key** exposes the entire incoming/outgoing transaction graph + amounts
   (funds safe, privacy not). New independent secrets — same custody concern as the
   shielded-seed Keychain item (`.biometryCurrentSet`, re-enrollment = loss); recovery
   depends on the mnemonic backup, the mainnet prerequisite.

2. **Why the existing daemon bundler is not a privacy relayer.** The daemon has a
   bundler, but it is a **self-relayer for the user's own Kernel account** — a persistent,
   user-funded EOA. Relaying unshields through it gives an **anonymity set of one**
   (clusters all the user's private txs under one address, funding traceable to the user)
   and it pays gas from a user-funded tank rather than from an in-pool relayer fee. A
   privacy relayer must be an unrelated third party with its own anonymity set — which is
   the Waku broadcaster network, not the daemon. (Self-submit, §2.3, makes the same
   linkage explicit and accepted rather than pretending the bundler adds privacy.)

3. **Subsquid indexer trust — accepted tradeoff (we use it, §2.4).** Sync pulls
   commitments from a centralized GraphQL indexer (`rail-squid.squids.live`) via a direct
   outbound HTTPS call that **bypasses the daemon/Helios**. Consequences: the sidecar needs
   outbound-network entitlement, the data is **unverified** (a malicious/censoring indexer
   can *omit* commitments → under-counted balance, but cannot steal funds), and the query
   pattern **leaks that this device uses Railgun**. Chosen for simplicity/speed; the
   RPC-only alternative (§2.4) removes it if this becomes unacceptable.

4. **POI "pending" state — verified real on Sepolia.** POI is on by default; only
   `"Valid"` notes are spendable, and freshly shielded funds read as pending until the POI
   lists include them. **Verified 2026-07-02** that Railgun Sepolia POI is live and
   validating (§4.1), so this clears on testnet (unlike the pp ASP placeholder). Still
   surface `pending` in the balance so the UI can annotate freshly-shielded, not-yet-cleared
   funds; and re-verify POI liveness before relying on it long-term.

5. **Circuit-artifact integrity (v2/v3 only).** Proving downloads large Groth16 keys/wasm
   from a remote host — must be **hash-verified** (a tampered proving key can fail proofs
   or be crafted to leak witness data). Proving is memory/CPU-heavy and slow, so it
   **cannot run inside the ~10 s RPC timeout** — it needs an async job model.

6. **Unaudited alpha.** `crates/railgun` is `0.1.0` / the TS package is `0.0.1-alpha.27`,
   explicitly "NOT READY FOR PRODUCTION." **Pin an exact git rev**; testnet only; **no
   mainnet funds**.

7. **State persistence.** Railgun persists UTXO/note/merkle state after every sync (0o600
   file). Sensitive note data (never private keys) is stored — protect the state file. The
   single-writer sidecar contains write races.

---

## 7. Roadmap (out of v1)

- **v2 — unshield (self-submit):** add `prepareUnshield`; the only unavoidable new cost is
  proof generation — a circuit-artifact loader (with hash verification) + an **async job
  model** (proofs exceed the RPC timeout). Self-submit accepts the submitter↔recipient
  linkage (§2.3, §6.2).
- **v3 — private relay (optional):** remove the submitter↔recipient linkage. Options in
  §7.1; the crate's **native 4337 + Privacy Paymaster** path (Option A) is the preferred
  starting point.
- **v4 — transfer:** shielded→shielded `prepareTransfer` (also proof-gated; private-relay
  strongly preferred).

### 7.1 Relayer binding options (how the Rust sidecar gets an unshield/transfer relayed)

The crate exposes a **native Rust 4337 path**: `RailgunProvider::prepare_userop(…, bundler:
&dyn Bundler, …)` builds a broadcastable EIP-7702 `SignableUserOperation`, with gas paid by
the **Privacy Paymaster** (Sepolia: `0xBb9D…`) and the bundler fee paid from a shielded fee
note. So "the relayer" is fundamentally a **4337 bundler**; privacy holds as long as that
bundler is not the user. Options, simplest→heaviest:

- **A. Native Rust 4337 bundler client.** No custom code needed —
  `userop_kit::bundler::PimlicoBundler::new(url)` already implements the `Bundler` trait
  (`eth_sendUserOperation` + receipt polling) against any Pimlico-compatible endpoint.
  Stack = **EntryPoint v0.8** (`0x4337…08`) + eth-infinitism **Simple7702Account**
  (`0xe6Cae…`, EIP-7702) + **Railgun Privacy Paymaster** (`0xBb9D…`), gas from the
  paymaster, bundler fee from a shielded note.
  **Verified on-chain (Sepolia, 2026-07-02):** EntryPoint v0.8, the Privacy Paymaster
  (deposit **0.178 ETH**), the Simple7702Account impl, and the Fee Adapter are **all
  deployed**. **BUT the paymaster is `staked = false`.** Kohaku's own tests
  (`plugin-transact-broadcast`) **self-host Alto** against a forked Sepolia — they do *not*
  use a public shared bundler.
  **Consequence:** functionally easy (point `PimlicoBundler` at a bundler), but **private,
  shared relay is not confirmed** — canonical ERC-7562 mempool rules restrict unstaked
  paymasters, so a hosted/shared bundler may reject these UserOps. True privacy needs the
  paymaster staked (Railgun's decision, not ours) *or* a genuinely shared bundler that
  accepts it. **Spike required** before relying on A for privacy: send one real Sepolia
  unshield UserOp through a hosted bundler and confirm acceptance.
  *(This also concretely confirms the daemon's bundler can't be reused: it targets
  EntryPoint v0.7 + Kernel, a different EntryPoint entirely.)*
- **B. Self-submit via the daemon (no relayer).** Sidecar returns the proved tx/UserOp;
  daemon submits from the user's account. Zero relay infra, simplest — but
  submitter↔recipient linkage (privacy-compromised). Acceptable only for "unshield to self".
- **C. Waku broadcaster (classic Railgun, best anonymity set).** No Rust client exists →
  FFI to a native Waku node (nwaku/go-waku) or reimplement the broadcaster protocol.
  Heaviest; a v3+ project.
- **D. Hybrid: co-process TS Waku client.** Keep proving/state in the Rust sidecar; run the
  mature `@railgun-community/waku-broadcaster-client` (TS) as a *separate* relay process the
  sidecar hands the proved tx to. Isolates the TS dependency to just the relay leg — a
  pragmatic middle ground if Waku-grade privacy is wanted before a Rust Waku client exists.

---

## 8. Open questions

1. ~~**Kohaku git rev to pin**~~ — **RESOLVED (2026-07-02):** pin
   `rev = "877026e1775a333c556c6fea54dc270009aac978"` (latest `master`,
   2026-07-01) for the `railgun` crate git dependency.
2. ~~**Sepolia POI liveness**~~ — **RESOLVED (2026-07-02):** Railgun Sepolia POI is live
   and validating (§4.1); `valid` can be non-zero on testnet.
3. **App-side spawn (deferred to a later implementation step, not v1-blocking):** wire the
   macOS app to spawn `railgun-helper` via the existing `SpawnHelper`/`CSpawn` machinery
   (same as `wallet-node`), and decide where the built binary is bundled/discovered. Until
   then the sidecar is exercised standalone (manual fd/socket harness, like `privacy-helper`).
4. **RPC batch size / archive limits (only if RPC-only sync is chosen):** with Subsquid as
   the default (§2.4) this is moot; revisit only if switching to `RpcSyncer`.
