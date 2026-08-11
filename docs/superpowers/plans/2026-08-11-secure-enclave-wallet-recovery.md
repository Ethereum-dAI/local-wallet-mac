# Secure Enclave Wallet Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect stale or inaccessible Secure Enclave wallet keys before the dashboard starts and provide an explicit, authenticated reset-to-onboarding recovery path.

**Architecture:** Introduce one read-only `WalletKeyValidator` that compares the current key tag and public key coordinates with `WalletRecord`. Both onboarding provisioning and `AppModel.bootstrap()` consume that validator; bootstrap publishes a structured recovery reason and stops before daemon/account work. `WalletLaunchGateView` constructs the chat dashboard only after bootstrap passes and otherwise presents `WalletRecoveryView`, whose reset action reuses the existing authenticated cleanup pipeline but returns to onboarding instead of silently creating replacement identities.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Security/Secure Enclave, LocalAuthentication, Swift Testing, Swift Package Manager, XcodeGen.

## Global Constraints

- Never create a replacement key while existing wallet metadata remains.
- Missing and mismatched keys fail closed before account inspection, daemon startup, gas warmup, reconciliation, or dashboard construction.
- Recovery requires explicit user action and the existing device-owner authentication boundary.
- Ordinary signing continues to use `KeyStore.sign` and must never provision a key.
- Reset uses `WalletResetCleanup.standard`; do not create a second list of secret stores to delete.
- Recovery reset marks onboarding incomplete and does not pre-create a new root or relayer key.
- Preserve every unrelated existing worktree change; stage only isolated recovery hunks.

---

## File Structure

- Create `wallet-macos/Sources/WalletMacOSApp/WalletKeyValidation.swift`: structured recovery reasons, validation result, and injectable read-only validator.
- Modify `wallet-macos/Sources/WalletMacOSApp/KeyStore.swift`: expose read-only public-key coordinate loading without provisioning.
- Modify `wallet-macos/Sources/WalletMacOSApp/AppError.swift`: add one structured recovery-required error and centralized copy.
- Modify `wallet-macos/Sources/WalletMacOSApp/AppModel.swift`: enforce validation during bootstrap and add a reset-to-onboarding destination using the existing cleanup runner.
- Modify `wallet-macos/Sources/WalletMacOSApp/OnboardingProvisioningService.swift`: reject stale metadata through the same validator.
- Create `wallet-macos/Sources/WalletMacOSApp/WalletRecoveryView.swift`: launch gate and explicit recovery UI.
- Modify `wallet-macos/Sources/WalletMacOSApp/WalletMacOSApp.swift`: bootstrap before dashboard construction and route recovery completion to onboarding.
- Modify `wallet-macos/Sources/WalletMacOSApp/ChatDashboardView.swift`: remove its duplicate bootstrap call so launch gating is authoritative.
- Create `wallet-macos/Tests/WalletMacOSAppTests/WalletKeyRecoveryTests.swift`: validator, bootstrap, onboarding, copy, and reset-policy regression coverage.
- Modify `wallet-macos/Tests/WalletMacOSAppTests/OnDemandAuthenticationAuditTests.swift`: update the shared-model source audit for the launch gate.
- Regenerate `LocalWallet.xcodeproj/project.pbxproj` from `project.yml`, then restore the local development-team and bundle-ID override used by this workstation.

### Task 1: Read-only wallet key validation

**Files:**
- Create: `wallet-macos/Sources/WalletMacOSApp/WalletKeyValidation.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/KeyStore.swift`
- Create: `wallet-macos/Tests/WalletMacOSAppTests/WalletKeyRecoveryTests.swift`

**Interfaces:**
- Consumes: `WalletRecord.keyTag`, `WalletRecord.matches(_:)`, `KeyStore.keyTag`, and `KeyStore.loadKey(authenticationContext:)`.
- Produces: `WalletKeyRecoveryReason`, `WalletKeyValidationResult`, `WalletKeyValidator.validate(_:)`, and `KeyStore.loadPublicKeyCoordinates(authenticationContext:)`.

- [ ] **Step 1: Write failing validator tests**

Create `WalletKeyRecoveryTests.swift` with fixtures and the four core states:

