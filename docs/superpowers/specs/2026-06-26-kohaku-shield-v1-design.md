# Kohaku Shield v1 — Design Spec

Date: 2026-06-26
Status: approved for implementation
Scope: PR #1 of a 2-PR roadmap

## Goal

Ship the smallest *mergeable, demonstrable* slice of Kohaku (Privacy Pools)
into the Local Wallet: a **private deposit (shield) round-trip on Sepolia** that
a stakeholder can watch work end-to-end, with minimal new key-custody surface to
review.

Demo: `/shield 0.01` on Sepolia → on-chain `UserOperationEvent` lands → the
**shielded balance shown in the app** updates **0 → 0.01**. Kill the daemon →
balance read fails (proves reads route through the verified provider, not a
second RPC).

Out of scope for v1 (roadmap, PR #2): withdraw/unshield, private-transfer,
mnemonic backup, ephemeral signing sidecar, mainnet.

## Why these choices (settled in brainstorming)

- **Privacy Pools is irreducibly TypeScript.** Its core is wasm ZK circuits
  (`@fatsolutions/privacy-pools-core-circuits`) + `maci-crypto` + `viem`. No Rust
  equivalent. So the integration is a **Node sidecar** — a *process boundary, not
  a language entanglement*. Swift/Rust talk to it over local IPC, same as they
  already talk to the daemon.
- **The Kohaku root is a separate BIP-39 mnemonic (HD).** Confirmed in the Kohaku
  docs: accounts are created with `{ type: 'mnemonic', mnemonic, accountIndex }`
  (viem `generateMnemonic`), `accountIndex` giving HD derivation. The Secure
  Enclave passkey is non-extractable and its ECDSA is non-deterministic, so it
  **cannot** parent this seed — the mnemonic is a genuinely new root the app must
  generate, store, and (post-v1) back up. v1 keeps it testnet + device-only so the
  *custody conversation* defers to PR #2.
- **Kohaku splits viewing vs spending keys** (viewing = scan notes / compute
  balances, no spend authority; spending = authorize withdraws, step-up auth).
  Both derive from the one seed. In v1 the sidecar holds the seed (read once at
  spawn): the **viewing key** drives `balance()` and the **spending-side** material
  derives the deposit precommitment for `prepareShield`. No fund-moving spend
  happens in v1 (no withdraw), so the spending key is computed, never used to move
  value — that lands in PR #2.

## Architecture

```
┌─────────────────────── local-wallet-mac (.app) ───────────────────────┐
│  Swift app (LLM + UI + passkey)                                        │
│    │  posix_spawn: fd-3 ready/token, fd-4 alive, fd-5 seed             │
│    ├──────────────▶ privacy-helper (Node sidecar)                      │
│    │                   Host.provider ──┐                               │
│    │                   balance()       │  eth_call / eth_getCode       │
│    │                   prepareShield()  │                              │
│    └──────────────▶ wallet-node (daemon) ◀┘ (verified reads)           │
│         localwallet_sendUserOperation                                  │
└────────────────────────────────────────────────────────────────────── ┘
```

## Component: `privacy-helper` Node sidecar (NEW)

- **Location:** `local-wallet-mac/privacy-helper/` (subfolder, not a new repo —
  it's app-owned, spawned by the app, its built artifact ships inside the .app
  bundle exactly like the daemon binary).
- **Size:** ~200–400 lines of glue. esbuild → one bundled `.js` + the `.wasm`
  proving assets ship in the bundle; `node_modules` stays dev/CI-only.
- **Deps:** `@kohaku-eth/privacy-pools`, `@kohaku-eth/plugins`,
  `@kohaku-eth/provider`.
- **Lifecycle:** long-lived for v1 (needs to poll balance). Receives the seed
  once over fd-5 at spawn.
  - `ponytail:` long-lived sidecar holds the testnet seed for the session — NOT
    the ephemeral per-op signing sidecar yet. Upgrade to the two-process split when
    withdraw lands (PR #2): **viewing key → long-lived read-only sidecar**
    (balances, no spend authority), **spending key → ephemeral signing sidecar**
    that dies after each op.
- **Local JSON-RPC** (over the inherited socket): `balance()`,
  `prepareShield(value)`.
- **Implements Kohaku `Host`:**
  - `provider` → forwards `eth_call` / `eth_getCode` to the **daemon's**
    authenticated socket (this is the provider/Helios unification — one verified
    read path, no second Helios).
  - `network.fetch` → standard `fetch` (pool subgraph).
  - `storage` → JSON file in App Support (shielded notes + Merkle state).
  - `keystore` → the mnemonic-derived seed received over fd-5; derives both the
    viewing and spending keys.

## Key custody & transport

- **At rest:** shielded seed in macOS Keychain, `kSecAttrAccessControl =
  .biometryCurrentSet` + `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
  **Every read triggers Face/Touch ID.** (User constraint: any key we process
  demands biometric.)
- **Transport (fd-5):** Swift reads the seed (biometric prompt) → `pipe()` →
  `posix_spawn_file_actions_adddup2(readEnd → 5)` in the child, close write end
  in child → parent writes raw 32 seed bytes to the write end, closes it (EOF) →
  Node reads fd 5 to EOF, closes it, derives Privacy Pools keys.
  - Seed never touches `argv`, env, or disk. Only the app and the sidecar ever
    see it; the daemon and protocol SDK never do. Byte-for-byte the pattern the
    daemon already uses for its fd-5 secret.
- **Gates per session:** one biometric at sidecar (re)spawn for the seed read;
  balance polling is free thereafter (the viewing key has no spend authority). The
  deposit tx is *additionally* gated by the passkey biometric at signing. Two keys,
  two gates.
- **Resolved (was open):** Kohaku's viewing/spending split is confirmed, so the
  cheap balance polling is honest — the resident key can't move funds. In v1 the
  single sidecar still derives both from the seed; the **two-process** transport
  (viewing → long-lived, spending → ephemeral) is the PR #2 hardening.

## Recovery (post-v1, but design for it now)

Because the root is a **BIP-39 mnemonic**, recovery is the standard wallet-seed
model, in three layers — only the last is fund-critical:
1. **App closed →** the sidecar's RAM working copy is gone; reopen re-reads the seed
   from **Keychain** over fd-5 (one biometric). No loss.
2. **`Host.storage` (notes/Merkle cache) lost →** rebuild by re-scanning the pool
   with the **viewing key**. A cache, not a secret.
3. **Device/Keychain lost →** re-enter the mnemonic, re-derive by `accountIndex`,
   re-scan. This is why PR #2 ships mnemonic backup. Optional multi-device: opt-in
   iCloud Keychain sync (drop `ThisDeviceOnly`).

Caveat: 0xbow's *consumer* docs describe per-note backup / non-recoverable keys —
that's the older UX, not the mnemonic-HD account model Kohaku wraps. Confirm the
exact per-deposit derivation in `@kohaku-eth/privacy-pools` before treating "one
mnemonic backs up everything" as final.

## Shield flow

1. `/shield 0.01` LLM intent (or button) → sidecar `prepareShield(value)` returns
   a `PublicOperation` = pool deposit calldata.
2. App wraps it as a Kernel `execute(pool, value, calldata)` UserOp.
3. Passkey signs (Secure Enclave, biometric).
4. Submit via existing `localwallet_sendUserOperation`.
5. Poll `balance()` → 0 → 0.01 once the deposit lands.

## Changes by repo

### `local-wallet-mac` (most of the work)
- **NEW** `privacy-helper/` sidecar (above).
- Spawn it mirroring `WalletMacOSApp/WalletNodeDaemon.swift` (fd-3 ready/token,
  fd-4 alive, **fd-5 seed**); bundle its built artifact as an app resource
  (`project.yml`).
- `Host.provider` shim forwards reads to the daemon via the existing
  `WalletNodeClient`.
- Generate + store the shielded seed in Keychain (biometric, device-only,
  testnet-tagged) — extend `KeyStore.swift`.
- Add `shield` to the `Tool` enum in
  `Sources/WalletToolLayer/ToolIntent.swift` and a matching `ToolDefinition` in
  `ToolDefinitions.swift` (args dict is already generic).
- **Display the shielded balance in the UI:** a view that calls the sidecar's
  `balance()` and renders it (alongside the existing public balance), refreshed
  after a successful shield and on a light poll. `ponytail:` reuse whatever the
  existing public-balance view does for refresh/formatting — no new balance
  framework.

### `local-wallet-daemon`
- Verify `max_call_gas_limit` in `crates/wallet-bundler/src/policy.rs`
  accommodates a ZK pool deposit; raise the cap if EntryPoint simulation rejects
  on gas. **Likely the only change** — the allowlist checks the *sender* (Kernel),
  not the call target, so a shield deposit wrapped in Kernel `execute` passes
  without policy changes.
- No new RPC methods (the sidecar reuses `eth_call` / `eth_getCode`).

### `local-wallet-protocol`
- **No changes.** Stays the pure deterministic crypto SDK. Pool note math lives
  in the Kohaku TS, not here.

## Verification

- **Wiring:** `node privacy-helper` standalone prints a balance and
  `prepareShield` returns valid deposit calldata against Sepolia.
- **Provider routing:** kill the daemon → sidecar balance read fails (reads go
  through the daemon socket, not a second RPC).
- **Shield end-to-end:** run the app on Sepolia, `/shield 0.01`, confirm a
  `UserOperationEvent` lands, deposit is observable on-chain, sidecar balance
  increments 0 → 0.01.
- **Biometric:** sidecar spawn prompts Face/Touch ID for the seed read; deposit
  signing prompts again for the passkey.
- **Regression:** existing `/transfer` and `/swap` flows unaffected with the
  sidecar running.

## Roadmap (not this PR)

- **PR #2 — withdraw / private-transfer:** the real privacy guarantee. Brings the
  **two-process key transport** (viewing key → long-lived read-only sidecar;
  spending key → ephemeral signing sidecar, dies after each op), **mnemonic backup
  UI** (+ optional iCloud Keychain sync), relayer broadcast (must NOT self-relay
  through the user's Kernel account — that re-links the funds), key **rotation** as
  a guarded `accountIndex`-bump + funds migration (not a metadata swap), and the
  full security/stakeholder review.
