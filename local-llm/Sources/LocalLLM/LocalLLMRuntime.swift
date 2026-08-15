import CLlamaBridge
import Foundation

public enum LocalLLMError: LocalizedError, Equatable {
    case modelNotFound(String)
    case loadFailed(String)
    case generationFailed(String)
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "Model file was not found at \(path)."
        case .loadFailed(let message):
            return message
        case .generationFailed(let message):
            return message
        case .notLoaded:
            return "The local model is not loaded."
        }
    }
}

public struct LocalLLMConfiguration: Sendable, Equatable {
    public var contextSize: Int32
    public var gpuLayers: Int32
    public var threads: Int32
    public var maxTokens: Int32
    public var temperature: Float

    public init(
        contextSize: Int32 = 4096,
        gpuLayers: Int32 = 99,
        threads: Int32 = 0,
        maxTokens: Int32 = 512,
        temperature: Float = 0.7
    ) {
        self.contextSize = contextSize
        self.gpuLayers = gpuLayers
        self.threads = threads
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public struct LocalLLMGeneration: Sendable, Equatable {
    public let text: String
    public let promptTokens: Int
    public let generatedTokens: Int
    public let contextSize: Int

    public var usedContextTokens: Int {
        promptTokens + generatedTokens
    }

    public var contextTokensLeft: Int {
        max(contextSize - usedContextTokens, 0)
    }
}

public final class LlamaRuntime: @unchecked Sendable {
    private let configuration: LocalLLMConfiguration
    internal let lock = NSLock()
    internal var handle: OpaquePointer?

    public init(configuration: LocalLLMConfiguration = LocalLLMConfiguration()) {
        self.configuration = configuration
    }

    deinit {
        unload()
    }

    public var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handle != nil
    }

    internal var embeddedChatTemplate: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, let templatePointer = lllm_runtime_chat_template(handle) else {
            return nil
        }
        return String(cString: templatePointer)
    }

    // Unsafe by design - for tests and llm-bench only.
    public var bridgeHandle: OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        return handle
    }

    public var configuredContextSize: Int {
        Int(configuration.contextSize)
    }

    public func loadModel(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalLLMError.modelNotFound(url.path)
        }

        lock.lock()
        if handle != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        let loadedHandle: OpaquePointer? = try withErrorBuffer { errorBuffer, errorLength in
            url.path.withCString { modelPath in
                lllm_runtime_create(
                    modelPath,
                    configuration.contextSize,
                    configuration.gpuLayers,
                    configuration.threads,
                    errorBuffer,
                    errorLength
                )
            }
        } errorMapper: { LocalLLMError.loadFailed($0) }

        guard let loadedHandle else {
            throw LocalLLMError.loadFailed("Failed to load local model.")
        }

        lock.lock()
        handle = loadedHandle
        lock.unlock()
    }

    @available(*, deprecated, message: "Use chat(messages:tools:options:) which returns an AsyncThrowingStream<ChatEvent, Error>. The new path supports the model's chat template, tools, sampler params, grammar, stop sequences, and cancellation.")
    public func generate(_ prompt: String) throws -> String {
        try generateWithStats(prompt).text
    }

    @available(*, deprecated, message: "Use chat(messages:tools:options:) and consume the final .done event for GenerationStats.")
    public func generateWithStats(_ prompt: String) throws -> LocalLLMGeneration {
        lock.lock()
        let currentHandle = handle
        lock.unlock()

        guard let currentHandle else {
            throw LocalLLMError.notLoaded
        }

        final class TokenAccumulator {
            var text = ""
        }

        let accumulator = TokenAccumulator()
        let promptTokens = try countPromptTokens(prompt, handle: currentHandle)
        let contextSize = max(runtimeContextSize(handle: currentHandle), configuredContextSize)

        let status: Int32 = try withErrorBuffer { errorBuffer, errorLength in
            prompt.withCString { promptPointer in
                let userData = Unmanaged.passUnretained(accumulator).toOpaque()
                return lllm_runtime_generate(
                    currentHandle,
                    promptPointer,
                    configuration.maxTokens,
                    configuration.temperature,
                    { tokenPointer, userData in
                        guard let tokenPointer, let userData else {
                            return
                        }
                        let accumulator = Unmanaged<TokenAccumulator>
                            .fromOpaque(userData)
                            .takeUnretainedValue()
                        accumulator.text += String(cString: tokenPointer)
                    },
                    userData,
                    errorBuffer,
                    errorLength
                )
            }
        } errorMapper: { LocalLLMError.generationFailed($0) }

        guard status >= 0 else {
            throw LocalLLMError.generationFailed("Generation failed with status \(status).")
        }

        return LocalLLMGeneration(
            text: accumulator.text.trimmingCharacters(in: .whitespacesAndNewlines),
            promptTokens: promptTokens,
            generatedTokens: Int(status),
            contextSize: contextSize
        )
    }

    @available(*, deprecated, message: "Use chat(messages:tools:options:) for real token-level streaming.")
    public func generateStream(_ prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let response = try self.generate(prompt)
                    continuation.yield(response)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func unload() {
        lock.lock()
        let currentHandle = handle
        handle = nil
        lock.unlock()

        if let currentHandle {
            lllm_runtime_destroy(currentHandle)
        }
    }

    private func withErrorBuffer<T>(
        _ body: (UnsafeMutablePointer<CChar>, Int32) throws -> T,
        errorMapper: (String) -> LocalLLMError
    ) throws -> T {
        var errorBuffer = [CChar](repeating: 0, count: 1024)
        let result = try errorBuffer.withUnsafeMutableBufferPointer { bufferPointer in
            try body(bufferPointer.baseAddress!, Int32(bufferPointer.count))
        }

        let bytes = errorBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let message = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            throw errorMapper(message)
        }

        return result
    }

    private func countPromptTokens(_ prompt: String, handle: OpaquePointer) throws -> Int {
        let count: Int32 = try withErrorBuffer { errorBuffer, errorLength in
            prompt.withCString { promptPointer in
                lllm_runtime_count_prompt_tokens(
                    handle,
                    promptPointer,
                    errorBuffer,
                    errorLength
                )
            }
        } errorMapper: { LocalLLMError.generationFailed($0) }

        guard count >= 0 else {
            throw LocalLLMError.generationFailed("Prompt token count failed with status \(count).")
        }

        return Int(count)
    }

    private func runtimeContextSize(handle: OpaquePointer) -> Int {
        Int(lllm_runtime_context_size(handle))
    }
}

