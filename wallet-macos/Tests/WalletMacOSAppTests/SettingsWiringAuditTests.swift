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
    @Test func defaultModelIsTheWalletFineTune() {
        #expect(LocalAIModel.recommended.id == "ef-dai-team/gemma-4-E4B-wallet-ft")
        #expect(LocalAIModel.recommended.artifactFileName == "gemma-4-E4B-wallet-ft.Q4_K_M.gguf")
        #expect(LocalAIModel.curated.first?.id == LocalAIModel.recommended.id)
        // The values that make an accidental default-model change dangerous rather
        // than merely wrong: an edited checksum or URL would silently point the
        // wallet at different bytes than the ones this build was pinned against.
        #expect(LocalAIModel.recommended.sha256 == "fdf5c30e86d83c0391bed5e005af85bd2af2eb1ef7455a64b9a463d4d8ced16b")
        #expect(LocalAIModel.recommended.artifactURL == URL(string: "https://huggingface.co/ef-dai-team/gemma-4-E4B-wallet-ft/resolve/main/gemma-4-E4B-wallet-ft.Q4_K_M.gguf?download=true")!)
    }

    /// The fine-tune is a merge into Gemma 4 E4B, not a different model: same
    /// `gemma4` block/head shape and trained context, so the Gemma DSL parsing and
    /// the context presets carry over untouched. Only the weights got bigger.
    @Test func defaultModelKeepsTheGemma4Shape() {
        let tuned = LocalAIModel.recommended.memoryProfile
        let base = LocalAIModel.gemma4Base.memoryProfile
        #expect(tuned.blockCount == base.blockCount)
        #expect(tuned.kvHeadCount == base.kvHeadCount)
        #expect(tuned.keyLength == base.keyLength)
        #expect(tuned.valueLength == base.valueLength)
        #expect(tuned.trainedContextTokens == base.trainedContextTokens)
        #expect(tuned.weightBytes == 5_335_292_160)
    }

    /// The base model stays in the catalog, at its own pin. Dropping it would
    /// strand every wallet that onboarded before the fine-tune: their stored
    /// `selectedModelID` would stop resolving and silently fall back to a model
    /// they have not downloaded.
    @Test func untunedBaseStaysCuratedAtItsOwnPin() {
        let base = LocalAIModel.gemma4Base
        #expect(base.id == "google/gemma-4-E4B-it")
        #expect(base.artifactFileName == "gemma-4-E4B-it-Q4_0.gguf")
        #expect(base.sha256 == "a555b900214b477d8880e7832e0b8925e139b0159640036b09fe472b6f2097f2")
        #expect(base.artifactURL == URL(string: "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_0.gguf?download=true")!)
        #expect(LocalAIModel.curated.contains { $0.id == base.id })
        #expect(base.id != LocalAIModel.recommended.id)
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

    /// First-run setup offers the default and nothing else. The second curated
    /// model is a Settings decision, made later by someone who has seen their own
    /// hardware verdicts — not a fork in the road before the wallet works.
    @Test func onboardingOffersTheDefaultAndNothingElse() {
        #expect(LocalAIModel.onboardingOptions.map(\.id) == [LocalAIModel.recommended.id])
        #expect(LocalAIModel.curated.count > LocalAIModel.onboardingOptions.count)
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
