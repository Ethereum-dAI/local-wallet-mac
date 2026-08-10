import Foundation
import Testing
@testable import LocalLLM

@Test func missingModelThrows() async throws {
    // Deliberately not the shared runtime: this asserts on load *failure*, so it
    // needs an unloaded runtime of its own. It costs nothing — it never loads a
    // model.
    let runtime = LlamaRuntime()
    let missingURL = URL(fileURLWithPath: "/tmp/local-llm-missing-model.gguf")

    #expect(throws: LocalLLMError.modelNotFound(missingURL.path)) {
        try runtime.loadModel(at: missingURL)
    }
}

@Test func gemmaSmokeTestWhenModelExists() async throws {
    // The shared runtime's configuration reproduces the one this test used to
    // build for itself (contextSize 2048, maxTokens 24, temperature 0.2) — see
    // SharedTestRuntime.swift.
    guard let runtime = try sharedLoadedRuntime() else { return }
    #expect(runtime.isLoaded)

    let response = try runtime.generate("Say hello in five words.")
    #expect(!response.isEmpty)
}
