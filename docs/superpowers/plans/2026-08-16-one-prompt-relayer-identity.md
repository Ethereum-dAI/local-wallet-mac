# One-Prompt Relayer Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate repeated onboarding biometrics while keeping relayer identity selection fail-closed: fresh setup uses zero prompts, resumed setup uses at most one, and passive app activity uses none.

**Architecture:** Keep the relayer secret in the existing `.userPresence` Keychain item and move public identity into a separate non-interactive Data Protection Keychain record. Add an immutable, append-only per-chain selection journal so passive code accepts only the app-authorized active or pending identity, never a key selected solely by wallet-node or cached settings. Every privileged operation re-derives identity from the protected secret with one caller-owned `LAContext` and requires exact public-store, journal, and daemon agreement.

**Tech Stack:** Swift 6, Security.framework, LocalAuthentication, CryptoKit, Swift Testing, existing wallet-node JSON-RPC and inherited-FD bootstrap.

## Global Constraints

- Preserve the user-owned signing changes in `LocalWallet.xcodeproj/project.pbxproj`; do not regenerate or edit it.
- Put new production storage and authority types in existing Xcode-enumerated files. New SwiftPM test files are safe.
- Never use UserDefaults, cached addresses, or daemon status alone as identity authority.
- Never put the protected secret into normal daemon launches.
- Never auto-prompt during launch, focus changes, refresh, or passive funding display.
- Public identity and journal records are insert-only. Exact duplicates are idempotent; conflicts fail closed.
- Historical journal records remain hash-validated, but only the head's active and pending references require live public identity records. This permits retired-key deletion without invalidating history.
- Active or pending per-key deletion is blocked outside the full reset/recovery workflow.
- Use dependency-injected Keychain clients in behavior tests. Source-string audits are secondary only.

---

## Task 1: Add prompt-free immutable public identity storage

**Files:**

- Modify: `wallet-macos/Sources/WalletMacOSApp/BundlerKeyStore.swift`
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/VerifiedRelayerIdentityTests.swift`

- [ ] Add failing tests for canonical public identity encoding, exact duplicate insertion, conflicting duplicate rejection, malformed data, wrong key reference, and prompt-free query shape.
- [ ] Introduce an injectable `SecurityItemClient` with `add`, `copyMatching`, and `delete` operations.
- [ ] Add `RelayerPublicIdentityStore` using service `com.localwallet.bundler-eoa.public-identity` and account equal to canonical `keyRef`.
- [ ] Store `VerifiedRelayerIdentity` as canonical encoded data with `kSecUseDataProtectionKeychain = true`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and no access-control object.
- [ ] Make every read explicitly non-interactive with an `LAContext` whose `interactionNotAllowed` is true; treat `errSecInteractionNotAllowed` as a storage-policy failure rather than missing data.
- [ ] Use `SecItemAdd` only. On `errSecDuplicateItem`, reload and accept only an exact semantic match.
- [ ] Run `swift test --package-path wallet-macos --filter VerifiedRelayerIdentityTests`.
- [ ] Commit: `feat: add immutable relayer identity store`.

## Task 2: Add the append-only relayer selection journal

**Files:**

- Modify: `wallet-macos/Sources/WalletMacOSApp/BundlerKeyStore.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/OnDemandAuthenticationState.swift`
- Add: `wallet-macos/Tests/WalletMacOSAppTests/RelayerChainStateJournalTests.swift`

- [ ] Add failing tests for genesis, canonical digest, contiguous epochs, gaps, forks, duplicate epochs, bad previous digest, wrong chain, active/pending equality, exact concurrent append, conflicting append, second pending candidate, exact promotion, and rejection of historical-key revival.
- [ ] Define `RelayerChainState` with version, chain ID, epoch, 32-byte previous digest, optional active key reference, and optional pending key reference. Use a zero digest for genesis and allow an explicit empty/tombstone head after reset-style active deletion.
- [ ] Encode with sorted-key canonical JSON and hash with CryptoKit SHA-256.
- [ ] Add `RelayerChainStateJournal` using service `com.localwallet.bundler-eoa.chain-state` and account `v1:<chainID>:<epoch>`.
- [ ] Read all records non-interactively, sort numerically, and reject malformed accounts, gaps, forks, duplicate epochs, or broken digest linkage.
- [ ] Add pure transition policy for `genesis`, `beginRotation`, `promotePending`, and empty/tombstone transitions.
- [ ] Add `RelayerIdentityAuthority` that resolves head active/pending identities from the public store and never accepts a daemon-selected historical identity.
- [ ] Run `swift test --package-path wallet-macos --filter RelayerChainStateJournalTests`.
- [ ] Commit: `feat: add relayer selection journal`.

## Task 3: Make the protected BundlerKeyStore secret-only

**Files:**

- Modify: `wallet-macos/Sources/WalletMacOSApp/BundlerKeyStore.swift`
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/VerifiedRelayerIdentityTests.swift`
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/OnDemandAuthenticationAuditTests.swift`

- [ ] Add failing tests proving a fresh insertion performs no protected read, an existing item performs exactly one protected read with the exact caller context, and no nested identity query occurs.
- [ ] Stop writing `VerifiedRelayerIdentity` into `kSecAttrGeneric` for new protected items.
- [ ] Remove passive `verifiedIdentity(forKeyRef:)`, metadata updates, and `hasKey` probing from the protected service.
- [ ] Generate a candidate and call insertion-only `SecItemAdd` directly. Return the in-memory record when inserted; on duplicate, discard candidate bytes and read the winner once with the supplied `LAContext`.
- [ ] In one authenticated query request secret data and legacy attributes together. Derive the address, reject mismatching legacy metadata if present, then insert or exact-match the separate public record.
- [ ] Ensure delete receives the caller's authenticated context and never creates another implicit context.
- [ ] Run focused identity and authentication-audit tests.
- [ ] Commit: `fix: make relayer secret reads single prompt`.

## Task 4: Centralize provisioning and prove the prompt budget

**Files:**

- Modify: `wallet-macos/Sources/WalletMacOSApp/OnboardingProvisioningService.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/OnboardingView.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/AppModel.swift`
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/OnboardingProvisioningServiceTests.swift`
- Add: `wallet-macos/Tests/WalletMacOSAppTests/RelayerProvisioningPromptBudgetTests.swift`

