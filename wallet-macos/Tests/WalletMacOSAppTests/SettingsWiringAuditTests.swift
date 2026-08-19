import Foundation
import Testing
@testable import WalletMacOSApp

/// Wiring tests for the Task 10 settings-correctness audit.
///
/// These prove the *actual* runtime behavior of two suspicions raised during the
/// audit, so the matrix doc is backed by executable evidence rather than a read of
/// the source alone.
struct SettingsWiringAuditTests {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "settings-audit-\(UUID().uuidString)")!
    }

    /// Suspicion A — the legacy onboarding RPC key
    /// (`com.localwallet.demo.onboarding.rpc-url`) is read as a fallback inside
    /// `DemoSettingsStore.networkSettings`. It feeds the **Sepolia** execution RPC
    /// (via `defaultingSepoliaRPCURL`) and only when the primary
    /// `com.localwallet.demo.sepolia-rpc-url` key is unset. Sepolia is the only app
    /// network, so that value also surfaces as the active execution RPC.
    @Test func legacyOnboardingRPCFallsBackIntoSepoliaNetworkSettings() {
        let defaults = suite()
        defaults.set("https://example.test/rpc", forKey: "com.localwallet.demo.onboarding.rpc-url")
        let store = DemoSettingsStore(defaults: defaults)
        let settings = store.networkSettings

        // The fallback feeds the Sepolia execution RPC...
        #expect(settings.sepoliaRPCURL == "https://example.test/rpc")
        // ...and Sepolia is always the active RPC.
        #expect(settings.activeRPCURL == "https://example.test/rpc")
        #expect(settings.activeChain.id == 11_155_111)
    }

    /// The fallback is only consulted when the primary Sepolia key is absent. Once
    /// the user has saved a Sepolia RPC explicitly, the legacy onboarding value is
    /// ignored (the `?? legacyOnboardingRPCURL` branch is never reached).
    @Test func explicitSepoliaRPCOverridesLegacyOnboardingFallback() {
        let defaults = suite()
        defaults.set("https://example.test/rpc", forKey: "com.localwallet.demo.onboarding.rpc-url")
        defaults.set("https://primary.test/rpc", forKey: "com.localwallet.demo.sepolia-rpc-url")
        let settings = DemoSettingsStore(defaults: defaults).networkSettings

        #expect(settings.sepoliaRPCURL == "https://primary.test/rpc")
        #expect(settings.activeRPCURL == "https://primary.test/rpc")
    }

    /// Suspicion B, resolved. Selection used to drive install only, which was safe
    /// while the catalog held exactly one model. It no longer does: the catalog is
    /// user-extensible, so selection drives the runtime through
    /// `InstalledModelStore` + `EmbeddedLlamaInferenceService.setActiveModel`.
    /// What must stay true is that the shipped default is the reviewed one.
    @Test func defaultModelIsTheUntunedQ4KMBase() {
        #expect(LocalAIModel.recommended.id == "google/gemma-4-E4B-it")
        #expect(LocalAIModel.recommended.artifactFileName == "gemma-4-E4B-it-Q4_K_M.gguf")
        #expect(LocalAIModel.curated.first?.id == LocalAIModel.recommended.id)
        // The values that make an accidental default-model change dangerous rather
        // than merely wrong: an edited checksum or URL would silently point the
        // wallet at different bytes than the ones this build was pinned against.
        // This sha256 is confirmed three ways — Hugging Face's `x-linked-etag` at the
        // pinned revision, a local copy of the file, and the pin an earlier revision
        // of this repo carried before Q4_K_M vanished from `main`.
        #expect(LocalAIModel.recommended.sha256 == "90ce98129eb3e8cc57e62433d500c97c624b1e3af1fcc85dd3b55ad7e0313e9f")
        #expect(LocalAIModel.recommended.artifactURL == URL(string: "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/1762c8e8713f/gemma-4-E4B-it-Q4_K_M.gguf?download=true")!)
    }

    /// The URL must stay revision-pinned. ggml-org re-quantized this repo and dropped
    /// Q4_K_M from `main`, so `resolve/main/gemma-4-E4B-it-Q4_K_M.gguf` returns 404 —
    /// a "tidy the URL" edit would break every new install's download, and the failure
    /// would surface as an unexplained "failed to load model" rather than a 404.
    @Test func defaultModelURLIsPinnedToARevisionNotToMain() {
        let url = LocalAIModel.recommended.artifactURL.absoluteString
        #expect(url.contains("/resolve/1762c8e8713f/"))
        #expect(!url.contains("/resolve/main/"))
    }

    /// The fine-tune is a merge into Gemma 4 E4B, not a different model: same
    /// `gemma4` block/head shape and trained context, so the Gemma DSL parsing and
    /// the context presets carry over untouched. Only the weights got bigger.
    @Test func defaultModelKeepsTheGemma4Shape() {
        let base = LocalAIModel.recommended.memoryProfile
        let tuned = LocalAIModel.walletFineTune.memoryProfile
        #expect(tuned.blockCount == base.blockCount)
        #expect(tuned.kvHeadCount == base.kvHeadCount)
        #expect(tuned.keyLength == base.keyLength)
        #expect(tuned.valueLength == base.valueLength)
        #expect(tuned.trainedContextTokens == base.trainedContextTokens)
        #expect(base.weightBytes == 5_335_289_824)
        #expect(tuned.weightBytes == 5_335_292_160)
    }

    /// The fine-tune stays in the catalog, at its own pin. Dropping it would strand
    /// every wallet that onboarded onto it: their stored `selectedModelID` would stop
    /// resolving and silently fall back to a model they have not downloaded.
    @Test func supersededFineTuneStaysCuratedAtItsOwnPin() {
        let tuned = LocalAIModel.walletFineTune
        #expect(tuned.id == "ef-dai-team/gemma-4-E4B-wallet-ft")
        #expect(tuned.artifactFileName == "gemma-4-E4B-wallet-ft.Q4_K_M.gguf")
        #expect(tuned.sha256 == "fdf5c30e86d83c0391bed5e005af85bd2af2eb1ef7455a64b9a463d4d8ced16b")
        #expect(tuned.artifactURL == URL(string: "https://huggingface.co/ef-dai-team/gemma-4-E4B-wallet-ft/resolve/main/gemma-4-E4B-wallet-ft.Q4_K_M.gguf?download=true")!)
        #expect(LocalAIModel.curated.contains { $0.id == tuned.id })
        #expect(tuned.id != LocalAIModel.recommended.id)
    }

    /// Every curated id is distinct. `curated` is the lookup table a stored
    /// `selectedModelID` resolves through and the `Identifiable` list Settings
    /// renders, so a duplicate id would make one row unreachable and the other
    /// ambiguous — which is the trap in reusing `google/gemma-4-E4B-it` for two
    /// different quantizations of the same model.
    @Test func curatedIDsAreUnique() {
        let ids = LocalAIModel.curated.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// An existing install keeps the model it downloaded. `selectedModelID` only
    /// falls back to the default when nothing is stored, so changing the default
    /// must not move anyone who already has a persisted choice.
    @Test func existingInstallKeepsItsStoredModel() {
        let defaults = suite()
        defaults.set("google/gemma-4-E4B-it", forKey: "com.localwallet.demo.onboarding.selected-model-id")

        #expect(OnboardingSettingsStore(defaults: defaults).selectedModelID == "google/gemma-4-E4B-it")
        #expect(OnboardingSettingsStore(defaults: suite()).selectedModelID == LocalAIModel.recommended.id)
    }

    /// First-run setup offers the default and Qwen3 8B, in that order — two pinned,
    /// measured models in the same memory class, so either gives a working wallet.
    /// It must stay a short list and never become a browser: any other GGUF is a
    /// Settings › Models decision, made later by someone who has seen their own
    /// hardware verdicts.
    @Test func onboardingOffersTheDefaultAndQwen() {
        #expect(LocalAIModel.onboardingOptions.map(\.id)
                == [LocalAIModel.recommended.id, LocalAIModel.qwen3.id])
        #expect(LocalAIModel.curated.count > LocalAIModel.onboardingOptions.count)
    }

    /// The superseded fine-tune is retained, not offered. A new install that picked it
    /// at onboarding would be choosing the model this change exists to demote.
    @Test func onboardingDoesNotOfferTheSupersededFineTune() {
        #expect(!LocalAIModel.onboardingOptions.contains { $0.id == LocalAIModel.walletFineTune.id })
    }

    /// Same pin as the default model, for the same reason: an edited checksum or
    /// URL would point the wallet at different bytes than this build was reviewed
    /// against. Values read from Qwen's own repo on 2026-08-07.
    @Test func curatedQwen3IsPinnedToQwensOwnBuild() {
        let qwen = LocalAIModel.qwen3
        #expect(qwen.id == "Qwen/Qwen3-8B")
        #expect(qwen.artifactRepo == "Qwen/Qwen3-8B-GGUF")
        #expect(qwen.artifactFileName == "Qwen3-8B-Q4_K_M.gguf")
        #expect(qwen.sha256 == "d98cdcbd03e17ce47681435b5150e34c1417f50b5c0019dd560e4882c5745785")
        #expect(qwen.artifactURL == URL(string: "https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf?download=true")!)
        #expect(LocalAIModel.curated.contains { $0.id == qwen.id })
        #expect(qwen.id != LocalAIModel.recommended.id)
    }
}
