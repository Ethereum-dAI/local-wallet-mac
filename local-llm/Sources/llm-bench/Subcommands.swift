import Foundation
import LocalLLM

struct BenchOptions {
    var modelPath: String = defaultModelPath()
    var repeats: Int = 5
    var warmup: Int = 1
    var seed: UInt32 = 0xC0DEFEED
    var jsonPath: String? = nil
}

func defaultModelPath() -> String {
    let home = NSHomeDirectory()
    return "\(home)/Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_K_M.gguf"
}

func parseSharedOptions(_ args: [String]) -> BenchOptions {
    var opts = BenchOptions()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--model":
            guard i + 1 < args.count else { i += 1; continue }
            opts.modelPath = args[i + 1]
            i += 2
        case "--repeats":
            guard i + 1 < args.count else { i += 1; continue }
            opts.repeats = Int(args[i + 1]) ?? opts.repeats
            i += 2
        case "--warmup":
            guard i + 1 < args.count else { i += 1; continue }
            opts.warmup = Int(args[i + 1]) ?? opts.warmup
            i += 2
        case "--seed":
            guard i + 1 < args.count else { i += 1; continue }
            let raw = args[i + 1]
            if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
                let hex = String(raw.dropFirst(2))
                opts.seed = UInt32(hex, radix: 16) ?? opts.seed
            } else {
                opts.seed = UInt32(raw) ?? opts.seed
            }
            i += 2
        case "--json":
            guard i + 1 < args.count else { i += 1; continue }
            opts.jsonPath = args[i + 1]
            i += 2
        default:
            i += 1
        }
    }
    return opts
}

private func summaryStats(_ samples: [Double]) -> (mean: Double, stddev: Double) {
    guard !samples.isEmpty else { return (0, 0) }
    let mean = samples.reduce(0, +) / Double(samples.count)
    let variance = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(samples.count)
    return (mean, sqrt(variance))
}

func runLoad(options: BenchOptions) async throws {
    print("== llm-bench load ==")
    print("config: repeats=\(options.repeats) warmup=\(options.warmup) model=\(options.modelPath)")

    let modelURL = URL(fileURLWithPath: options.modelPath)
    var samples: [Double] = []
    for i in 0..<(options.repeats + options.warmup) {
        let runtime = LlamaRuntime()
        let t0 = Date()
        try runtime.loadModel(at: modelURL)
        let elapsed = Date().timeIntervalSince(t0)
        runtime.unload()
        if i >= options.warmup {
            samples.append(elapsed)
        }
    }
    let s = summaryStats(samples)
    print(String(format: "cold load: %.2fs +/- %.2fs (mean of %d runs)", s.mean, s.stddev, samples.count))
}

func runPrefill(options: BenchOptions) async throws {
    print("== llm-bench prefill ==")
    print("config: repeats=\(options.repeats) warmup=\(options.warmup) seed=0x\(String(options.seed, radix: 16))")

    let runtime = LlamaRuntime()
    try runtime.loadModel(at: URL(fileURLWithPath: options.modelPath))
    defer { runtime.unload() }

    for name in ["prefill-short", "prefill-med", "prefill-long"] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures") else {
            print("\(name): fixture missing - skipping")
            continue
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let messages: [ChatMessage] = [.init(role: .user, content: text)]

        var perRun: [Double] = []
        var promptTokens = 0
        for i in 0..<(options.repeats + options.warmup) {
            var opts = SamplerOptions()
            opts.maxTokens = 1
            opts.seed = options.seed
            opts.temperature = 0.2

            let t0 = Date()
            var done = false
            for try await event in runtime.chat(messages: messages, tools: [], options: opts) {
                if case .done(let stats, _) = event {
                    if i >= options.warmup { perRun.append(Date().timeIntervalSince(t0)) }
                    promptTokens = stats.promptTokens
                    done = true
                    break
                }
            }
            if !done && i >= options.warmup { perRun.append(Date().timeIntervalSince(t0)) }
        }
        let s = summaryStats(perRun)
        print("\(name): prompt=\(promptTokens) tokens · prefill+1 = \(String(format: "%.2fs ± %.2fs", s.mean, s.stddev)) (mean of \(perRun.count) runs)")
    }
}

func runDecode(options: BenchOptions) async throws {
    print("== llm-bench decode ==")
    print("config: repeats=\(options.repeats) warmup=\(options.warmup) seed=0x\(String(options.seed, radix: 16))")

    let runtime = LlamaRuntime()
    try runtime.loadModel(at: URL(fileURLWithPath: options.modelPath))
    defer { runtime.unload() }
    guard let seedURL = Bundle.module.url(forResource: "decode-seed", withExtension: "txt", subdirectory: "Fixtures") else {
        print("decode-seed fixture missing - aborting subcommand")
        return
    }
    let text = try String(contentsOf: seedURL, encoding: .utf8)
    let messages: [ChatMessage] = [.init(role: .user, content: text)]

    var samples: [Double] = []
    for i in 0..<(options.repeats + options.warmup) {
        var opts = SamplerOptions()
        opts.maxTokens = 256
        opts.seed = options.seed
        opts.temperature = 0.2

        var firstTokenAt: Date? = nil
        var generated = 0
        for try await event in runtime.chat(messages: messages, tools: [], options: opts) {
            switch event {
            case .textToken:
                if firstTokenAt == nil { firstTokenAt = Date() }
                generated += 1
            case .done:
                let elapsed = firstTokenAt.map { Date().timeIntervalSince($0) } ?? 0
                let throughput = elapsed > 0 ? Double(generated) / elapsed : 0
                if i >= options.warmup { samples.append(throughput) }
            @unknown default:
                break
            }
        }
    }
    let s = summaryStats(samples)
    print("decode: \(String(format: "%.1f tok/s ± %.1f", s.mean, s.stddev)) (mean of \(samples.count) runs over 256 generated tokens)")
}

func runTimeToFirstToken(options: BenchOptions) async throws {
    print("== llm-bench ttft ==")
    print("config: repeats=\(options.repeats) warmup=\(options.warmup) seed=0x\(String(options.seed, radix: 16))")

    let runtime = LlamaRuntime()
    try runtime.loadModel(at: URL(fileURLWithPath: options.modelPath))
    defer { runtime.unload() }
    let messages: [ChatMessage] = [.init(role: .user, content: "Hi.")]

    var samples: [Double] = []
    for i in 0..<(options.repeats + options.warmup) {
        var opts = SamplerOptions()
        opts.maxTokens = 1
        opts.seed = options.seed
        opts.temperature = 0.2

        let t0 = Date()
        for try await event in runtime.chat(messages: messages, tools: [], options: opts) {
            if case .textToken = event {
                if i >= options.warmup { samples.append(Date().timeIntervalSince(t0)) }
                break
            }
        }
    }
    let s = summaryStats(samples)
    print("ttft: \(String(format: "%.0f ms ± %.0f", s.mean * 1000, s.stddev * 1000)) (mean of \(samples.count) runs)")
}
func runRender(options _: BenchOptions) async throws { print("== llm-bench render ==\nTODO: implemented in Task 3.3") }
func runGrammar(options _: BenchOptions) async throws { print("== llm-bench grammar ==\nTODO: implemented in Task 3.3") }

func runAll(options: BenchOptions) async throws {
    try await runLoad(options: options)
    try await runPrefill(options: options)
    try await runDecode(options: options)
    try await runTimeToFirstToken(options: options)
    try await runRender(options: options)
    try await runGrammar(options: options)
}
