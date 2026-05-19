import Foundation
import LocalLLM
import WalletToolLayer

func runRoundTrip(options: EvalOptions) async throws {
    print("== wallet-eval round-trip ==")
    print("config: repeats=\(options.repeats) seed=0x\(String(options.seed, radix: 16))")

    let runtime = LlamaRuntime()
    try runtime.loadModel(at: URL(fileURLWithPath: options.modelPath))
    defer { runtime.unload() }
    let extractor = BridgePEGExtractor(runtime: runtime)

    var firstTurnHits = 0
    var followUpStaysQuiet = 0
    var samples: [Double] = []

    for i in 0..<options.repeats {
        let started = Date()
        let system = """
        You are the local AI inside a macOS Ethereum wallet app. \(ToolDefinitions.systemNudge)
        """

        var messages: [LocalLLM.ChatMessage] = [
            .init(role: .system, content: system),
            .init(role: .user, content: "Send 0.1 ETH to vitalik.eth"),
        ]
        var sampler = SamplerOptions()
        sampler.maxTokens = 192; sampler.temperature = 0.2; sampler.seed = options.seed
        var acc = ""
        for try await event in runtime.chat(messages: messages, tools: ToolDefinitions.phase1, options: sampler) {
            if case .textToken(let p) = event { acc += p }
        }
        let firstParsed = try extractor.extract(from: acc)
        let gotTool = firstParsed.toolCalls.contains { $0.name == "transfer" }
        if gotTool { firstTurnHits += 1 }
        if options.verbose {
            print("  run \(i+1): turn1 raw=\(acc.prefix(120))... toolCalls=\(firstParsed.toolCalls.count) (gotTool=\(gotTool))")
        }

        let toolCallContent = firstParsed.toolCalls.first.map { call -> String in
            "<|tool_call>call:\(call.name){\(call.arguments.map { "\($0.key):<|\"|>\($0.value)<|\"|>" }.joined(separator: ","))}<tool_call|>"
        } ?? acc
        messages.append(.init(role: .assistant, content: toolCallContent))
        let toolCallId = firstParsed.toolCalls.first?.id ?? "call_0"
        let toolResponseJSON = "{\"status\":\"acknowledged\",\"intent_id\":\"\(toolCallId)\"}"
        messages.append(.init(role: .tool,
                              content: toolResponseJSON,
                              toolCallId: toolCallId))

        messages.append(.init(role: .user, content: "Thanks!"))
        acc = ""
        for try await event in runtime.chat(messages: messages, tools: ToolDefinitions.phase1, options: sampler) {
            if case .textToken(let p) = event { acc += p }
        }
        let secondParsed = try extractor.extract(from: acc)
        let staysQuiet = secondParsed.toolCalls.isEmpty
        if staysQuiet { followUpStaysQuiet += 1 }
        if options.verbose {
            print("  run \(i+1): turn2 raw=\(acc.prefix(120))... toolCalls=\(secondParsed.toolCalls.count) (staysQuiet=\(staysQuiet))")
        }
        samples.append(Date().timeIntervalSince(started))
    }

    let firstRate = Double(firstTurnHits) / Double(options.repeats)
    let quietRate = Double(followUpStaysQuiet) / Double(options.repeats)
    let s = summaryStats(samples)
    print(String(format: "first-turn tool-call hit: %d/%d (%.0f%%)", firstTurnHits, options.repeats, firstRate * 100))
    print(String(format: "follow-up stays quiet:    %d/%d (%.0f%%)", followUpStaysQuiet, options.repeats, quietRate * 100))
    print(String(format: "wall clock per round:     %.1fs ± %.1f", s.mean, s.stddev))

    EvalReport.shared.recordRaw(subcommand: "round-trip", label: "first-turn-hit",  value: firstRate, samples: options.repeats, metric: "rate")
    EvalReport.shared.recordRaw(subcommand: "round-trip", label: "follow-up-quiet", value: quietRate, samples: options.repeats, metric: "rate")
    EvalReport.shared.record(EvalEntry(subcommand: "round-trip", label: "wall-clock-seconds", metric: "seconds", mean: s.mean, stddev: s.stddev, samples: samples.count))
}
