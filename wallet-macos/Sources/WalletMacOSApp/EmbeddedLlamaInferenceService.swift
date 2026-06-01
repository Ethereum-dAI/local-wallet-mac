import Foundation
import LocalLLM
import WalletToolLayer

struct EmbeddedLlamaGenerationResult: Equatable {
    let response: String
    let thinking: String?
    let duration: TimeInterval
    let promptTokens: Int
    let generatedTokens: Int
    let contextSize: Int
    let toolCalls: [ParsedToolCall]

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

enum EmbeddedLlamaStreamEvent {
    case token(String)
    case completed(EmbeddedLlamaGenerationResult)
}

/// Some Gemma 4 builds leak the reasoning channel into the content stream as
/// literal `<|channel>thought ... <channel|>` markers that the upstream
/// common_chat_parse does not currently split. Re-extract them here so the
/// dashboard can still render reasoning in its own disclosure.
struct GemmaStreamingSplit {
    let reasoning: String?
    let content: String
}

enum GemmaChannelFallback {
    static let openMarker = "<|channel>"
    static let closeMarker = "<channel|>"

    static func streamingSplit(of text: String) -> GemmaStreamingSplit {
        guard let openRange = text.range(of: openMarker) else {
            return GemmaStreamingSplit(reasoning: nil, content: text)
        }
        let prefix = String(text[..<openRange.lowerBound])
        if let closeRange = text.range(of: closeMarker, range: openRange.upperBound..<text.endIndex) {
            let inner = String(text[openRange.upperBound..<closeRange.lowerBound])
            let reasoning = stripChannelName(inner)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = String(text[closeRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            let body: String
            if trimmedPrefix.isEmpty {
                body = suffix
            } else if suffix.isEmpty {
                body = trimmedPrefix
            } else {
                body = trimmedPrefix + "\n\n" + suffix
            }
            return GemmaStreamingSplit(
                reasoning: reasoning.isEmpty ? nil : reasoning,
                content: body
            )
        }
        let inner = String(text[openRange.upperBound...])
        let reasoning = stripChannelName(inner)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return GemmaStreamingSplit(
            reasoning: reasoning.isEmpty ? nil : reasoning,
            content: prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func normalise(_ parsed: ParsedAssistantTurnFlat) -> ParsedAssistantTurnFlat {
        let trimmedReasoning = parsed.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedReasoning.isEmpty,
              let content = parsed.content,
              content.contains(openMarker)
        else {
            return parsed
        }
        let split = streamingSplit(of: content)
        return ParsedAssistantTurnFlat(
            content: split.content.isEmpty ? nil : split.content,
            reasoning: split.reasoning,
            toolCalls: parsed.toolCalls
        )
    }

    private static func stripChannelName(_ text: String) -> String {
        var iterator = text.unicodeScalars.makeIterator()
        var nameLength = 0
        while let scalar = iterator.next(), CharacterSet.letters.contains(scalar) {
            nameLength += 1
        }
        if nameLength == 0 {
            return text
        }
        return String(text.dropFirst(nameLength))
    }
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

    func stream(
        prompt: String,
        history: [EmbeddedLlamaChatTurn],
        thinkingEnabled: Bool
    ) -> AsyncThrowingStream<EmbeddedLlamaStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    let modelURL = try installedModelURL()
                    if !runtime.isLoaded {
                        try runtime.loadModel(at: modelURL)
                    }

                    var messages: [LocalLLM.ChatMessage] = [
                        LocalLLM.ChatMessage(
                            role: LocalLLM.ChatMessage.Role.system,
                            content: "\(personaSystemPrompt())\n\n\(ToolDefinitions.systemNudge)"
                        )
                    ]
                    messages.append(contentsOf: history.map { turn in
                        switch turn.role {
                        case .user:
                            return LocalLLM.ChatMessage(role: LocalLLM.ChatMessage.Role.user, content: turn.text)
                        case .assistant:
                            return LocalLLM.ChatMessage(role: LocalLLM.ChatMessage.Role.assistant, content: turn.text)
                        }
                    })
                    messages.append(LocalLLM.ChatMessage(role: LocalLLM.ChatMessage.Role.user, content: prompt))

                    var options = SamplerOptions()
                    options.maxTokens = 384
                    options.temperature = thinkingEnabled ? 0.7 : 0.3
                    options.enableThinking = thinkingEnabled

                    var accumulated = ""
                    var stats: GenerationStats?
                    for try await event in runtime.chat(messages: messages, tools: ToolDefinitions.phase1, options: options) {
                        try Task.checkCancellation()
                        switch event {
                        case .textToken(let token):
                            accumulated += token
                            continuation.yield(.token(token))
                        case .done(let generationStats, stopReason: _):
                            stats = generationStats
                        }
                    }

                    let extracted: ParsedAssistantTurnFlat
                    do {
                        extracted = try BridgePEGExtractor(runtime: runtime).extract(from: accumulated)
                    } catch {
                        extracted = ParsedAssistantTurnFlat(content: accumulated, reasoning: nil, toolCalls: [])
                    }
                    let parsed = GemmaChannelFallback.normalise(extracted)
                    let generationStats = stats ?? GenerationStats(
                        promptTokens: 0,
                        generatedTokens: 0,
                        contextSize: runtime.configuredContextSize,
                        duration: 0
                    )

                    let result = EmbeddedLlamaGenerationResult(
                        response: (parsed.content ?? accumulated).trimmingCharacters(in: .whitespacesAndNewlines),
                        thinking: parsed.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines),
                        duration: generationStats.duration,
                        promptTokens: generationStats.promptTokens,
                        generatedTokens: generationStats.generatedTokens,
                        contextSize: generationStats.contextSize,
                        toolCalls: parsed.toolCalls
                    )
                    continuation.yield(.completed(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func installedModelURL() throws -> URL {
        if let path = settingsStore.installedModelPath, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let localURL = try downloadManager.localFileURL(for: .recommended)
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }
        if let bundledURL = downloadManager.bundledFileURL(for: .recommended),
           FileManager.default.fileExists(atPath: bundledURL.path) {
            return bundledURL
        }
        return localURL
    }

    private func personaSystemPrompt() -> String {
        return """
        You are the local AI inside a macOS Ethereum wallet app.
        Reply in Markdown.
        Use the available wallet tools when the user asks to perform an on-chain action.
        If the request is not a wallet action, answer directly and concisely.
        Do not expose hidden chain-of-thought.
        """
    }
}
