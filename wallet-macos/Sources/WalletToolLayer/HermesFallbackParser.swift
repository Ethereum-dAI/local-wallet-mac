import Foundation

/// Parses Hermes/Qwen-style tool calls out of raw assistant text.
///
/// Qwen3 (and most non-Gemma tool-calling models) emit:
///
///     <tool_call>
///     {"name": "transfer", "arguments": {"to": "vitalik.eth", "amount": "0.1"}}
///     </tool_call>
///
/// This is the sibling of `Gemma4FallbackParser`, which handles Gemma's
/// `<|tool_call>call:NAME{…}<tool_call|>` DSL. Note the tags differ by a single
/// pipe, and that difference was load-bearing: the Gemma parser is gated on
/// `contains("<|tool_call>")`, which a Hermes tag can never match, so before
/// this type existed the wallet could not execute a tool call from any Qwen
/// model at all — every case recorded `no-tool-call` while the model was in
/// fact emitting a correct, well-formed call.
///
/// Upstream llama.cpp is still the primary parser; this runs only when it
/// returns nothing or rejects the turn outright.
enum HermesFallbackParser {
    static let openTag = "<tool_call>"
    static let closeTag = "</tool_call>"

    /// True when the text looks like it carries at least one Hermes call.
    /// Deliberately checks for the pipe-less opener so it cannot collide with
    /// Gemma's `<|tool_call>`.
    static func looksLikeHermes(_ text: String) -> Bool {
        guard let range = text.range(of: openTag) else { return false }
        // `<|tool_call>` contains `tool_call>` but not `<tool_call>`, so a plain
        // `range(of:)` is already unambiguous. Guard the boundary anyway in case
        // a future dialect nests one inside the other.
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if before == "|" { return false }
        }
        return true
    }

    /// Every well-formed call in `text`, in order. Malformed blocks are skipped
    /// rather than failing the whole turn: a model that emits one good call and
    /// one truncated one should still produce the good one, exactly as the
    /// Gemma fallback behaves.
    static func parse(_ text: String) -> [ParsedToolCall] {
        var calls: [ParsedToolCall] = []
        var cursor = text.startIndex

        while let open = text.range(of: openTag, range: cursor..<text.endIndex) {
            guard let close = text.range(of: closeTag, range: open.upperBound..<text.endIndex) else {
                break  // unterminated block — a truncated generation
            }
            let body = text[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let call = parseBody(body, index: calls.count) {
                calls.append(call)
            }
            cursor = close.upperBound
        }
        return calls
    }

    /// `{"name": …, "arguments": {…}}` -> a flat-string-argument call.
    private static func parseBody(_ body: String, index: Int) -> ParsedToolCall? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty
        else { return nil }

        // `arguments` is usually an object, but some models emit it as a JSON
        // string. Accept both rather than dropping an otherwise valid call.
        var arguments: [String: Any] = [:]
        if let dict = obj["arguments"] as? [String: Any] {
            arguments = dict
        } else if let encoded = obj["arguments"] as? String,
                  let nested = encoded.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: nested) as? [String: Any] {
            arguments = dict
        }

        let id = (obj["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(index)"
        return ParsedToolCall(id: id, name: name, arguments: flatten(arguments))
    }

    /// Matches `BridgePEGExtractor.flattenArgs`: string leaves pass through,
    /// everything else is re-serialised to JSON so downstream sees only strings.
    static func flatten(_ obj: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in obj {
            if let s = value as? String {
                out[key] = s
            } else if let data = try? JSONSerialization.data(withJSONObject: value,
                                                             options: [.fragmentsAllowed]),
                      let s = String(data: data, encoding: .utf8) {
                out[key] = s
            } else {
                out[key] = String(describing: value)
            }
        }
        return out
    }

    /// The `<think>…</think>` trace, if the model emitted one.
    static func reasoning(in text: String) -> String? {
        guard let open = text.range(of: "<think>"),
              let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex)
        else { return nil }
        let body = text[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// Prose with the reasoning and tool-call blocks removed — what the user
    /// would be shown when the model both talks and acts.
    static func content(in text: String) -> String? {
        var stripped = text
        for (open, close) in [("<think>", "</think>"), (openTag, closeTag)] {
            while let o = stripped.range(of: open),
                  let c = stripped.range(of: close, range: o.upperBound..<stripped.endIndex) {
                stripped.removeSubrange(o.lowerBound..<c.upperBound)
            }
        }
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
