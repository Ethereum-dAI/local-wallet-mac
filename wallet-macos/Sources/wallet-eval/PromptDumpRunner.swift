import Foundation
import LocalLLM
import WalletToolLayer

// Dumps the exact bytes the app feeds the model, so the fine-tune dataset and the
// eval harness can be generated against them instead of against a scaffold of
// their own. The previous harness pasted a ~4.5 KB tool/safety preamble into the
// prompt; the app sends `systemNudge` plus tools injected through the model's own
// chat template. Models trained on the former lost 8-17 points when run under the
// latter, which is what this subcommand exists to prevent recurring.

private struct PromptDumpCase: Encodable {
    let label: String
    let messages: [[String: String]]
    let rendered: String
}

private struct PromptDump: Encodable {
    let systemPrompt: String
    let toolsJSON: String
    let toolNames: [String]
    let cases: [PromptDumpCase]
}

/// The app's system prompt, verbatim. `EmbeddedLlamaInferenceService` and every
/// wallet-eval runner build it this way; keep them in step.
let appSystemPrompt = "You are the local AI inside a macOS Ethereum wallet app. \(ToolDefinitions.systemNudge)"

func runPromptDump(options: EvalOptions) async throws {
    let runtime = LlamaRuntime()
    try runtime.loadModel(at: URL(fileURLWithPath: options.modelPath))
    defer { runtime.unload() }

    // Representative shapes: a plain single turn, and a multi-turn where the model
    // asked a clarifying question and the user answered — the app's two real forms.
    let shapes: [(String, [LocalLLM.ChatMessage])] = [
        ("single-turn", [
            .init(role: .system, content: appSystemPrompt),
            .init(role: .user, content: "Send 0.25 ETH to vitalik.eth"),
        ]),
        ("multi-turn", [
            .init(role: .system, content: appSystemPrompt),
            .init(role: .user, content: "I want to send some USDC"),
            .init(role: .assistant, content: "How much USDC would you like to send, and to whom?"),
            .init(role: .user, content: "12.5 to 0x000000000000000000000000000000000000dEaD"),
        ]),
    ]

    var dumped: [PromptDumpCase] = []
    for (label, messages) in shapes {
        let rendered = try runtime.renderChatPrompt(messages: messages,
                                                    tools: ToolDefinitions.phase1,
                                                    enableThinking: SamplerOptions().enableThinking)
        dumped.append(PromptDumpCase(
            label: label,
            messages: messages.map { ["role": $0.role.rawValue, "content": $0.content ?? ""] },
            rendered: rendered
        ))
    }

    let dump = PromptDump(
        systemPrompt: appSystemPrompt,
        toolsJSON: ToolDefinition.toOpenAISchemaJSON(ToolDefinitions.phase1),
        toolNames: ToolDefinitions.phase1.map(\.name),
        cases: dumped
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(dump)

    if let path = options.jsonPath {
        try data.write(to: URL(fileURLWithPath: path))
        print("prompt dump written to \(path)")
        print("tools: \(dump.toolNames.joined(separator: ", "))")
    } else {
        print(String(data: data, encoding: .utf8) ?? "")
    }
}
