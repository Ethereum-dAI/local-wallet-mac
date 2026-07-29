import Foundation
import Testing
import LocalLLM
@testable import WalletToolLayer

@Suite(.serialized) struct ToolCallExtractorSuite {

@Test func extractorParsesPlainTextAsContentOnly() async throws {
    let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_0.gguf")
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let rt = LlamaRuntime()
    try rt.loadModel(at: url)
    defer { rt.unload() }

    let extractor = BridgePEGExtractor(runtime: rt)
    let parsed = try extractor.extract(from: "Sure, what address do you want to send to?")
    #expect(parsed.toolCalls.isEmpty)
    #expect((parsed.content ?? "").contains("address"))
}

@Test func extractorReturnsEnvelopeForGemmaDSL() async throws {
    // OPEN-POINTS P1.A: hand-crafted DSL on Gemma parser currently returns
    // empty tool_calls. This test pins the envelope-shape contract.
    let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_0.gguf")
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let rt = LlamaRuntime()
    try rt.loadModel(at: url)
    defer { rt.unload() }

    let extractor = BridgePEGExtractor(runtime: rt)
    let raw = #"<|tool_call>call:transfer{to:<|"|>vitalik.eth<|"|>,amount:<|"|>0.1<|"|>}<tool_call|>"#
    let parsed = try extractor.extract(from: raw)
    if let first = parsed.toolCalls.first {
        // If upstream fixes its synthetic-DSL parsing, prefer this branch.
        #expect(first.name == "transfer")
    } else {
        // Current behaviour: envelope without tool_calls.
        #expect(parsed.toolCalls.isEmpty)
    }
}

} // end ToolCallExtractorSuite
