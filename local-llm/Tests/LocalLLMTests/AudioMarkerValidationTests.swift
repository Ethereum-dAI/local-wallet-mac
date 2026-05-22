import Foundation
import Testing
@testable import LocalLLM

@Suite(.serialized)
struct AudioMarkerValidationTests {
    private func makeAttachment(_ samples: [Float] = [0.0], sampleRate: Int = 16_000) -> AudioAttachment {
        AudioAttachment(samples: samples, sampleRate: sampleRate)
    }

    @Test("mmproj not loaded throws mmprojNotLoaded")
    func mmprojMissing() async throws {
        guard LocalLLMTestEnv.filesExist(LocalLLMTestEnv.modelURL) else {
            return
        }

        let runtime = LlamaRuntime()
        try runtime.loadModel(at: LocalLLMTestEnv.modelURL)
        defer { runtime.unload() }

        var iterator = runtime.chat(
            messages: [ChatMessage(role: .user, content: "<__media__> hi")],
            tools: [],
            options: SamplerOptions(),
            userAudio: makeAttachment()
        ).makeAsyncIterator()

        await #expect(throws: LocalLLMError.mmprojNotLoaded) {
            _ = try await iterator.next()
        }
    }

    @Test("sample-rate mismatch throws audioSampleRateMismatch")
    func sampleRateMismatch() async throws {
        guard LocalLLMTestEnv.filesExist(LocalLLMTestEnv.modelURL, LocalLLMTestEnv.mmprojURL) else {
            return
        }

        let runtime = LlamaRuntime()
        try runtime.loadModel(at: LocalLLMTestEnv.modelURL)
        try runtime.loadMmproj(at: LocalLLMTestEnv.mmprojURL)
        defer { runtime.unload() }

        let stream = runtime.chat(
            messages: [ChatMessage(role: .user, content: "<__media__>")],
            tools: [],
            options: SamplerOptions(),
            userAudio: makeAttachment(sampleRate: 48_000)
        )

        await #expect(throws: LocalLLMError.audioSampleRateMismatch(expected: 16_000, got: 48_000)) {
            for try await _ in stream { break }
        }
    }

    @Test("marker count mismatch throws")
    func markerMismatch() async throws {
        guard LocalLLMTestEnv.filesExist(LocalLLMTestEnv.modelURL, LocalLLMTestEnv.mmprojURL) else {
            return
        }

        let runtime = LlamaRuntime()
        try runtime.loadModel(at: LocalLLMTestEnv.modelURL)
        try runtime.loadMmproj(at: LocalLLMTestEnv.mmprojURL)
        defer { runtime.unload() }

        let stream = runtime.chat(
            messages: [ChatMessage(role: .user, content: "no marker here")],
            tools: [],
            options: SamplerOptions(),
            userAudio: makeAttachment()
        )

        do {
            for try await _ in stream { break }
            Issue.record("expected throw")
        } catch let LocalLLMError.audioMarkerCountMismatch(markers, attachments) {
            #expect(markers == 0)
            #expect(attachments == 1)
        }
    }

    @Test("non-finite sample throws audioContainsNonFinite")
    func nonFinite() async throws {
        guard LocalLLMTestEnv.filesExist(LocalLLMTestEnv.modelURL, LocalLLMTestEnv.mmprojURL) else {
            return
        }

        let runtime = LlamaRuntime()
        try runtime.loadModel(at: LocalLLMTestEnv.modelURL)
        try runtime.loadMmproj(at: LocalLLMTestEnv.mmprojURL)
        defer { runtime.unload() }

        let stream = runtime.chat(
            messages: [ChatMessage(role: .user, content: "<__media__>")],
            tools: [],
            options: SamplerOptions(),
            userAudio: makeAttachment([0.1, .nan, 0.2])
        )

        await #expect(throws: LocalLLMError.audioContainsNonFinite) {
            for try await _ in stream { break }
        }
    }
}
