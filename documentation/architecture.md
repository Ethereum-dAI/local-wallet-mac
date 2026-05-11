# Architecture

This document explains *why* Local Wallet's daemon is shaped the way it is. Per-crate READMEs cover *what* each crate does and what's stable; this is the rationale layer on top.

The audience is a developer who has already read the root `README.md` and understands the high-level layout (macOS app + Rust daemon + Swift bridge). If you're trying to fork this for your own opinionated wallet, also read [`forking-for-your-wallet.md`](forking-for-your-wallet.md). For things we explicitly chose not to do, read [`whats-not-here.md`](whats-not-here.md).

## Why a daemon (not a library)?

The signing crypto is genuinely a library — `wallet-signature` and `wallet-kernel` are pure, synchronous, generic over addresses, and called in-process from Swift via the FFI. That's the right shape for code that takes deterministic inputs and produces deterministic outputs.

Everything else needs to live somewhere with a real lifecycle: a long-running process that watches for receipts in the background, persists nonce reservations across crashes, holds the bundler EOA secret in process RAM (and only in RAM), and serializes admin actions behind a single-use challenge. None of that fits inside a library called from Swift on the request path. A daemon gives us:

- **Independent lifecycle.** The daemon can outlive a single user action (receipt watching, store reconciliation) without forcing the app's UI thread to be alive.
- **A clean security boundary.** The macOS app talks to the daemon over an authenticated JSON-RPC channel; the daemon refuses unauthenticated callers; admin actions need a challenge issued out-of-band. This is a defendable model regardless of what calls the daemon.
- **Language-agnostic surface.** The JSON-RPC contract documented in `rust-core/crates/wallet-node-api/README.md` is the public surface. Today only Swift calls it; tomorrow a CLI tool or a different platform's app could.
- **Crash isolation.** A panic in the daemon doesn't take the macOS app down with it (and vice versa). The fd-3/fd-4 spawn contract gives us deterministic process teardown semantics from either side.

The cost is a process boundary on the read/write paths. For a wallet that submits a transaction every few seconds at most, this is negligible.

## Why Helios (not trusted RPC, not a full node)?

The privacy/sovereignty pitch is "you don't have to trust your RPC." The naive way to read Ethereum state — `eth_getBalance`, `eth_call`, `eth_getTransactionReceipt` — points at a public RPC provider and trusts what comes back. If that provider is compromised, censoring, or just buggy, the wallet acts on a wrong picture of the chain and may sign a transaction that doesn't reflect what the user thinks they're authorizing.

A full node fixes this but is infeasible on a user's laptop: hundreds of GB of state, days to sync, ongoing bandwidth.

A light client like Helios sits between: it tracks the consensus chain (Beacon chain sync committee signatures), knows the current finalized state root, and verifies execution-layer reads by requesting Merkle proofs against that state root. The execution RPC can lie about a value but cannot forge a Merkle proof against a state root signed by ~hundreds of thousands of validators.

The trade-offs we accept:

