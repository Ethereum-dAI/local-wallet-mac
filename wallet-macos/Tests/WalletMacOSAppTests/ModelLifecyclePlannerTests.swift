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
}
