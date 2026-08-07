import Foundation
import Testing
@testable import WalletMacOSApp

/// The sentence shown under the Hugging Face file picker, before anything is
/// downloaded. It must be specific — a number the user can act on — and must never
/// read as a refusal, because the download is always allowed.
struct RemoteModelFitDescriberTests {
    private let gb: UInt64 = 1_073_741_824

    private func budget(ram: UInt64, metal: UInt64) -> HardwareBudget {
        HardwareBudget(totalMemoryBytes: ram, metalBudgetBytes: metal, freeDiskBytes: 200 * gb)
    }

    /// A small 2-bit-ish model: ~1.5 GB of weights, a modest KV cache.
    private let small = ModelMemoryProfile(
        weightBytes: 1_500_000_000,
        blockCount: 24,
        kvHeadCount: 2,
        keyLength: 128,
        valueLength: 128,
        trainedContextTokens: 32_768
    )

    @Test func aModelThatFitsSaysSoWithBothNumbers() {
        let fit = RemoteModelFitDescriber.describe(
            profile: small,
            contextTokens: 4096,
            budget: budget(ram: 32 * gb, metal: 24 * gb)
        )
        #expect(fit.verdict == .fits)
        // Grouping separators are locale-dependent, so assert against the same
        // formatter the copy uses rather than a hardcoded "4,096".
        #expect(fit.summary.hasPrefix("Fits at \(RemoteModelFitDescriber.tokenText(4096))"))
        #expect(fit.summary.contains("this Mac can give a model"))
    }

    @Test func aModelThatWillNotFitNamesTheMacItWants() {
        let profile = LocalAIModel.recommended.memoryProfile
        let tiny = budget(ram: 8 * gb, metal: 6 * gb)
        let fit = RemoteModelFitDescriber.describe(profile: profile, contextTokens: 4096, budget: tiny)

        #expect(fit.verdict == .wontFit)
        let wanted = ModelFitEvaluator.minimumMemoryBytes(
            profile: profile,
            contextTokens: 4096,
            comfortable: true
        )
        #expect(fit.summary.contains(RemoteModelFitDescriber.memoryText(wanted)))
        // Advisory, not a refusal: nothing here tells the user they cannot proceed.
        #expect(fit.summary.lowercased().contains("cannot") == false)
    }

    /// When only the *chosen* context is too big, say which one does work here —
    /// that is a one-click fix, not a hardware purchase.
    @Test func aContextThatIsTooBigPointsAtOneThatIsNot() {
        let big = ModelMemoryProfile(
            weightBytes: 6_000_000_000,
            blockCount: 48,
            kvHeadCount: 8,
            keyLength: 128,
            valueLength: 128,
            trainedContextTokens: 131_072
        )
        let mac = budget(ram: 24 * gb, metal: 18 * gb)
        let fit = RemoteModelFitDescriber.describe(profile: big, contextTokens: 131_072, budget: mac)

        #expect(fit.verdict == .wontFit)
        let smaller = try? #require(ModelFitEvaluator.largestFittingContext(profile: big, budget: mac))
        #expect(fit.summary.contains("It does fit here at \(RemoteModelFitDescriber.tokenText(smaller ?? 0))"))
    }

    @Test func anUnreadableHeaderDoesNotPretendToKnow() {
        let fit = RemoteModelFitDescriber.describe(
            profile: nil,
            contextTokens: 4096,
            budget: budget(ram: 32 * gb, metal: 24 * gb)
        )
        #expect(fit.verdict == .unknown)
        #expect(fit.summary.contains(RemoteModelFitDescriber.unknownFallbackReason))
        #expect(fit.summary.contains("You can still add it"))
    }

    /// When the probe failed for a nameable reason — a gated repo, a host that
    /// refuses ranged reads — say which, instead of a bare "unknown".
    @Test func aNamedFailureIsQuotedInTheSummary() {
        let reason = GGUFHeaderError.rangeNotSupported(status: 403).localizedDescription
        let fit = RemoteModelFitDescriber.unknown(reason: reason)
        #expect(fit.verdict == .unknown)
        #expect(fit.summary.contains("HTTP 403"))
        #expect(fit.summary.contains("You can still add it"))
        #expect(fit.summary.contains(RemoteModelFitDescriber.unknownFallbackReason) == false)
    }

    /// Before `refreshHardwareBudget()` has landed there is nothing to compare
    /// against; the form must not show a verdict it cannot justify.
    @Test func noBudgetYieldsTheUnknownSummary() {
        let fit = RemoteModelFitDescriber.describe(profile: small, contextTokens: 4096, budget: nil)
        #expect(fit.verdict == .unknown)
    }

    /// RAM is quoted 1024-based; `.file` would render a 36 GiB budget as "38.65 GB"
    /// next to a Mac the user knows as a 36 GB machine.
    @Test func memoryIsFormattedInBinaryUnits() {
        #expect(RemoteModelFitDescriber.memoryText(36 * gb) == "36 GB")
    }
}

/// The post-download load test's report. The model is installed whatever this
/// says — every outcome has to read as information, not a rejection.
struct ModelSelfTestReportTests {
    @Test func aCleanRunNamesTheContextItRanAt() {
        let message = ModelSelfTestReport.message(for: .ready(contextTokens: 8192))
        #expect(message.contains(RemoteModelFitDescriber.tokenText(8192)))
        #expect(message.contains("tool call"))
    }

    /// The actionable case: arithmetic said one size, a real load said another.
    /// The message has to name both, and say what to do about it.
    @Test func aStepDownNamesBothSizesAndTheFix() {
        let message = ModelSelfTestReport.message(for: .steppedDown(from: 32_768, to: 8192))
        #expect(message.contains(RemoteModelFitDescriber.tokenText(32_768)))
        #expect(message.contains(RemoteModelFitDescriber.tokenText(8192)))
        #expect(message.contains("lower the context window"))
    }

    /// A model that loads but cannot emit a tool call is useless for transfers —
    /// that has to be said plainly rather than reported as a success.
    @Test func aModelWithoutToolCallsIsCalledOut() {
        let message = ModelSelfTestReport.message(for: .noToolSupport)
        #expect(message.contains("transfers and swaps may not work"))
    }

    @Test func aFailureCarriesTheUnderlyingReason() {
        let message = ModelSelfTestReport.message(for: .failed("unable to allocate KV cache"))
        #expect(message.contains("unable to allocate KV cache"))
    }
}
