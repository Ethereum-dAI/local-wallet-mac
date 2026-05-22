import CLlamaBridge
import Foundation

public enum LocalLLMError: LocalizedError, Equatable {
    case modelNotFound(String)
    case loadFailed(String)
    case generationFailed(String)
    case notLoaded
    case audioNotSupported
    case mmprojNotLoaded
    case mmprojLoadFailed(String)
    case audioSampleRateMismatch(expected: Int, got: Int)
    case audioMarkerCountMismatch(markers: Int, attachments: Int)
    case audioContainsNonFinite
    case audioBufferTooLarge(samples: Int)

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
        case .audioNotSupported:
            return "The loaded model does not support audio input."
        case .mmprojNotLoaded:
            return "The audio model (mmproj) has not been loaded."
        case .mmprojLoadFailed(let message):
            return "Failed to load the audio model: \(message)"
        case .audioSampleRateMismatch(let expected, let got):
            return "Audio sample rate mismatch: expected \(expected) Hz, got \(got) Hz."
        case .audioMarkerCountMismatch(let markers, let attachments):
            return "Audio marker count \(markers) does not match attachments count \(attachments)."
        case .audioContainsNonFinite:
            return "Audio buffer contains non-finite samples (NaN or Inf)."
        case .audioBufferTooLarge(let samples):
            return "Audio buffer too large: \(samples) samples."
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

// MARK: - Multimodal audio support

extension LlamaRuntime {
    public func loadMmproj(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalLLMError.modelNotFound(url.path)
        }
        let runtimeHandle = try requireRuntimeHandle()
        var err = [CChar](repeating: 0, count: 1024)
        let status = err.withUnsafeMutableBufferPointer { ptr -> Int32 in
            url.path.withCString { pathPtr in
                lllm_runtime_load_mmproj(runtimeHandle, pathPtr, ptr.baseAddress, Int32(ptr.count))
            }
        }
        if status != 0 {
            let msg = String(cString: err)
            switch status {
            case -1:
                throw LocalLLMError.mmprojLoadFailed(msg.isEmpty ? "mtmd_init_from_file returned null" : msg)
            case -2:
                throw LocalLLMError.audioNotSupported
            case -3:
                throw LocalLLMError.modelNotFound(url.path)
            default:
                throw LocalLLMError.mmprojLoadFailed(msg.isEmpty ? "load_mmproj failed (\(status))" : msg)
            }
        }
    }