// MARK: - ParsedAssistantTurn

public struct ParsedAssistantTurn: Codable, Sendable, Equatable {
    public let content: String?
    public let reasoning: String?
    public let toolCalls: [ToolCall]

    private enum CodingKeys: String, CodingKey {
        case content, reasoning
        case toolCalls = "tool_calls"
    }

    public init(content: String?, reasoning: String?, toolCalls: [ToolCall]) {
        self.content = content
        self.reasoning = reasoning
        self.toolCalls = toolCalls
    }
}

// MARK: - LlamaRuntime chat extension

extension LlamaRuntime {
    public func chat(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        options: SamplerOptions
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try self.chatBlocking(messages: messages,
                                           tools: tools,
                                           options: options,
                                           continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private final class ChatCallbackBox {
        let continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
        let stopSequences: [String]
        var accumulated: String = ""
        var generated: Int = 0
        var cancelled: Bool = false
        var matchedStop: String? = nil

        init(continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation,
             stopSequences: [String]) {
            self.continuation = continuation
            self.stopSequences = stopSequences
        }
    }

    private func chatBlocking(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        options: SamplerOptions,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) throws {
        let runtimeHandle = try requireRuntimeHandle()
        let messagesJSON = try encodeMessages(messages)
        let toolsJSON = ToolDefinition.toOpenAISchemaJSON(tools)
        let renderedPrompt = try renderChat(handle: runtimeHandle,
                                            messagesJSON: messagesJSON,
                                            toolsJSON: toolsJSON,
                                            enableThinking: options.enableThinking)

        let promptTokens = try countTokens(handle: runtimeHandle, text: renderedPrompt)
        let started = Date()

        let box = ChatCallbackBox(continuation: continuation, stopSequences: options.stopSequences)
        let boxPtr = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ChatCallbackBox>.fromOpaque(boxPtr).release() }

        let params = lllm_sampler_params(
            max_tokens:      options.maxTokens,
            temperature:     options.temperature,
            top_p:           options.topP,
            top_k:           options.topK,
            min_p:           options.minP,
            repeat_penalty:  options.repeatPenalty,
            seed:            options.seed
        )

        let stopsCStr: [UnsafeMutablePointer<CChar>?] = options.stopSequences.map { strdup($0) }
        defer { stopsCStr.forEach { if let p = $0 { free(p) } } }
        var stopPointers: [UnsafePointer<CChar>?] = stopsCStr.map { UnsafePointer($0) }
        stopPointers.append(nil)

        var grammarCStr: UnsafeMutablePointer<CChar>? = nil
        if let g = options.grammarGBNF { grammarCStr = strdup(g) }
        defer { if let p = grammarCStr { free(p) } }

        let cCallback: lllm_token_callback_v2 = { tokenPtr, userData in
            guard let tokenPtr, let userData else { return 0 }
            let box = Unmanaged<ChatCallbackBox>.fromOpaque(userData).takeUnretainedValue()
            let piece = String(cString: tokenPtr)
            box.generated += 1
            box.accumulated.append(piece)

            if Task.isCancelled {
                box.cancelled = true
                return 1
            }

            box.continuation.yield(.textToken(piece))

            for s in box.stopSequences where !s.isEmpty && box.matchedStop == nil {
                if box.accumulated.hasSuffix(s) || box.accumulated.contains(s) {
                    box.matchedStop = s
                    return 1
                }
            }
            return 0
        }

        var err = [CChar](repeating: 0, count: 1024)
        let produced = err.withUnsafeMutableBufferPointer { errPtr -> Int32 in
            renderedPrompt.withCString { promptPtr -> Int32 in
                stopPointers.withUnsafeBufferPointer { stopPtr -> Int32 in
                    lllm_runtime_generate_v2(
                        runtimeHandle,
                        promptPtr,
                        params,
                        grammarCStr,
                        options.stopSequences.isEmpty ? nil : stopPtr.baseAddress,
                        cCallback,
                        boxPtr,
                        errPtr.baseAddress,
                        Int32(errPtr.count))
                }
            }
        }

        if produced < 0 {
            let message = String(cString: err)
            continuation.finish(throwing: LocalLLMError.generationFailed(message))
            return
        }

        let reason: StopReason
        if box.cancelled {
            reason = .cancelled
        } else if let matched = box.matchedStop {
            reason = .stopSequence(matched)
        } else if Int(produced) >= Int(options.maxTokens) {
            reason = .maxTokens
        } else {
            reason = .endOfStream
        }

        let stats = GenerationStats(
            promptTokens: promptTokens,
            generatedTokens: Int(produced),
            contextSize: Int(lllm_runtime_context_size(runtimeHandle)),
            duration: Date().timeIntervalSince(started)
        )
        continuation.yield(.done(stats, stopReason: reason))
        continuation.finish()
    }

    /// The exact prompt string `chat(messages:tools:options:)` would feed the model,
    /// without generating. Exposed so training data can be built against the same
    /// bytes the app actually sends: the eval harness and the fine-tune dataset used
    /// to render their own scaffold, and the drift between that and this was silent.
    public func renderChatPrompt(messages: [ChatMessage],
                                 tools: [ToolDefinition],
                                 enableThinking: Bool = true) throws -> String {
        let runtimeHandle = try requireRuntimeHandle()
        return try renderChat(handle: runtimeHandle,
                              messagesJSON: try encodeMessages(messages),
                              toolsJSON: ToolDefinition.toOpenAISchemaJSON(tools),
                              enableThinking: enableThinking)
    }

    public func parseAssistantTurn(_ assistantOutput: String) throws -> ParsedAssistantTurn {
        let runtimeHandle = try requireRuntimeHandle()
        var err = [CChar](repeating: 0, count: 1024)
        let raw = err.withUnsafeMutableBufferPointer { ptr -> UnsafeMutablePointer<CChar>? in
            assistantOutput.withCString { outputPtr in
                lllm_parse_assistant_turn(runtimeHandle, outputPtr, ptr.baseAddress, Int32(ptr.count))
            }
        }
        guard let raw else {
            throw LocalLLMError.generationFailed(String(cString: err))
        }
        defer { lllm_string_free(raw) }
        let data = Data(String(cString: raw).utf8)
        return try JSONDecoder().decode(ParsedAssistantTurn.self, from: data)
    }

    // MARK: - private helpers

    private func requireRuntimeHandle() throws -> OpaquePointer {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { throw LocalLLMError.notLoaded }
        return h
    }

    private func encodeMessages(_ messages: [ChatMessage]) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(messages)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func renderChat(handle: OpaquePointer,
                            messagesJSON: String,
                            toolsJSON: String,
                            enableThinking: Bool) throws -> String {
        var err = [CChar](repeating: 0, count: 1024)
        let raw = err.withUnsafeMutableBufferPointer { ptr -> UnsafeMutablePointer<CChar>? in
            lllm_chat_render(handle, messagesJSON, toolsJSON,
                              enableThinking ? 1 : 0,
                              ptr.baseAddress, Int32(ptr.count))
        }
        guard let raw else {
            throw LocalLLMError.generationFailed(String(cString: err))
        }
        defer { lllm_string_free(raw) }
        return String(cString: raw)
    }

    private func countTokens(handle: OpaquePointer, text: String) throws -> Int {
        var err = [CChar](repeating: 0, count: 256)
        let count = err.withUnsafeMutableBufferPointer { ptr -> Int32 in
            text.withCString { textPtr in
                lllm_count_tokens(handle, textPtr, ptr.baseAddress, Int32(ptr.count))
            }
        }
        if count < 0 {
            throw LocalLLMError.generationFailed(String(cString: err))
        }
        return Int(count)
    }
}