- [ ] Add fakes that count protected reads and compare `LAContext` object identity.
- [ ] Add failing tests for fresh winner (zero reads), existing winner (one read), concurrent loser (one read of canonical winner), secret-only crash recovery, authentication cancellation, loaded-probe failure, locked-probe failure, idempotent retry, public conflict, and no ready publication before final readback.
- [ ] Refactor provisioning into one shared coordinator used by onboarding and dashboard reset.
- [ ] Flow: atomic protected insert/read winner, derive and insert public identity, loaded daemon probe, secret-free locked daemon probe, ensure exact journal genesis, then passive public/journal readback.
- [ ] Keep the generated record local to the task and discard it after registration. Do not store secret bytes in onboarding state, settings, or published model state.
- [ ] Reuse the one provisioning/reset `LAContext` for every protected operation and invalidate only after the full action completes.
- [ ] Correct failed-state UI so a verification failure does not falsely render successfully created keys as “Not created yet.”
- [ ] Run focused provisioning and registration tests.
- [ ] Commit: `fix: enforce relayer provisioning prompt budget`.

## Task 5: Bind passive dashboard state to app-owned authority

**Files:**

- Modify: `wallet-macos/Sources/WalletMacOSApp/AppModel.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/ChatDashboardView.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/BundlerGasStatus.swift`
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/BundlerGasStatusTests.swift`
- Add: `wallet-macos/Tests/WalletMacOSAppTests/PassiveRelayerIdentityResolverTests.swift`

- [ ] Add failing tests for stable exact binding, missing public record, missing journal, daemon-selected unauthorized key, wrong chain/address/key reference/lifecycle, compromise state, authorized pending state, promotion idempotence, and zero protected-store/auth-factory calls.
- [ ] Publish a verified relayer identity from `AppModel` only after journal selection, public lookup, and `RelayerIdentityBindingPolicy` all agree.
- [ ] Keep raw daemon status only for diagnostics and explicit migration routing; never expose its funding address as trusted without app-owned binding.
- [ ] Remove direct `BundlerKeyStore` identity lookup and `try?` error erasure from `ChatDashboardView`.
- [ ] Route all top-up/funding UI through the verified identity published by `AppModel`.
- [ ] Add an explicit `Verify bundler` action for completed legacy wallets with a coherent daemon key reference but missing public registry/journal. It authenticates once, reads/derives the secret, exact-binds daemon status, inserts the public record/genesis, and refreshes. It never auto-prompts.
- [ ] Run passive resolver and gas-status tests.
- [ ] Commit: `fix: bind passive relayer status to identity authority`.

## Task 6: Authorize privileged relayer reads from the journal

**Files:**

- Modify: `wallet-macos/Sources/WalletMacOSApp/AppModel.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/OnDemandAuthenticationState.swift`
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/OnDemandAuthenticationStateTests.swift`
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/OnDemandAuthenticationAuditTests.swift`

- [ ] Add failing tests proving only journal-active and exact daemon-retiring historical identities can be loaded; pending, retired, cached, or arbitrary daemon-selected identities are rejected.
- [ ] Before any protected read, validate the journal snapshot and exact daemon status.
- [ ] Reuse the action's one `LAContext` across all necessary protected reads.
- [ ] After each read, re-derive identity and require exact public record, journal authorization, and daemon binding before installing into wallet-node memory.
- [ ] Remove UserDefaults and daemon-key fallbacks from privileged key selection.
- [ ] Ensure top-up post-auth proof uses the same authority path.
- [ ] Run on-demand authentication suites.
- [ ] Commit: `fix: authorize relayer unlocks from journal`.

## Task 7: Make rotation retry-safe and app-authorized

**Files:**

- Modify: `wallet-macos/Sources/WalletMacOSApp/WalletNodeClient.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/AppModel.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/OnDemandAuthenticationState.swift`
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/WalletNodeClientDecodingTests.swift`
- Add: `wallet-macos/Tests/WalletMacOSAppTests/RelayerRotationCoordinatorTests.swift`

