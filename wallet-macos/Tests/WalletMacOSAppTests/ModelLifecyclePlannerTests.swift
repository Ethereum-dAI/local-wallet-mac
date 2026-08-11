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
            bundledCopyExists: false
        ) == .tracked(path: "/tmp/tracked.gguf", displayName: "Qwen3 8B"))
    }

    /// The regression this exists for: a curated model whose file `ModelCatalog`
    /// found through its `localFileURL` fallback has no store record, and removal
    /// used to `return` silently on exactly that — reporting success while leaving
    /// gigabytes on disk.
    @Test func aCuratedFileWithNoRecordIsStillRemoved() {
        #expect(ModelRemovalPlanner.target(
            record: nil,
            curated: .gemma4Base,
            downloadedCopyPath: "/tmp/gemma-4-E4B-it-Q4_0.gguf",
            bundledCopyExists: false
        ) == .untracked(path: "/tmp/gemma-4-E4B-it-Q4_0.gguf", displayName: LocalAIModel.gemma4Base.name))
    }

    /// Deleting the copy inside `Contents/Resources/Models` would damage the running
    /// application, so a bundled-only model is refused — with a reason, not silently.
    @Test func aBundledOnlyModelIsRefusedRatherThanDeleted() {
        #expect(ModelRemovalPlanner.target(
            record: nil,
            curated: .recommended,
            downloadedCopyPath: nil,
            bundledCopyExists: true
        ) == .bundledOnly(displayName: LocalAIModel.recommended.name))
    }

    @Test func nothingOnDiskAndNothingRecordedRemovesNothing() {
        #expect(ModelRemovalPlanner.target(
            record: nil,
            curated: .recommended,
            downloadedCopyPath: nil,
            bundledCopyExists: false
        ) == .nothingToRemove)
        // An id that is neither curated nor installed — a row that outlived its model.
        #expect(ModelRemovalPlanner.target(
            record: nil,
            curated: nil,
            downloadedCopyPath: nil,
            bundledCopyExists: false
        ) == .nothingToRemove)
    }
}

/// The install in flight belongs to the chat model, not to the Settings view: the
/// download outlives any single appearance of that view, so its progress has to as
/// well. These pin the shape that makes re-attachment possible — a row can ask
/// "is this install mine?" without holding any state of its own.
struct ModelInstallProgressTests {
    @Test func progressIsAddressedByModelIDSoARowCanClaimIt() {
        var install = ModelInstallProgress(
            modelID: "ef-dai-team/gemma-4-E4B-wallet-ft",
            displayName: "Gemma 4 E4B (wallet-tuned)",
            phase: .downloading(0)
        )
        #expect(install.modelID == LocalAIModel.recommended.id)
        install.phase = .downloading(0.5)
        #expect(install.phase == .downloading(0.5))
        install.phase = .testing
        #expect(install.phase == .testing)
    }

    @Test func anOutcomeCarriesWhetherItFailed() {
        #expect(ModelInstallOutcome(isFailure: false, text: "ok").isFailure == false)
        #expect(ModelInstallOutcome(isFailure: true, text: "boom") != ModelInstallOutcome(isFailure: false, text: "boom"))
    }
}