```swift
import Foundation
import Testing
@testable import WalletMacOSApp

private func recoveryRecord(
    keyTag: String = "wallet-key",
    coordinates: PublicKeyCoordinates = PublicKeyCoordinates(
        x: Data(repeating: 0x11, count: 32),
        y: Data(repeating: 0x22, count: 32)
    )
) -> WalletRecord {
    WalletRecord(
        walletId: UUID(),
        keyTag: keyTag,
        pubkeyX: coordinates.x,
        pubkeyY: coordinates.y,
        chainId: ChainConfiguration.ethereumSepolia.id,
        kernelAccountAddress: "0x1111111111111111111111111111111111111111",
        isDeployed: false,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Test func validatorAcceptsTheMatchingAccessibleKey() throws {
    let coordinates = PublicKeyCoordinates(
        x: Data(repeating: 0x11, count: 32),
        y: Data(repeating: 0x22, count: 32)
    )
    let validator = WalletKeyValidator(currentKeyTag: "wallet-key") { coordinates }
    #expect(try validator.validate(recoveryRecord(coordinates: coordinates)) == .available)
}

@Test func validatorReportsMissingWithoutCreatingAKey() throws {
    var loadCount = 0
    let validator = WalletKeyValidator(currentKeyTag: "wallet-key") {
        loadCount += 1
        return nil
    }
    #expect(try validator.validate(recoveryRecord()) == .recoveryRequired(.missing))
    #expect(loadCount == 1)
}

@Test func validatorRejectsAStoredTagFromAnotherSigningIdentity() throws {
    var loadedCoordinates = false
    let validator = WalletKeyValidator(currentKeyTag: "current-key") {
        loadedCoordinates = true
        return PublicKeyCoordinates(x: Data(), y: Data())
    }
    #expect(try validator.validate(recoveryRecord(keyTag: "old-key")) == .recoveryRequired(.mismatch))
    #expect(!loadedCoordinates)
}

@Test func validatorRejectsDifferentPublicKeyCoordinates() throws {
    let other = PublicKeyCoordinates(
        x: Data(repeating: 0x33, count: 32),
        y: Data(repeating: 0x44, count: 32)
    )
    let validator = WalletKeyValidator(currentKeyTag: "wallet-key") { other }
    #expect(try validator.validate(recoveryRecord()) == .recoveryRequired(.mismatch))
}
```

- [ ] **Step 2: Run the focused tests and confirm they fail to compile**

Run:

```bash
cd wallet-macos
swift test --filter WalletKeyRecoveryTests
```

Expected: failure because `WalletKeyValidator`, `WalletKeyRecoveryReason`, and `WalletKeyValidationResult` do not exist.

- [ ] **Step 3: Implement the validator and read-only key API**

Create `WalletKeyValidation.swift`:

```swift
import Foundation

enum WalletKeyRecoveryReason: Equatable {
    case missing
    case mismatch
}

enum WalletKeyValidationResult: Equatable {
    case available
    case recoveryRequired(WalletKeyRecoveryReason)
}

struct WalletKeyValidator {
    private let currentKeyTag: String
    private let loadCoordinates: () throws -> PublicKeyCoordinates?

    init(keyStore: KeyStore = KeyStore()) {
        self.init(currentKeyTag: keyStore.keyTag) {
            try keyStore.loadPublicKeyCoordinates()
        }
    }

    init(
        currentKeyTag: String,
        loadCoordinates: @escaping () throws -> PublicKeyCoordinates?
    ) {
        self.currentKeyTag = currentKeyTag
        self.loadCoordinates = loadCoordinates
    }

    func validate(_ record: WalletRecord) throws -> WalletKeyValidationResult {
        guard record.keyTag == currentKeyTag else {
            return .recoveryRequired(.mismatch)
        }
        guard let coordinates = try loadCoordinates() else {
            return .recoveryRequired(.missing)
        }
        return record.matches(coordinates)
            ? .available
            : .recoveryRequired(.mismatch)
    }
}
```

Add this read-only method to `KeyStore` next to `loadKey`:

```swift
func loadPublicKeyCoordinates(
    authenticationContext: LAContext? = nil
) throws -> PublicKeyCoordinates? {
    guard let key = try loadKey(authenticationContext: authenticationContext) else {
        return nil
    }
    return try publicKeyCoordinates(for: key)
}
```

Do not call `createOrLoadKey` from this method.

- [ ] **Step 4: Run the validator tests**

Run:

```bash
cd wallet-macos
swift test --filter WalletKeyRecoveryTests
```

Expected: all four validator tests pass.

- [ ] **Step 5: Review and commit the isolated validator change**

