# Bundler Activation Hierarchy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the external-funding actions visually dominant and replace the oversized passive status card with one compact, dash-separated status line.

**Architecture:** Keep the existing activation state machine, polling service, and shared `BundlerExternalFundingActions` component. Change only the shared component's presentation (using its existing `compact` switch) and the activation step's copy/status rendering, with source-audit tests preventing a regression to borderless actions or a full status card.

**Tech Stack:** Swift 6, SwiftUI for macOS 15, Swift Testing, XcodeGen/Xcode.

## Global Constraints

- `Copy address` stays first and is the filled primary action.
- `Open Sepolia faucet` stays second and is an outlined secondary action.
- Opening the faucet must not change the clipboard.
- Use dashes (`—`), never centered dots, between status phrases and values.
- The status is one compact inline row; do not wrap checking, waiting, ready, or failure in `OnboardingGlassCard`.
- Preserve the existing `0.005 ETH` readiness floor, polling, explicit Continue, failure behavior, and authentication boundary.
- Respect `compact`: onboarding uses large controls; the dashboard reuse remains small.
- Do not stage or commit the user's Xcode Team or bundle-identifier values.

---

## File Structure

- Modify `wallet-macos/Sources/WalletMacOSApp/BundlerFundingPolicy.swift`: centralize the human-readable minimum and recommended amounts.
- Modify `wallet-macos/Sources/WalletMacOSApp/BundlerExternalFundingActions.swift`: promote Copy and Faucet to primary/secondary controls while preserving compact dashboard rendering.
- Modify `wallet-macos/Sources/WalletMacOSApp/OnboardingView.swift`: clarify the amount copy and render activation status as a compact inline row.
- Modify `wallet-macos/Tests/WalletMacOSAppTests/OnboardingBundlerActivationTests.swift`: audit action order/styles, clipboard separation, dash copy, and absence of the status card.

### Task 1: Lock the approved hierarchy with failing source-audit tests

**Files:**
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/OnboardingBundlerActivationTests.swift`

**Interfaces:**
- Consumes: `appSource(named:)` and `sourceSlice(_:from:until:)` test helpers.
- Produces: regression checks for the shared funding controls and `BundlerActivationStep` source.

- [ ] **Step 1: Replace the existing external-action audit and add the activation hierarchy audit**

```swift
@Test func externalFundingActionsKeepCopyPrimaryAndFaucetSeparate() throws {
    let source = try appSource(named: "BundlerExternalFundingActions.swift")
    let copy = try sourceSlice(
        source,
        from: "Button {",
        until: "Link(destination: faucetURL)"
    )
    let faucet = try sourceSlice(
        source,
        from: "Link(destination: faucetURL)",
        until: ".accessibilityHint(\"Opens the faucet without changing the clipboard\")"
    )

    #expect(copy.contains("NSPasteboard.general.setString"))
    #expect(copy.contains(".buttonStyle(.borderedProminent)"))
    #expect(faucet.contains(".buttonStyle(.bordered)"))
    #expect(faucet.contains("NSPasteboard") == false)
    #expect(source.firstRange(of: "Copy address")!.lowerBound
        < source.firstRange(of: "Open Sepolia faucet")!.lowerBound)
}

@Test func activationScreenUsesCompactDashSeparatedStatus() throws {
    let source = try appSource(named: "OnboardingView.swift")
    let activation = try sourceSlice(
        source,
        from: "private struct BundlerActivationStep",
        until: "private struct SyncStep"
    )

    #expect(activation.contains("OnboardingGlassCard") == false)
    #expect(activation.contains("statusText(") == false)
    #expect(activation.contains("Waiting for deposit —"))
    #expect(activation.contains(" detected — "))
    #expect(activation.contains(" required"))
    #expect(activation.contains("Deposit detected —"))
    #expect(activation.contains("Retry check"))
    #expect(activation.contains("·") == false)
}
```

- [ ] **Step 2: Run the focused test and confirm it fails**

Run:

```bash
swift test --package-path wallet-macos --filter OnboardingBundlerActivationTests
```

Expected: FAIL because the actions are still borderless and the status still uses `OnboardingGlassCard` and `statusText`.

### Task 2: Promote funding actions and collapse the passive status

**Files:**
- Modify: `wallet-macos/Sources/WalletMacOSApp/BundlerFundingPolicy.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/BundlerExternalFundingActions.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/OnboardingView.swift`
- Test: `wallet-macos/Tests/WalletMacOSAppTests/OnboardingBundlerActivationTests.swift`

**Interfaces:**
- Consumes: exact funding thresholds, `BundlerExternalFundingActions.compact`, `OnboardingBundlerActivationState`, and `WeiFormatter.ethDisplayString(fromHexWei:)`.
- Produces: `minimumBalanceDisplay`, updated `recommendedBalanceDisplay`, ranked funding actions, and a compact status row.

- [ ] **Step 1: Centralize the two display amounts**

```swift
static let minimumBalanceWeiHex = "0x11c37937e08000"       // 0.005 ETH
static let recommendedBalanceWeiHex = "0x2386f26fc10000"   // 0.01 ETH
static let minimumBalanceDisplay = "0.005 ETH"
static let recommendedBalanceDisplay = "0.01 ETH"
```

- [ ] **Step 2: Give the shared actions per-control hierarchy**

Keep the existing address field and clipboard implementation. Replace the borderless action row with:

```swift
HStack(spacing: 10) {
    Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            copied = false
        }
    } label: {
        Label(
            copied ? "Copied" : "Copy address",
            systemImage: copied ? "checkmark" : "doc.on.doc"
        )
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.borderedProminent)
    .tint(accent)
    .controlSize(compact ? .small : .large)
    .accessibilityHint(
        "Copies the bundler address for funding from another wallet"
    )

    Link(destination: faucetURL) {
        Label("Open Sepolia faucet", systemImage: "safari")
            .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .tint(accent)
    .controlSize(compact ? .small : .large)
    .accessibilityHint("Opens the faucet without changing the clipboard")
}
```

- [ ] **Step 3: Clarify the funding copy**

```swift
Text("Fund your relayer")
    .font(.system(size: 21, weight: .bold))
    .foregroundStyle(OnboardingPalette.primaryText)
