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
            throw ToolExtractionError.parseFailed(message: error.localizedDescription)
        }

        let flat: [ParsedToolCall] = parsed.toolCalls.enumerated().map { idx, call in
            let id = call.id.isEmpty ? "call_\(idx)" : call.id
            let args = Self.flattenArgs(call.function.arguments)
            return ParsedToolCall(id: id, name: call.function.name, arguments: args)
        }
        return ParsedAssistantTurnFlat(
            content: parsed.content,
            reasoning: parsed.reasoning,
            toolCalls: flat
        )
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