    public var audioSampleRate: Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return nil }
        let rate = lllm_runtime_audio_sample_rate(handle)
        return rate > 0 ? Int(rate) : nil
    }

    public var mediaMarker: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, let marker = lllm_runtime_media_marker(handle) else {
            return nil
        }
        return String(cString: marker)
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

    public func chat(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        options: SamplerOptions,
        userAudio: AudioAttachment?
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    if let audio = userAudio {
                        try self.chatBlockingAudio(
                            messages: messages,
                            tools: tools,
                            options: options,
                            audio: audio,
                            continuation: continuation)
                    } else {
                        try self.chatBlocking(
                            messages: messages,
                            tools: tools,
                            options: options,
                            continuation: continuation)
                    }
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

    private func chatBlockingAudio(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        options: SamplerOptions,
        audio: AudioAttachment,
        continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) throws {
        let runtimeHandle = try requireRuntimeHandle()

        guard let marker = mediaMarker else {
            throw LocalLLMError.mmprojNotLoaded
        }
        guard let expectedRate = audioSampleRate else {
            throw LocalLLMError.mmprojNotLoaded
        }
        guard audio.sampleRate == expectedRate else {
            throw LocalLLMError.audioSampleRateMismatch(expected: expectedRate, got: audio.sampleRate)
        }

        guard let lastUser = messages.last(where: { $0.role == .user }),
              let lastContent = lastUser.content else {
            throw LocalLLMError.audioMarkerCountMismatch(markers: 0, attachments: 1)
        }
        let markerCount = lastContent.components(separatedBy: marker).count - 1
        guard markerCount == 1 else {
            throw LocalLLMError.audioMarkerCountMismatch(markers: markerCount, attachments: 1)
        }

        let maxSamples = 30 * 16_000 * 60
        guard audio.samples.count <= maxSamples else {
            throw LocalLLMError.audioBufferTooLarge(samples: audio.samples.count)
        }

        var clamped = audio.samples
        for i in 0..<clamped.count {
            let value = clamped[i]
            guard value.isFinite else {
                throw LocalLLMError.audioContainsNonFinite
            }
            if value > 1.0 {
                clamped[i] = 1.0
            } else if value < -1.0 {
                clamped[i] = -1.0
            }
        }

        let messagesJSON = try encodeMessages(messages)
        let toolsJSON = ToolDefinition.toOpenAISchemaJSON(tools)
        let renderedPrompt = try renderChat(handle: runtimeHandle,
                                            messagesJSON: messagesJSON,
                                            toolsJSON: toolsJSON,
                                            enableThinking: options.enableThinking)

        let started = Date()
        let box = ChatCallbackBox(continuation: continuation, stopSequences: options.stopSequences)
        let boxPtr = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ChatCallbackBox>.fromOpaque(boxPtr).release() }

        let params = lllm_sampler_params(
            max_tokens: options.maxTokens,
            temperature: options.temperature,
            top_p: options.topP,
            top_k: options.topK,
            min_p: options.minP,
            repeat_penalty: options.repeatPenalty,
            seed: options.seed
        )

        let stopsCStr: [UnsafeMutablePointer<CChar>?] = options.stopSequences.map { strdup($0) }
        defer { stopsCStr.forEach { if let p = $0 { free(p) } } }
        var stopPointers: [UnsafePointer<CChar>?] = stopsCStr.map { UnsafePointer($0) }
        stopPointers.append(nil)

        var grammarCStr: UnsafeMutablePointer<CChar>? = nil
        if let grammar = options.grammarGBNF {
            grammarCStr = strdup(grammar)
        }
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

            for sequence in box.stopSequences where !sequence.isEmpty && box.matchedStop == nil {
                if box.accumulated.hasSuffix(sequence) || box.accumulated.contains(sequence) {
                    box.matchedStop = sequence
                    return 1
                }
            }
            return 0
        }

        var outPromptTokens: Int32 = 0
        var err = [CChar](repeating: 0, count: 1024)
        let produced: Int32 = clamped.withUnsafeBufferPointer { sampleBuffer in
            var audioInput = lllm_audio_input(samples: sampleBuffer.baseAddress, n_samples: clamped.count)
            return withUnsafePointer(to: &audioInput) { audioPtr in
                err.withUnsafeMutableBufferPointer { errPtr in
                    renderedPrompt.withCString { promptPtr in
                        stopPointers.withUnsafeBufferPointer { stopPtr in
                            lllm_runtime_generate_v2_media(
                                runtimeHandle,
                                promptPtr,
                                params,
                                grammarCStr,
                                options.stopSequences.isEmpty ? nil : stopPtr.baseAddress,
                                audioPtr,
                                1,
                                cCallback,
                                boxPtr,
                                &outPromptTokens,
                                errPtr.baseAddress,
                                Int32(errPtr.count)
                            )
                        }
                    }
                }
            }
        }

        if produced < 0 {
            throw mapMediaStatus(produced, message: String(cString: err))
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
            promptTokens: Int(outPromptTokens),
            generatedTokens: Int(produced),
            contextSize: Int(lllm_runtime_context_size(runtimeHandle)),
            duration: Date().timeIntervalSince(started)
        )
        continuation.yield(.done(stats, stopReason: reason))
        continuation.finish()
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

    internal func renderChatForTesting(messages: [ChatMessage], tools: [ToolDefinition]) throws -> String {
        let runtimeHandle = try requireRuntimeHandle()
        let messagesJSON = try encodeMessages(messages)
        let toolsJSON = ToolDefinition.toOpenAISchemaJSON(tools)
        return try renderChat(handle: runtimeHandle,
                              messagesJSON: messagesJSON,
                              toolsJSON: toolsJSON,
                              enableThinking: false)
    }

    // MARK: - private helpers

    private func mapMediaStatus(_ status: Int32, message: String) -> LocalLLMError {
        switch status {
        case -8:
            return .mmprojNotLoaded
        case -5:
            return .audioMarkerCountMismatch(markers: 0, attachments: 0)
        case -9:
            return .generationFailed("audio preprocessing failed: \(message)")
        case -6, -3, -4, -7:
            return .generationFailed(message)
        default:
            return .generationFailed(message.isEmpty ? "media generation failed (\(status))" : message)
        }
    }

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