```bash
git diff --check -- wallet-macos/Sources/WalletMacOSApp/WalletKeyValidation.swift wallet-macos/Sources/WalletMacOSApp/KeyStore.swift wallet-macos/Tests/WalletMacOSAppTests/WalletKeyRecoveryTests.swift
git add wallet-macos/Sources/WalletMacOSApp/WalletKeyValidation.swift wallet-macos/Sources/WalletMacOSApp/KeyStore.swift wallet-macos/Tests/WalletMacOSAppTests/WalletKeyRecoveryTests.swift
git commit -m "feat: validate persisted wallet key material"
```

Expected: commit contains only validator, read-only key loading, and its tests. If pre-existing hunks in `KeyStore.swift` cannot be isolated, do not commit them; leave the verified change unstaged and record that exception.

### Task 2: Fail closed in onboarding and bootstrap

**Files:**
- Modify: `wallet-macos/Sources/WalletMacOSApp/AppError.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/AppModel.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/OnboardingProvisioningService.swift`
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/WalletKeyRecoveryTests.swift`

**Interfaces:**
- Consumes: `WalletKeyValidator.validate(_:)` and `WalletKeyValidationResult` from Task 1.
- Produces: `AppError.walletKeyRecoveryRequired(_:)`, `AppModel.walletRecoveryReason`, and validator injection in `AppModel` and `OnboardingProvisioningService`.

- [ ] **Step 1: Add failing bootstrap, onboarding, metadata-preservation, and copy tests**

Append:

```swift
private func recoveryMetadataStore(record: WalletRecord) throws -> (WalletMetadataStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("wallet-key-recovery-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("wallet-record.json")
    let store = WalletMetadataStore(fileURL: url)
    try store.save(record)
    return (store, directory)
}

@Test @MainActor func bootstrapStopsBeforePresentingWalletWhenKeyIsMissing() throws {
    let record = recoveryRecord()
    let (metadataStore, directory) = try recoveryMetadataStore(record: record)
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaultsName = "WalletKeyRecoveryTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let validator = WalletKeyValidator(currentKeyTag: record.keyTag) { nil }
    let model = AppModel(
        metadataStore: metadataStore,
        settingsStore: DemoSettingsStore(defaults: defaults),
        onboardingSettingsStore: OnboardingSettingsStore(defaults: defaults),
        walletKeyValidator: validator,
        walletNodeClient: nil
    )

    model.bootstrap()

    #expect(model.walletRecoveryReason == .missing)
    #expect(model.walletRecord == nil)
    #expect(model.accountInspection == nil)
    #expect(try metadataStore.load() == record)
}

@Test func onboardingRefusesExistingMetadataWhenItsKeyIsMissing() throws {
    let record = recoveryRecord()
    let (metadataStore, directory) = try recoveryMetadataStore(record: record)
    defer { try? FileManager.default.removeItem(at: directory) }
    let validator = WalletKeyValidator(currentKeyTag: record.keyTag) { nil }
    let service = OnboardingProvisioningService(
        metadataStore: metadataStore,
        walletKeyValidator: validator
    )

    #expect(throws: AppError.self) {
        try service.createOrLoadIdentity()
    }
    #expect(try metadataStore.load() == record)
}

@Test func walletKeyRecoveryCopyIsActionableAndHonest() {
    let missing = AppError.walletKeyRecoveryRequired(.missing).localizedDescription
    let mismatch = AppError.walletKeyRecoveryRequired(.mismatch).localizedDescription
    #expect(missing.contains("Reset local wallet"))
    #expect(mismatch.contains("Reset local wallet"))
    #expect(!missing.lowercased().contains("recover the key"))
    #expect(!mismatch.lowercased().contains("recover the key"))
}
```

- [ ] **Step 2: Run tests and verify the new behavior fails**

Run:

```bash
cd wallet-macos
swift test --filter WalletKeyRecoveryTests
```

Expected: compile failures for the new error, published state, and initializer arguments.

- [ ] **Step 3: Add structured recovery error copy**

Add `case walletKeyRecoveryRequired(WalletKeyRecoveryReason)` to `AppError`, with:

```swift
case let .walletKeyRecoveryRequired(reason):
    switch reason {
    case .missing:
        return "The wallet's Secure Enclave key is unavailable to this app. Reset local wallet to create a new identity and continue."
    case .mismatch:
        return "The Secure Enclave key does not match this wallet's saved identity. Reset local wallet to create a new identity and continue."
    }
