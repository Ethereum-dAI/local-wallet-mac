# Active Footer Status Highlights Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Thinking on and Session key active immediately distinguishable in the dashboard footer without changing either feature's behavior.

**Architecture:** Extend the existing private `StatusPill` component with one inactive-by-default highlight input, then bind that input to the existing Thinking and Session key state sources. Keep all styling inside `StatusPill` so no call site duplicates fill, text, or border rules.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing

## Global Constraints

- Work from synchronized `main` in the clean integration clone.
- Do not modify `LocalWallet.xcodeproj/project.pbxproj` or the original worktree's local signing override.
- Reuse `ChatPalette` and `StatusPill`; introduce no new color token or animation.
- Highlight Thinking only when `thinkingEnabled` is true.
- Highlight Session key only when `statusTitle` is exactly `Active`.
- Keep explicit state text so meaning never depends on color.
- Do not use em dashes in product copy.

---

### Task 1: Add semantic active styling to footer status pills

**Files:**
- Modify: `wallet-macos/Tests/WalletMacOSAppTests/DashboardChromeAuditTests.swift`
- Modify: `wallet-macos/Sources/WalletMacOSApp/ChatDashboardView.swift:4797-4852`
- Modify: `wallet-macos/Sources/WalletMacOSApp/ChatDashboardView.swift:7592-7610`

**Interfaces:**
- Consumes: `ChatDashboardModel.thinkingEnabled`, `LocalWalletSessionSettingsSnapshot.statusTitle`, and existing `ChatPalette` colors.
- Produces: `StatusPill(icon:text:tint:isHighlighted:)` where `isHighlighted` defaults to `false`.

- [ ] **Step 1: Write the failing dashboard chrome audit**

Add this test to `DashboardChromeAuditTests`:

```swift
@Test func activeFooterControlsUseSemanticHighlights() throws {
    let source = try dashboardSource()
    let footer = try slice(source, from: "private var footerControls", until: "private var composer")
    let statusPill = try slice(
        source,
        from: "private struct StatusPill",
        until: "private struct SessionStatusPopover"
    )

    #expect(footer.contains("isHighlighted: model.thinkingEnabled"))
    #expect(footer.contains("isHighlighted: sessionPillIsHighlighted"))
    #expect(source.contains("model.settingsSnapshot.session.statusTitle == \"Active\""))
    #expect(footer.contains(".accessibilityLabel(\"Thinking\")"))
    #expect(footer.contains(".accessibilityValue(model.thinkingEnabled ? \"On\" : \"Off\")"))
    #expect(statusPill.contains("var isHighlighted = false"))
    #expect(statusPill.contains("isHighlighted ? ChatPalette.primaryText : ChatPalette.secondaryText"))
    #expect(statusPill.contains("isHighlighted ? ChatPalette.selectedPanel : ChatPalette.panel"))
    #expect(statusPill.contains("isHighlighted ? tint.opacity(0.8) : ChatPalette.border"))
}
```

- [ ] **Step 2: Run the focused test and confirm it fails**

Run:

```bash
swift test --package-path wallet-macos --filter DashboardChromeAuditTests
```

Expected: the new test fails because `StatusPill` has no `isHighlighted` input and neither footer control binds active state.

- [ ] **Step 3: Implement the reusable highlight state**

Add the exact Session key highlight predicate near the existing Session pill presentation helpers:

```swift
private var sessionPillIsHighlighted: Bool {
    model.settingsSnapshot.session.statusTitle == "Active"
}
```

Update the Thinking call site:

```swift
StatusPill(
    icon: model.thinkingEnabled ? "brain" : "brain.head.profile",
    text: model.thinkingEnabled ? "Thinking on" : "Thinking off",
    tint: model.thinkingEnabled ? ChatPalette.accent : ChatPalette.secondaryText,
    isHighlighted: model.thinkingEnabled
)
```

Add these modifiers to the Thinking button after `.buttonStyle(.plain)`:

```swift
.accessibilityLabel("Thinking")
.accessibilityValue(model.thinkingEnabled ? "On" : "Off")
.help("Toggle model thinking")
```

Update the Session key call site:

```swift
StatusPill(
    icon: sessionPillIcon,
    text: sessionPillText,
    tint: sessionPillTint,
    isHighlighted: sessionPillIsHighlighted
)
```

Extend `StatusPill` and centralize all active styling:

```swift
private struct StatusPill: View {
    let icon: String
    let text: String
    var tint: Color = ChatPalette.secondaryText
    var isHighlighted = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isHighlighted ? ChatPalette.primaryText : ChatPalette.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(
            Capsule()
                .fill(isHighlighted ? ChatPalette.selectedPanel : ChatPalette.panel)
                .overlay(
                    Capsule().stroke(
                        isHighlighted ? tint.opacity(0.8) : ChatPalette.border,
                        lineWidth: isHighlighted ? 1 : 0.8
                    )
                )
        )
    }
}
```

- [ ] **Step 4: Run the focused dashboard test**

Run:

```bash
swift test --package-path wallet-macos --filter DashboardChromeAuditTests
```

Expected: all `DashboardChromeAuditTests` pass.

- [ ] **Step 5: Run full Swift verification**

Run:

```bash
swift test --package-path wallet-macos
git diff --check
```

Expected: all Swift package tests pass and `git diff --check` produces no output.

- [ ] **Step 6: Commit the tested implementation**

```bash
git add wallet-macos/Sources/WalletMacOSApp/ChatDashboardView.swift \
    wallet-macos/Tests/WalletMacOSAppTests/DashboardChromeAuditTests.swift
git commit -m "feat: highlight active assistant controls"
```

