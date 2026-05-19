import Foundation
import Testing
import LocalLLM
@testable import WalletToolLayer

@Suite(.serialized) struct EndToEndToolCallSuite {

private func loadedRuntime() throws -> LlamaRuntime? {
    let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_K_M.gguf")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let rt = LlamaRuntime()
    try rt.loadModel(at: url)
    return rt
}

/// Drives the same pipeline EmbeddedLlamaInferenceService.generate() uses:
/// system (persona + nudge) + user message -> runtime.chat(tools:) ->
/// accumulate tokens -> BridgePEGExtractor.extract(accumulated).
///
/// This is the moment-of-truth for OPEN-POINTS P1.A. If the model emits
/// a <|tool_call> block and the bridge's common_chat_parse extracts it,
/// P1.A is closed (the synthetic-fixture parse failure was an
/// input-quirk, not a structural defect). If the model emits a block but
/// the extractor returns tool_calls.isEmpty, P1.A is a real blocker
/// for the tool layer and we need to investigate upstream.
///
/// We do NOT fail the test when tool_calls is empty - the test records
/// the outcome so the CI signal is the test report itself, not a
/// red/green. The acceptance check is a HUMAN inspection of the printed
/// summary plus a manual decision.
@Test func transferIntentEndToEndProducesToolCall() async throws {
    guard let rt = try loadedRuntime() else { return }
    defer { rt.unload() }

    let system = """
    You are the local AI inside a macOS Ethereum wallet app. Reply in Markdown.
    Be concise and direct.

    When the user clearly expresses intent to perform an on-chain action (transfer, swap,     etc.), you MUST call the corresponding tool with structured arguments instead of     describing the action in prose. If essential information is missing, ask one short     clarifying question in natural language and wait for the answer before calling the     tool. Never invent recipient addresses, ENS names, contact names, token symbols, or     amounts that the user has not provided.
    """
    let messages: [LocalLLM.ChatMessage] = [
        .init(role: .system, content: system),
        .init(role: .user,   content: "Send 0.1 ETH to vitalik.eth"),
    ]
    var options = SamplerOptions()
    options.maxTokens = 256
    options.temperature = 0.2
    options.enableThinking = false

    var accumulated = ""
    var doneStats: GenerationStats? = nil
    for try await event in rt.chat(messages: messages, tools: ToolDefinitions.phase1, options: options) {
        switch event {
        case .textToken(let p): accumulated.append(p)
        case .done(let s, _):  doneStats = s
        }
    }

    print("[P1.A-probe] raw assistant output (\(accumulated.count) chars):")
    print("--- begin ---")
    print(accumulated)
    print("--- end ---")
    print("[P1.A-probe] stats: \(doneStats.map(String.init(describing:)) ?? "nil")")

    let extractor = BridgePEGExtractor(runtime: rt)
    let parsed = try extractor.extract(from: accumulated)
    print("[P1.A-probe] parsed.content = \(parsed.content.map(String.init(describing:)) ?? "nil")")
    print("[P1.A-probe] parsed.reasoning = \(parsed.reasoning.map(String.init(describing:)) ?? "nil")")
    print("[P1.A-probe] parsed.toolCalls.count = \(parsed.toolCalls.count)")
    for (i, call) in parsed.toolCalls.enumerated() {
        print("[P1.A-probe]   toolCalls[\(i)]: name=\(call.name) args=\(call.arguments)")
    }

    // With the Gemma4 fallback parser, we now expect at least one tool call.
    #expect(parsed.toolCalls.count >= 1)
    let first = parsed.toolCalls[0]
    #expect(first.name == "transfer")
    #expect(first.arguments["to"] == "vitalik.eth")
    #expect(first.arguments["amount"] == "0.1")
}

} // end EndToEndToolCallSuite