```

Keep `missingKeyReference` for signing-time fail-closed protection. Remove `metadataKeyMismatch` only after confirming no remaining references with `rg metadataKeyMismatch`.

- [ ] **Step 4: Gate `AppModel.bootstrap()` with the validator**

Add:

```swift
@Published private(set) var walletRecoveryReason: WalletKeyRecoveryReason?
private let walletKeyValidator: WalletKeyValidator
```

Extend the initializer:

```swift
walletKeyValidator: WalletKeyValidator? = nil,
```

and initialize it with the exact `keyStore` instance:

```swift
self.walletKeyValidator = walletKeyValidator ?? WalletKeyValidator(keyStore: keyStore)
```

At bootstrap start clear `walletRecoveryReason`. Replace the entire current `existing.keyTag` branch—including automatic key creation and metadata deletion—with:

```swift
switch try walletKeyValidator.validate(existing) {
case .available:
    let coordinates = PublicKeyCoordinates(x: existing.pubkeyX, y: existing.pubkeyY)
    appendLog("bootstrap: validated accessible wallet key x=\(coordinates.x.shortHex) y=\(coordinates.y.shortHex)")
    // Keep the existing predicted-address refresh and save logic here.
case let .recoveryRequired(reason):
    walletRecord = nil
    walletRecoveryReason = reason
    throw AppError.walletKeyRecoveryRequired(reason)
}
```

The catch block may continue to publish `lastError`, but `shouldInspectAfterBootstrap` must remain false. Do not clear metadata and do not call `createOrLoadPublicKeyCoordinates()` when a record exists.

- [ ] **Step 5: Gate onboarding provisioning with the same validator**

Add `private let walletKeyValidator: WalletKeyValidator`, extend the initializer with `walletKeyValidator: WalletKeyValidator? = nil`, and initialize it from the supplied `keyStore` when not injected.

Replace the existing tag-only record reuse with:

```swift
if let existing = try metadataStore.load() {
    switch try walletKeyValidator.validate(existing) {
    case .available:
        break
    case let .recoveryRequired(reason):
        throw AppError.walletKeyRecoveryRequired(reason)
    }
    // Keep the existing address prediction, refreshed record, save, and return.
}
```

The fresh-key provisioning branch runs only when metadata is absent.

- [ ] **Step 6: Run focused recovery and signing regression tests**

Run:

```bash
cd wallet-macos
swift test --filter WalletKeyRecoveryTests
swift test --filter signingRefusesToMintAReplacementRootKey
```

Expected: recovery tests pass; the existing signing test still passes and the test key remains absent.

- [ ] **Step 7: Review and commit the isolated bootstrap gate**

```bash
git diff --check -- wallet-macos/Sources/WalletMacOSApp/AppError.swift wallet-macos/Sources/WalletMacOSApp/AppModel.swift wallet-macos/Sources/WalletMacOSApp/OnboardingProvisioningService.swift wallet-macos/Tests/WalletMacOSAppTests/WalletKeyRecoveryTests.swift
git add wallet-macos/Sources/WalletMacOSApp/AppError.swift wallet-macos/Sources/WalletMacOSApp/AppModel.swift wallet-macos/Sources/WalletMacOSApp/OnboardingProvisioningService.swift wallet-macos/Tests/WalletMacOSAppTests/WalletKeyRecoveryTests.swift
git commit -m "fix: block wallets with unavailable enclave keys"
```

Expected: commit contains only the recovery gate. If pre-existing hunks prevent isolation, leave the verified recovery hunks unstaged rather than sweeping unrelated changes into the commit.

### Task 3: Reuse reset cleanup with an onboarding destination

**Files:**
- Modify: `wallet-macos/Sources/WalletMacOSApp/AppModel.swift`
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/WalletKeyRecoveryTests.swift`

**Interfaces:**
- Consumes: the existing authenticated `resetDemoWalletAuthorized()` flow and `WalletResetCleanup.standard`.
- Produces: `WalletResetDestination`, `AppModel.resetWalletForRecoveryAuthorized()`, and destination-specific post-cleanup behavior.

- [ ] **Step 1: Write failing reset-destination policy tests**

Append:

