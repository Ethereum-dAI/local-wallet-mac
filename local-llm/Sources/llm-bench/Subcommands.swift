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

func runPrefill(options _: BenchOptions) async throws { print("== llm-bench prefill ==\nTODO: implemented in Task 3.2") }
func runDecode(options _: BenchOptions) async throws { print("== llm-bench decode ==\nTODO: implemented in Task 3.2") }
func runTimeToFirstToken(options _: BenchOptions) async throws { print("== llm-bench ttft ==\nTODO: implemented in Task 3.2") }
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
