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

/// The row's leading glyph used to be a radio button on every row, including
/// models that were not downloaded — it looked selectable and was not. These pin
/// the states the icon and the action set have to distinguish.
struct ModelRowAffordanceTests {
    private func row(isInstalled: Bool, isActive: Bool, isDefault: Bool = false) -> SettingsModelRow {
        SettingsModelRow(
            id: "m",
            displayName: "m",
            detail: "5.03 GB",
            source: .curated,
            verdict: .fits,
            estimatedBytes: 1,
            isInstalled: isInstalled,
            isActive: isActive,
            isDefault: isDefault
        )
    }

    /// A model that is not on disk offers exactly one action — download it. It must
    /// not also look selectable.
    @Test func anUndownloadedModelOffersOnlyDownload() {
        let r = row(isInstalled: false, isActive: false)
        #expect(r.isDownloadable == true)
        #expect(r.isInstalled == false)
        #expect(r.isRemovable == false)
    }

    /// Installed but not running: selectable, and removable.
    @Test func anInstalledInactiveModelIsSelectableAndRemovable() {
        let r = row(isInstalled: true, isActive: false)
        #expect(r.isDownloadable == false)
        #expect(r.isRemovable == true)
    }

    /// The running model has no action at all — "Use" on the active row was a
    /// permanently disabled button, which reads as broken rather than as state.
    @Test func theActiveModelOffersNothingToPress() {
        let r = row(isInstalled: true, isActive: true)
        #expect(r.isDownloadable == false)
        #expect(r.isRemovable == false)
    }

    /// The default model is never removable even when idle — it is the fallback
    /// every other selection falls back to.
    @Test func theDefaultModelIsNeverRemovable() {
        #expect(row(isInstalled: true, isActive: false, isDefault: true).isRemovable == false)
    }
}

/// Cancelling is a decision, not a network failure, and has to read that way.
struct ModelDownloadCancellationTests {
    @Test func cancellationHasItsOwnMessage() {
        let text = LocalAIModelDownloadError.cancelled.errorDescription ?? ""
        #expect(text.contains("cancelled"))
        #expect(text.lowercased().contains("failed") == false)
    }

    /// The collision message told users to cancel at a time when nothing could.
    /// Now that Cancel exists, the wording is honest either way.
    @Test func theCollisionMessagePointsAtSomethingThatExists() {
        let text = LocalAIModelDownloadError.downloadAlreadyInProgress.errorDescription ?? ""
        #expect(text.contains("Cancel it"))
    }

    /// Nothing in flight must report a cancellation that did not happen.
    @Test func cancellingWithNothingInFlightReportsFalse() {
        #expect(LocalAIModelDownloadManager().cancelActiveDownload() == false)
    }
}
