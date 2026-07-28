import Foundation
import Testing
@testable import LocalLLM
import CLlamaBridge

@Test func countsExactBytesWithoutWrappingInPromptTemplate() async throws {
    let modelURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_0.gguf")
    guard FileManager.default.fileExists(atPath: modelURL.path) else { return }

    let runtime = LlamaRuntime()
    try runtime.loadModel(at: modelURL)
    defer { runtime.unload() }

    var errorBuffer = [CChar](repeating: 0, count: 1024)
    let count = errorBuffer.withUnsafeMutableBufferPointer { buffer in
        "hello world".withCString { text in
            lllm_count_tokens(
                runtime.bridgeHandle,
                text,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
    }

    #expect(count > 0)
    #expect(count < 10)
}