- **A bundled checkpoint** ages out. If the bundled checkpoint is too old and there's no on-disk Helios DB, `wallet-node` falls back to an offline-chain mode where authenticated control APIs (status, lifecycle, audit/repair) still work but verified reads and simulation-dependent sends are degraded. We fail closed rather than serving unverified data.
- **Helios is pinned.** `helios-ethereum` and `helios-core` are pinned to revision `204c998a927348e1c000a664f08d5b37b1b0d924`. We don't routine-bump it. Bumping requires re-running both the real stateOverride smoke and the mainnet-fork Kernel fixture before merging — see `rust-core/crates/wallet-chain/README.md`.
- **A hostile pair (execution RPC + consensus RPC) colluding around a stale checkpoint** is a residual risk; documented in the [Threat Model](../rust-core/crates/wallet-node/README.md#threat-model).

## Why fail-closed simulation?

Before submitting a UserOp, the daemon runs `simulateValidation` against the EntryPoint via state override — it deploys a "simulations runtime" contract into a virtual call context and runs the actual EntryPoint validation logic against it. If the validation would revert on-chain, we don't submit.

State override is a powerful but non-standard JSON-RPC capability. Different providers implement it differently (or not at all). Helios supports it, but its semantics depend on the underlying execution RPC's `eth_call` behavior.

We protect this with a one-shot "smoke check": at startup, the daemon replaces WETH bytecode at a fixed mainnet address via state override and confirms the resulting storage behavior matches expectations (`wallet-chain/src/smoke.rs` → `run_smoke_test`). If the smoke check fails, the daemon refuses to accept any simulation-dependent send for the rest of its lifetime.

The reasoning is asymmetric: a false negative on simulation (reject a UserOp that would have succeeded on-chain) is a usability problem; a false positive (accept a UserOp the EntryPoint would have rejected) burns gas and confuses users. We pay for the conservatism.

The smoke check is one-shot rather than periodic because the daemon is session-scoped — it's spawned per macOS app session, lives a few hours at most, and dies with its parent. A long-running service would need periodic re-validation.

## Why bundler-EOA-in-RAM with app-side Keychain durability?

The bundler EOA is the on-chain payer for the user's UserOps. Its private key is real money: anyone with it can drain the EOA's balance and submit operations that look like the user's wallet wanted them.

The split:

- **The macOS app owns the durable copy** in its Keychain, gated by user presence (biometric). Rotation, install, and delete flows all originate from the app; the user authenticates locally; the secret is unwrapped only in the app process.
- **The daemon holds the secret only in process RAM**, received over the authenticated transport at install/rotate time. Status and read RPCs never return private key material. When the daemon dies, the in-memory secret is gone.

Why not store it in the daemon's SQLite store? Three reasons:

1. **No process-restart trust assumption.** A daemon that finds a bundler secret on disk has to assume the file system has not been tampered with since it last wrote. We don't want that assumption — the durable trust root is the macOS Keychain, not the daemon's filesystem.
2. **A memory snapshot of a running daemon contains the secret** — that's an honest residual risk we document in the threat model — but a *crashed* daemon contains nothing.
3. **The admin handshake is the only writable path.** `wallet_installBundlerEOA`, `wallet_rotateBundlerEOA`, and `wallet_deleteBundlerEOA` require a single-use challenge from `wallet_beginAdminAction` bound to `(action, ownerScope, chainId, keyRef)`. The daemon cannot construct an admin action on its own — that's the macOS app's job, gated behind a user-presence check.

The cost is that the daemon must re-receive the secret every time it restarts. For a per-spawn daemon, that's once per macOS app session.

## Why ERC-4337 v0.7?

v0.7 is the maturity baseline — well-deployed, well-audited, supported by the audited Kernel build we pin. v0.8 has shipped (it switches to EIP-712 typed-data hashing, primarily to integrate with EIP-7702 EOAs-with-code), but moving to it is a real protocol bump:

- The UserOp hash format changes from `keccak256(abi.encode(...))` to EIP-712 typed data with `\x19\x01 || domainSeparator || structHash`.
- The pinned EntryPoint address changes (new deployment).
- Kernel ships a v0.8-compatible validator that verifies against the new hash.
- Our `wallet-bundler::simulations` embeds the v0.7 EntryPointSimulations runtime as bytecode (`entry_point_simulations_runtime.hex`); v0.8 has its own runtime.
- The mainnet-fork Kernel fixture would need to be redone against v0.8 deployments.

We surfaced this as `EntryPointVersion::V07` in `wallet-bundler/src/profile.rs` so the migration is a "add a variant" task rather than a "find every hardcoded reference" task. Today only V07 is supported. The strategic argument for moving — primarily EIP-7702 onboarding — is real but doesn't apply to V1's scope, where we onboard via Secure Enclave and predicted Kernel addresses, not by upgrading existing EOAs.

## Why Kernel WebAuthn over alternatives?

Three considerations drove the choice:

- **The Secure Enclave gives us hardware-bound P-256 keys.** A wallet that uses Secure Enclave can promise the user "your key cannot be exported, even by us, even by malware running as your user" in a way that no software-key wallet can. This is a meaningful claim for the privacy/sovereignty pitch.
- **WebAuthn is the on-chain shape that maps to P-256 signatures.** The Kernel WebAuthn validator decodes a 6-field ABI struct `(bytes authData, string clientDataJSON, uint256 responseTypeLocation, uint256 r, uint256 s, bool usePrecompiled)` and verifies the P-256 signature over `sha256(authenticatorData || sha256(clientDataJSON))`. This is the validator that lets a Secure Enclave key sign for an ERC-4337 account.
- **RIP-7212 makes it gas-cheap.** The precompile at `0x...0100` verifies P-256 in ~3.4k gas; the fallback Daimo P256 verifier at `0xc2b78104907F722DABAc4C69f826a522B2754De4` is ~330k gas. The validator's `usePrecompiled: bool` field picks between them. We allowlist both (chain-scoped), with the daemon checking that the Daimo verifier's deployed code matches the pinned hash — see `wallet-bundler/src/allowlist.rs`.

We chose Kernel specifically (over Safe, Biconomy, or a custom 4337 account) because it has audited WebAuthn validator support, a deterministic factory, and a CREATE2 address derivation we can precompute in the FFI before the account is even deployed. Alternatives could work but would cost re-implementing those primitives.

## Why one-op bundles, no paymaster, nonce key zero, mainnet+Sepolia only?

These are the V1 scope decisions, surfaced as `BundlerPolicyInvariants::LOCAL_WALLET_V1` in `wallet-bundler/src/policy.rs`:

- **One op per bundle.** A real public bundler aggregates UserOps from many users to amortize submission gas. Local Wallet bundles only the user's own ops. Aggregation would mean trusting the relayer to mix in operations we don't control — a different security posture.
- **No paymaster.** A paymaster is a third-party signer that says "I'll pay for this UserOp." Including one means trusting the paymaster's signing infrastructure, rate limiting, and stake — a meaningful expansion of the trust model. V1 uses an app-owned bundler EOA (the user's own money) for gas; we revisit paymasters when we know which trust model we want.
- **Nonce key zero.** Kernel v3's nonce is `(validation mode, validation type, validation id, parallel key, sequence)`. Parallel keys allow concurrent UserOps from the same account; nonce key zero keeps things sequential and reasoning straightforward. Surfaced as `BundlerPolicyInvariants::required_nonce_key`.
- **Mainnet + Sepolia.** Surfaced as `SupportedChain` (`Mainnet`, `Sepolia`). Adding a chain means: pinning new code hashes for the Kernel factory/impl/validator on that chain (they may differ if deployed by different addresses), updating the allowlist, validating against deployed bytecode. Not free — every chain is a new attack surface.

