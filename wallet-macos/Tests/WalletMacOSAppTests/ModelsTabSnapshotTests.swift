import Foundation
import Testing
@testable import WalletMacOSApp

struct ModelsTabSnapshotTests {
    private let gb: UInt64 = 1_073_741_824

    @Test func rowCarriesVerdictAndInstallState() {
        let row = SettingsModelRow(
            id: LocalAIModel.recommended.id,
            displayName: "Gemma 4 E4B",
            detail: "Q4_0 · 4.59 GB",
            source: .curated,
            verdict: .fits,
            estimatedBytes: 6_900_000_000,
            isInstalled: true,
            isActive: true,
            isDefault: true
        )
        #expect(row.verdict.label == "Fits")
        #expect(row.isRemovable == false)
    }

    @Test func customInstalledRowIsRemovableWhenInactive() {
        let row = SettingsModelRow(
            id: "owner/repo#file.gguf",
            displayName: "file",
            detail: "owner/repo",
            source: .huggingFace,
            verdict: .tight,
            estimatedBytes: 1,
            isInstalled: true,
            isActive: false,
            isDefault: false
        )
        #expect(row.isRemovable == true)
    }

    @Test func hardwareSummaryFormatsBudgetForDisplay() {
        let summary = SettingsHardwareSummary(budget: HardwareBudget(
            totalMemoryBytes: 36 * gb,
            metalBudgetBytes: 30_182_211_584,
            freeDiskBytes: 211 * gb
        ))
        #expect(summary.memoryText.contains("36"))
        #expect(summary.budgetText.contains("28"))
        #expect(summary.diskText.contains("211"))
    }
}
