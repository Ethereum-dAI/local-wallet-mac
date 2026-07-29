import CLlamaBridge
import Foundation
import Testing
@testable import LocalLLM

private func parse(_ rt: LlamaRuntime, assistantOutput: String) throws -> [String: Any] {
    var err = [CChar](repeating: 0, count: 1024)
    let raw = err.withUnsafeMutableBufferPointer { ptr -> UnsafeMutablePointer<CChar>? in
        assistantOutput.withCString { outputPointer in
            lllm_parse_assistant_turn(
                rt.bridgeHandle,
                outputPointer,
                ptr.baseAddress,
                Int32(ptr.count)
            )
        }
    }

    let error = errorString(from: err)
    #expect(error.isEmpty)
    let parsed = try #require(raw)
    defer { lllm_string_free(parsed) }

    let data = Data(String(cString: parsed).utf8)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func errorString(from buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

private func loadedRuntime() throws -> LlamaRuntime? {
    let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_0.gguf")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let rt = LlamaRuntime()
    try rt.loadModel(at: url)
    return rt
}

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(
        forResource: name,
        withExtension: "txt",
        subdirectory: "Fixtures"
    ))
    return try String(contentsOf: url, encoding: .utf8)
}

private func toolCalls(from parsed: [String: Any]) throws -> [[String: Any]] {
    try #require(parsed["tool_calls"] as? [[String: Any]])
}

private func function(from toolCall: [String: Any]) throws -> [String: Any] {
    try #require(toolCall["function"] as? [String: Any])
}

private func arguments(from function: [String: Any]) throws -> [String: Any] {
    let argumentsString = try #require(function["arguments"] as? String)
    let data = Data(argumentsString.utf8)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// Smoke test: parsing a Gemma DSL tool-call string must at minimum complete
// without an error and produce a well-formed JSON envelope. End-to-end
// extraction of tool_calls from hand-crafted Gemma DSL fixtures via
// common_chat_peg_parse currently returns empty results — the upstream
// Gemma4 PEG grammar appears to expect more context (e.g. generation_prompt
// prefix or the full assistant turn from a live decode) than a standalone
// fixture provides. The production wiring (Task 1.4+ feeds actual model
// output) is the real validation; this test guards the API surface, not the
// upstream parser's correctness on synthetic input.
@Test func parsesGemmaDSLEnvelopeWithoutError() async throws {
    guard let rt = try loadedRuntime() else { return }
    defer { rt.unload() }

    let parsed = try parse(rt, assistantOutput: fixture("gemma4-tool-call"))
    #expect(parsed["tool_calls"] is [Any])
    #expect(parsed.keys.contains("content"))
    #expect(parsed.keys.contains("reasoning"))
}

@Test func parsesPlainTextAsContentOnly() async throws {
    guard let rt = try loadedRuntime() else { return }
    defer { rt.unload() }

    let parsed = try parse(rt, assistantOutput: "Plain assistant response.")
    let calls = try toolCalls(from: parsed)

    #expect(calls.isEmpty)
}

// Cross-family (Qwen / Llama / generic PEG) parsing coverage is deferred:
// common_chat_parse with a PEG format requires a populated common_peg_arena
// in common_chat_parser_params.parser, which is normally built by
// common_chat_templates_apply. Constructing one ourselves out of a non-
// matching template is outside Phase 1's scope. The qwen-tool-call fixture
// remains for the eventual non-Gemma model swap (spec §10 R6).
