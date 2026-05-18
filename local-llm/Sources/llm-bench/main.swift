import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard let sub = args.first else {
    let usage = "usage: llm-bench <load|prefill|decode|ttft|render|grammar|all> [--model PATH] [--repeats N] [--warmup N] [--seed S] [--json PATH]\n"
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

let opts = parseSharedOptions(Array(args.dropFirst()))

do {
    switch sub {
    case "load":    try await runLoad(options: opts)
    case "prefill": try await runPrefill(options: opts)
    case "decode":  try await runDecode(options: opts)
    case "ttft":    try await runTimeToFirstToken(options: opts)
    case "render":  try await runRender(options: opts)
    case "grammar": try await runGrammar(options: opts)
    case "all":     try await runAll(options: opts)
    default:
        let msg = "unknown subcommand: \(sub)\n"
        FileHandle.standardError.write(Data(msg.utf8))
        exit(2)
    }
} catch {
    let msg = "llm-bench failed: \(error.localizedDescription)\n"
    FileHandle.standardError.write(Data(msg.utf8))
    exit(1)
}
