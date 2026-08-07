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
    private let stateLock = NSLock()
    private var runtime: LlamaRuntime
    private var loadedModelURL: URL?
    private var loadedContextTokens: Int?
    private var desiredModelURL: URL?
    private var desiredContextTokens: Int

    init(
        settingsStore: OnboardingSettingsStore = OnboardingSettingsStore(),
        downloadManager: LocalAIModelDownloadManager = LocalAIModelDownloadManager()
    ) {
        self.settingsStore = settingsStore
        self.downloadManager = downloadManager
        let model = LocalAIModel.curated.first { $0.id == settingsStore.selectedModelID } ?? .recommended
        let tokens = ContextWindowPresets.clamp(settingsStore.contextWindowTokens, maxTokens: model.maxContextTokens)
        self.desiredContextTokens = tokens
        self.runtime = LlamaRuntime(configuration: LocalLLMConfiguration(contextSize: Int32(tokens)))
    }

    /// Point the service at a different GGUF. The swap happens lazily, at the start
    /// of the next generation, so an in-flight stream is never pulled out from under
    /// its caller.
    func setActiveModel(url: URL, contextTokens: Int) {
        stateLock.lock()
        desiredModelURL = url
        desiredContextTokens = contextTokens
        stateLock.unlock()
    }

    /// Drops this service's loaded runtime so something else — the post-download
    /// self test — can load a model without two sets of weights being resident at
    /// once, which is exactly the OOM the fit verdicts exist to avoid. The next
    /// `stream()` reloads lazily via `prepareRuntime`, so the only cost is one
    /// model load on the next message.
    ///
    /// As in `prepareRuntime`, the old runtime is *released*, never `unload()`ed:
    /// an in-flight generation may still hold its own reference to it, and tearing
    /// down the native handle underneath that call would be a use-after-free.
    /// Callers should therefore only reach for this when no generation is running,
    /// or the weights they meant to free stay resident anyway.
    func releaseLoadedRuntime() {
        let replacement = LlamaRuntime(configuration: LocalLLMConfiguration(contextSize: Int32(contextSize)))
        stateLock.lock()
        runtime = replacement
        loadedModelURL = nil
        loadedContextTokens = nil
        stateLock.unlock()
    }

    var activeModelURL: URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return desiredModelURL ?? loadedModelURL
    }

    var runtimeStatus: String {
        stateLock.lock()
        let current = runtime
        stateLock.unlock()
        return current.isLoaded ? "Local model loaded" : "Local runtime ready"
    }

    var contextSize: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return desiredContextTokens
    }

    func stream(
        prompt: String,
        history: [EmbeddedLlamaChatTurn],
        thinkingEnabled: Bool
    ) -> AsyncThrowingStream<EmbeddedLlamaStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    let activeRuntime = try prepareRuntime()

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
                    for try await event in activeRuntime.chat(messages: messages, tools: ToolDefinitions.phase1, options: options) {
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
                        extracted = try BridgePEGExtractor(runtime: activeRuntime).extract(from: accumulated)
                    } catch {
                        extracted = ParsedAssistantTurnFlat(content: accumulated, reasoning: nil, toolCalls: [])
                    }
                    let parsed = GemmaChannelFallback.normalise(extracted)
                    let generationStats = stats ?? GenerationStats(
                        promptTokens: 0,
                        generatedTokens: 0,
                        contextSize: activeRuntime.configuredContextSize,
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

    /// Loads the desired model, swapping in a fresh runtime first when the
    /// selection or the context window changed. Returns the runtime this call's
    /// generation must use — callers hold onto that value rather than re-reading
    /// `runtime` later in the stream, so a concurrent swap triggered by another
    /// `stream()` call cannot switch the model out from under an in-flight
    /// generation.
    ///
    /// Every `stateLock` critical section here is a plain snapshot/assignment with
    /// no throwing call inside it: `installedModelURL()` can throw (e.g. no model
    /// installed yet), and `loadModel` can take seconds — neither may run while the
    /// lock is held, or a throw would leak the lock and deadlock every later caller.
    private func prepareRuntime() throws -> LlamaRuntime {
        stateLock.lock()
        let loaded = ModelLoadState(modelURL: loadedModelURL, contextTokens: loadedContextTokens)
        let desiredAtStart = DesiredModel(modelURL: desiredModelURL, contextTokens: desiredContextTokens)
        let current = runtime
        stateLock.unlock()

        let resolvedURL = try desiredAtStart.modelURL ?? installedModelURL()
        let target = ModelSwapTarget(modelURL: resolvedURL, contextTokens: desiredAtStart.contextTokens)

        guard ModelSwapPlanner.needsSwap(loaded: loaded, target: target) else {
            if !current.isLoaded {
                try current.loadModel(at: target.modelURL)
                stateLock.lock()
                loadedModelURL = target.modelURL
                loadedContextTokens = target.contextTokens
                stateLock.unlock()
            }
            return current
        }

        // Do NOT call `current.unload()` here. A second, concurrent `stream()`
        // call may already be mid-generation on `current`'s native llama.cpp
        // handle — `LlamaRuntime.chatBlocking` holds that handle and runs
        // `lllm_runtime_generate_v2` on it for the whole generation, outside
        // LlamaRuntime's own lock. Destroying the handle out from under that call
        // would be a use-after-free in llama.cpp. Instead we just drop our
        // reference to `current`; `LlamaRuntime.deinit` calls `unload()` itself,
        // so the native handle is torn down only once every holder — including
        // any in-flight generation's own `activeRuntime` snapshot — has released
        // it. Trade-off: while an overlapping swap is in flight, two runtimes (two
        // models' worth of memory) can be briefly resident at once; that costs
        // memory, never correctness.
        let replacement = LlamaRuntime(configuration: LocalLLMConfiguration(contextSize: Int32(target.contextTokens)))
        try replacement.loadModel(at: target.modelURL)

        stateLock.lock()
        let desiredNow = DesiredModel(modelURL: desiredModelURL, contextTokens: desiredContextTokens)
        if let committed = ModelSwapPlanner.commit(
            justLoaded: target,
            desiredAtLoadStart: desiredAtStart,
            desiredNow: desiredNow
        ) {
            // The desire has not moved on since this load started: adopt the
            // replacement as the service's shared runtime.
            runtime = replacement
            loadedModelURL = committed.modelURL
            loadedContextTokens = committed.contextTokens
        }
        // Else: `setActiveModel` landed a new desire while we were loading.
        // Leave `runtime`/`loadedModelURL`/`loadedContextTokens` untouched so the
        // next `prepareRuntime()` call still sees a mismatch against the newer
        // desire and swaps again — this load is not lost, it just isn't recorded
        // as current. `replacement` is still returned below for this call's own
        // generation to use.
        stateLock.unlock()
        return replacement
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
