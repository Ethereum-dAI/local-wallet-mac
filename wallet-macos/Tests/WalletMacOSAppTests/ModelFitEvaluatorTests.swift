import Foundation
import Testing
@testable import WalletMacOSApp

struct ModelFitEvaluatorTests {
    private let gb: UInt64 = 1_073_741_824

    /// Real Gemma 4 E4B Q4_0 numbers, read from the GGUF header:
    /// 42 layers, 2 KV heads, key/value length 512 → 168 KiB per token.
    private let gemma = ModelMemoryProfile(
        weightBytes: 4_590_807_392,
        blockCount: 42,
        kvHeadCount: 2,
        keyLength: 512,
        valueLength: 512,
        trainedContextTokens: 131_072
    )

    private func budget(ram: UInt64, metal: UInt64) -> HardwareBudget {
        HardwareBudget(totalMemoryBytes: ram, metalBudgetBytes: metal, freeDiskBytes: 500 * gb)
    }

    @Test func kvCacheIs168KiBPerToken() {
        let oneToken = ModelFitEvaluator.kvCacheBytes(profile: gemma, contextTokens: 1)
        #expect(oneToken == 172_032)
        #expect(ModelFitEvaluator.kvCacheBytes(profile: gemma, contextTokens: 8192) == 172_032 * 8192)
    }

    @Test func requiredBytesAddsFifteenPercentOverhead() {
        let need = ModelFitEvaluator.requiredBytes(profile: gemma, contextTokens: 8192)
        let raw = 4_590_807_392 + UInt64(172_032 * 8192)
        #expect(need == raw / 100 * 115)
    }

    @Test func gemmaFitsComfortablyOnA36GBMac() {
        let verdict = ModelFitEvaluator.verdict(
            profile: gemma, contextTokens: 8192,
            budget: budget(ram: 36 * gb, metal: 30_182_211_584)
        )
        #expect(verdict == .fits)
    }

    @Test func longContextDoesNotFitEvenOnA36GBMac() {
        let verdict = ModelFitEvaluator.verdict(
            profile: gemma, contextTokens: 131_072,
            budget: budget(ram: 36 * gb, metal: 30_182_211_584)
        )
        #expect(verdict == .wontFit)
    }

    @Test func sixteenGigMacFitsAtEightKAndIsTightAtSixteenK() {
        let small = budget(ram: 16 * gb, metal: 12 * gb)   // 9.6 GiB usable
        #expect(ModelFitEvaluator.verdict(profile: gemma, contextTokens: 8192, budget: small) == .fits)
        #expect(ModelFitEvaluator.verdict(profile: gemma, contextTokens: 16384, budget: small) == .tight)
        #expect(ModelFitEvaluator.verdict(profile: gemma, contextTokens: 32768, budget: small) == .wontFit)
    }

    /// The case the deleted 16 GB gate used to block outright: an 8 GB Air cannot
    /// hold the default model, and now says so with numbers instead of refusing.
    @Test func eightGigMacCannotHoldTheDefaultModel() {
        let tiny = budget(ram: 8 * gb, metal: 6 * gb)      // 4.8 GiB usable
        #expect(ModelFitEvaluator.verdict(profile: gemma, contextTokens: 4096, budget: tiny) == .wontFit)
    }

    @Test func missingProfileIsUnknownNotAFailure() {
        let verdict = ModelFitEvaluator.verdict(
            profile: nil, contextTokens: 8192,
            budget: budget(ram: 36 * gb, metal: 30_182_211_584)
        )
        #expect(verdict == .unknown)
    }

    @Test func largestFittingContextPicksAPresetFromTheLadder() {
        let small = budget(ram: 16 * gb, metal: 12 * gb)
        #expect(ModelFitEvaluator.largestFittingContext(profile: gemma, budget: small) == 8192)
        let tiny = budget(ram: 8 * gb, metal: 6 * gb)
        #expect(ModelFitEvaluator.largestFittingContext(profile: gemma, budget: tiny) == nil)
    }

    /// The inverse of the fit check: what does *this model* demand of a Mac?
    /// This is what a per-model "minimum requirement" actually means — a fixed RAM
    /// number cannot express it, because it moves with the quant and the context.
    @Test func minimumMemoryIsDerivedFromTheModelNotAFixedNumber() {
        // Gemma Q4_0 needs 5.67 GiB at 4k → comfortable on ~11.8 GiB of RAM.
        #expect(ModelFitEvaluator.minimumMemoryBytes(profile: gemma, contextTokens: 4096, comfortable: true)
                == 12_687_016_583)
        // At 8k the same model demands a bigger Mac: ~13.4 GiB.
        #expect(ModelFitEvaluator.minimumMemoryBytes(profile: gemma, contextTokens: 8192, comfortable: true)
                == 14_375_224_010)
        // Usable-but-tight is a lower bar than comfortable.
        #expect(ModelFitEvaluator.minimumMemoryBytes(profile: gemma, contextTokens: 4096, comfortable: false)
                < ModelFitEvaluator.minimumMemoryBytes(profile: gemma, contextTokens: 4096, comfortable: true))
    }

    /// A small model must produce a small requirement — the whole point of making
    /// the minimum model-dependent.
    @Test func aSmallModelDemandsASmallMac() {
        let tiny = ModelMemoryProfile(
            weightBytes: 1_710_000_000, blockCount: 26, kvHeadCount: 2,
            keyLength: 256, valueLength: 256, trainedContextTokens: 32_768
        )
        let required = ModelFitEvaluator.minimumMemoryBytes(profile: tiny, contextTokens: 4096, comfortable: true)
        #expect(required < 8 * gb)
        #expect(ModelFitEvaluator.verdict(
            profile: tiny, contextTokens: 4096,
            budget: budget(ram: 8 * gb, metal: 6 * gb)
        ) == .fits)
    }

    @Test func ladderReachesGemmasTrainedContext() {
        #expect(ContextWindowPresets.options(maxTokens: 131_072).contains(131_072))
        #expect(ContextWindowPresets.options(maxTokens: 8192).last == 8192)
    }
}
