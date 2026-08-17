# Reasoning Marker Sanitization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent recognized reasoning-channel tags from appearing inside the Thinking disclosure for new and previously stored chat messages.

**Architecture:** Add one pure outer-marker sanitizer to `ReasoningChannelFallback`. Use it when normalizing parsed assistant turns and at the completed-message display boundary; keep streaming parsing on the existing marker-aware splitter and sanitize its reasoning before rendering.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, llama.cpp assistant-turn parsing.

## Global Constraints

- Strip only complete recognized outer pairs from `ReasoningMarkers.all`.
- Preserve embedded, unmatched, or ordinary marker examples unchanged.
- Preserve parsed content and tool calls exactly.
- Do not migrate or rewrite the chat SQLite database.
- Keep marker logic DRY in `ReasoningChannelFallback`.

---

### Task 1: Add marker-aware reasoning sanitization

**Files:**
- Modify: `wallet-macos/Sources/WalletMacOSApp/EmbeddedLlamaInferenceService.swift:66-166`
- Test: `wallet-macos/Tests/WalletMacOSAppTests/ReasoningChannelFallbackTests.swift`

**Interfaces:**
- Consumes: `ReasoningMarkers.all` and `ParsedAssistantTurnFlat`.
- Produces: `ReasoningChannelFallback.sanitizedReasoning(_:) -> String?` and a normalized parsed reasoning field.

- [ ] **Step 1: Write failing sanitizer and normalization tests**

```swift
@Test func normaliseStripsMarkersFromAnExistingReasoningField() {
    let parsed = ParsedAssistantTurnFlat(
        content: nil,
        reasoning: "<think>Which token? ETH or another ERC-20?</think>",
        toolCalls: []
    )
    let result = ReasoningChannelFallback.normalise(parsed)
    #expect(result.reasoning == "Which token? ETH or another ERC-20?")
}

@Test func sanitizerPreservesEmbeddedOrUnmatchedMarkerExamples() {
    #expect(ReasoningChannelFallback.sanitizedReasoning("Explain <think> tags") == "Explain <think> tags")
    #expect(ReasoningChannelFallback.sanitizedReasoning("<think>unfinished") == "<think>unfinished")
}

@Test func sanitizerDropsAnEmptyOuterBlock() {
    #expect(ReasoningChannelFallback.sanitizedReasoning(" <think>  </think> ") == nil)
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `swift test --package-path wallet-macos --filter ReasoningChannelFallbackTests`

Expected: FAIL because `sanitizedReasoning` does not exist and existing reasoning remains wrapped.

- [ ] **Step 3: Implement the pure sanitizer and use it in `normalise`**

```swift
static func sanitizedReasoning(_ reasoning: String?) -> String? {
    guard let reasoning else { return nil }
    let trimmed = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    for markers in ReasoningMarkers.all {
        guard trimmed.hasPrefix(markers.open), trimmed.hasSuffix(markers.close) else {
            continue
        }
        let bodyStart = trimmed.index(trimmed.startIndex, offsetBy: markers.open.count)
        let bodyEnd = trimmed.index(trimmed.endIndex, offsetBy: -markers.close.count)
        guard bodyStart <= bodyEnd else { continue }
        let body = String(trimmed[bodyStart..<bodyEnd])
        let sanitized = strippedChannelName(body, markers: markers)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }

    return trimmed
}
```

Update `normalise` so a non-empty `parsed.reasoning` is rebuilt with `sanitizedReasoning(parsed.reasoning)` instead of returned unchanged. Continue using `streamingSplit` only when the parser supplied no reasoning and content contains a marker.

- [ ] **Step 4: Run focused tests**

Run: `swift test --package-path wallet-macos --filter ReasoningChannelFallbackTests`

Expected: all `ReasoningChannelFallbackTests` pass.

- [ ] **Step 5: Commit the parser boundary**

```bash
git add wallet-macos/Sources/WalletMacOSApp/EmbeddedLlamaInferenceService.swift \
    wallet-macos/Tests/WalletMacOSAppTests/ReasoningChannelFallbackTests.swift
git commit -m "fix: sanitize reasoning channel markers"
```

### Task 2: Repair rendering of previously stored reasoning

**Files:**
- Modify: `wallet-macos/Sources/WalletMacOSApp/ChatDashboardView.swift:6830-6970,7420-7470`
- Test: `wallet-macos/Tests/WalletMacOSAppTests/ReasoningChannelFallbackTests.swift`

**Interfaces:**
- Consumes: `ReasoningChannelFallback.sanitizedReasoning(_:)` from Task 1.
- Produces: marker-free completed and streaming Thinking disclosures without changing persisted rows.

- [ ] **Step 1: Add a failing display-boundary audit**

```swift
@Test func dashboardSanitizesStoredAndStreamingReasoningBeforeRendering() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let sourceURL = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/WalletMacOSApp/ChatDashboardView.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    #expect(source.contains("ReasoningChannelFallback.sanitizedReasoning(message.thinking)"))
    #expect(source.contains("ReasoningChannelFallback.sanitizedReasoning(parts.reasoning)"))
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `swift test --package-path wallet-macos --filter ReasoningChannelFallbackTests`

Expected: FAIL because both disclosures currently render raw reasoning values.

- [ ] **Step 3: Sanitize both display paths**

In `ChatBubble`, derive the displayed value once:

```swift
private var displayedThinking: String? {
    ReasoningChannelFallback.sanitizedReasoning(message.thinking)
}
```

Render `displayedThinking` instead of `message.thinking`. In `StreamingAssistantBubble`, call `ReasoningChannelFallback.sanitizedReasoning(parts.reasoning)` before passing reasoning to `MarkdownMessageText`.

- [ ] **Step 4: Run focused and full verification**

Run: `swift test --package-path wallet-macos --filter ReasoningChannelFallbackTests`

Expected: all focused tests pass.

Run: `swift test --package-path wallet-macos`

Expected: all Swift package tests pass.

Run: `git diff --check`

Expected: no output.

- [ ] **Step 5: Commit the display fallback**

```bash
git add wallet-macos/Sources/WalletMacOSApp/ChatDashboardView.swift \
    wallet-macos/Tests/WalletMacOSAppTests/ReasoningChannelFallbackTests.swift
git commit -m "fix: hide reasoning markers in chat history"
```
