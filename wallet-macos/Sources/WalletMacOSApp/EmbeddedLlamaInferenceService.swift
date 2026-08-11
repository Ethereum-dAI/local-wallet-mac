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

/// Some models leak their reasoning channel into the content stream as literal
/// markers that the upstream `common_chat_parse` does not split for us. Re-extract
/// them here so the dashboard can render reasoning in its own disclosure instead of
/// printing it as the answer.
///
/// Two marker styles are handled, because the app now runs more than one model:
/// Gemma's `<|channel>thought … <channel|>` and the `<think> … </think>` used by
/// Qwen3 and other reasoning models. Adding a style is a one-line change to
/// `ReasoningMarkers.all`.
struct ReasoningSplit {
    let reasoning: String?
    let content: String
}

struct ReasoningMarkers {
    let open: String
    let close: String
    /// Gemma writes a channel name straight after the opening marker
    /// (`<|channel>thought`); it is routing metadata, not reasoning. `<think>` has
    /// no such name, and stripping leading letters there would eat the first word.
    let hasChannelName: Bool

    static let all: [ReasoningMarkers] = [
        ReasoningMarkers(open: "<|channel>", close: "<channel|>", hasChannelName: true),
        ReasoningMarkers(open: "<think>", close: "</think>", hasChannelName: false),
    ]
}

enum ReasoningChannelFallback {
    static func streamingSplit(of text: String) -> ReasoningSplit {
        if let opened = firstOpen(in: text) {
            return splitAtOpen(text, markers: opened.markers, openRange: opened.range)
        }
        // A close marker with nothing opening it: several chat templates pre-fill
        // the opening tag, so the model's own output begins *inside* the reasoning
        // and only ever emits the closing one. Everything before it is reasoning.
        if let closed = firstClose(in: text) {
            let reasoning = String(text[..<closed.range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let content = String(text[closed.range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ReasoningSplit(reasoning: reasoning.isEmpty ? nil : reasoning, content: content)
        }
        return ReasoningSplit(reasoning: nil, content: text)
    }

    static func normalise(_ parsed: ParsedAssistantTurnFlat) -> ParsedAssistantTurnFlat {
        let trimmedReasoning = parsed.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedReasoning.isEmpty,
              let content = parsed.content,
              containsAnyMarker(content)
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

    static func containsAnyMarker(_ text: String) -> Bool {
        ReasoningMarkers.all.contains { text.contains($0.open) || text.contains($0.close) }
    }

    // MARK: - Internals

    /// Earliest opening marker of any style, so a model that emits both is split at
    /// whichever actually came first rather than at whichever we happened to check.
    private static func firstOpen(in text: String) -> (markers: ReasoningMarkers, range: Range<String.Index>)? {
        ReasoningMarkers.all
            .compactMap { markers in text.range(of: markers.open).map { (markers, $0) } }
            .min { $0.1.lowerBound < $1.1.lowerBound }
    }

    private static func firstClose(in text: String) -> (markers: ReasoningMarkers, range: Range<String.Index>)? {
        ReasoningMarkers.all
            .compactMap { markers in text.range(of: markers.close).map { (markers, $0) } }
            .min { $0.1.lowerBound < $1.1.lowerBound }
    }

    private static func splitAtOpen(
        _ text: String,
        markers: ReasoningMarkers,
        openRange: Range<String.Index>
    ) -> ReasoningSplit {
        let prefix = String(text[..<openRange.lowerBound])
        guard let closeRange = text.range(
            of: markers.close,
            range: openRange.upperBound..<text.endIndex
        ) else {
            // Still streaming: the reasoning has opened and not closed, so nothing
            // after the marker is content yet.
            let inner = String(text[openRange.upperBound...])
            let reasoning = strippedChannelName(inner, markers: markers)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ReasoningSplit(
                reasoning: reasoning.isEmpty ? nil : reasoning,
                content: prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let inner = String(text[openRange.upperBound..<closeRange.lowerBound])
        let reasoning = strippedChannelName(inner, markers: markers)
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
        return ReasoningSplit(reasoning: reasoning.isEmpty ? nil : reasoning, content: body)
    }

    private static func strippedChannelName(_ text: String, markers: ReasoningMarkers) -> String {
        guard markers.hasChannelName else { return text }
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

    /// Resize the context window without changing which model is loaded.
    ///
    /// Separate from `setActiveModel` because the context picker has no model URL
    /// to hand over: the active model may be one `prepareRuntime` resolved from
    /// `installedModelPath` rather than one anybody selected, and passing a URL
    /// here would be inventing a model switch. `prepareRuntime` compares the whole
    /// `(url, contextTokens)` pair, so moving this alone is enough to make the next
    /// message reload at the new size.
    func setContextTokens(_ tokens: Int) {
        stateLock.lock()
        desiredContextTokens = tokens
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
                    let parsed = ReasoningChannelFallback.normalise(extracted)
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

    /// The model file to load, resolved by `ModelFileResolver` — which prefers the
    /// stored path only when it still exists, then the *selected* model's own copies
    /// rather than the recommended model's. Both details matter: the recommended
    /// model's file name changes when the default changes, and the stored path can
    /// point into a bundle the user has since replaced.
    private func installedModelURL() throws -> URL {
        let selected = LocalAIModel.curated.first { $0.id == settingsStore.selectedModelID }
        let path = ModelFileResolver.resolve(
            storedPath: settingsStore.installedModelPath,
            selectedLocalPath: selected.flatMap { try? downloadManager.localFileURL(for: $0) }?.path,
            selectedBundledPath: selected.flatMap { downloadManager.bundledFileURL(for: $0) }?.path,
            fallbackPath: try downloadManager.localFileURL(for: .recommended).path,
            exists: { FileManager.default.fileExists(atPath: $0) }
        )
        return URL(fileURLWithPath: path)
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
