import Foundation
import Testing
@testable import WalletMacOSApp

struct OnboardingModelGateTests {
    private let gb: UInt64 = 1_073_741_824

    private func budget(ram: UInt64, metal: UInt64) -> HardwareBudget {
        HardwareBudget(totalMemoryBytes: ram, metalBudgetBytes: metal, freeDiskBytes: 200 * gb)
    }

    /// A 16 GB Mac was refused outright by the deleted `hasMinimumModelMemory` gate
    /// even though the default model runs there comfortably at the smallest preset.
    @Test func sixteenGigMacIsNotWarnedAtAll() {
        let sixteen = budget(ram: 16 * gb, metal: 12 * gb)
        let verdict = ModelFitEvaluator.verdict(
            profile: LocalAIModel.recommended.memoryProfile,
            contextTokens: ContextWindowPresets.fallback,
            budget: sixteen
        )
        #expect(verdict == .fits)
        #expect(OnboardingModelGate.allowsDownload(verdict: verdict) == true)
        #expect(OnboardingModelGate.warning(
            verdict: verdict,
            profile: LocalAIModel.recommended.memoryProfile,
            contextTokens: ContextWindowPresets.fallback,
            budget: sixteen
        ) == nil)
    }

    /// An 8 GB Mac genuinely cannot hold the default model — it is told so, with the
    /// numbers, and may still install it.
    @Test func eightGigMacIsWarnedButStillAllowed() {
        let small = budget(ram: 8 * gb, metal: 6 * gb)
        let profile = LocalAIModel.recommended.memoryProfile
        let verdict = ModelFitEvaluator.verdict(
            profile: profile,
            contextTokens: ContextWindowPresets.fallback,
            budget: small
        )
        #expect(verdict == .wontFit)
        #expect(OnboardingModelGate.allowsDownload(verdict: verdict) == true)
        let warning = OnboardingModelGate.warning(
            verdict: verdict,
            profile: profile,
            contextTokens: ContextWindowPresets.fallback,
            budget: small
        )
        #expect(warning?.isEmpty == false)
        // The warning must quote what the Mac actually has, not a fixed threshold.
        #expect(warning?.contains("GB") == true)
        #expect(warning?.contains("16 GB RAM") == false)
        // …and it must name the Mac this model does want, computed from the model.
        let minimum = ModelFitEvaluator.minimumMemoryBytes(
            profile: profile,
            contextTokens: ContextWindowPresets.fallback,
            comfortable: true
        )
        #expect(warning?.contains(RemoteModelFitDescriber.memoryText(minimum)) == true)
    }

    /// Without a profile there is no per-model number to quote, so the sentence
    /// degrades to the available-memory-only form rather than inventing one.
    @Test func aWontFitWarningWithoutAProfileStillWarns() {
        let warning = OnboardingModelGate.warning(
            verdict: .wontFit,
            profile: nil,
            contextTokens: ContextWindowPresets.fallback,
            budget: budget(ram: 8 * gb, metal: 6 * gb)
        )
        #expect(warning?.contains("below what it needs") == true)
    }

    @Test func aTightFitWarnsAboutSpeedNotCapacity() {
        let warning = OnboardingModelGate.warning(
            verdict: .tight,
            profile: LocalAIModel.recommended.memoryProfile,
            contextTokens: ContextWindowPresets.fallback,
            budget: budget(ram: 16 * gb, metal: 12 * gb)
        )
        #expect(warning?.contains("slow") == true)
    }

    @Test func everyVerdictAllowsTheDownload() {
        for verdict in [ModelFitVerdict.fits, .tight, .wontFit, .unknown] {
            #expect(OnboardingModelGate.allowsDownload(verdict: verdict) == true)
        }
    }

    @Test func anUnknownProfileProducesNoWarning() {
        #expect(OnboardingModelGate.warning(
            verdict: .unknown,
            profile: nil,
            contextTokens: ContextWindowPresets.fallback,
            budget: budget(ram: 8 * gb, metal: 6 * gb)
        ) == nil)
    }
}