- [ ] Decode every pending-funding entry's EOA and key reference from the existing wallet-node response instead of discarding key references.
- [ ] Add failing tests for journal-before-install ordering, crash after journal append, lost install response, exact candidate reuse, exact activation/promotion, concurrent exact winner, conflicting candidate, and second-rotation rejection.
- [ ] Plan rotation from the journal head. If pending exists, retry that exact candidate; never generate another.
- [ ] For a new candidate, perform insertion-only secret/public creation and append pending state before daemon installation.
- [ ] Accept promotion only when daemon reports the exact authorized pending candidate active and the prior active key retiring or retired.
- [ ] Append promotion exactly once and reject any arbitrary historical or otherwise stored key.
- [ ] Run Swift rotation tests and focused Rust rotation tests.
- [ ] Commit: `fix: make relayer rotation authority retry safe`.

## Task 8: Enforce safe deletion and reset ordering

**Files:**

- Modify: `wallet-macos/Sources/WalletMacOSApp/WalletResetCleanup.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/AppModel.swift`
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/KeyLifecycleFixesTests.swift`

- [ ] Add failing tests for journal then public then protected deletion order and failure short-circuiting.
- [ ] Make relayer cleanup one fail-fast step: journal first, public identities second, protected secrets last with the existing authorized context.
- [ ] If journal or public cleanup fails, preserve protected secrets for explicit recovery.
- [ ] Block targeted deletion of active or pending identities outside full reset. Retired identity deletion removes public authority before secret material and leaves hash-valid history.
- [ ] Make reset use the shared provisioning coordinator for its replacement identity and require final journal/public/daemon agreement before bootstrap succeeds.
- [ ] Run key lifecycle and reset tests.
- [ ] Commit: `fix: order relayer authority cleanup safely`.

## Task 9: Verification gates and signed runtime acceptance

**Files:**

- Modify: `scripts/run-bundler-key-hardening-gate.sh`
- Add: `scripts/audit-local-wallet-auth-prompts.sh`
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/OnDemandAuthenticationAuditTests.swift`

- [ ] Replace the disproven “attributes-only means prompt-free” source audit with guards that passive code uses only the dedicated public store and that protected reads require a supplied context.
- [ ] Add deterministic prompt-budget tests: fresh 0 protected reads, existing/retry 1, passive 0, cancelled action no auto-retry, privileged action one shared context.
- [ ] Add a read-only log helper that summarizes Local Wallet/CoreAuthentication UI activations between explicit start/end timestamps. It must not claim to automate Touch ID.
- [ ] Run `swift test --package-path wallet-macos`.
- [ ] Run `swift test --package-path swift-bridge`.
- [ ] Run `cargo test --manifest-path local-wallet-daemon/Cargo.toml -p wallet-node --test integration_fd_e2e -- --include-ignored --test-threads=1`.
- [ ] Run focused wallet-node rotation tests and `cargo fmt --check`/`cargo clippy -D warnings` for touched Rust crates if Rust changes occur.
- [ ] Run `xcodebuild -project LocalWallet.xcodeproj -scheme LocalWalletApp -configuration Debug -destination 'platform=macOS' build` without changing the project file.
- [ ] Run `git diff --check` and a security diff review.
- [ ] Perform the signed physical acceptance pass after one warm build:
  - Fresh Create Keys: 0 authentication dialogs.
  - Existing-key Create Keys or Retry: exactly 1 dialog.
  - Dashboard launch, repeated focus changes, and refresh: 0 dialogs.
  - First privileged transaction: 1 authorization session.
  - Cancel onboarding authentication: no second prompt until explicit Retry.
- [ ] Record any unchanged pre-existing Rust failures separately; do not misrepresent focused green tests as a fully green workspace.
- [ ] Commit: `test: gate relayer identity prompt budget`.

## Completion Criteria

- [ ] Fresh setup reaches the funding screen with no biometric prompt.
- [ ] Existing/legacy setup recovery asks once at most.
- [ ] Passive app lifecycle never requests authentication.
- [ ] Dashboard and funding addresses require exact journal, public Keychain, and daemon agreement.
- [ ] Privileged actions derive and verify the protected secret under one explicit authorization session.
- [ ] Rotation cannot revive an old stored identity and retries the same pending candidate after interruption.
- [ ] Cleanup cannot leave passively trusted identity after protected-key deletion.
- [ ] Full Swift tests, relevant daemon tests, signed build, runtime prompt counts, and security review pass.
