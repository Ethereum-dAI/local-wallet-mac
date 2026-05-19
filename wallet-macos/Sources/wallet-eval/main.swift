import Foundation
import WalletToolLayer
import LocalLLM

let args = Array(CommandLine.arguments.dropFirst())
let sub = args.first ?? "all"
let opts = parseEvalOptions(Array(args.dropFirst()))
EvalReport.shared.jsonPath = opts.jsonPath

do {
    switch sub {
    case "recognition": try await runRecognition(options: opts)
    case "round-trip":  try await runRoundTrip(options: opts)
    case "latency":     try await runLatency(options: opts)
    case "all":         try await runAll(options: opts)
    case "--help", "-h":
        print("usage: wallet-eval <recognition|round-trip|latency|all> [--model PATH] [--repeats N] [--seed S] [--json PATH] [--filter CATEGORY] [--verbose]")
    default:
        FileHandle.standardError.write(Data("unknown subcommand: \(sub)\n".utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("wallet-eval failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}

func runRecognition(options _: EvalOptions) async throws {
    print("== wallet-eval recognition ==")
    print("Implemented in Task 6.2 dispatch. See RecognitionRunner.swift (not yet created).")
}

func runAll(options: EvalOptions) async throws {
    try await runRecognition(options: options); print("")
    try await runRoundTrip(options: options);   print("")
    try await runLatency(options: options);     print("")
    print("== Done ==")
    if let p = EvalReport.shared.jsonPath {
        print("JSON written to \(p)")
    }
}
