import Foundation

/// Swift-side fallback parser for the Gemma 4 tool-call DSL emitted by the
/// model when `common_chat_parse` upstream fails to recognise it (OPEN-POINTS
/// P1.A on the pinned llama.cpp commit). Handles the deterministic shape:
///
///     <|tool_call>call:NAME{key:<|"|>value<|"|>,key:<|"|>value<|"|>,...}<tool_call|>
///
/// Phase 1 only emits string-valued arguments (transfer / swap), so this
/// parser optimises for that shape and accepts bare values as a defensive
/// fallback (no crashes on slightly off output).
public enum Gemma4FallbackParser {
    private static let opener = "<|tool_call>"
    private static let closer = "<tool_call|>"
    private static let quote  = #"<|"|>"#

    public static func parse(_ input: String) -> [ParsedToolCall] {
        var result: [ParsedToolCall] = []
        var cursor = input.startIndex
        var callIndex = 0
        while let openerRange = input.range(of: opener, range: cursor..<input.endIndex),
              let closerRange = input.range(of: closer, range: openerRange.upperBound..<input.endIndex)
        {
            let bodyRange = openerRange.upperBound..<closerRange.lowerBound
            let body = String(input[bodyRange])
            if let call = parseCallBody(body, defaultID: "call_\(callIndex)") {
                result.append(call)
                callIndex += 1
            }
            cursor = closerRange.upperBound
        }
        return result
    }

    private static func parseCallBody(_ body: String, defaultID: String) -> ParsedToolCall? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("call:") else { return nil }
        let afterCall = trimmed.dropFirst("call:".count)
        guard let braceStart = afterCall.firstIndex(of: "{"),
              let braceEnd = afterCall.lastIndex(of: "}"),
              braceStart < braceEnd
        else { return nil }
        let name = String(afterCall[..<braceStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let argsBody = String(afterCall[afterCall.index(after: braceStart)..<braceEnd])
        let args = parseArgs(argsBody)
        return ParsedToolCall(id: defaultID, name: name, arguments: args)
    }

    private static func parseArgs(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        var rest = Substring(body)
        while !rest.isEmpty {
            rest = rest.drop(while: { $0.isWhitespace || $0 == "," })
            if rest.isEmpty { break }
            guard let colon = rest.firstIndex(of: ":") else { break }
            let key = String(rest[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            rest = rest[rest.index(after: colon)...]
            rest = rest.drop(while: { $0.isWhitespace })
            if rest.hasPrefix(quote) {
                let afterOpen = rest.index(rest.startIndex, offsetBy: quote.count)
                let tail = rest[afterOpen...]
                if let endRange = tail.range(of: quote) {
                    let value = String(tail[tail.startIndex..<endRange.lowerBound])
                    out[key] = value
                    rest = tail[endRange.upperBound...]
                } else {
                    break
                }
            } else {
                let comma = rest.firstIndex(of: ",") ?? rest.endIndex
                let raw = rest[rest.startIndex..<comma]
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { out[key] = value }
                rest = rest[comma...]
            }
        }
        return out
    }
}
