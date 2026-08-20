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

    /// The default's `gemma4` shape, which the KV-cache arithmetic and the context
    /// presets are both derived from. Read from the GGUF header of the pinned artifact,
    /// so a wrong value here means the memory planner is sizing a different model.
    @Test func defaultModelKeepsTheGemma4Shape() {
        let base = LocalAIModel.recommended.memoryProfile
        #expect(base.blockCount == 42)
        #expect(base.kvHeadCount == 2)
        #expect(base.keyLength == 512)
        #expect(base.valueLength == 512)
        #expect(base.trainedContextTokens == 131_072)
        #expect(base.weightBytes == 5_335_289_824)
    }

    /// Every curated artifact must be one somebody can still fetch.
    ///
    /// This replaces `supersededFineTuneStaysCuratedAtItsOwnPin`, which asserted the
    /// opposite: the wallet fine-tune was kept in `curated` precisely so that installs
    /// which onboarded onto it kept resolving their stored `selectedModelID`. That was
    /// right while the repo existed. It has since been deleted, and a row pointing at a
    /// deleted repo is worse than no row at all — it resolves, so the fallback to
    /// `recommended` never fires, and the download 404s instead.
    ///
    /// The app now ships no first-party weights, so the invariant is simply that no
    /// curated entry points into this org. Adding one back means also committing to
    /// keeping that repo alive.
    @Test func curatedModelsPointAtLiveUpstreamRepos() {
        for model in LocalAIModel.curated {
            #expect(
                !model.artifactRepo.hasPrefix("ef-dai-team/"),
                Comment(rawValue: "\(model.id) points at a first-party repo; the app "
                                  + "ships upstream artifacts only")
            )
            #expect(model.artifactURL.host == "huggingface.co")
            #expect(model.artifactURL.absoluteString.contains(model.artifactRepo))
            #expect(model.sha256.count == 64)
        }
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
        // Onboarding may offer a subset of the catalog, never something outside it:
        // an option that is not curated has no profile to resolve back to.
        let curatedIDs = Set(LocalAIModel.curated.map(\.id))
        #expect(LocalAIModel.onboardingOptions.allSatisfy { curatedIDs.contains($0.id) })
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
