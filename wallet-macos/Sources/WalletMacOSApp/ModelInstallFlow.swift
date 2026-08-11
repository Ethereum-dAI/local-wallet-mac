import Foundation

/// What adding a model is doing right now, so the form can say so rather than
/// showing a stalled progress bar. The load test runs a real llama.cpp load and
/// one generation, which can take a minute — long enough that it needs its own
/// phase.
enum ModelInstallPhase: Equatable, Sendable {
    case downloading(Double)
    case testing
}

/// The sentence appended to the download message once the freshly installed model
/// has been loaded for real. Pure, so the wording of each outcome is testable
/// without a GPU.
enum ModelSelfTestReport {
    static let skippedWhileGenerating = "Skipped the load test because a reply was in progress."

    static func message(for result: ModelSelfTestResult) -> String {
        switch result {
        case .ready(let tokens):
            return "It loaded and made a tool call at \(RemoteModelFitDescriber.tokenText(tokens))."
        case .steppedDown(let from, let to):
            return "It does not load at \(RemoteModelFitDescriber.tokenText(from)) on this Mac, only "
                + "\(RemoteModelFitDescriber.tokenText(to)) — lower the context window before using it."
        case .noToolSupport:
            return "It loads, but did not answer with a tool call, so transfers and swaps may not work."
        case .failed(let reason):
            return "It could not be loaded on this Mac: \(reason)"
        }
    }
}

/// A verdict on a model that is *not* downloaded yet, computed from its GGUF
/// header read over a ranged request.
struct RemoteModelFit: Equatable {
    let verdict: ModelFitVerdict
    let summary: String
}

/// Turns a remote model's profile into the sentence shown under the file picker.
/// Pure, so the copy — including the "needs a Mac with about N" inversion — is
/// unit-testable without a network or a GPU.
enum RemoteModelFitDescriber {
    static let unknownFallbackReason = "Could not read this file's memory needs before downloading."
    static let unknownSuffix = "You can still add it; the verdict is recomputed from the file itself once it is on disk."

    /// `reason` is the specific failure when there is one — a gated repo, a host
    /// that refuses ranged reads, a header this parser does not understand. Saying
    /// which beats a bare "unknown", and none of them stop the download.
    static func unknown(reason: String? = nil) -> RemoteModelFit {
        RemoteModelFit(verdict: .unknown, summary: "\(reason ?? unknownFallbackReason) \(unknownSuffix)")
    }

    static func describe(
        profile: ModelMemoryProfile?,
        contextTokens: Int,
        budget: HardwareBudget?
    ) -> RemoteModelFit {
        guard let profile, let budget else { return unknown() }
        let verdict = ModelFitEvaluator.verdict(
            profile: profile,
            contextTokens: contextTokens,
            budget: budget
        )
        let need = memoryText(ModelFitEvaluator.requiredBytes(profile: profile, contextTokens: contextTokens))
        let available = memoryText(budget.usableBytes)

        switch verdict {
        case .unknown:
            return unknown()
        case .fits:
            return RemoteModelFit(
                verdict: verdict,
                summary: "Fits at \(tokenText(contextTokens)) — about \(need) of the \(available) this Mac can give a model."
            )
        case .tight:
            return RemoteModelFit(
                verdict: verdict,
                summary: "Tight at \(tokenText(contextTokens)) — about \(need) of the \(available) available. Replies may be slow."
            )
        case .wontFit:
            let minimum = memoryText(ModelFitEvaluator.minimumMemoryBytes(
                profile: profile,
                contextTokens: contextTokens,
                comfortable: true
            ))
            var summary = "Won't fit at \(tokenText(contextTokens)) — needs about \(need), and this Mac has \(available) for a model. "
                + "It wants a Mac with about \(minimum)."
            if let smaller = ModelFitEvaluator.largestFittingContext(profile: profile, budget: budget) {
                summary += " It does fit here at \(tokenText(smaller))."
            }
            return RemoteModelFit(verdict: verdict, summary: summary)
        }
    }

    /// `.memory` (1024-based), not `.file`: these are RAM figures, and `.file`
    /// renders 36 GiB as "38.65 GB" next to a Mac the user knows as a 36 GB one.
    static func memoryText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    static func tokenText(_ tokens: Int) -> String {
        "\(tokens.formatted()) tokens"
    }
}
