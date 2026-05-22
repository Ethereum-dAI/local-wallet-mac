import Foundation
import Testing
@testable import LocalLLM

@Suite(.serialized)
struct AudioGenerationSmokeTests {
    @Test("3s sine fixture produces tokens and reports multimodal prompt tokens")
    func smoke() async throws {
        guard LocalLLMTestEnv.filesExist(LocalLLMTestEnv.modelURL, LocalLLMTestEnv.mmprojURL) else {
            return
        }

        let runtime = LlamaRuntime()
        try runtime.loadModel(at: LocalLLMTestEnv.modelURL)
        try runtime.loadMmproj(at: LocalLLMTestEnv.mmprojURL)
        defer { runtime.unload() }

        let (samples, sampleRate) = try LocalLLMTestEnv.loadFixtureWAV()
        let marker = try #require(runtime.mediaMarker)

        var options = SamplerOptions()
        options.maxTokens = 32

        let stream = runtime.chat(
            messages: [ChatMessage(role: .user, content: "\(marker) what do you hear?")],
            tools: [],
            options: options,
            userAudio: AudioAttachment(samples: samples, sampleRate: sampleRate)
        )

        var tokens = 0
        var finalStats: GenerationStats?
        for try await event in stream {
            switch event {
            case .textToken:
                tokens += 1
            case .done(let stats, _):
                finalStats = stats
            }
        }

        #expect(tokens >= 1)
        let stats = try #require(finalStats)
        #expect(stats.promptTokens > 50)
        #expect(stats.generatedTokens > 0)
    }
}
