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
enum ModelRemovalPlanner {
    static func isBlockedBecauseActive(id: String, selectedModelID: String) -> Bool {
        id == selectedModelID
    }

    static func mayForgetEntry(fileExistedBeforeAttempt: Bool, deletionSucceeded: Bool) -> Bool {
        !fileExistedBeforeAttempt || deletionSucceeded
    }
}
