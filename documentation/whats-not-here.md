# What's Not Here

This page lists features that are commonly expected in ERC-4337 user agents and Ethereum wallets but are NOT in Local Wallet today. Each item names what's missing, why it's missing, and (if applicable) what would have to change to add it.

If you're forking, also read [`forking-for-your-wallet.md`](forking-for-your-wallet.md). If you want the design rationale for what *is* here, read [`architecture.md`](architecture.md).

## Paymaster support

**Why missing:** V1 scope explicitly excludes sponsored transactions to keep the threat model small (no third-party signer dependency, no paymaster trust assumption, no off-chain rate-limiting service). Surfaced as `BundlerPolicyInvariants::reject_paymaster = true` in `wallet-bundler/src/policy.rs`.

**What it would take:** Set `reject_paymaster: false` in your policy invariants, plumb paymaster fields through `simulateValidation`, allowlist a set of trusted paymasters with chain-scoped code-hash pins, audit the `funding.rs` shortfall logic so paymaster-funded operations don't trip `INSUFFICIENT_SMART_ACCOUNT_BALANCE`. The trust model expansion is the larger question — paymaster signers, throttling rules, stake requirements.

## Multi-chain at runtime

**Why missing:** The daemon picks one chain at startup. Multi-chain would change the request routing layer (which chain is a request for?), the SQLite schema (per-chain tables or chain-tagged rows), the audit/repair surface (per-chain reports), and the bundler EOA model (one EOA shared across chains, or one EOA per chain).

**What it would take:** A meaningful re-architecture. Track as Direction C in the open-source-readiness brief; not on the V1 roadmap.

## Multiple account profiles in one daemon

**Why missing:** `KERNEL_V3_3_0_PROFILE` is a single-valued constant. Supporting multiple account shapes simultaneously means runtime profile dispatch (which profile does this UserOp's sender match?), per-profile allowlists, per-profile policy.

**What it would take:** A profile registry, profile selection in inbound requests (or sender-based detection), per-profile fork tests. Worth doing if the wallet ever supports both Kernel and Safe accounts in the same install.

## Signed-manifest runtime allowlist promotion

**Why missing:** `wallet-bundler::manifest` has the verification scaffolding (Ed25519, 30-day max lifetime, denylist precedence), but runtime promotion is disabled in non-debug builds because no production trust roots are embedded. The static allowlist (per-chain pinned code hashes) is the only allowlist consulted at runtime today.

**What it would take:** A signing operation (who signs new allowlist additions, when, under what review), a key custody decision (where the signing key lives, how it's rotated), a deployment story for trust roots (how the daemon learns which public keys are valid signers).

## Recovery after Secure Enclave / WebAuthn key loss

**Why missing:** Out of V1 scope. Hardware-bound keys are non-exportable by design — that's the whole point of the Secure Enclave. If the user loses their Mac without having backed up their wallet via some other channel, the funds in their smart account are unrecoverable from the Mac alone.

**What it would take:** A separate recovery scheme — social recovery (threshold of guardians can rotate the validator), seed-phrase backup of a *recovery* key that's separate from the Secure Enclave signing key, or a hardware-secured external backup. Each is its own product surface; none are simple add-ons.

## Generic ERC-7579 module enumeration

**Why missing:** The Kernel allowlist pins one validator (WebAuthn) and one root validator id. Generic module enumeration — executors, hooks, fallbacks — is not in scope. The daemon refuses any UserOp whose Kernel account uses unrecognized modules.

**What it would take:** A trust model for arbitrary modules. Today the model is "the validator is the one we pinned." A generic-modules wallet has to answer: which executors are safe, which hooks are safe, which fallbacks are safe — and that's policy work, not just code.

## ERC20 / batch / delegate execution paths

**Why missing:** Only ETH transfer is fork-tested via `tests/mainnet_fork_kernel.rs`. Other execution paths (ERC20 transfers, batched calls via ERC-7579, delegate executions via Kernel's executor modules) are not exercised against deployed bytecode. They may work — they may not.

**What it would take:** Additional fork-test fixtures for each execution shape, plus policy and funding rules that account for token-denominated value, batch gas accounting, and delegate-call security implications.

## Production Keychain access-group entitlement validation

**Why missing:** The daemon's current development path uses the non-access-group Keychain fallback. Access-group flows require a paid Apple Developer Program account and provisioning work that hasn't been done end-to-end. The `tools/keychain-spike/` exists to validate the entitlement chain when an Apple account is available.

**What it would take:** Apple Developer Program setup, entitlement plumbing in `project.yml`, end-to-end packaging validation, signed `.app` testing across machines.

## Notarization

**Why missing:** Demo builds are not notarized. The packaged demo zip from `scripts/package-macos-demo.sh` is intended for direct download, not Mac App Store distribution.

**What it would take:** A notarization step in the package script, an Apple Developer ID for notarization, and probably an automation pipeline so it doesn't depend on a single developer's local credentials.

## A public mempool / shared bundler infrastructure

**Why missing:** This is a private bundler — it accepts UserOps from one source (the user's macOS app) and submits them on behalf of one user. There is no mempool, no P2P, no aggregator integration, no reputation system.

**What it would take:** A different product. Local Wallet is intentionally not a public bundler. If you want a public 4337 bundler, look at Pimlico, Stackup, or Alchemy's bundler service — that's their product surface.

## Cross-platform daemon (Linux, Windows)

**Why missing:** The daemon is Rust and would compile on Linux and Windows in principle, but the spawn-with-fd lifecycle (`posix_spawn` + fd-3/fd-4 + `getppid() == 1` orphan backstop) is POSIX-specific and the macOS app's Swift `CSpawn` shim is the only known integration. Windows would need a different lifecycle protocol.

**What it would take:** A cross-platform spawn protocol (probably a structured stdin/stdout JSON channel instead of fd-3/4), a Windows-equivalent of the fd-4 alive pipe, a lifecycle test harness that runs on each platform. Surfaceable but not currently a product priority.
