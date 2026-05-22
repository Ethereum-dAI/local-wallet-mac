import Foundation
import Testing
@testable import LocalLLM

@Suite(.serialized)
struct MediaMarkerTests {
    @Test("media marker and audio sample rate are available after loading mmproj")
    func markerLifecycle() throws {
        guard LocalLLMTestEnv.filesExist(LocalLLMTestEnv.modelURL, LocalLLMTestEnv.mmprojURL) else {
            return
        }

        let runtime = LlamaRuntime()
        try runtime.loadModel(at: LocalLLMTestEnv.modelURL)
        defer { runtime.unload() }

        #expect(runtime.mediaMarker == nil)
        #expect(runtime.audioSampleRate == nil)

        try runtime.loadMmproj(at: LocalLLMTestEnv.mmprojURL)
        #expect(runtime.mediaMarker?.isEmpty == false)
        #expect(runtime.audioSampleRate == 16_000)
    }
}
