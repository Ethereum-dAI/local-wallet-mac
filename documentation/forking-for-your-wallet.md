# Forking Local Wallet For Your Wallet

This is a worked example. It walks through retargeting the daemon stack as if you wanted to ship a *Safe accounts on Base* variant of Local Wallet, since that's the most common shape of fork. The same pattern applies to Biconomy/MetaMask Smart Account variants, to a different Kernel build, to Optimism instead of Base, etc.

If you're forking, you should also have read [`architecture.md`](architecture.md) — that explains *why* each of these choices exists.

## What stays

These pieces of the daemon stack are not specific to Kernel WebAuthn or to mainnet/Sepolia. You can pick them up unchanged:

- **Verified chain reads via Helios** — `wallet-chain` provides the `ChainAdapter` trait, the `HeliosChainAdapter`, the offline-fallback chain, the stateOverride smoke check, and the `MockChainAdapter` for tests. None of this knows about ERC-4337 or Kernel.
- **Bundler EOA management** — `wallet-node` admin RPCs (`wallet_beginAdminAction`, `wallet_installBundlerEOA`, `wallet_rotateBundlerEOA`, `wallet_deleteBundlerEOA`) and the in-RAM signing path. The privacy/security boundary (durable copy in the parent's Keychain, daemon RAM-only, single-use challenges) is account-shape-agnostic.
- **SQLite store and audit/repair** — `wallet-node-store` schema and the closed `wallet_repairStore` action set don't depend on the account profile.
- **Watcher and receipt reconciliation** — `wallet-bundler::watcher` (`reconcile_once`, `eligible_replacement_candidate`) and the daemon's background watcher loop work the same against any deployed account.
- **Spawn-with-fd lifecycle** — `wallet-macos/Sources/Spawn/` and `wallet-node/src/ready.rs`. Fd-3 ready / fd-4 alive / `getppid() == 1` backstop is OS-level, not protocol-level.

## What changes

### 1. The `KernelProfile` becomes a `SafeProfile`

The single source of truth for account-shape pins is `rust-core/crates/wallet-bundler/src/profile.rs`. `KERNEL_V3_3_0_PROFILE` is a `KernelProfile` const that bundles factory/implementation/validator addresses and per-chain code-hash arrays. Replacing it for Safe means:

- Defining a `SafeProfile` (or repurposing `KernelProfile`'s field set if Safe's structure maps cleanly — Safe accounts have a singleton, a fallback handler, and module addresses; the field names will differ).
- Pinning the Safe singleton, the proxy bytecode, and any module code hashes per chain you support.
- Updating the allowlist resolver in `wallet-bundler/src/allowlist.rs` to call your `validate_safe_*` helpers instead of the `validate_kernel_*` helpers.

`wallet-addresses` is the small crate that exports the static address constants. Add your Safe addresses there, then consume them from `profile.rs`.

### 2. The signature scheme

`wallet-signature` is currently WebAuthn-specific. If your Safe variant uses ECDSA over the EntryPoint hash with a Safe domain separator, you'll need:

- A new signing-message builder that does *not* go through WebAuthn's `authenticatorData || sha256(clientDataJSON)` ceremony.
- A new ABI-encoder for the signature shape Safe expects (typically the EIP-712 Safe domain).
- The corresponding FFI surface in `wallet-ffi` if your Apple/iOS app needs to sign in-process. Today the FFI exports five buffer-returning helpers; you'd add equivalents for your scheme and remove the WebAuthn-specific ones.

For a Kernel-with-different-validator fork (e.g., a Kernel ECDSA validator instead of WebAuthn), the change is much smaller: `wallet-kernel` stays generic, and you swap the validator pin in `KernelProfile.webauthn_validator` for an ECDSA validator address.

### 3. The chain set

`SupportedChain` in `wallet-bundler/src/profile.rs` is currently `Mainnet | Sepolia`. Adding Base means:

- Add a `Base` variant returning chain ID 8453 from `chain_id()`.
- Update `from_chain_id()` to recognize 8453.
- Update `wallet-chain` config to accept Base's execution + consensus RPC endpoints. **Note**: Helios's L1 light client model assumes you're tracking the Beacon chain. Base is an L2 with its own state; running a verified-reads client against Base means either an L2 light client (different protocol) or accepting that L2 reads are not consensus-verified the same way. Document the trade-off explicitly for your fork.
- Pin Safe singleton + module code hashes on Base in your `SafeProfile`.

### 4. The fork-test fixture

The canonical proof that the daemon does what it claims is `rust-core/crates/wallet-node/tests/mainnet_fork_kernel.rs`. It:

- Spins up Anvil against a mainnet fork at a pinned block.
- Validates the pinned Kernel bytecode is what we expect at the deployed addresses.
- Constructs a deterministic UserOp, signs it via the FFI's WebAuthn ABI, runs `simulateValidation` via state override, submits a real `handleOps`, and asserts the receipt.
- Runs a 50-send bundler-EOA flatness check.

Retargeting it for Safe-on-Base means:

- A new fork-test fixture (`tests/base_fork_safe.rs` or similar) that forks Base at a chosen block, validates Safe singleton bytecode, signs a Safe-shaped UserOp, asserts the same end-to-end path.
- An archive-capable Base RPC (the pinned block has to be retrievable). Document the env var (e.g., `BASE_RPC_URL`).
- A retargeted `scripts/run-kernel-mainnet-fork-check.sh` equivalent that knows which RPC and which block to use.

This fixture is the load-bearing acceptance gate. If your fork passes default `cargo test --workspace` but fails the fork fixture, the fork fixture is right.

## What you'd want to discuss with us

These are open design questions where we'd be glad to align on direction before you fork — open an issue:

- **Signed-manifest promotion.** Today the manifest scaffolding exists in `wallet-bundler::manifest` (Ed25519 verification, 30-day max lifetime, denylist precedence) but runtime promotion is disabled in non-debug builds. If your fork wants live allowlist updates, the trust-root deployment story is the question to settle.
- **Multi-chain at runtime.** The daemon picks one chain at startup. If your wallet wants to talk to Mainnet *and* Base from the same daemon session, that's a real re-architecture (per-chain Helios instance, per-chain bundler EOA scoping, request routing). Not currently supported and not trivially shimmable.
- **Paymaster support.** If your wallet wants sponsored transactions, expect a meaningful expansion of the trust model. The path is in `whats-not-here.md`.
- **Recovery flows.** Hardware-bound keys can't be exported by design; recovery is a separate product surface we punted on. If your fork wants social recovery or a threshold scheme, that's its own design.

Forks that go through any of these without coordination are likely to hit the same dead ends we did.
