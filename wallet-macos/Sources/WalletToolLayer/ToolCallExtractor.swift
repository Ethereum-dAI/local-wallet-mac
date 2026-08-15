import Foundation
import LocalLLM

public struct ParsedToolCall: Equatable, Codable, Sendable {
    public let id: String
    public let name: String
    /// Flat-string map of arguments. Non-string JSON leaves are re-serialised
    /// to JSON-encoded strings (consistent with ToolIntent.args).
    public let arguments: [String: String]

    public init(id: String, name: String, arguments: [String: String]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Named …Flat (deviation from spec §5's ParsedAssistantTurn) deliberately:
/// LocalLLM.ParsedAssistantTurn already exists upstream; this wallet-side type
/// wraps it with a flat-string-map arguments representation.
public struct ParsedAssistantTurnFlat: Equatable, Codable, Sendable {
    public let content: String?
    public let reasoning: String?
    public let toolCalls: [ParsedToolCall]

    public init(content: String?, reasoning: String?, toolCalls: [ParsedToolCall]) {
        self.content = content
        self.reasoning = reasoning
        self.toolCalls = toolCalls
    }
}

public protocol ToolCallExtractor: Sendable {
    func extract(from assistantOutput: String) throws -> ParsedAssistantTurnFlat
}

public struct BridgePEGExtractor: ToolCallExtractor {
    private let runtime: LlamaRuntime

    public init(runtime: LlamaRuntime) {
        self.runtime = runtime
    }

    public func extract(from assistantOutput: String) throws -> ParsedAssistantTurnFlat {
        let parsed: LocalLLM.ParsedAssistantTurn
        do {
            parsed = try runtime.parseAssistantTurn(assistantOutput)
        } catch {
            // Upstream rejected the whole turn — for a Qwen GGUF it reports
            // "does not match the expected peg-native format" on output that is
            // in fact a correct Hermes call. Because this threw, the fallback
            // below was previously unreachable and every Qwen case recorded
            // `no-tool-call`, which made `Qwen/Qwen3-8B` (a curated,
            // user-selectable model) an AI that could never act. Try the text
            // fallbacks before giving up.
            if let recovered = Self.fallbackTurn(from: assistantOutput) {
                return recovered
            }
            // No tool call to recover, but the model did say something. Upstream
            // rejects a whole Qwen turn on format grounds, so treating that as a
            // hard error would also break the cases where declining IS correct —
            // a safety refusal or a clarifying question would surface as a parse
            // failure instead of as the right answer. Prefer the prose.
            let trimmed = assistantOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return ParsedAssistantTurnFlat(
                    content: HermesFallbackParser.content(in: assistantOutput) ?? trimmed,
                    reasoning: HermesFallbackParser.reasoning(in: assistantOutput),
                    toolCalls: []
                )
            }
            throw ToolExtractionError.parseFailed(message: error.localizedDescription)
        }

        let upstreamFlat: [ParsedToolCall] = parsed.toolCalls.enumerated().map { idx, call in
            let id = call.id.isEmpty ? "call_\(idx)" : call.id
            let args = Self.flattenArgs(call.function.arguments)
            return ParsedToolCall(id: id, name: call.function.name, arguments: args)
        }

        // OPEN-POINTS P1.A: upstream common_chat_parse currently misses Gemma 4
        // DSL tool calls on the pinned llama.cpp commit, and misses Hermes calls
        // for Qwen-family GGUFs. When that happens we see no upstream tool calls
        // plus a recognisable marker in the raw input, so fall through to the
        // matching Swift fallback parser.
        if upstreamFlat.isEmpty,
           let fallback = Self.fallbackTurn(from: assistantOutput,
                                            reasoning: parsed.reasoning)
        {
            return fallback
        }

        return ParsedAssistantTurnFlat(
            content: parsed.content,
            reasoning: parsed.reasoning,
            toolCalls: upstreamFlat
        )
    }

    /// Dialect-dispatched text parsing, used when upstream finds nothing or
    /// rejects the turn. Returns nil when no dialect matches, so the caller can
    /// preserve upstream's own result (or its error) rather than inventing one.
    static func fallbackTurn(from assistantOutput: String,
                             reasoning: String? = nil) -> ParsedAssistantTurnFlat? {
        if assistantOutput.contains("<|tool_call>") {
            let calls = Gemma4FallbackParser.parse(assistantOutput)
            if !calls.isEmpty {
                return ParsedAssistantTurnFlat(content: nil,
                                               reasoning: reasoning,
                                               toolCalls: calls)
            }
        }
        if HermesFallbackParser.looksLikeHermes(assistantOutput) {
            let calls = HermesFallbackParser.parse(assistantOutput)
            if !calls.isEmpty {
                return ParsedAssistantTurnFlat(
                    content: HermesFallbackParser.content(in: assistantOutput),
                    reasoning: reasoning ?? HermesFallbackParser.reasoning(in: assistantOutput),
                    toolCalls: calls
                )
            }
        }
        return nil
    }

    private static func flattenArgs(_ jsonString: String) -> [String: String] {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String {
                out[k] = s
            } else if let data = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]),
                      let s = String(data: data, encoding: .utf8) {
                out[k] = s
            } else {
                out[k] = String(describing: v)
            }
        }
        return out
    }
}
