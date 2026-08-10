import Foundation
import Testing
@testable import LocalLLM
import CLlamaBridge

private func render(_ rt: LlamaRuntime, messages: String, tools: String?, thinking: Bool) -> (output: String?, error: String) {
    var err = [CChar](repeating: 0, count: 1024)
    let raw = err.withUnsafeMutableBufferPointer { ptr -> UnsafeMutablePointer<CChar>? in
        return lllm_chat_render(rt.bridgeHandle,
                                 messages,
                                 tools,
                                 thinking ? 1 : 0,
                                 ptr.baseAddress, Int32(ptr.count))
    }
    let errStr = String(cString: err)
    if let raw {
        defer { lllm_string_free(raw) }
        return (String(cString: raw), errStr)
    }
    return (nil, errStr)
}

@Test func renderRejectsMalformedMessagesJSON() async throws {
    guard let rt = try sharedLoadedRuntime() else { return }
    let (out, err) = render(rt, messages: "not json", tools: nil, thinking: false)
    #expect(out == nil)
    #expect(err.contains("messages_json"))
}

@Test func renderProducesPromptThatEndsInModelTurn() async throws {
    guard let rt = try sharedLoadedRuntime() else { return }
    let (out, _) = render(rt,
        messages: #"[{"role":"user","content":"Hi."}]"#,
        tools: nil,
        thinking: false)
    #expect(out != nil)
    #expect(out?.hasSuffix("<|turn>model\n") == true)
}

@Test func renderIncludesToolBlockWhenToolsProvided() async throws {
    guard let rt = try sharedLoadedRuntime() else { return }
    let (out, _) = render(rt,
        messages: #"[{"role":"user","content":"swap 1 eth to usdc"}]"#,
        tools: #"[{"type":"function","function":{"name":"swap","description":"x","parameters":{"type":"object","properties":{}}}}]"#,
        thinking: false)
    #expect(out != nil)
    #expect(out?.contains("<|tool>declaration:swap") == true)
}

@Test func renderInjectsThinkingChannelWhenEnabled() async throws {
    guard let rt = try sharedLoadedRuntime() else { return }
    let (out, _) = render(rt,
        messages: #"[{"role":"user","content":"x"}]"#,
        tools: nil,
        thinking: true)
    #expect(out != nil)
    #expect(out?.contains("<|think|>") == true)
}
