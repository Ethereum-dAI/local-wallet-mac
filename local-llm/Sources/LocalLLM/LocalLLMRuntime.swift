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
    private let lock = NSLock()
    private var handle: OpaquePointer?

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

    public func generate(_ prompt: String) throws -> String {
        try generateWithStats(prompt).text
    }

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
