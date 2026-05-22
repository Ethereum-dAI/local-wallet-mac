import Foundation
import Testing
@testable import LocalLLM

@Suite(.serialized)
struct LoadMmprojTests {
    @Test("loads mmproj and exposes 16 kHz sample rate")
    func happyPath() throws {
        guard LocalLLMTestEnv.filesExist(LocalLLMTestEnv.modelURL, LocalLLMTestEnv.mmprojURL) else {
            return
        }

        let runtime = LlamaRuntime()
        try runtime.loadModel(at: LocalLLMTestEnv.modelURL)
        defer { runtime.unload() }

        try runtime.loadMmproj(at: LocalLLMTestEnv.mmprojURL)
        #expect(runtime.audioSampleRate == 16_000)
    }

    @Test("loadMmproj is idempotent")
    func idempotent() throws {
        guard LocalLLMTestEnv.filesExist(LocalLLMTestEnv.modelURL, LocalLLMTestEnv.mmprojURL) else {
            return
        }

        let runtime = LlamaRuntime()
        try runtime.loadModel(at: LocalLLMTestEnv.modelURL)
        defer { runtime.unload() }

        try runtime.loadMmproj(at: LocalLLMTestEnv.mmprojURL)
        try runtime.loadMmproj(at: LocalLLMTestEnv.mmprojURL)
        #expect(runtime.audioSampleRate == 16_000)
    }

    @Test("missing path throws modelNotFound")
    func missingPath() throws {
        guard LocalLLMTestEnv.filesExist(LocalLLMTestEnv.modelURL) else {
            return
        }

        let runtime = LlamaRuntime()
        try runtime.loadModel(at: LocalLLMTestEnv.modelURL)
        defer { runtime.unload() }

        let bogus = URL(fileURLWithPath: "/nonexistent/mmproj.gguf")
        #expect(throws: LocalLLMError.modelNotFound(bogus.path)) {
            try runtime.loadMmproj(at: bogus)
        }
    }
}
