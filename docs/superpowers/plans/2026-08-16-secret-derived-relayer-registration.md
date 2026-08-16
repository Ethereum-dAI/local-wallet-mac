# Secret-Derived Relayer Registration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure fresh onboarding and dashboard wallet reset register the newly created relayer with wallet-node before exposing the wallet, while returning every ordinary daemon launch to a secret-free locked state.

**Architecture:** Reuse wallet-node's existing trusted fd 5 secret bootstrap for a short-lived registration launch. A shared Swift service verifies the secret-loaded status, terminates that daemon, launches a second daemon with an explicit empty key list, verifies the same public identity is durable and locked, and terminates it. Onboarding and reset both call this service before publishing success; normal startup remains unchanged and prompt-free.

**Tech Stack:** Swift 6, Swift Concurrency, Security/LocalAuthentication, Swift Testing, Rust wallet-node integration tests, authenticated AF_UNIX wallet-node RPC.

## Global Constraints

- Do not add a daemon API that accepts an unproven public relayer address.
- Do not trust `UserDefaults` relayer address data as identity authority.
- Do not read protected relayer secrets during normal app launch, focus changes, or passive status refresh.
- Do not retain a secret-loaded registration daemon after setup.
- Reuse `RelayerIdentityBindingPolicy`, `WalletNodeDaemon.launch`, and the existing fd 5 payload rather than duplicating validation or transport.
- Do not modify or stage the developer's existing `LocalWallet.xcodeproj/project.pbxproj` signing changes.

---

## File Map

- `wallet-macos/Sources/WalletMacOSApp/WalletNodeDaemon.swift`: add the shared registration orchestrator and one-probe lifecycle helper.
- `wallet-macos/Sources/WalletMacOSApp/OnboardingProvisioningService.swift`: return the in-memory relayer record needed for immediate registration.
- `wallet-macos/Sources/WalletMacOSApp/OnboardingView.swift`: register before publishing key readiness.
- `wallet-macos/Sources/WalletMacOSApp/AppModel.swift`: register a reset-created relayer before dashboard bootstrap.
- `wallet-macos/Tests/WalletMacOSAppTests/RelayerBootstrapRegistrationTests.swift`: pure policy and two-probe orchestration regression tests.
- `wallet-macos/Tests/WalletMacOSAppTests/OnDemandAuthenticationAuditTests.swift`: source-order checks for onboarding/reset and preservation of prompt-free passive paths.
- `local-wallet-daemon/crates/wallet-node/tests/integration_fd_e2e.rs`: prove an fd-registered identity persists across an empty-key restart as active and locked.

---

### Task 1: Add and Test the Shared Registration Orchestrator

**Files:**
- Modify: `wallet-macos/Sources/WalletMacOSApp/WalletNodeDaemon.swift`
- Create: `wallet-macos/Tests/WalletMacOSAppTests/RelayerBootstrapRegistrationTests.swift`

**Interfaces:**
- Consumes: `BundlerSecretRecord`, `VerifiedRelayerIdentity.derive`, `RelayerIdentityBindingPolicy.verify`, `WalletNodeDaemon.launch`.
- Produces: `RelayerBootstrapRegistrationService.register(record:chain:gasPolicy:) async throws -> VerifiedRelayerIdentity`.

- [ ] **Step 1: Write failing registration-policy tests**

Cover both expected phases and every trust boundary:

```swift
@Test func loadedRegistrationAndLockedRestartAreBothRequired() throws {
    let identity = try fixtureIdentity()
    try RelayerBootstrapRegistrationPolicy.verify(
        status: fixtureStatus(identity: identity, keyLoaded: true, reason: "bundler_eoa_needs_topup"),
        identity: identity,
        expectedKeyLoaded: true
    )
    try RelayerBootstrapRegistrationPolicy.verify(
        status: fixtureStatus(identity: identity, keyLoaded: false, reason: "bundler_eoa_locked"),
        identity: identity,
        expectedKeyLoaded: false
    )
}
```

