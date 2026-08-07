import Foundation
import LocalLLM
import WalletToolLayer

enum LocalAIModelSelfTestError: Error, Equatable {
    case outOfMemory
}

enum ModelSelfTestResult: Equatable, Sendable {
    case ready(contextTokens: Int)
    case steppedDown(from: Int, to: Int)
    case noToolSupport
    case failed(String)
}

/// The seam that lets the step-down logic be tested without a 4.6 GB file.
///
/// `probeToolCall` is `async` rather than the brief's synchronous
/// `throws -> Bool`: the real implementation drains an `AsyncThrowingStream`
/// from `LlamaRuntime.chat`, and blocking a thread on a `DispatchSemaphore`
/// while a Swift-concurrency task is in flight risks priority inversion (and,
/// on a starved executor, deadlock) — unacceptable for up to two minutes in an
/// app that also has to keep the daemon responsive. `async throws` lets the
/// caller `await` it on a normal cooperative thread instead.
protocol ModelProbeRuntime {
    func load(at url: URL, contextTokens: Int) throws
    func probeToolCall() async throws -> Bool
    func unload()
}

/// Loads a freshly downloaded model for real, dropping the context window one
/// preset at a time until it fits, then checks the model can emit a tool call —
/// which is the only capability a wallet actually needs from it.
struct ModelSelfTest {
    private let runtime: ModelProbeRuntime

    init(runtime: ModelProbeRuntime) {
        self.runtime = runtime
    }

    func run(
        modelURL: URL,
        requestedContextTokens: Int,
        trainedContextTokens: Int
    ) async -> ModelSelfTestResult {
        let ladder = ContextWindowPresets
            .options(maxTokens: trainedContextTokens)
            .filter { $0 <= requestedContextTokens }
            .sorted(by: >)
        guard !ladder.isEmpty else {
            return .failed("No context preset is small enough for this model.")
        }

        var lastError = "The model could not be loaded."
        for tokens in ladder {
            do {
                try runtime.load(at: modelURL, contextTokens: tokens)
            } catch {
                lastError = error.localizedDescription
                continue
            }
            defer { runtime.unload() }
            guard (try? await runtime.probeToolCall()) == true else {
                return .noToolSupport
            }
            return tokens == requestedContextTokens
                ? .ready(contextTokens: tokens)
                : .steppedDown(from: requestedContextTokens, to: tokens)
        }
        return .failed(lastError)
    }
}

/// The real probe: a throwaway `LlamaRuntime` plus one fixed prompt that must come
/// back as a tool call.
final class LlamaProbeRuntime: ModelProbeRuntime {
    private var runtime: LlamaRuntime?

    func load(at url: URL, contextTokens: Int) throws {
        let candidate = LlamaRuntime(configuration: LocalLLMConfiguration(contextSize: Int32(contextTokens)))
        try candidate.loadModel(at: url)
        runtime = candidate
    }

    func probeToolCall() async throws -> Bool {
        guard let runtime else { return false }
        var options = SamplerOptions()
        options.maxTokens = 128
        options.temperature = 0
        let messages = [
            LocalLLM.ChatMessage(role: .system, content: ToolDefinitions.systemNudge),
            LocalLLM.ChatMessage(role: .user, content: "Send 0.001 ETH to 0x000000000000000000000000000000000000dEaD"),
        ]
        var accumulated = ""
        for try await event in runtime.chat(messages: messages, tools: ToolDefinitions.phase1, options: options) {
            if case .textToken(let token) = event { accumulated += token }
        }
        let parsed = try? BridgePEGExtractor(runtime: runtime).extract(from: accumulated)
        return parsed?.toolCalls.isEmpty == false
    }

    func unload() {
        runtime?.unload()
        runtime = nil
    }
}
