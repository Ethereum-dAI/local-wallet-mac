import Foundation

/// What is actually resident in `EmbeddedLlamaInferenceService.runtime` right now:
/// the model URL and context size it was loaded with, or `nil`/`nil` before the
/// first load.
struct ModelLoadState: Equatable {
    var modelURL: URL?
    var contextTokens: Int?
}

/// The model + context window a generation should run with, once
/// `desiredModelURL` has been resolved against the installed-model fallback.
struct ModelSwapTarget: Equatable {
    var modelURL: URL
    var contextTokens: Int
}

/// The service's raw, unresolved desire — `desiredModelURL`/`desiredContextTokens`
/// as `setActiveModel` last wrote them. Kept distinct from `ModelSwapTarget`
/// because comparing the *raw* desire before and after a load is what lets
/// `commit` detect "the user picked something else while we were loading" without
/// re-running the (throwing) installed-model fallback lookup a second time.
struct DesiredModel: Equatable {
    var modelURL: URL?
    var contextTokens: Int
}

/// The pure decision at the heart of `EmbeddedLlamaInferenceService`'s runtime
/// swap: given what is currently loaded and what is currently desired, does the
/// next generation need a fresh `LlamaRuntime`, and — separately — may a load that
/// just finished be recorded as the new "loaded" state? Kept free of `LlamaRuntime`
/// itself (no model file, no llama.cpp) so both questions, including the "a desire
/// changed mid-load" race, are unit-testable.
enum ModelSwapPlanner {
    /// Whether the runtime backing `loaded` still satisfies `target`. `false`
    /// means the existing runtime can be reused as-is (the cheap, expected path —
    /// a needless reload here costs seconds and gigabytes).
    static func needsSwap(loaded: ModelLoadState, target: ModelSwapTarget) -> Bool {
        loaded.modelURL != target.modelURL || loaded.contextTokens != target.contextTokens
    }

    /// Whether a load that targeted `justLoaded` (started when the desire was
    /// `desiredAtLoadStart`) may be committed as the new `loaded` state, given the
    /// desire `desiredNow` — read again after the (multi-second) load completed.
    ///
    /// Returns `nil` when the desire moved on while the load was in flight: the
    /// caller must not record the just-finished load as current, so the next
    /// `needsSwap` call still sees a mismatch against the newer desire and swaps
    /// again. The stale load is still returned to its own caller for that one
    /// generation — it is simply never adopted as the service's shared state.
    static func commit(
        justLoaded: ModelSwapTarget,
        desiredAtLoadStart: DesiredModel,
        desiredNow: DesiredModel
    ) -> ModelLoadState? {
        guard desiredAtLoadStart == desiredNow else { return nil }
        return ModelLoadState(modelURL: justLoaded.modelURL, contextTokens: justLoaded.contextTokens)
    }
}
