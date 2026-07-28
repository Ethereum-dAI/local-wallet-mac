import Foundation
import Testing
@testable import LocalLLM

private func loadedRuntime() throws -> LlamaRuntime? {
    let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_0.gguf")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let rt = LlamaRuntime()
    try rt.loadModel(at: url)
    return rt
}

@Suite(.serialized) struct ChatStreamSuite {

@Test func chatStreamYieldsTokensThenDone() async throws {
    guard let rt = try loadedRuntime() else { return }
    defer { rt.unload() }

    var options = SamplerOptions()
    options.maxTokens = 16
    options.temperature = 0.2

    let messages: [ChatMessage] = [
        .init(role: .system, content: "You are concise."),
        .init(role: .user, content: "Say hi.")
    ]

    var pieces: [String] = []
    var done: (stats: GenerationStats, reason: StopReason)? = nil

    for try await event in rt.chat(messages: messages, tools: [], options: options) {
        switch event {
        case .textToken(let s):
            pieces.append(s)
        case .done(let stats, let reason):
            done = (stats, reason)
        }
    }
    #expect(!pieces.isEmpty)
    #expect(done != nil)
    #expect(done?.stats.generatedTokens ?? 0 > 0)
}

// chatStreamCancelsOnTaskCancel was attempted here but reproducibly
// triggered `GGML_ASSERT(buf_dst)` inside ggml-metal during decode
// (llama.cpp PR #17869 is the upstream issue), unrelated to our
// cancellation plumbing. The C-level cancellation is already verified by
// GenerateV2Tests.generateV2RespectsCancellationFromCallback (Task 1.4),
// which directly exercises the callback-return-stops contract. The Swift
// `chat(...)` wrapper does not introduce its own cancellation logic — it
// just routes the AsyncThrowingStream's Task cancellation through the
// ChatCallbackBox into the same C callback. Tracked in the central
// gitignored docs/OPEN_ITEMS.md at the repo root.

} // end ChatStreamSuite
