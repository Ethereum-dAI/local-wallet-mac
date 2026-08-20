import Foundation
import Testing

/// The nudge + clause join must exist in exactly ONE place.
///
/// Five `wallet-eval` runners each carried their own copy of the system prompt, so a
/// prompt edit reached whichever the author remembered. That was fixed by routing them
/// all through `ToolDefinitions.appSystemPrompt` — but `EmbeddedLlamaInferenceService`,
/// the only path a user actually talks to, kept interpolating `systemNudge` and
/// `safetyClause` itself, and the doc comment asserting otherwise cited a test
/// (`appPromptCarriesTheSafetyClause`) that never read that file.
///
/// A behavioural test cannot catch the next copy: two hand-built joins are
/// byte-identical right up until someone changes the separator in one of them, and the
/// call site is buried in a closure that needs a live `LlamaRuntime`. So this is a
/// source audit, in the same spirit as `ProductCopyPunctuationAuditTests` — it checks
/// the shape of the code rather than its output.
@Suite struct SafetyTailSingleSourceAuditTests {
    @Test func noSourceOutsideToolDefinitionsBuildsTheSafetyTail() throws {
        let sources = packageRoot().appendingPathComponent("Sources", isDirectory: true)
        let files = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
            .filter { !$0.hasSuffix("WalletToolLayer/ToolDefinitions.swift") }
            .sorted()

        var offenders: [String] = []
        for relativePath in files {
            let source = try String(
                contentsOf: sources.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for (offset, line) in source.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                // Both constants named on one line means the join is being rebuilt here.
                // Referring to either one alone is fine: `ModelSelfTest` sends the nudge
                // by itself on purpose.
                if line.contains("ToolDefinitions.systemNudge"),
                   line.contains("ToolDefinitions.safetyClause") {
                    offenders.append("\(relativePath):\(offset + 1): \(line)")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            Comment(rawValue: """
            These build the nudge + clause join by hand. Call \
            ToolDefinitions.chatSystemPrompt(persona:) or read \
            ToolDefinitions.safetyTail instead, so the separator lives in one place:
            \(offenders.joined(separator: "\n"))
            """)
        )
    }

    /// The chat path must reach the tail through the shared helper, not by naming the
    /// pieces. Deleting the call and inlining the join again would pass the audit above
    /// only if it also dropped one of the two constant names, so pin the call itself.
    @Test func theChatPathCallsTheSharedComposer() throws {
        let service = packageRoot()
            .appendingPathComponent("Sources/WalletMacOSApp/EmbeddedLlamaInferenceService.swift")
        let source = try String(contentsOf: service, encoding: .utf8)
        #expect(source.contains("ToolDefinitions.chatSystemPrompt(persona: personaSystemPrompt())"))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
