import Foundation
import Testing
@testable import LocalLLM

@Suite(.serialized)
struct MediaMarkerSurvivesRenderTests {
    @Test("marker substring appears in rendered prompt")
    func markerSurvives() throws {
        guard LocalLLMTestEnv.filesExist(LocalLLMTestEnv.modelURL, LocalLLMTestEnv.mmprojURL) else {
            return
        }

        let runtime = LlamaRuntime()
        try runtime.loadModel(at: LocalLLMTestEnv.modelURL)
        try runtime.loadMmproj(at: LocalLLMTestEnv.mmprojURL)
        defer { runtime.unload() }

        let marker = try #require(runtime.mediaMarker)
        let rendered = try runtime.renderChatForTesting(
            messages: [ChatMessage(role: .user, content: "\(marker) please describe this audio.")],
            tools: []
        )

        #expect(rendered.contains(marker))
    }
}
