import Foundation

let args = Array(CommandLine.arguments.dropFirst())
if let sub = args.first {
    print("wallet-eval scaffold — subcommand \(sub) lands in Phase 6.")
} else {
    print("usage: wallet-eval <recognition|round-trip|latency|all> [--model PATH] [--repeats N] [--json PATH]")
}
