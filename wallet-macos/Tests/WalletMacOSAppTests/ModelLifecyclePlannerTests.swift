import Foundation
import Testing
@testable import WalletMacOSApp

struct ModelActivationPlannerTests {
    private func entry(installedPath: String?, profile: ModelMemoryProfile? = nil) -> ModelCatalogEntry {
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
            installedPath: installedPath,
            isDefault: false
        )
    }

    private let profile = ModelMemoryProfile(
        weightBytes: 1,
        blockCount: 1,
        kvHeadCount: 1,
        keyLength: 1,
        valueLength: 1,
        trainedContextTokens: 8192
    )

    @Test func fileMissingFromDiskFailsAsNotInstalled() {
        let decision = ModelActivationPlanner.decide(
            entry: entry(installedPath: "/tmp/does-not-exist.gguf", profile: profile),
            fileExists: false,
            currentContextTokens: 4096
        )
        #expect(decision == .notInstalled)
    }

    @Test func idNotInTheCatalogFailsAsNotInstalled() {
        let decision = ModelActivationPlanner.decide(
            entry: nil,
            fileExists: true,
            currentContextTokens: 4096
        )
        #expect(decision == .notInstalled)
    }

    @Test func installedModelActivatesWithItsPathAndTheStoredContextWindow() {
        let decision = ModelActivationPlanner.decide(
            entry: entry(installedPath: "/tmp/present.gguf", profile: profile),
            fileExists: true,
            currentContextTokens: 4096
        )
        #expect(decision == .activate(ActiveModelSelection(
            url: URL(fileURLWithPath: "/tmp/present.gguf"),
            contextTokens: 4096,
            displayName: "file"
        )))
    }

    @Test func contextIsClampedToTheModelsTrainedMaximum() {
        // The stored preference (65536) exceeds this model's trained max (8192),
        // so activation must clamp down rather than hand llama.cpp a context size
        // the model was never trained for.
        let decision = ModelActivationPlanner.decide(
            entry: entry(installedPath: "/tmp/present.gguf", profile: profile),
            fileExists: true,
            currentContextTokens: 65536
        )
        #expect(decision == .activate(ActiveModelSelection(
            url: URL(fileURLWithPath: "/tmp/present.gguf"),
            contextTokens: 8192,
            displayName: "file"
        )))
    }

    @Test func unknownProfileFallsBackToTheCuratedRecommendedMax() {
        let decision = ModelActivationPlanner.decide(
            entry: entry(installedPath: "/tmp/present.gguf", profile: nil),
            fileExists: true,
            currentContextTokens: 4096
        )
        guard case let .activate(selection) = decision else {
            Issue.record("expected activation")
            return
        }
        #expect(selection.contextTokens == ContextWindowPresets.clamp(4096, maxTokens: LocalAIModel.recommended.maxContextTokens))
    }
}

struct ModelRemovalPlannerTests {
    @Test func removingTheCurrentlySelectedModelIsBlocked() {
        #expect(ModelRemovalPlanner.isBlockedBecauseActive(id: "active", selectedModelID: "active"))
    }

    @Test func removingAnInactiveModelIsNotBlocked() {
        #expect(!ModelRemovalPlanner.isBlockedBecauseActive(id: "other", selectedModelID: "active"))
    }

    @Test func removingAnInactiveModelWithASuccessfulDeleteMayForgetTheEntry() {
        #expect(ModelRemovalPlanner.mayForgetEntry(fileExistedBeforeAttempt: true, deletionSucceeded: true))
    }

    @Test func aFileAlreadyGoneBeforeTheAttemptStillMayForgetTheEntry() {
        // The user deleted the file by hand (e.g. in Finder); there is nothing left
        // to delete, so the stale catalog row must still be clearable.
        #expect(ModelRemovalPlanner.mayForgetEntry(fileExistedBeforeAttempt: false, deletionSucceeded: true))
    }

    @Test func aFailedDeletionMustNotForgetTheEntry() {
        // A locked file, a permissions error, or a file held open by an in-progress
        // load must not make the app lose track of a multi-gigabyte file still on
        // disk — the entry stays so it is still visible and still removable later.
        #expect(!ModelRemovalPlanner.mayForgetEntry(fileExistedBeforeAttempt: true, deletionSucceeded: false))
    }

    private func record(path: String) -> InstalledModel {
        InstalledModel(
            id: "Qwen/Qwen3-8B",
            displayName: "Qwen3 8B",
            repoID: "Qwen/Qwen3-8B-GGUF",
            fileName: "Qwen3-8B-Q4_K_M.gguf",
            path: path,
            sizeBytes: 1,
            sha256: nil,
            profile: nil
        )
    }