```swift
@Test func recoveryResetDestinationReturnsToOnboardingWithoutReplacementKeys() {
    #expect(WalletResetDestination.onboarding.recreatesRelayer == false)
    #expect(WalletResetDestination.onboarding.rebootstrapsWallet == false)
    #expect(WalletResetDestination.onboarding.marksOnboardingIncomplete)
}

@Test func dashboardResetDestinationKeepsExistingBehavior() {
    #expect(WalletResetDestination.dashboard.recreatesRelayer)
    #expect(WalletResetDestination.dashboard.rebootstrapsWallet)
    #expect(WalletResetDestination.dashboard.marksOnboardingIncomplete == false)
}
```

- [ ] **Step 2: Run the focused tests and verify the enum is missing**

Run:

```bash
cd wallet-macos
swift test --filter WalletKeyRecoveryTests
```

Expected: compile failure for `WalletResetDestination`.

- [ ] **Step 3: Introduce the two reset destinations**

Add near `AppModel`:

```swift
enum WalletResetDestination: Equatable {
    case dashboard
    case onboarding

    var recreatesRelayer: Bool { self == .dashboard }
    var rebootstrapsWallet: Bool { self == .dashboard }
    var marksOnboardingIncomplete: Bool { self == .onboarding }
}
```

Make the current public method delegate without changing settings behavior:

```swift
func resetDemoWalletAuthorized() async throws {
    try await resetDemoWalletAuthorized(destination: .dashboard)
}

func resetWalletForRecoveryAuthorized() async throws {
    try await resetDemoWalletAuthorized(destination: .onboarding)
}
```

Move the existing implementation into:

```swift
private func resetDemoWalletAuthorized(destination: WalletResetDestination) async throws
```

- [ ] **Step 4: Branch only after the shared destructive cleanup succeeds**

After `WalletResetCleanup.standard(...).run`, keep relayer recreation only when `destination.recreatesRelayer`. Always clear in-memory wallet state. For `.onboarding`:

```swift
if destination.marksOnboardingIncomplete {
    onboardingSettingsStore.markIncomplete()
}
walletRecoveryReason = nil
lastError = nil
bridgeStatus = destination == .dashboard
    ? "Demo wallet reset. Creating a fresh Secure Enclave key…"
    : "Local wallet reset. Return to onboarding to create a new identity."
```

Call `bootstrap()` only when `destination.rebootstrapsWallet`. Do not duplicate preflight, authentication, daemon quiescence, database cleanup, or `WalletResetCleanup.standard`.

- [ ] **Step 5: Run reset and recovery regression tests**

Run:

```bash
cd wallet-macos
swift test --filter WalletKeyRecoveryTests
swift test --filter walletResetCleanup
swift test --filter commandLineResetAlsoAuthenticatesBeforeCleanup
```

Expected: all tests pass; source audit still confirms authentication precedes cleanup.

- [ ] **Step 6: Review and commit the isolated reset destination**

```bash
git diff --check -- wallet-macos/Sources/WalletMacOSApp/AppModel.swift wallet-macos/Tests/WalletMacOSAppTests/WalletKeyRecoveryTests.swift
git add wallet-macos/Sources/WalletMacOSApp/AppModel.swift wallet-macos/Tests/WalletMacOSAppTests/WalletKeyRecoveryTests.swift
git commit -m "feat: reset inaccessible wallets through onboarding"
```

Expected: reset continues to have one destructive pipeline. If `AppModel.swift` contains inseparable pre-existing work, do not create a mixed commit.

### Task 4: Pre-dashboard recovery UI and launch routing

**Files:**
- Create: `wallet-macos/Sources/WalletMacOSApp/WalletRecoveryView.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/WalletMacOSApp.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/ChatDashboardView.swift`
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/OnDemandAuthenticationAuditTests.swift`
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/WalletKeyRecoveryTests.swift`

**Interfaces:**
- Consumes: `AppModel.walletRecoveryReason` and `AppModel.resetWalletForRecoveryAuthorized()`.
- Produces: `WalletLaunchGateView` and `WalletRecoveryView`.

- [ ] **Step 1: Write failing source-routing and recovery-copy tests**

Update the existing shared-instance audit to expect:

```swift
#expect(dashboard.contains("let model = AppModel()"))
#expect(dashboard.contains("self.model = model"))
#expect(dashboard.contains("model.bootstrap()"))
#expect(dashboard.contains("WalletLaunchGateView(walletModel: model"))
```

Append this source audit inside `OnDemandAuthenticationAuditTests` so it reuses the suite's existing `appSource(_:)` helper:

