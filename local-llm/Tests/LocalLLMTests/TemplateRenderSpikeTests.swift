import Foundation
import Testing
@testable import LocalLLM
import CLlamaBridge

private func loadedRuntime() throws -> LlamaRuntime? {
    let modelURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_0.gguf")
    guard FileManager.default.fileExists(atPath: modelURL.path) else { return nil }
    let rt = LlamaRuntime()
    try rt.loadModel(at: modelURL)
    return rt
}

private func chatRender(_ rt: LlamaRuntime, messages: String, tools: String?) -> String? {
    var buf = [CChar](repeating: 0, count: 1024)
    let result = buf.withUnsafeMutableBufferPointer { ptr -> UnsafeMutablePointer<CChar>? in
        return lllm_chat_render(rt.bridgeHandle, messages, tools, /*enable_thinking=*/0,
                                 ptr.baseAddress, Int32(ptr.count))
    }
    guard let result else { return nil }
    defer { lllm_string_free(result) }
    return String(cString: result)
}

@Test func spikeRendersSystemAndUserOnly() async throws {
    guard let rt = try loadedRuntime() else { return }
    defer { rt.unload() }

    let messages = #"""
    [{"role":"system","content":"You are a wallet assistant."},
     {"role":"user","content":"Hello."}]
    """#
    let rendered = chatRender(rt, messages: messages, tools: nil)
    #expect(rendered != nil)
    let r = rendered ?? ""
    #expect(r.contains("<|turn>system"))
    #expect(r.contains("You are a wallet assistant."))
    #expect(r.contains("<|turn>user"))
    #expect(r.contains("Hello."))
    #expect(r.hasSuffix("<|turn>model\n"))
}

@Test func spikeRendersToolsBlock() async throws {
    guard let rt = try loadedRuntime() else { return }
    defer { rt.unload() }

    let messages = #"""
    [{"role":"system","content":"You are a wallet assistant."},
     {"role":"user","content":"Send 0.1 eth to vitalik."}]
    """#
    let tools = #"""
    [{"type":"function","function":{"name":"transfer",
      "description":"Send tokens.",
      "parameters":{"type":"object",
        "properties":{"to":{"type":"string"},"amount":{"type":"string"}},
        "required":["to","amount"]}}}]
    """#
    let rendered = chatRender(rt, messages: messages, tools: tools)
    #expect(rendered != nil)
    let r = rendered ?? ""
    #expect(r.contains("<|tool>declaration:transfer"))
    #expect(r.contains("description"))
    #expect(r.contains("<|\"|>"))
}
