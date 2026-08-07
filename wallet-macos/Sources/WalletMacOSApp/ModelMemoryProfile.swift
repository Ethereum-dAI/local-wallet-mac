import Foundation

/// Everything needed to predict a GGUF model's memory footprint, read either from
/// the GGUF header or pinned for a curated model.
struct ModelMemoryProfile: Equatable, Codable {
    let weightBytes: UInt64
    let blockCount: Int
    let kvHeadCount: Int
    let keyLength: Int
    let valueLength: Int
    let trainedContextTokens: Int
}

enum ModelFitVerdict: String, Equatable {
    case fits
    case tight
    case wontFit
    case unknown

    var label: String {
        switch self {
        case .fits: return "Fits"
        case .tight: return "Tight"
        case .wontFit: return "Won't fit"
        case .unknown: return "Size unknown"
        }
    }
}

enum ModelFitEvaluator {
    /// llama.cpp keeps an f16 K and V entry per layer, per KV head, per token.
    static func kvCacheBytes(profile: ModelMemoryProfile, contextTokens: Int) -> UInt64 {
        let perToken = UInt64(profile.blockCount)
            * UInt64(profile.kvHeadCount)
            * UInt64(profile.keyLength + profile.valueLength)
            * 2
        return perToken * UInt64(max(contextTokens, 0))
    }

    /// Weights + KV cache + 15% for the compute graph, scratch buffers and tokenizer.
    static func requiredBytes(profile: ModelMemoryProfile, contextTokens: Int) -> UInt64 {
        let raw = profile.weightBytes + kvCacheBytes(profile: profile, contextTokens: contextTokens)
        return raw / 100 * 115
    }

    static func verdict(
        profile: ModelMemoryProfile?,
        contextTokens: Int,
        budget: HardwareBudget
    ) -> ModelFitVerdict {
        guard let profile else { return .unknown }
        let need = requiredBytes(profile: profile, contextTokens: contextTokens)
        if need <= budget.comfortableBytes { return .fits }
        if need <= budget.usableBytes { return .tight }
        return .wontFit
    }

    /// The inverse of `verdict`: the smallest Mac this model is happy on.
    ///
    /// Below ~20 GiB the 40% reserve binds and the budget is 0.6 × RAM; above it the
    /// reserve is a flat 8 GiB. Metal's own ~75% ceiling is looser than both, so it
    /// does not enter the inversion. Used for copy like "needs a Mac with 12 GB".
    static func minimumMemoryBytes(
        profile: ModelMemoryProfile,
        contextTokens: Int,
        comfortable: Bool
    ) -> UInt64 {
        let need = requiredBytes(profile: profile, contextTokens: contextTokens)
        let target = comfortable ? need * 100 / 80 : need
        let smallMachine = target * 100 / 60
        let twentyGiB: UInt64 = 20 * 1_073_741_824
        return smallMachine <= twentyGiB ? smallMachine : target + 8 * 1_073_741_824
    }

    /// The largest ladder preset that still lands in `.fits`, or nil if none do.
    static func largestFittingContext(
        profile: ModelMemoryProfile,
        budget: HardwareBudget
    ) -> Int? {
        ContextWindowPresets.options(maxTokens: profile.trainedContextTokens)
            .filter { verdict(profile: profile, contextTokens: $0, budget: budget) == .fits }
            .max()
    }
}

/// Onboarding used to refuse to continue below 16 GB of RAM. It advises instead:
/// the download is always permitted, and a Mac that cannot hold the model at the
/// smallest preset gets a plain warning with the numbers behind it.
enum OnboardingModelGate {
    static func allowsDownload(verdict: ModelFitVerdict) -> Bool { true }

    /// `profile` and `contextTokens` are what the verdict was computed from; they
    /// let the won't-fit sentence name the Mac this model actually wants instead
    /// of leaving "below what it needs" unquantified.
    static func warning(
        verdict: ModelFitVerdict,
        profile: ModelMemoryProfile?,
        contextTokens: Int,
        budget: HardwareBudget
    ) -> String? {
        switch verdict {
        case .fits, .unknown:
            return nil
        case .tight:
            return "This model will use most of the memory available to it on this Mac. Replies may be slow."
        case .wontFit:
            let available = RemoteModelFitDescriber.memoryText(budget.usableBytes)
            guard let profile else {
                return "This Mac has \(available) available for the model, which is below what it needs. You can still install it, but expect swapping or a failed load."
            }
            let needed = RemoteModelFitDescriber.memoryText(
                ModelFitEvaluator.requiredBytes(profile: profile, contextTokens: contextTokens)
            )
            let minimum = RemoteModelFitDescriber.memoryText(ModelFitEvaluator.minimumMemoryBytes(
                profile: profile,
                contextTokens: contextTokens,
                comfortable: true
            ))
            return "This Mac has \(available) available for the model, which is below the \(needed) it needs — it wants a Mac with about \(minimum). You can still install it, but expect swapping or a failed load."
        }
    }
}

extension ModelFitEvaluator {
    /// The presets worth offering: everything the model's trained context allows,
    /// minus the sizes this Mac cannot hold. The app does not list a setting that
    /// would hang it — a `.wontFit` context is not a choice, it is a failure.
    /// Always returns at least one preset so the picker is never empty.
    static func selectableContexts(
        profile: ModelMemoryProfile?,
        budget: HardwareBudget?
    ) -> [Int] {
        let all = ContextWindowPresets.options(
            maxTokens: profile?.trainedContextTokens ?? ContextWindowPresets.fallback
        )
        guard let profile, let budget else { return all }
        let runnable = all.filter {
            verdict(profile: profile, contextTokens: $0, budget: budget) != .wontFit
        }
        return runnable.isEmpty ? [all.first ?? ContextWindowPresets.fallback] : runnable
    }
}