Text(
    "Send at least \(BundlerFundingPolicy.minimumBalanceDisplay) on Sepolia — "
        + "\(BundlerFundingPolicy.recommendedBalanceDisplay) recommended."
)
    .font(.system(size: 14, weight: .medium))
    .foregroundStyle(OnboardingPalette.secondaryText)
    .fixedSize(horizontal: false, vertical: true)
```

- [ ] **Step 4: Replace the status card with compact status rows**

Replace `activationStatus` and delete `statusText(title:detail:)`:

```swift
@ViewBuilder
private var activationStatus: some View {
    switch state.bundlerActivationState {
    case .idle, .checking:
        activationStatusLine(
            text: "Checking balance — updates automatically",
            showsProgress: true
        )
    case .waiting(let balance):
        activationStatusLine(
            text: "Waiting for deposit — "
                + "\(balance.map(WeiFormatter.ethDisplayString(fromHexWei:)) ?? \"0 ETH\") detected — "
                + "\(BundlerFundingPolicy.minimumBalanceDisplay) required",
            showsProgress: true
        )
    case .ready(let balance):
        activationStatusLine(
            text: "Deposit detected — \(WeiFormatter.ethDisplayString(fromHexWei: balance))",
            icon: "checkmark.circle.fill",
            color: OnboardingPalette.success
        )
    case .failed(let message):
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(OnboardingPalette.warning)
                .accessibilityHidden(true)
            Text("Couldn’t verify balance — \(message)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OnboardingPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Retry check") {
                state.refreshBundlerActivationNow()
            }
            .buttonStyle(OnboardingTextButtonStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }
}

private func activationStatusLine(
    text: String,
    icon: String? = nil,
    color: Color = OnboardingPalette.secondaryText,
    showsProgress: Bool = false
) -> some View {
    HStack(spacing: 10) {
        if showsProgress {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        } else if let icon {
            Image(systemName: icon)
                .foregroundStyle(color)
                .accessibilityHidden(true)
        }
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    .accessibilityElement(children: .combine)
}
```

- [ ] **Step 5: Run the focused activation suite**

```bash
swift test --package-path wallet-macos --filter OnboardingBundlerActivationTests
```

Expected: PASS. Existing tests still prove threshold gating, polling, cancellation, stale-run rejection, and funded-to-unfunded demotion.

- [ ] **Step 6: Commit the tested UI change**

```bash
git add wallet-macos/Sources/WalletMacOSApp/BundlerFundingPolicy.swift \
  wallet-macos/Sources/WalletMacOSApp/BundlerExternalFundingActions.swift \
  wallet-macos/Sources/WalletMacOSApp/OnboardingView.swift \
  wallet-macos/Tests/WalletMacOSAppTests/OnboardingBundlerActivationTests.swift
git commit -m "fix: clarify bundler activation actions"
```

### Task 3: Run regressions and build the app

**Files:**
- Verify only; no source changes expected.

**Interfaces:**
- Consumes: the complete Swift package and generated `LocalWallet.xcodeproj`.
- Produces: evidence that the shared dashboard rendering, onboarding behavior, and app target still compile.

- [ ] **Step 1: Run the dashboard audit because the action component is shared**

```bash
swift test --package-path wallet-macos --filter DashboardChromeAuditTests
```

Expected: PASS.

- [ ] **Step 2: Run the full Swift suite**

```bash
swift test --package-path wallet-macos
```

Expected: PASS with no activation or dashboard failures.

- [ ] **Step 3: Build the macOS app without signing**

```bash
xcodebuild -project LocalWallet.xcodeproj \
  -scheme LocalWalletApp \
  -configuration Debug \
  -destination platform=macOS \
  -derivedDataPath /tmp/local-wallet-activation-hierarchy-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Confirm repository hygiene**

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; the only remaining unstaged project diff is the user's personal Xcode signing configuration.