    @Test func aTrackedInstallIsRemovedByItsRecordedPath() {
        #expect(ModelRemovalPlanner.target(
            record: record(path: "/tmp/tracked.gguf"),
            curated: .qwen3,
            downloadedCopyPath: "/tmp/curated-destination.gguf",
            bundledCopyPath: nil
        ) == .tracked(path: "/tmp/tracked.gguf", displayName: "Qwen3 8B"))
    }

    /// A record's path can point *inside* the .app: on an embedded build
    /// `download(model:)` returns the bundled copy, onboarding persists it, and
    /// `migrateLegacySlotIfNeeded` copies that path into a record. Removal must
    /// refuse it — deleting from `Contents/Resources/Models` breaks the running
    /// app's signature — so the bundled check outranks `.tracked`.
    @Test func aRecordPointingInsideTheAppBundleIsRefusedNotDeleted() {
        let bundled = "/Applications/Local Wallet.app/Contents/Resources/Models/model.gguf"
        #expect(ModelRemovalPlanner.target(
            record: record(path: bundled),
            curated: .recommended,
            downloadedCopyPath: nil,
            bundledCopyPath: bundled
        ) == .bundledOnly(displayName: "Qwen3 8B"))
        // Same file, written unnormalised — still the bundled copy.
        #expect(ModelRemovalPlanner.target(
            record: record(path: "/Applications/Local Wallet.app/Contents/Resources/Models/../Models/model.gguf"),
            curated: .recommended,
            downloadedCopyPath: nil,
            bundledCopyPath: bundled
        ) == .bundledOnly(displayName: "Qwen3 8B"))
    }

    /// A record that merely coexists with a bundled copy is still deletable — it is
    /// a separate file in Application Support.
    @Test func aRecordBesideABundledCopyIsStillRemovedByItsOwnPath() {
        #expect(ModelRemovalPlanner.target(
            record: record(path: "/tmp/downloaded.gguf"),
            curated: .recommended,
            downloadedCopyPath: nil,
            bundledCopyPath: "/Applications/Local Wallet.app/Contents/Resources/Models/model.gguf"
        ) == .tracked(path: "/tmp/downloaded.gguf", displayName: "Qwen3 8B"))
    }

    @Test func nothingIsEverDeletedFromInsideTheApplicationBundle() {
        let bundle = "/Applications/Local Wallet.app"
        #expect(ModelRemovalPlanner.isInsideBundle(path: "\(bundle)/Contents/Resources/Models/m.gguf", bundlePath: bundle))
        #expect(ModelRemovalPlanner.isInsideBundle(path: bundle, bundlePath: bundle))
        #expect(!ModelRemovalPlanner.isInsideBundle(path: "/Users/me/Library/Application Support/LocalWallet/Models/m.gguf", bundlePath: bundle))
        // A sibling directory whose name merely starts with the bundle's path.
        #expect(!ModelRemovalPlanner.isInsideBundle(path: "/Applications/Local Wallet.app-backup/m.gguf", bundlePath: bundle))
    }

    /// The regression this exists for: a curated model whose file `ModelCatalog`
    /// found through its `localFileURL` fallback has no store record, and removal
    /// used to `return` silently on exactly that — reporting success while leaving
    /// gigabytes on disk.
    @Test func aCuratedFileWithNoRecordIsStillRemoved() {
        #expect(ModelRemovalPlanner.target(
            record: nil,
            curated: .qwen3,
            downloadedCopyPath: "/tmp/Qwen3-8B-Q4_K_M.gguf",
            bundledCopyPath: nil
        ) == .untracked(path: "/tmp/Qwen3-8B-Q4_K_M.gguf",
                        displayName: LocalAIModel.qwen3.name))
    }

    /// Deleting the copy inside `Contents/Resources/Models` would damage the running
    /// application, so a bundled-only model is refused — with a reason, not silently.
    @Test func aBundledOnlyModelIsRefusedRatherThanDeleted() {
        #expect(ModelRemovalPlanner.target(
            record: nil,
            curated: .recommended,
            downloadedCopyPath: nil,
            bundledCopyPath: "/Applications/Local Wallet.app/Contents/Resources/Models/model.gguf"
        ) == .bundledOnly(displayName: LocalAIModel.recommended.name))
    }

    @Test func nothingOnDiskAndNothingRecordedRemovesNothing() {
        #expect(ModelRemovalPlanner.target(
            record: nil,
            curated: .recommended,
            downloadedCopyPath: nil,
            bundledCopyPath: nil
        ) == .nothingToRemove)
        // An id that is neither curated nor installed — a row that outlived its model.
        #expect(ModelRemovalPlanner.target(
            record: nil,
            curated: nil,
            downloadedCopyPath: nil,
            bundledCopyPath: nil
        ) == .nothingToRemove)
    }
}

