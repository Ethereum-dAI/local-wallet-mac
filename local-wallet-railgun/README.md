# local-wallet-railgun

RAILGUN **shield + unshield** for Local Wallet — a Rust sidecar wrapping Kohaku's
`crates/railgun`, targeting Sepolia. Unshields exit through **RAILGUN's privacy
paymaster** as a sponsored ERC-4337 UserOperation, submitted by a **public bundler**.
Nothing of ours pays gas, so there is no broadcaster and nothing to fund.

> Part of the `local-wallet-mac` monorepo (mirrors `local-wallet-daemon/` and
> `local-wallet-protocol/`). Alpha, unaudited, **testnet only — no mainnet funds.**

## What's here

One runnable process, one crate:

- **`railgun-helper`** — the sidecar, and the only process. Serves `balance` /
  `maxUnshieldable` / `prepareShield` / `unshield` / `unshieldStatus` over a
  bearer-authenticated Unix-socket JSON-RPC API. Wraps the RAILGUN Rust SDK: derives the
  shielded account from entropy, syncs (Subsquid + RPC), builds shield txs, and **proves +
  submits** unshield exits. It spawns no child: each exit is signed by an ephemeral
  single-use sender and broadcast by a public bundler, so there is nothing else here to
  spawn, own, or fund — the app talks to this one socket and that's the whole surface.

### Unshield is asynchronous

Groth16 proving is slow, so unshield is a background job, not a blocking call:

- `unshield {amountWei, to}` → returns `{jobId}` **immediately**; proving + bundler
  submission run in the background (the RAILGUN provider is `!Send`, so proving runs on a
  current-thread + `LocalSet` runtime).
- `unshieldStatus {jobId}` → `{status: pending | submitted | done | error, result?, error?,
  code?}`. `submitted` means the bundler accepted the UserOperation (a real op hash exists)
  and inclusion is pending; `done` means it landed. `submitted` and `done` share ONE
  `result` schema, differing only in `included`.

### `maxUnshieldable` — why the full balance is never spendable

`maxUnshieldable` returns `{maxValueWei, receivableAtMaxWei, reserveWei}` (all `0x`-hex
wei) and, like `unshield`, performs a live RAILGUN sync + bundler gas probe before
answering. The three fields are **not interchangeable**:

- `maxValueWei` — the largest `amountWei` the sidecar will currently accept. This is the
  input bound: validate a requested amount against it, and it's what a Max control should
  fill in.
- `receivableAtMaxWei` — what the recipient would actually net if you requested
  `maxValueWei`. **Display only** — never feed it back into `unshield`.
- `reserveWei` — the gas headroom held back in the pool at that ceiling.

Two separate deductions explain why 100% of the shielded balance is never unshieldable:
RAILGUN's 25 bps (0.25%) treasury unshield fee reduces what the recipient receives (there
is no gross-up — the requested amount IS what leaves the pool), and a **second**, in-pool
WETH fee note pays the privacy paymaster for gas. Only the first is known before proving,
which is why `maxUnshieldable` reserves headroom (`reserveWei`) for the second.

### fd-5 spawn contract