```swift
@Test func recoveryViewRequiresExplicitResetAndDoesNotConstructAReplacementKey() throws {
    let source = try appSource("WalletRecoveryView.swift")
    #expect(source.contains("Wallet key unavailable"))
    #expect(source.contains("Reset local wallet"))
    #expect(source.contains("resetWalletForRecoveryAuthorized"))
    #expect(!source.contains("createOrLoadPublicKeyCoordinates"))
}
```

Use the test suite's existing source-directory helper rather than introducing a second path resolver.

- [ ] **Step 2: Run the audit and confirm it fails**

Run:

```bash
cd wallet-macos
swift test --filter OnDemandAuthenticationAuditTests
swift test --filter recoveryViewRequiresExplicitReset
```

Expected: failures because the launch gate and recovery view are absent.

- [ ] **Step 3: Build the launch gate and recovery screen**

Create `WalletRecoveryView.swift` with:

```swift
import SwiftUI

struct WalletLaunchGateView: View {
    @ObservedObject var walletModel: AppModel
    let onRecoveryCompleted: () -> Void

    var body: some View {
        if let reason = walletModel.walletRecoveryReason {
            WalletRecoveryView(
                reason: reason,
                walletModel: walletModel,
                onRecoveryCompleted: onRecoveryCompleted
            )
        } else {
            LocalWalletChatDashboardView(walletModel: walletModel)
        }
    }
}

struct WalletRecoveryView: View {
    let reason: WalletKeyRecoveryReason
    @ObservedObject var walletModel: AppModel
    let onRecoveryCompleted: () -> Void
    @State private var resetError: String?

    var body: some View {
        ZStack {
            Color(red: 0.045, green: 0.055, blue: 0.100).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "key.slash.fill")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Wallet key unavailable")
                    .font(.system(size: 30, weight: .bold))
                Text(explanation)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 560)
                Text("Resetting removes this local wallet identity and its local wallet data. The inaccessible private key cannot be recovered by this app.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 560)
                if let resetError {
                    Text(resetError).foregroundStyle(.red).textSelection(.enabled)
                }
                Button(walletModel.isResettingWallet ? "Resetting…" : "Reset local wallet") {
                    Task {
                        do {
                            try await walletModel.resetWalletForRecoveryAuthorized()
                            onRecoveryCompleted()
                        } catch {
                            resetError = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(walletModel.isResettingWallet)
            }
            .padding(48)
        }
        .frame(minWidth: 980, minHeight: 720)
    }

    private var explanation: String {
        switch reason {
        case .missing:
            return "The saved wallet belongs to a Secure Enclave key that is no longer available to this signed app. This can happen after the development team, bundle identifier, or Keychain state changes."
        case .mismatch:
            return "The accessible Secure Enclave key does not match this wallet's saved public identity, so the app will not use either one."
        }
    }
}
```

Keep all reset work in `AppModel`; the view only displays state and calls the authorized recovery method.

- [ ] **Step 4: Make bootstrap authoritative before dashboard construction**

In `AppDelegate.showDashboard()`:

```swift
let model = AppModel()
self.model = model
model.bootstrap()
window?.contentViewController = NSHostingController(
    rootView: WalletLaunchGateView(walletModel: model) { [weak self] in
        self?.showOnboarding()
    }
)
```

In `showOnboarding()`, set `model = nil` before replacing the controller. Remove `self.walletModel.bootstrap()` from `ChatDashboardModel.init`; it is too late because that initializer already loads chat data and starts subsequent warmups. Leave gas warmup and reconciliation where they are because the launch gate now creates `ChatDashboardModel` only after validation succeeds.

- [ ] **Step 5: Run focused UI/source audits**

Run:

```bash
cd wallet-macos
swift test --filter OnDemandAuthenticationAuditTests
swift test --filter WalletKeyRecoveryTests
```

Expected: launch routing, explicit reset copy, authentication ordering, and key validation tests pass.

- [ ] **Step 6: Regenerate the Xcode project and preserve local signing**

Run the repository's documented XcodeGen command, then restore this workstation's current local overrides in `LocalWallet.xcodeproj/project.pbxproj`:

```text
DEVELOPMENT_TEAM = 3HP24ZYX3G;
PRODUCT_BUNDLE_IDENTIFIER = ai.ethereum.localwallet.demo.2;
```

Inspect the generated references for the new source files:

