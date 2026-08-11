import Foundation
import Testing
@testable import WalletMacOSApp

struct ModelSelectionTests {
    private let gb: UInt64 = 1_073_741_824

    private func entry(profile: ModelMemoryProfile?) -> ModelCatalogEntry {
        ModelCatalogEntry(
            id: "owner/repo#file.gguf",
            displayName: "file",
            detail: "owner/repo",
            sizeText: "1 GB",
            source: .huggingFace,
            repoID: "owner/repo",
            fileName: "file.gguf",
            downloadURL: nil,
            sha256: nil,
            profile: profile,
            installedPath: "/tmp/file.gguf",
            isDefault: false
        )
    }

    @Test func verdictUsesTheStoredContextWindow() {
        let store = OnboardingSettingsStore(defaults: UserDefaults(suiteName: "sel-\(UUID().uuidString)")!)
        store.contextWindowTokens = 8192
        let budget = HardwareBudget(totalMemoryBytes: 36 * gb, metalBudgetBytes: 30_182_211_584, freeDiskBytes: 500 * gb)
        let profile = LocalAIModel.recommended.memoryProfile

        #expect(ModelSelectionPolicy.verdict(
            entry: entry(profile: profile),
            contextTokens: store.contextWindowTokens,
            budget: budget
        ) == .fits)
    }

    @Test func unknownProfileNeverBlocksSelection() {
        let budget = HardwareBudget(totalMemoryBytes: 8 * gb, metalBudgetBytes: 6 * gb, freeDiskBytes: 10 * gb)
        #expect(ModelSelectionPolicy.verdict(entry: entry(profile: nil), contextTokens: 8192, budget: budget) == .unknown)
        #expect(ModelSelectionPolicy.allowsSelection(verdict: .unknown) == true)
        #expect(ModelSelectionPolicy.allowsSelection(verdict: .wontFit) == true)
    }

    @Test func selectionRequiresConfirmationOnlyWhenItWillNotFit() {
        #expect(ModelSelectionPolicy.needsConfirmation(verdict: .fits) == false)
        #expect(ModelSelectionPolicy.needsConfirmation(verdict: .tight) == false)
        #expect(ModelSelectionPolicy.needsConfirmation(verdict: .wontFit) == true)
        #expect(ModelSelectionPolicy.needsConfirmation(verdict: .unknown) == true)
    }
}