The RAILGUN entropy (the sidecar's one secret) travels on **fd 5**, never argv/env —
matching how the app spawns `wallet-node`. `spawn.rs` handles delivery (pipe + `dup2`, with
an explicit `CLOEXEC` clear so fd 5 survives even when the pipe read end already *is* fd 5)
and raw-libc `read_fd5`. The env var (`RAILGUN_ENTROPY_HEX`) remains a standalone/dev
fallback only.

### Paymaster-sponsored exits, and the derived single-use sender

RAILGUN's classic privacy relies on a *shared* broadcaster network (Waku) so the tx
submitter is an unrelated third party. This wallet takes a third path, distinct from both
that model and from a self-run broadcaster: each exit is an ERC-4337 UserOperation
**sponsored by RAILGUN's privacy paymaster** — an on-chain contract, so sponsorship is
permissionless and no off-chain party approves or sees the request — and **submitted by a
public bundler**. Nobody funds anything, and there is no persistent broadcaster EOA whose
address would link every exit together.

Each exit gets a fresh, **single-use** EIP-7702 sender, derived from the same entropy root
at `m/44'/60'/0'/1/{index}` — BIP-44's INTERNAL branch, deliberately disjoint from
`m/44'/60'/0'/0/{index}`, the EXTERNAL branch any real account on this mnemonic would use,
so an exit sender can never collide with one of the wallet's own addresses. The unshield
note lands on that sender and the same UserOperation's call data unwraps the WETH and
forwards native ETH to the recipient — one atomic transaction, no separate forwarding tx.
`index` is a monotonically increasing counter persisted under `RAILGUN_STATE_DIR` (see
below): it must survive app relaunches. A reset counter restarts at 0 and then re-walks the
whole sequence of already-published senders — not one lost exit but every subsequent one — and
because the counter is bound to the machine rather than to the seed, restoring the same
entropy on a second machine does this by construction. See `src/exit_index.rs` for the full
reasoning.

Because the sender is **derived, not random**, a stranded exit is recoverable: if delivery
reverts after the unshield already executed during paymaster validation, or the bundler's
response to `eth_sendUserOperation` is lost, re-deriving the sender at the reported index
locates the funds. `ExitError::DeliveryReverted` / `BundlerRejected` carry the index +
sender for exactly this reason — the app must never discard them.

> **Root coupling (security note).** The RAILGUN shielded account and every exit sender are
> derived from the same BIP-39 mnemonic (entropy root): the account at `m/44'/1984'/…` /
> `m/420'/1984'/…`, each exit sender at `m/44'/60'/0'/1/{index}`. A leak of the
> entropy root compromises the shielded funds AND every exit sender derivable from it —
> though those senders hold funds only transiently, for the span of one in-flight exit.
> (The Kernel/passkey account is unaffected — it is not derived from this mnemonic.)

## From the macOS app

`/shield 0.01` and `/unshield 0.01 to 0x…` are available as slash commands (with
autocomplete) and as LLM-callable tools in the chat layer via `WalletToolLayer`;
`key=value` forms are also parsed. Shield builds a Kernel `execute` UserOp signed with the
Secure Enclave passkey (`prepareShield` → `executeBatch`); unshield requires device-owner
authentication, then calls the sidecar's async `unshield` and polls `unshieldStatus` — the
exit is sponsored by RAILGUN's privacy paymaster and submitted by a public bundler, so the
user needs no gas of their own — showing a submitted→confirmed card while it refreshes the
shielded balance until it settles. A Max control fills the composer with `maxValueWei` and
shows the "you will receive" breakdown (treasury fee + gas reserve) from
`receivableAtMaxWei` / `reserveWei`. `RailgunHelperClient` is the typed Unix-socket
JSON-RPC client (mirrors the `wallet-node` transport).

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
cargo build                  # railgun-helper (one binary; syncs to head, no fork cap)
cargo test --lib             # unit tests (secret/fd-5 parse, key + exit-sender derivation,
                             # RPC auth/round-trip, async job state, fee/reserve arithmetic)
cargo clippy --lib --bins
```

## End-to-end (the acceptance check)

Shields native ETH, then runs several **async** unshields on an **anvil fork of Sepolia**,
each exiting through RAILGUN's privacy paymaster as a sponsored UserOperation submitted by
a **local Alto bundler** — a public bundler cannot see an anvil fork, so the fixture brings
one up itself (`npx --yes @pimlico/alto@0.0.20`, or `$LOCAL_WALLET_ALTO_BIN` if set; there
is no skip path). It spawns **only the helper** via fd-5 (no child of its own), and asserts:
the recipient's **native-ETH** delta at each exit (the requested amount minus RAILGUN's
unshield fee); that the paymaster's own EntryPoint deposit strictly falls across every exit
while the ephemeral sender holds zero native ETH before and after (proof the gas came from
the paymaster and from nothing of ours); and that each exit's sender is the address the
entropy root derives at the index the sidecar reported (rotation + recoverability). Needs
`foundry` (anvil), Node/`npx` on `PATH` (for Alto, unless `LOCAL_WALLET_ALTO_BIN` is set),
and outbound network (RAILGUN Subsquid indexer + a one-time Groth16 circuit-artifact
download).

**Pinned at fork block `11011021`** — NOT `10822990`, which the pre-paymaster fixture used:
RAILGUN's privacy paymaster and fee adapter have no deployed code at that height (verified
via `eth_getCode`), so the entire paymaster path is unreachable there. `11011021` is the
block upstream Kohaku's own paymaster fork test pins, is Subsquid-indexed, and has both
contracts deployed with the paymaster holding sponsorable EntryPoint deposit.

**Measured proving cost** (circuit `railgun/01x03` — the shape a paymaster exit actually
proves: unshield note + fee note + change): **8.45s cold, 5.01s warm** per proof, so a
typical two-proof exit takes **~13.5s**. The SDK's fee-convergence loop was observed
consuming 2, 3, 4, and **5 of its 5 rounds** on an idle fork with flat gas (convergence
needs the new fee estimate ≤ the previous one AND within 1%, and ordinary estimate jitter
makes that `≤` close to a coin flip per round) — a convergence failure therefore retries
the whole exit **once, unconditionally**, rather than gating the retry on gas movement.
The fixture has a hard 45-minute wall-clock cap so it can never hang, but a full run
(shield, three exits, first-run circuit-artifact download, inclusion waits) is on the order
of several minutes, not seconds.

```bash
RPC_URL_SEPOLIA="https://sepolia.infura.io/v3/<key>" ./scripts/e2e-fork.sh
```

Live-Sepolia is possible by pointing the binary at a real RPC — no funded broadcaster
needed, just RPC access, since the paymaster and a public bundler cover gas — but the fork
is the default check.

## Key facts / caveats

- **Unshield delivers native ETH.** The Kohaku crate's unshield only delivers the wrapped
  base token (WETH), so the same UserOperation that unshields to the ephemeral sender also
  `WETH.withdraw()`s (unwrap) and forwards **native ETH** to the recipient — one atomic
  transaction, minus RAILGUN's unshield fee.
- **The bundler URL is hardcoded and keyless by design**
  (`https://public.pimlico.io/v2/{chain_id}/rpc`). An API key in the URL would be a stable
  identifier attached to every exit, so a keyed endpoint would be *worse* for privacy than
  the free public one — there is no production override. `RAILGUN_BUNDLER_URL` exists only
  under the `fork-sync` test feature, so a fork fixture can point at a local Alto; a
  production build has no override path at all.
- **POI is OFF on the fork** (`.with_poi()` not called). POI validity comes from the live
  `ppoi.fdi.network` aggregator, which validates against real chain state — a note freshly
  shielded on a local fork can never become POI-`Valid`. Without POI a note is spendable
  right after sync (see the crate's own `transact_utxo.rs`). POI-on is a live-Sepolia
  concern, out of scope here.
- **`fork-sync` feature** caps Subsquid sync at the fork block (Subsquid indexes *live*
  Sepolia) and enables the `RAILGUN_BUNDLER_URL` override above; required for the e2e, off
  for live deployments.
- Kohaku `railgun` dep is pinned to rev `877026e…`; the `js` feature is never enabled.
- **Config:** the one secret (RAILGUN entropy) arrives over the fd-5 spawn contract (see
  above); the env-provided `RAILGUN_ENTROPY_HEX` remains a standalone/dev fallback only.
  Remaining knobs are env: `RAILGUN_RPC_URL` / `LOCAL_WALLET_PRIVACY_RPC_URL`,
  `RAILGUN_SOCKET`, `RAILGUN_TOKEN`, `RAILGUN_FORK_BLOCK` (fork-sync only). `RAILGUN_STATE_DIR`
  holds the per-exit rotation counter (`<state_dir>/exit-index`) and **must be a persistent
  directory** — the app points it at its own Application Support dir; losing or resetting it
  reuses the whole published sender sequence, not just one. The counter is per-machine, not
  per-seed, so a restore onto a second machine reuses it too. There is no broadcaster key:
  every exit sender is derived from the entropy at spend time, never stored separately.

## License

MIT OR Apache-2.0.