```bash
rg -n "WalletKeyValidation.swift|WalletRecoveryView.swift" LocalWallet.xcodeproj/project.pbxproj
```

Expected: each file has one file reference and one sources-build-phase entry; there are no duplicated local package references.

- [ ] **Step 7: Review and commit the isolated UI/routing change**

```bash
git diff --check -- wallet-macos/Sources/WalletMacOSApp/WalletRecoveryView.swift wallet-macos/Sources/WalletMacOSApp/WalletMacOSApp.swift wallet-macos/Sources/WalletMacOSApp/ChatDashboardView.swift wallet-macos/Tests/WalletMacOSAppTests/OnDemandAuthenticationAuditTests.swift wallet-macos/Tests/WalletMacOSAppTests/WalletKeyRecoveryTests.swift LocalWallet.xcodeproj/project.pbxproj
git add wallet-macos/Sources/WalletMacOSApp/WalletRecoveryView.swift wallet-macos/Sources/WalletMacOSApp/WalletMacOSApp.swift wallet-macos/Sources/WalletMacOSApp/ChatDashboardView.swift wallet-macos/Tests/WalletMacOSAppTests/OnDemandAuthenticationAuditTests.swift wallet-macos/Tests/WalletMacOSAppTests/WalletKeyRecoveryTests.swift LocalWallet.xcodeproj/project.pbxproj
git commit -m "feat: add inaccessible wallet recovery screen"
```

Expected: one launch gate, one recovery view, and no unrelated UI/project-file hunks. Skip the commit if existing file changes cannot be safely isolated.

### Task 5: Full verification and local recovery exercise

**Files:**
- Verify only; no new production files expected.

**Interfaces:**
- Consumes: all recovery behavior from Tasks 1-4.
- Produces: a passing package suite, signed Xcode build, and a manually confirmed reset-to-onboarding flow.

- [ ] **Step 1: Run formatting and full Swift tests**

```bash
cd wallet-macos
swift test
```

Expected: all `WalletMacOSAppTests`, `WalletToolLayerTests`, and `SpawnHelperTests` pass.

- [ ] **Step 2: Run a signed Xcode build without invoking the Run action**

```bash
xcodebuild -project LocalWallet.xcodeproj -scheme LocalWalletApp -configuration Debug -destination 'platform=macOS' build
```

Expected: `** BUILD SUCCEEDED **`; the pre-build wallet-node release build succeeds and code signing uses `3HP24ZYX3G.ai.ethereum.localwallet.demo.2`.

- [ ] **Step 3: Confirm the stale-wallet path does not start runtime work**

Launch from Xcode with the existing stale `wallet-record.json`. Expected:

- The first app surface is `Wallet key unavailable`.
- No chat dashboard is visible.
- No Touch ID prompt appears merely from landing on the recovery screen.
- No wallet-node funding or signing error appears.
- The existing metadata file remains until reset is approved.

- [ ] **Step 4: Exercise the authorized reset**

Click `Reset local wallet`, approve the single device-owner authentication prompt, and confirm:

- The app returns to onboarding.
- The old `wallet-record.json` is gone.
- Wallet-node SQLite state and current-access-group wallet, bundler, session, and privacy keys are cleared by the existing reset pipeline.
- The old Secure Enclave key from a previous signing access group may remain inaccessible and orphaned; the current app cannot recover or delete it.
- A new wallet is created only after onboarding reaches provisioning again.

- [ ] **Step 5: Inspect the final diff and status**

```bash
git diff --check
git status --short
git diff -- wallet-macos/Sources/WalletMacOSApp/WalletKeyValidation.swift wallet-macos/Sources/WalletMacOSApp/WalletRecoveryView.swift wallet-macos/Sources/WalletMacOSApp/KeyStore.swift wallet-macos/Sources/WalletMacOSApp/AppError.swift wallet-macos/Sources/WalletMacOSApp/AppModel.swift wallet-macos/Sources/WalletMacOSApp/OnboardingProvisioningService.swift wallet-macos/Sources/WalletMacOSApp/WalletMacOSApp.swift wallet-macos/Sources/WalletMacOSApp/ChatDashboardView.swift wallet-macos/Tests/WalletMacOSAppTests/WalletKeyRecoveryTests.swift wallet-macos/Tests/WalletMacOSAppTests/OnDemandAuthenticationAuditTests.swift
```

Expected: no whitespace errors, no silent key creation in an existing-metadata branch, and no unrelated files staged.
