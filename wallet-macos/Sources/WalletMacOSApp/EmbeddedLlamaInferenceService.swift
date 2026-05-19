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
            switch event {
            case .textToken(let token):
                accumulated += token
            case .done(let generationStats, stopReason: _):
                stats = generationStats
            }
        }

        let parsed: ParsedAssistantTurnFlat
        do {
            parsed = try BridgePEGExtractor(runtime: runtime).extract(from: accumulated)
        } catch {
            parsed = ParsedAssistantTurnFlat(content: accumulated, reasoning: nil, toolCalls: [])
        }
        let generationStats = stats ?? GenerationStats(
            promptTokens: 0,
            generatedTokens: 0,
            contextSize: runtime.configuredContextSize,
            duration: 0
        )

        return EmbeddedLlamaGenerationResult(
            response: (parsed.content ?? accumulated).trimmingCharacters(in: .whitespacesAndNewlines),
            thinking: parsed.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines),
            duration: generationStats.duration,
            promptTokens: generationStats.promptTokens,
            generatedTokens: generationStats.generatedTokens,
            contextSize: generationStats.contextSize,
            toolCalls: parsed.toolCalls
        )
    }

    private func installedModelURL() throws -> URL {
        if let path = settingsStore.installedModelPath, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return try downloadManager.localFileURL(for: .recommended)
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