/// Which file the runtime loads. Both cases here are regressions the shipped
/// default's rename would otherwise have caused.
struct ModelFileResolverTests {
    private let stored = "/Applications/Local Wallet.app/Contents/Resources/Models/old-embedded.gguf"

    @Test func aStoredPathThatStillExistsWins() {
        let path = ModelFileResolver.resolve(
            storedPath: stored,
            selectedLocalPath: "/models/selected.gguf",
            selectedBundledPath: nil,
            fallbackPath: "/models/default.gguf",
            exists: { _ in true }
        )
        #expect(path == stored)
    }

    /// Finding: replacing an embedded-model .app changed the embedded GGUF's file
    /// name, so the persisted path pointed inside the previous bundle. It used to be
    /// returned verbatim, and every message failed to load a model.
    @Test func aStoredPathIntoAReplacedBundleFallsBackToTheSelectedModel() {
        let path = ModelFileResolver.resolve(
            storedPath: stored,
            selectedLocalPath: "/models/selected.gguf",
            selectedBundledPath: nil,
            fallbackPath: "/models/default.gguf",
            exists: { $0 == "/models/selected.gguf" }
        )
        #expect(path == "/models/selected.gguf")
    }

    /// Finding: the fallback was hardcoded to `.recommended`, so making the
    /// fine-tune the default silently repointed a base-model user with no stored
    /// path at a GGUF they never downloaded. It must resolve *their* selection.
    @Test func noStoredPathResolvesTheSelectedModelNotTheDefault() {
        let path = ModelFileResolver.resolve(
            storedPath: "",
            selectedLocalPath: "/models/gemma-4-E4B-it-Q4_0.gguf",
            selectedBundledPath: nil,
            fallbackPath: "/models/gemma-4-E4B-wallet-ft.Q4_K_M.gguf",
            exists: { $0 == "/models/gemma-4-E4B-it-Q4_0.gguf" }
        )
        #expect(path == "/models/gemma-4-E4B-it-Q4_0.gguf")
    }

    @Test func theSelectedModelsBundledCopyIsUsedWhenNothingIsInApplicationSupport() {
        let path = ModelFileResolver.resolve(
            storedPath: nil,
            selectedLocalPath: "/models/selected.gguf",
            selectedBundledPath: "/Applications/Local Wallet.app/Contents/Resources/Models/selected.gguf",
            fallbackPath: "/models/default.gguf",
            exists: { $0.contains(".app/") }
        )
        #expect(path == "/Applications/Local Wallet.app/Contents/Resources/Models/selected.gguf")
    }

    /// Nothing resolves: name the file the user actually chose, so the failure says
    /// something true rather than blaming the default model.
    @Test func whenNothingExistsTheStoredPathIsPreferredOverTheDefault() {
        #expect(ModelFileResolver.resolve(
            storedPath: "/models/mine.gguf",
            selectedLocalPath: nil,
            selectedBundledPath: nil,
            fallbackPath: "/models/default.gguf",
            exists: { _ in false }
        ) == "/models/mine.gguf")
        #expect(ModelFileResolver.resolve(
            storedPath: nil,
            selectedLocalPath: nil,
            selectedBundledPath: nil,
            fallbackPath: "/models/default.gguf",
            exists: { _ in false }
        ) == "/models/default.gguf")
    }
}

/// The install in flight belongs to the app, not to the Settings view: the download
/// outlives any single appearance of that view, so its progress has to as well.
/// These pin the shape that makes re-attachment possible — a row can ask "is this
/// install mine?" without holding any state of its own.
struct ModelInstallProgressTests {
    @Test func progressIsAddressedByModelIDSoARowCanClaimIt() {
        // Built from `recommended` rather than a literal id: the point of the test is
        // that progress is addressed BY model id, and a hardcoded default id turned
        // this into a second, incidental pin on which model ships.
        var install = ModelInstallProgress(
            modelID: LocalAIModel.recommended.id,
            displayName: LocalAIModel.recommended.name,
            phase: .downloading(progress(0))
        )
        #expect(install.modelID == LocalAIModel.recommended.id)
        install.phase = .downloading(progress(0.5))
        #expect(install.phase == .downloading(progress(0.5)))
        install.phase = .testing
        #expect(install.phase == .testing)
    }

