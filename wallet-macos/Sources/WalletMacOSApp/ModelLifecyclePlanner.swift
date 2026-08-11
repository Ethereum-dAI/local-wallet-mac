import Foundation

/// The pure decision behind `AppModel.selectModel`: whether the requested catalog
/// entry can be activated on this Mac right now, and if so, exactly what to
/// activate it with. Kept free of `FileManager`/`UserDefaults` — same shape as
/// `ModelSwapPlanner` — so the "does this catalog entry resolve to something
/// loadable" and "what context window does it clamp to" decisions are
/// unit-testable without a real file on disk. `AppModel` answers the one impure
/// question ("does the file actually exist") and hands the boolean in; this type
/// makes the actual decision, so a regression here (e.g. the wrong URL, or a
/// clamp against the wrong max) is a regression in the app, not just in a
/// restated copy of it.
enum ModelActivationPlanner {
    enum Decision: Equatable {
        case notInstalled
        case activate(ActiveModelSelection)
    }

    static func decide(
        entry: ModelCatalogEntry?,
        fileExists: Bool,
        currentContextTokens: Int
    ) -> Decision {
        guard let entry, let path = entry.installedPath, fileExists else {
            return .notInstalled
        }
        let tokens = ContextWindowPresets.clamp(
            currentContextTokens,
            maxTokens: entry.profile?.trainedContextTokens ?? LocalAIModel.recommended.maxContextTokens
        )
        return .activate(ActiveModelSelection(
            url: URL(fileURLWithPath: path),
            contextTokens: tokens,
            displayName: entry.displayName
        ))
    }
}

/// The pure decisions behind `AppModel.removeModel`. Two independent questions,
/// both free of `FileManager`:
///
/// 1. `isBlockedBecauseActive` — is removal refused because this is the
///    currently-selected model? Checked first in `AppModel`, before any
///    filesystem call, because refusing early is cheaper than attempting (and
///    possibly failing) a delete.
/// 2. `mayForgetEntry` — after an attempted file deletion, may the store entry be
///    forgotten? A file that was already missing before the attempt (deleted by
///    hand in Finder, say) is treated as success, so a user in that state can
///    still clear the stale entry. A real deletion failure must keep the entry:
///    the model stays visible and removable later, rather than the app silently
///    losing track of a multi-gigabyte file still sitting on disk.
/// What a Remove press should actually act on.
///
/// The third case is the bug this type exists to close. `ModelCatalog` reports a
/// curated model as installed whenever its file is on disk — including via the
/// `bundledFileURL` / `localFileURL` fallbacks, which need no `InstalledModelStore`
/// record. Removal, meanwhile, started with `guard let installed =
/// installedModelStore.model(id:) else { return }`: a silent early return that let
/// the caller report "removed" while the file sat untouched on disk. That state is
/// not exotic — it is what an onboarding install, or a legacy record cleared by
/// hand, leaves behind.
enum ModelRemovalTarget: Equatable {
    /// A tracked install: delete the file, then forget the record.
    case tracked(path: String, displayName: String)
    /// A curated model whose file is on disk with no store record. Delete the
    /// file; there is no record to forget.
    case untracked(path: String, displayName: String)
    /// Only the copy embedded in the .app exists. Deleting that would vandalise
    /// the application bundle, so it is refused rather than attempted.
    case bundledOnly(displayName: String)
    /// Nothing on disk and nothing recorded — Remove must say so, not claim
    /// success.
    case nothingToRemove
}

enum ModelRemovalPlanner {
    static func isBlockedBecauseActive(id: String, selectedModelID: String) -> Bool {
        id == selectedModelID
    }

    static func mayForgetEntry(fileExistedBeforeAttempt: Bool, deletionSucceeded: Bool) -> Bool {
        !fileExistedBeforeAttempt || deletionSucceeded
    }

    /// `downloadedCopyPath` is the curated destination path **only when a file is
    /// actually there** — the caller does that existence check, so this stays pure.
    static func target(
        record: InstalledModel?,
        curated: LocalAIModel?,
        downloadedCopyPath: String?,
        bundledCopyExists: Bool
    ) -> ModelRemovalTarget {
        if let record {
            return .tracked(path: record.path, displayName: record.displayName)
        }
        guard let curated else { return .nothingToRemove }
        if let downloadedCopyPath {
            return .untracked(path: downloadedCopyPath, displayName: curated.name)
        }
        return bundledCopyExists ? .bundledOnly(displayName: curated.name) : .nothingToRemove
    }
}
