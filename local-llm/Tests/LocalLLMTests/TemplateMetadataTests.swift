import Foundation
import Testing
@testable import LocalLLM
import CLlamaBridge

@Test func chatTemplateMetadataIsAvailableAfterLoad() async throws {
    let modelURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_K_M.gguf")
    guard FileManager.default.fileExists(atPath: modelURL.path) else { return }

    let runtime = LlamaRuntime()
    try runtime.loadModel(at: modelURL)
    defer { runtime.unload() }

    let template = runtime.embeddedChatTemplate
    #expect(template != nil)
    #expect(template?.contains("<|tool_call>") == true)
    #expect(template?.contains("format_function_declaration") == true)
}