## Why SQLite + audit/repair (not "operator edits the DB")?

The daemon persists UserOps, raw submitted transactions, nonce reservations, receipts, bundler EOA records and lifecycle, and audit history. It uses SQLite via `rusqlite` (bundled), wrapped in an async actor that keeps blocking SQLite work off the request path.

The honest alternative for fixing inconsistent state (a UserOp that was submitted but whose tx hash never landed; a nonce reservation orphaned by a crashed watcher) is "manual SQL." We chose against it for two reasons:

- **The daemon's invariants are non-trivial.** UserOp state, transaction state, nonce state, and receipt state are linked. A naive `UPDATE` that "looks right" can leave the store in a state the daemon then misinterprets. The audit/repair surface — `wallet_auditStore`, `wallet_auditHistory`, `wallet_auditReport`, `wallet_repairStore` — encodes the legal transitions explicitly.
- **Repair actions are gated to specific finding codes.** `markSubmittedTxFailed`, `abandonNonceReservation`, `clearTentativeReceipt`, `markTxDropped`, `rebuildUserOpFromReceipt` — five actions, each of which only applies when the audit step has produced a finding code that matches. Operators don't compose arbitrary fixes; they pick from a closed menu.

Operators reach this surface through `wallet-node admin ...` (a CLI subcommand of the daemon binary that talks JSON-RPC over the same authenticated transport). The macOS app could expose it too.