Add individual rejection assertions for wrong chain, key reference, EOA, inactive lifecycle, compromise flag, `keyLoaded == false` during registration, and `keyLoaded == true` during the read-only restart.

- [ ] **Step 2: Write a failing orchestration test**

Inject a probe closure that records the supplied key arrays. Return one loaded status followed by one locked status, then assert the sequence is `[[record], []]`, the returned identity is secret-derived, and a first-probe failure prevents the second probe.

- [ ] **Step 3: Run the focused tests and confirm failure**

Run:

```bash
swift test --package-path wallet-macos --filter RelayerBootstrapRegistration
```

Expected: compilation fails because the policy and service do not exist.

- [ ] **Step 4: Implement the minimal policy and service**

Add these internal shapes to `WalletNodeDaemon.swift`:

```swift
enum RelayerBootstrapRegistrationPolicy {
    enum Failure: LocalizedError, Equatable {
        case unexpectedLoadedState(expected: Bool, actual: Bool)
    }

    static func verify(
        status: WalletNodeClient.RelayerStatus,
        identity: VerifiedRelayerIdentity,
        expectedKeyLoaded: Bool
    ) throws {
        guard status.keyLoaded == expectedKeyLoaded else {
            throw Failure.unexpectedLoadedState(
                expected: expectedKeyLoaded,
                actual: status.keyLoaded
            )
        }
        try RelayerIdentityBindingPolicy.verify(status: status, against: identity)
    }
}

@MainActor
struct RelayerBootstrapRegistrationService {
    typealias Probe = @MainActor (
        [BundlerSecretRecord], ChainConfiguration, WalletNodeDaemon.GasPolicy
    ) async throws -> WalletNodeClient.RelayerStatus

    private let probe: Probe

    init() { self.probe = Self.runProbe }
    init(probe: @escaping Probe) { self.probe = probe }

    func register(
        record: BundlerSecretRecord,
        chain: ChainConfiguration,
        gasPolicy: WalletNodeDaemon.GasPolicy
    ) async throws -> VerifiedRelayerIdentity {
        let identity = try VerifiedRelayerIdentity.derive(
            keyRef: record.keyRef,
            secret: record.secret
        )
        guard identity.chainID == chain.id else {
            throw VerifiedRelayerIdentity.ValidationError.keyRefChainMismatch(
                expected: chain.id,
                actual: identity.chainID
            )
        }
        let loaded = try await probe([record], chain, gasPolicy)
        try RelayerBootstrapRegistrationPolicy.verify(
            status: loaded,
            identity: identity,
            expectedKeyLoaded: true
        )
        let locked = try await probe([], chain, gasPolicy)
        try RelayerBootstrapRegistrationPolicy.verify(
            status: locked,
            identity: identity,
            expectedKeyLoaded: false
        )
        return identity
    }
}
```

`runProbe` must launch with `heliosVerificationEnabled: false`, fetch `bundlerStatus`, and call `terminateAndWait()` on both success and failure paths. It must return only after the child is reaped.

- [ ] **Step 5: Run focused tests**

Run the command from Step 3. Expected: all `RelayerBootstrapRegistration` tests pass.

- [ ] **Step 6: Commit Task 1**

```bash
git add wallet-macos/Sources/WalletMacOSApp/WalletNodeDaemon.swift wallet-macos/Tests/WalletMacOSAppTests/RelayerBootstrapRegistrationTests.swift
git commit -m "feat: verify relayer registration across locked restart"
```

---

### Task 2: Make Onboarding Registration a Completion Gate

