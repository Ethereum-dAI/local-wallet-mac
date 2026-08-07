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

    /// A curated model the user has not fetched yet is the only row with something
    /// to download — the app knows its URL and checksum. A Hugging Face row exists
    /// because its file is already on disk.
    @Test func onlyAnUninstalledCuratedRowOffersADownload() {
        func row(source: ModelSource, isInstalled: Bool) -> SettingsModelRow {
            SettingsModelRow(
                id: "x",
                displayName: "x",
                detail: "x",
                source: source,
                verdict: .fits,
                estimatedBytes: 1,
                isInstalled: isInstalled,
                isActive: false,
                isDefault: false
            )
        }
        #expect(row(source: .curated, isInstalled: false).isDownloadable == true)
        #expect(row(source: .curated, isInstalled: true).isDownloadable == false)
        #expect(row(source: .huggingFace, isInstalled: false).isDownloadable == false)
        #expect(row(source: .huggingFace, isInstalled: true).isDownloadable == false)
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