    @Test func anOutcomeCarriesWhetherItFailed() {
        #expect(ModelInstallOutcome(isFailure: false, text: "ok").isFailure == false)
        #expect(ModelInstallOutcome(isFailure: true, text: "boom") != ModelInstallOutcome(isFailure: false, text: "boom"))
    }

    /// The Hugging Face form drew whatever install existed, without checking whose
    /// it was: pressing Download on a curated row put a second progress bar — and a
    /// working Cancel — inside a panel about a different model entirely.
    @Test func anInstallARowIsDrawingIsNotTheHuggingFaceFormsToShow() {
        let install = ModelInstallProgress(
            modelID: LocalAIModel.recommended.id,
            displayName: LocalAIModel.recommended.name,
            phase: .downloading(progress(0.3))
        )
        #expect(install.isClaimedByRow(ids: LocalAIModel.curated.map(\.id)))
        // A Hugging Face add has no row until `InstalledModelStore` has a record,
        // so nothing else can be drawing it.
        let custom = ModelInstallProgress(
            modelID: "owner/repo#f.gguf",
            displayName: "f",
            phase: .downloading(progress(0))
        )
        #expect(!custom.isClaimedByRow(ids: LocalAIModel.curated.map(\.id)))
    }

    /// URLSession reports progress per received chunk; publishing an update that
    /// formats identically is a redraw that changes no pixels.
    @Test func onlyRenderedTelemetryChangesAreWorthPublishing() {
        #expect(!ModelInstallPhase.downloading(progress(0.5012)).isVisibleChange(
            from: .downloading(progress(0.5014))
        ))
        #expect(ModelInstallPhase.downloading(progress(0.51)).isVisibleChange(
            from: .downloading(progress(0.50))
        ))
        #expect(ModelInstallPhase.testing.isVisibleChange(from: .downloading(progress(0.999))))
        #expect(!ModelInstallPhase.testing.isVisibleChange(from: .testing))
    }

    private func progress(_ fraction: Double) -> ModelDownloadProgress {
        ModelDownloadProgress(
            completedBytes: Int64(fraction * 1_000_000),
            totalBytes: 1_000_000,
            bytesPerSecond: nil
        )
    }
}

@MainActor
struct ModelInstallStoreTests {
    @Test func aSecondInstallIsRefusedWhileOneIsInFlight() {
        let store = ModelInstallStore()
        #expect(store.begin(modelID: "a", displayName: "A"))
        #expect(!store.begin(modelID: "b", displayName: "B"))
        #expect(store.install?.modelID == "a")
    }

    @Test func progressForADifferentModelIsIgnored() {
        let store = ModelInstallStore()
        _ = store.begin(modelID: "a", displayName: "A")
        let progress = ModelDownloadProgress(completedBytes: 900, totalBytes: 1_000, bytesPerSecond: nil)
        store.update(modelID: "b", phase: .downloading(progress))
        #expect(store.install?.phase == .downloading(
            ModelDownloadProgress(completedBytes: 0, totalBytes: 0, bytesPerSecond: nil)
        ))
        store.update(modelID: "a", phase: .downloading(progress))
        #expect(store.install?.phase == .downloading(progress))
    }

    /// Starting an install clears the previous outcome, and finishing replaces the
    /// install with one — so the banner never shows a stale result next to a live
    /// download.
    @Test func theOutcomeIsClearedOnStartAndSetOnFinish() {
        let store = ModelInstallStore()
        _ = store.begin(modelID: "a", displayName: "A")
        store.finish(ModelInstallOutcome(isFailure: true, text: "boom"))
        #expect(store.install == nil)
        #expect(store.outcome?.isFailure == true)

        _ = store.begin(modelID: "b", displayName: "B")
        #expect(store.outcome == nil)
    }

    /// It outlives the view that shows it, so it needs a way out that is not
    /// "start another multi-gigabyte download".
    @Test func anOutcomeCanBeDismissed() {
        let store = ModelInstallStore()
        _ = store.begin(modelID: "a", displayName: "A")
        store.finish(ModelInstallOutcome(isFailure: false, text: "done"))
        store.clearOutcome()
        #expect(store.outcome == nil)
    }
}
