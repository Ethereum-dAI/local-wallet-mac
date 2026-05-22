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

    enum Payload: Equatable {
        case text(String)
        case audio(samples: [Float], durationSeconds: TimeInterval)
        case audioPlaceholder(durationSeconds: TimeInterval)
    }

    let role: Role
    let payload: Payload
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
    private let mmprojDownloadManager: LocalMmprojDownloadManager
    private let runtime: LlamaRuntime

    init(
        settingsStore: OnboardingSettingsStore = OnboardingSettingsStore(),
        downloadManager: LocalAIModelDownloadManager = LocalAIModelDownloadManager(),
        mmprojDownloadManager: LocalMmprojDownloadManager = LocalMmprojDownloadManager(),
        runtime: LlamaRuntime = LlamaRuntime()
    ) {
        self.settingsStore = settingsStore
        self.downloadManager = downloadManager
        self.mmprojDownloadManager = mmprojDownloadManager
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

                    let messages = buildMessages(
                        history: history,
                        pendingUserContent: prompt
                    )

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

    func streamAudio(
        samples: [Float],
        durationSeconds: TimeInterval,
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
                    try await ensureMmprojLoaded()
                    let marker = try requireMarker()

                    let messages = buildMessages(
                        history: history,
                        pendingUserContent: "\(marker) "
                    )

                    var options = SamplerOptions()
                    options.maxTokens = 384
                    options.temperature = thinkingEnabled ? 0.7 : 0.3
                    options.enableThinking = thinkingEnabled

                    var accumulated = ""
                    var stats: GenerationStats?
                    let audio = AudioAttachment(samples: samples, sampleRate: 16_000)
                    for try await event in runtime.chat(
                        messages: messages,
                        tools: ToolDefinitions.phase1,
                        options: options,
                        userAudio: audio
                    ) {
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
        return try downloadManager.localFileURL(for: .recommended)
    }

    func mmprojLocalURL() throws -> URL {
        try mmprojDownloadManager.localFileURL(for: .gemma4Audio)
    }

    func isMmprojInstalled() -> Bool {
        mmprojDownloadManager.isInstalled(.gemma4Audio)
    }

    func downloadMmproj(progress: @escaping LocalMmprojDownloadManager.ProgressHandler) async throws -> URL {
        try await mmprojDownloadManager.download(.gemma4Audio, progress: progress)
    }

    private func ensureMmprojLoaded() async throws {
        let url = try mmprojDownloadManager.localFileURL(for: .gemma4Audio)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalLLMError.mmprojLoadFailed("mmproj file missing; download first")
        }
        try runtime.loadMmproj(at: url)
    }

    private func requireMarker() throws -> String {
        guard let marker = runtime.mediaMarker else {
            throw LocalLLMError.mmprojNotLoaded
        }
        return marker
    }

    private func buildMessages(
        history: [EmbeddedLlamaChatTurn],
        pendingUserContent: String
    ) -> [LocalLLM.ChatMessage] {
        var messages: [LocalLLM.ChatMessage] = [
            LocalLLM.ChatMessage(
                role: .system,
                content: "\(personaSystemPrompt())\n\n\(ToolDefinitions.systemNudge)"
            )
        ]

        for turn in history {
            switch (turn.role, turn.payload) {
            case (.user, .text(let text)):
                messages.append(.init(role: .user, content: text))
            case (.assistant, .text(let text)):
                messages.append(.init(role: .assistant, content: text))
            case (.user, .audio(_, let durationSeconds)),
                 (.user, .audioPlaceholder(let durationSeconds)):
                messages.append(.init(role: .user, content: formatPlaceholder(durationSeconds: durationSeconds)))
            case (.assistant, .audio),
                 (.assistant, .audioPlaceholder):
                break
            }
        }

        messages.append(.init(role: .user, content: pendingUserContent))
        return messages
    }

    private func formatPlaceholder(durationSeconds: TimeInterval) -> String {
        let total = max(0, Int(durationSeconds.rounded()))
        return String(format: "[voice message · %d:%02d]", total / 60, total % 60)
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
