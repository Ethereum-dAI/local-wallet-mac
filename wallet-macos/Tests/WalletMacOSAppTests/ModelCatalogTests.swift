import Foundation
import Testing
@testable import WalletMacOSApp

struct ModelCatalogTests {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "model-catalog-\(UUID().uuidString)")!
    }

    @Test func defaultModelIsFirstAndMarked() {
        let catalog = ModelCatalog(installedStore: InstalledModelStore(defaults: suite()))
        #expect(catalog.entries.first?.id == LocalAIModel.recommended.id)
        #expect(catalog.entries.first?.isDefault == true)
        #expect(catalog.entries.first?.source == .curated)
    }

    @Test func customModelsAppearAfterCuratedOnes() {
        let defaults = suite()
        let store = InstalledModelStore(defaults: defaults)
        store.add(InstalledModel(
            id: "unsloth/gemma-4-E2B-it-GGUF#gemma-4-E2B-it-Q4_K_M.gguf",
            displayName: "gemma-4-E2B-it-Q4_K_M",
            repoID: "unsloth/gemma-4-E2B-it-GGUF",
            fileName: "gemma-4-E2B-it-Q4_K_M.gguf",
            path: "/tmp/e2b.gguf",
            sizeBytes: 1_710_000_000,
            sha256: "def",
            profile: nil
        ))

        let catalog = ModelCatalog(installedStore: store)
        #expect(catalog.entries.count == LocalAIModel.curated.count + 1)
        #expect(catalog.entries.last?.source == .huggingFace)
        #expect(catalog.entries.last?.installedPath == "/tmp/e2b.gguf")
    }

    /// Re-adding the default's own repo from the Hugging Face field is an ordinary
    /// custom install: it keeps its `owner/repo#file.gguf` id and its own row, next
    /// to the curated one. The two are distinct rows over distinct files — the
    /// curated download keeps the bare file name, a typed-in repo is namespaced —
    /// so neither can remove the other's bytes.
    @Test func reAddingTheDefaultsRepoByHandIsJustAnotherCustomRow() {
        let store = InstalledModelStore(defaults: suite())
        let model = LocalAIModel.recommended
        let handAddedID = "\(model.artifactRepo)#\(model.artifactFileName)"
        store.add(InstalledModel(
            id: handAddedID,
            displayName: "gemma-4-E4B-wallet-ft.Q4_K_M",
            repoID: model.artifactRepo,
            fileName: model.artifactFileName,
            path: "/tmp/ef-dai-team_gemma-4-E4B-wallet-ft__gemma-4-E4B-wallet-ft.Q4_K_M.gguf",
            sizeBytes: model.memoryProfile.weightBytes,
            sha256: model.sha256,
            profile: model.memoryProfile
        ))

        let catalog = ModelCatalog(installedStore: store)
        #expect(catalog.entries.count == LocalAIModel.curated.count + 1)
        #expect(catalog.entries.last?.id == handAddedID)
        #expect(catalog.entries.last?.source == .huggingFace)
        #expect(catalog.entries.first?.id == model.id)
    }

    /// Qwen3's header was read from the pinned artifact; these are the four numbers
    /// the fit verdict is computed from, so a typo in any of them silently mis-sizes
    /// every verdict for this model.
    @Test func curatedQwen3CarriesItsMeasuredMemoryProfile() {
        let profile = LocalAIModel.qwen3.memoryProfile
        #expect(profile.weightBytes == 5_027_783_488)
        #expect(profile.blockCount == 36)
        #expect(profile.kvHeadCount == 8)
        #expect(profile.keyLength == 128)
        #expect(profile.valueLength == 128)
        #expect(profile.trainedContextTokens == 40_960)
        // 36 x 8 x (128+128) x 2 bytes = 144 KiB per token.
        #expect(ModelFitEvaluator.kvCacheBytes(profile: profile, contextTokens: 1) == 147_456)
    }

    /// Every curated model sits in the same memory class as the default, which is
    /// the point of the set: a Mac that runs one runs all of them. Guards against
    /// someone swapping in a quant that quietly changes that.
    @Test func allCuratedModelsAreInTheSameMemoryClass() {
        let bytes = LocalAIModel.curated.map {
            ModelFitEvaluator.requiredBytes(profile: $0.memoryProfile, contextTokens: 4096)
        }
        let smallest = bytes.min()!
        let largest = bytes.max()!
        #expect(largest < smallest * 3 / 2)
    }

    @Test func curatedGemmaCarriesItsMeasuredMemoryProfile() {
        let profile = LocalAIModel.walletFineTune.memoryProfile
        #expect(profile.blockCount == 42)
        #expect(profile.kvHeadCount == 2)
        #expect(profile.keyLength == 512)
        #expect(profile.trainedContextTokens == 131_072)
    }
}