**Files:**
- Modify: `wallet-macos/Sources/WalletMacOSApp/OnboardingProvisioningService.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/OnboardingView.swift`
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/OnDemandAuthenticationAuditTests.swift`

**Interfaces:**
- Consumes: `RelayerBootstrapRegistrationService.register` from Task 1.
- Produces: `OnboardingProvisioningResult.bundlerSecretRecord` used only inside `provisionKeys()`.

- [ ] **Step 1: Add failing source-order tests**

Assert that `provisionKeys()` awaits `relayerRegistrationService.register` before assigning `.ready`, and that `complete()` still requires `.ready`. Keep the existing assertion that chain-readiness launch contains no `BundlerKeyStore` access.

- [ ] **Step 2: Run the focused audit test and confirm failure**

```bash
swift test --package-path wallet-macos --filter OnDemandAuthenticationAuditTests
```

Expected: the new onboarding registration-order assertion fails.

- [ ] **Step 3: Return the exact relayer record from provisioning**

Change the result to:

```swift
struct OnboardingProvisioningResult {
    let kernelAccountAddress: String
    let bundlerAddress: String
    let bundlerSecretRecord: BundlerSecretRecord
}
```

Refactor the relayer helper to return both identity and record. New keys return the freshly generated record without reading Keychain again. Existing keys are read only from the explicit **Create Keys** action with reason `"Finish setting up the local relayer"`; the authenticated read validates or migrates metadata before returning.

- [ ] **Step 4: Gate `keyState.ready` on registration**

Inject `RelayerBootstrapRegistrationService` into `OnboardingState`. In `provisionKeys()`, persist network settings, obtain the active chain and resolved gas policy, await `register`, verify the returned address equals `result.bundlerAddress`, and only then assign `.ready`. Any failure assigns `.failed` and exposes no funding step.

- [ ] **Step 5: Run onboarding and authentication tests**

```bash
swift test --package-path wallet-macos --filter Onboarding
swift test --package-path wallet-macos --filter OnDemandAuthenticationAuditTests
```

Expected: all selected tests pass and passive launch audits still prove no protected read.

- [ ] **Step 6: Commit Task 2**

```bash
git add wallet-macos/Sources/WalletMacOSApp/OnboardingProvisioningService.swift wallet-macos/Sources/WalletMacOSApp/OnboardingView.swift wallet-macos/Tests/WalletMacOSAppTests/OnDemandAuthenticationAuditTests.swift
git commit -m "fix: register relayer before onboarding funding"
```

---

### Task 3: Make Dashboard Reset Register Before Bootstrap

**Files:**
- Modify: `wallet-macos/Sources/WalletMacOSApp/AppModel.swift`
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/OnDemandAuthenticationAuditTests.swift`
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/KeyLifecycleFixesTests.swift`

**Interfaces:**
- Consumes: `RelayerBootstrapRegistrationService.register` from Task 1 and the reset-created `BundlerSecretRecord`.
- Produces: a reset path whose next ordinary daemon launch sees an active locked relayer row.

- [ ] **Step 1: Add failing reset-order tests**

In the reset source slice, assert this strict order:

```text
authorize -> quiesce -> clear SQLite -> clear Keychain -> create replacement -> register -> sync cache -> clear UI state -> bootstrap
```

Also assert the registration receives the existing reset authentication-created record and normal `ensureWalletNodeClient()` still launches with `bundlerSecrets: []`.

- [ ] **Step 2: Run focused tests and confirm failure**

```bash
swift test --package-path wallet-macos --filter OnDemandAuthenticationAuditTests
swift test --package-path wallet-macos --filter KeyLifecycleFixesTests
```

Expected: reset-order assertion fails before implementation.

- [ ] **Step 3: Inject and call the registration service**

Add a defaulted `relayerBootstrapRegistrationService` dependency to `AppModel.init`. In the `.dashboard` reset branch, await registration immediately after `createIfNeeded`. Only after it returns the exact expected identity should `syncUnlockedRelayerAddress`, `clearInMemoryWalletStateAfterReset`, and `bootstrap()` proceed.

Registration failure must propagate through the existing reset failure path. It must not publish success or start a daemon with an unregistered identity.

- [ ] **Step 4: Run focused tests**

Run the commands from Step 2. Expected: all pass.

- [ ] **Step 5: Commit Task 3**

```bash
git add wallet-macos/Sources/WalletMacOSApp/AppModel.swift wallet-macos/Tests/WalletMacOSAppTests/OnDemandAuthenticationAuditTests.swift wallet-macos/Tests/WalletMacOSAppTests/KeyLifecycleFixesTests.swift
git commit -m "fix: register reset relayer before dashboard bootstrap"
```

---

### Task 4: Prove wallet-node Persistence Across a Locked Restart

**Files:**
- Modify: `local-wallet-daemon/crates/wallet-node/tests/integration_fd_e2e.rs`

**Interfaces:**
- Consumes: existing `spawn_wallet_node`, fd 5 payload, SQLite store, and authenticated Unix RPC helpers.
- Produces: an end-to-end regression test for secret-loaded registration followed by an empty-key restart.

- [ ] **Step 1: Extend the ignored fd lifecycle test**

After the first process exits successfully, spawn a second process with the same `TempHome`, write `{"keys":[]}`, await ready, and call `wallet_bundlerStatus`. Assert:

```rust
assert_eq!(result["keyRef"], "bundler-eoa:default:1:1");
assert_eq!(result["eoa"], "0x1a642f0e3c3af545e7acbd38b07251b3990914f1");
assert_eq!(result["lifecycle"], "active");
assert_eq!(result["keyLoaded"], false);
assert_eq!(result["reason"], "bundler_eoa_locked");
```

Use the existing bearer token and socket request format from `integration_unix_e2e.rs`; do not add HTTP or network dependencies.

- [ ] **Step 2: Run the fd integration test**

```bash
cargo test --manifest-path local-wallet-daemon/Cargo.toml -p wallet-node --test integration_fd_e2e -- --include-ignored --test-threads=1
```

Expected: both fd lifecycle tests pass offline.

- [ ] **Step 3: Commit Task 4**

```bash
git add local-wallet-daemon/crates/wallet-node/tests/integration_fd_e2e.rs
git commit -m "test: prove relayer registration survives locked restart"
```

---

### Task 5: Full Verification and Final Checkpoint

**Files:**
- Modify only if verification exposes a defect in Task 1 through Task 4.

**Interfaces:**
- Consumes: all prior tasks.
- Produces: a buildable, tested branch without altering the developer's runnable signed DerivedData product.

- [ ] **Step 1: Run all Swift tests**

```bash
swift test --package-path wallet-macos
```

Expected: zero failures.

- [ ] **Step 2: Run wallet-node and workspace Rust tests**

```bash
cargo test --manifest-path local-wallet-daemon/Cargo.toml -p wallet-node
cargo test --manifest-path local-wallet-daemon/Cargo.toml --workspace
```

Expected: zero failures; network/fork tests remain skipped unless explicitly configured.

- [ ] **Step 3: Build the macOS app in isolated DerivedData**

```bash
xcodebuild -project LocalWallet.xcodeproj -scheme LocalWalletApp -configuration Debug -derivedDataPath /private/tmp/local-wallet-relayer-registration-dd CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`. Do not run this unsigned artifact and do not replace Xcode's normal signed Run product.

- [ ] **Step 4: Inspect the final diff and staging scope**

```bash
git diff --check
git status --short
git diff --stat HEAD~4..HEAD
```

Expected: no whitespace errors; `LocalWallet.xcodeproj/project.pbxproj` remains the only unrelated unstaged modification.

- [ ] **Step 5: Confirm the feature checkpoints are complete**

Run:

```bash
git log --oneline -5
git diff --cached --name-only
```

Expected: the design and four task checkpoints are present, the index is empty, and `LocalWallet.xcodeproj/project.pbxproj` was never staged.
