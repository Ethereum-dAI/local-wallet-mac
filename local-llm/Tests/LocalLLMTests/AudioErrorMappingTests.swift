import Foundation
import Testing
@testable import LocalLLM

@Suite(.serialized)
struct AudioErrorMappingTests {
    @Test("buffer larger than the sanity ceiling throws audioBufferTooLarge")
    func bufferTooLarge() async throws {
        guard LocalLLMTestEnv.filesExist(LocalLLMTestEnv.modelURL, LocalLLMTestEnv.mmprojURL) else {
            return
        }

        let runtime = LlamaRuntime()
        try runtime.loadModel(at: LocalLLMTestEnv.modelURL)
        try runtime.loadMmproj(at: LocalLLMTestEnv.mmprojURL)
        defer { runtime.unload() }

        let huge = [Float](repeating: 0, count: 30 * 16_000 * 60 + 1)
        let stream = runtime.chat(
            messages: [ChatMessage(role: .user, content: "<__media__>")],
            tools: [],
            options: SamplerOptions(),
            userAudio: AudioAttachment(samples: huge, sampleRate: 16_000)
        )

        do {
            for try await _ in stream { break }
            Issue.record("expected throw")
        } catch let LocalLLMError.audioBufferTooLarge(samples) {
            #expect(samples == huge.count)
        }
    }

    @Test("loadMmproj against the wrong file throws a typed audio error")
    func wrongMmprojFile() throws {
        guard LocalLLMTestEnv.filesExist(LocalLLMTestEnv.modelURL) else {
            return
        }

        let runtime = LlamaRuntime()
        try runtime.loadModel(at: LocalLLMTestEnv.modelURL)
        defer { runtime.unload() }

        do {
            try runtime.loadMmproj(at: LocalLLMTestEnv.modelURL)
            Issue.record("expected throw")
        } catch LocalLLMError.audioNotSupported {
        } catch let LocalLLMError.mmprojLoadFailed(message) {
            #expect(!message.isEmpty)
        }
    }
}
