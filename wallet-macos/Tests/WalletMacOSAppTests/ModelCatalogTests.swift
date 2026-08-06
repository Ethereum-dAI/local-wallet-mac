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
        #expect(catalog.entries.count == LocalAIModel.available.count + 1)
        #expect(catalog.entries.last?.source == .huggingFace)
        #expect(catalog.entries.last?.installedPath == "/tmp/e2b.gguf")
    }

    @Test func curatedGemmaCarriesItsMeasuredMemoryProfile() {
        let profile = LocalAIModel.recommended.memoryProfile
        #expect(profile.blockCount == 42)
        #expect(profile.kvHeadCount == 2)
        #expect(profile.keyLength == 512)
        #expect(profile.trainedContextTokens == 131_072)
    }
}