## Why the spawn-with-fd lifecycle?

`wallet-node` runs as a child of the macOS app. The lifecycle contract:

- The app spawns the daemon via `posix_spawn` (through the `CSpawn` shim — see `wallet-macos/Sources/Spawn/`), pre-installing two pipes:
  - **fd 3** is the daemon's "ready" write end. The daemon writes a JSON object with `token`, `apiVersion`, `daemonSpawnProtocol`, `socketPath`, `httpAddr` to fd 3 so the parent learns it's ready and gets the bearer token.
  - **fd 4** is the daemon's "alive" read end. The daemon watches it for end-of-file: when the parent closes its write end (including by crashing), the daemon shuts down.
- As a backstop, the daemon also exits if its parent process becomes init (`getppid() == 1`), so an orphaned daemon dies even if the alive pipe is bypassed.

Why not run as a launchd agent, or a service the user starts manually?

- **Single-spawning-parent fits the threat model.** The bearer token never leaves the spawning parent. The macOS app is the only authorized caller. A long-running service would need a richer auth model (per-client tokens, audit log of who called what), which we explicitly defer.
- **Process death is the cleanup story.** When the user closes the app, the daemon dies. No leaked SQLite locks, no orphaned bundler EOA secret in RAM, no dangling sockets.
- **The alive-pipe pattern is a deterministic detector.** Polling for parent liveness is racy; an alive pipe is the OS-level guarantee that EOF arrives when (and only when) the parent's write end closes.

The spawn protocol version (`daemonSpawnProtocol`) is reserved in the ready JSON so future fd-numbering or framing changes have a migration story. Today the value is `1`.

## What the privacy/security boundary actually defends

Putting the layers together:

- **Private keys never cross the FFI.** The user's signing key (Secure Enclave) and the bundler EOA secret (Keychain) live entirely in Swift. Rust sees public coordinates, hashes, and 64-byte `(r, s)` signature outputs. The C ABI in `wallet-ffi` enforces this by simply not exposing key material — there's no way to ask Rust for a private key because no function returns one.
- **The daemon's authenticated transport is the only outside surface.** Bearer token via `--print-ready` (HTTP) or fd-3 (Unix socket). Method dispatch refuses unauthenticated calls. Admin actions require an additional single-use challenge. Non-loopback HTTP binds require an explicit `--allow-public` opt-in (see `wallet-node/src/transport/http.rs`).
- **Verified reads from Helios.** The daemon's view of the chain is consensus-checked.
- **Fail-closed simulation.** State-override smoke gate; if it fails, simulation-dependent sends are rejected.
- **Closed audit/repair surface.** Operator state corrections are constrained to a documented set of actions.

What none of these layers defend against:

- A compromised macOS app. It holds the bearer token, the durable bundler EOA secret, and the user's biometric gate.
- A compromised parent process more broadly.
- A second user on the same machine who reads the bearer token from logs, shell history, or process arguments.
- A hostile execution+consensus RPC pair colluding around a stale checkpoint.
- A memory snapshot of a running daemon (the bundler EOA secret is in RAM).

These are documented honestly in the [Threat Model](../rust-core/crates/wallet-node/README.md#threat-model). The point of writing them down is to set the right expectations: Local Wallet's safety claim is "we don't make trust assumptions you can't audit," not "we defend against everything."

## What's not here

For features Local Wallet explicitly does not implement and why, see [`whats-not-here.md`](whats-not-here.md).
