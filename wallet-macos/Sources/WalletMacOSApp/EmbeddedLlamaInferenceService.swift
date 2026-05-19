import Foundation
import LocalLLM

struct EmbeddedLlamaGenerationResult: Equatable {
    let response: String
    let thinking: String?
    let duration: TimeInterval
    let promptTokens: Int
    let generatedTokens: Int
    let contextSize: Int

    var usedContextTokens: Int {
        promptTokens + generatedTokens
    }

    var contextTokensLeft: Int {
        max(contextSize - usedContextTokens, 0)
    }
}

struct EmbeddedLlamaChatTurn: Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let role: Role
    let text: String
}

final class EmbeddedLlamaInferenceService: @unchecked Sendable {
    private let settingsStore: OnboardingSettingsStore
    private let downloadManager: LocalAIModelDownloadManager
    private let runtime: LlamaRuntime

    init(
        settingsStore: OnboardingSettingsStore = OnboardingSettingsStore(),
        downloadManager: LocalAIModelDownloadManager = LocalAIModelDownloadManager(),
        runtime: LlamaRuntime = LlamaRuntime()
    ) {
        self.settingsStore = settingsStore
        self.downloadManager = downloadManager
        self.runtime = runtime
    }

    var runtimeStatus: String {
        runtime.isLoaded ? "Local model loaded" : "Local runtime ready"
    }

    var contextSize: Int {
        runtime.configuredContextSize
    }

    func generate(
        prompt: String,
        history: [EmbeddedLlamaChatTurn],
        thinkingEnabled: Bool
    ) async throws -> EmbeddedLlamaGenerationResult {
        let modelURL = try installedModelURL()
        if !runtime.isLoaded {
            try runtime.loadModel(at: modelURL)
        }

        let requestPrompt = buildRequestPrompt(prompt, history: history, thinkingEnabled: thinkingEnabled)
        let startedAt = Date()
        let generation = try runtime.generateWithStats(requestPrompt)
        let parsed = parseResponse(generation.text, thinkingEnabled: thinkingEnabled)

        return EmbeddedLlamaGenerationResult(
            response: parsed.answer,
            thinking: parsed.thinking,
            duration: Date().timeIntervalSince(startedAt),
            promptTokens: generation.promptTokens,
            generatedTokens: generation.generatedTokens,
            contextSize: generation.contextSize
        )
    }

    private func installedModelURL() throws -> URL {
        if let path = settingsStore.installedModelPath, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return try downloadManager.localFileURL(for: .recommended)
    }

    private func buildRequestPrompt(
        _ prompt: String,
        history: [EmbeddedLlamaChatTurn],
        thinkingEnabled: Bool
    ) -> String {
        let transcript = history.map { turn in
            switch turn.role {
            case .user:
                return "User: \(turn.text)"
            case .assistant:
                return "Assistant: \(turn.text)"
            }
        }
        .joined(separator: "\n\n")

        if thinkingEnabled {
            return """
            You are the local AI inside a macOS Ethereum wallet app.
            Reply in Markdown.
            Only include <thinking>...</thinking> when the request needs multi-step reasoning, planning, or analysis.
            For greetings, identity questions, short factual answers, or simple follow-ups, omit thinking entirely.
            When you do include thinking, make it a brief user-facing reasoning summary.
            Put the final user-visible answer inside <answer>...</answer>.
            Keep the thinking summary concise and do not include hidden chain-of-thought.

            Conversation so far:
            \(transcript.isEmpty ? "No previous messages." : transcript)

            Current user request:
            \(prompt)
            """
        }

        return """
        You are the local AI inside a macOS Ethereum wallet app.
        Reply in Markdown.
        Do not include <thinking>, <think>, reasoning traces, or hidden chain-of-thought.
        Answer directly.

        Conversation so far:
        \(transcript.isEmpty ? "No previous messages." : transcript)

        Current user request:
        \(prompt)
        """
    }

    private func parseResponse(_ rawResponse: String, thinkingEnabled: Bool) -> (answer: String, thinking: String?) {
        var answer = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        let thinking = thinkingEnabled ? extractTaggedContent(from: answer, tags: ["thinking", "think"]) : nil

        for tag in ["thinking", "think"] {
            answer = removeTaggedContent(from: answer, tag: tag)
        }

        if let taggedAnswer = extractTaggedContent(from: answer, tags: ["answer"]) {
            answer = taggedAnswer
        } else {
            answer = removeTagMarkers(from: answer, tags: ["answer"])
        }

        return (
            answer.trimmingCharacters(in: .whitespacesAndNewlines),
            thinking?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    private func extractTaggedContent(from text: String, tags: [String]) -> String? {
        for tag in tags {
            let pattern = "<\\s*\(tag)\\s*>(.*?)<\\s*/\\s*\(tag)\\s*>"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
                continue
            }
            guard let contentRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            return String(text[contentRange])
        }
        return nil
    }

    private func removeTaggedContent(from text: String, tag: String) -> String {
        let pattern = "<\\s*\(tag)\\s*>.*?<\\s*/\\s*\(tag)\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private func removeTagMarkers(from text: String, tags: [String]) -> String {
        tags.reduce(text) { partial, tag in
            partial
                .replacingOccurrences(of: "<\(tag)>", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "</\(tag)>", with: "", options: .caseInsensitive)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
