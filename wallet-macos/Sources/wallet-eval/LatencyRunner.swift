import Foundation
import LocalLLM
import WalletToolLayer

func runLatency(options: EvalOptions) async throws {
    print("== wallet-eval latency ==")
    print("config: repeats=\(options.repeats) seed=0x\(String(options.seed, radix: 16))")

    let runtime = LlamaRuntime()
    try runtime.loadModel(at: URL(fileURLWithPath: options.modelPath))
    defer { runtime.unload() }

    let prompt = "Send 0.1 ETH to vitalik.eth"
    let system = "You are the local AI inside a macOS Ethereum wallet app. \(ToolDefinitions.systemNudge)"

    var ttftSamples: [Double] = []
    var ttdSamples: [Double] = []
    for _ in 0..<options.repeats {
        var sampler = SamplerOptions()
        sampler.maxTokens = 192; sampler.temperature = 0.2; sampler.seed = options.seed
        let messages: [LocalLLM.ChatMessage] = [
            .init(role: .system, content: system),
            .init(role: .user, content: prompt),
        ]

        let started = Date()
        var firstTokenAt: Date? = nil
        var endAt: Date? = nil
        for try await event in runtime.chat(messages: messages, tools: ToolDefinitions.phase1, options: sampler) {
            switch event {
            case .textToken:
                if firstTokenAt == nil { firstTokenAt = Date() }
            case .done:
                endAt = Date()
            }
        }
        if let f = firstTokenAt { ttftSamples.append(f.timeIntervalSince(started) * 1000) }
        if let e = endAt        { ttdSamples.append(e.timeIntervalSince(started) * 1000) }
    }
    let ttftS = summaryStats(ttftSamples)
    let ttdS  = summaryStats(ttdSamples)
    print(String(format: "ttft (ms):           %.0f ± %.0f", ttftS.mean, ttftS.stddev))
    print(String(format: "ttd (full turn ms):  %.0f ± %.0f", ttdS.mean, ttdS.stddev))

    EvalReport.shared.record(EvalEntry(subcommand: "latency", label: "ttft-ms",
                                       metric: "ms", mean: ttftS.mean, stddev: ttftS.stddev,
                                       samples: ttftSamples.count))
    EvalReport.shared.record(EvalEntry(subcommand: "latency", label: "ttd-ms",
                                       metric: "ms", mean: ttdS.mean, stddev: ttdS.stddev,
                                       samples: ttdSamples.count))
}
