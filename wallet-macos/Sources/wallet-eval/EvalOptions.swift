import Foundation

struct EvalOptions {
    var modelPath: String = defaultModelPath()
    var repeats: Int = 3
    var seed: UInt32 = 0xC0DEFEED
    var jsonPath: String? = nil
    var filter: String? = nil
    var verbose: Bool = false
}

/// The app's default model, so `swift run wallet-eval` scores what the wallet
/// actually ships. It must track `LocalAIModel.recommended.artifactFileName` —
/// hardcoded rather than imported because `WalletMacOSApp` is an executable target
/// and cannot be linked from here. Getting this wrong makes the harness report a
/// different model's score as the app's: it once pointed at the untuned base while
/// the fine-tune shipped, and it now names the Q4_K_M base because that is the
/// default again. Note the Q4_K_M suffix — a `Q4_0` copy is a different artifact.
func defaultModelPath() -> String {
    let home = NSHomeDirectory()
    return "\(home)/Library/Application Support/LocalWallet/Models/gemma-4-E4B-it-Q4_K_M.gguf"
}

func parseEvalOptions(_ args: [String]) -> EvalOptions {
    var o = EvalOptions()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--model":
            guard i + 1 < args.count else { i += 1; continue }
            o.modelPath = args[i+1]; i += 2
        case "--repeats":
            guard i + 1 < args.count else { i += 1; continue }
            o.repeats = Int(args[i+1]) ?? o.repeats; i += 2
        case "--seed":
            guard i + 1 < args.count else { i += 1; continue }
            let raw = args[i+1]
            if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
                o.seed = UInt32(raw.dropFirst(2), radix: 16) ?? o.seed
            } else {
                o.seed = UInt32(raw) ?? o.seed
            }
            i += 2
        case "--json":
            guard i + 1 < args.count else { i += 1; continue }
            o.jsonPath = args[i+1]; i += 2
        case "--filter":
            guard i + 1 < args.count else { i += 1; continue }
            o.filter = args[i+1]; i += 2
        case "--verbose":
            o.verbose = true; i += 1
        default:
            i += 1
        }
    }
    return o
}
