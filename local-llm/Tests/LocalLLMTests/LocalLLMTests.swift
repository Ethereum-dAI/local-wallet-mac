import Foundation
import Testing
@testable import LocalLLM

@Test func missingModelThrows() async throws {
    let runtime = LlamaRuntime()
    let missingURL = URL(fileURLWithPath: "/tmp/local-llm-missing-model.gguf")

    #expect(throws: LocalLLMError.modelNotFound(missingURL.path)) {
        try runtime.loadModel(at: missingURL)
    }
}

@Test func gemmaSmokeTestWhenModelExists() async throws {
    let modelURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_0.gguf")

    guard FileManager.default.fileExists(atPath: modelURL.path) else {
        return
    }

    let runtime = LlamaRuntime(
        configuration: LocalLLMConfiguration(
            contextSize: 2048,
            gpuLayers: 99,
            threads: 0,
            maxTokens: 24,
            temperature: 0.2
        )
    )
    defer {
        runtime.unload()
    }

    try runtime.loadModel(at: modelURL)
    #expect(runtime.isLoaded)

    let response = try runtime.generate("Say hello in five words.")
    #expect(!response.isEmpty)
}
