import Foundation

enum ModelSource: String, Equatable {
    case curated
    case huggingFace
}

struct ModelCatalogEntry: Identifiable, Equatable {
    let id: String
    let displayName: String
    let detail: String
    let sizeText: String
    let source: ModelSource
    let repoID: String
    let fileName: String
    let downloadURL: URL?
    let sha256: String?
    let profile: ModelMemoryProfile?
    let installedPath: String?
    let isDefault: Bool

    var isInstalled: Bool {
        guard let installedPath, !installedPath.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: installedPath)
    }
}

/// Curated models first (default first of all), then anything the user added.
struct ModelCatalog {
    let entries: [ModelCatalogEntry]

    init(installedStore: InstalledModelStore, downloadManager: LocalAIModelDownloadManager = LocalAIModelDownloadManager()) {
        let curated = LocalAIModel.curated.map { model -> ModelCatalogEntry in
            let installed = installedStore.model(id: model.id)?.path
                ?? downloadManager.bundledFileURL(for: model)?.path
                ?? (try? downloadManager.localFileURL(for: model))?.path
            return ModelCatalogEntry(
                id: model.id,
                displayName: model.name,
                detail: model.detail,
                sizeText: model.size,
                source: .curated,
                repoID: model.artifactRepo,
                fileName: model.artifactFileName,
                downloadURL: model.artifactURL,
                sha256: model.sha256,
                profile: model.memoryProfile,
                installedPath: installed,
                isDefault: model.id == LocalAIModel.recommended.id
            )
        }

        let curatedIDs = Set(curated.map(\.id))
        let custom = installedStore.installed
            .filter { !curatedIDs.contains($0.id) }
            .map { model in
                ModelCatalogEntry(
                    id: model.id,
                    displayName: model.displayName,
                    detail: model.repoID,
                    sizeText: ByteCountFormatter.string(fromByteCount: Int64(model.sizeBytes), countStyle: .file),
                    source: .huggingFace,
                    repoID: model.repoID,
                    fileName: model.fileName,
                    downloadURL: nil,
                    sha256: model.sha256,
                    profile: model.profile,
                    installedPath: model.path,
                    isDefault: false
                )
            }

        entries = curated + custom
    }
}

/// What `ChatDashboardModel` needs in order to point the runtime at a new model.
struct ActiveModelSelection: Equatable {
    let url: URL
    let contextTokens: Int
    let displayName: String
}

/// The one place that decides what a verdict means for the UI. Advisory by design:
/// nothing here can prevent a download or a selection, it only decides whether the
/// user is asked to confirm first.
enum ModelSelectionPolicy {
    static func verdict(
        entry: ModelCatalogEntry,
        contextTokens: Int,
        budget: HardwareBudget
    ) -> ModelFitVerdict {
        ModelFitEvaluator.verdict(profile: entry.profile, contextTokens: contextTokens, budget: budget)
    }

    static func allowsSelection(verdict: ModelFitVerdict) -> Bool { true }

    static func needsConfirmation(verdict: ModelFitVerdict) -> Bool {
        switch verdict {
        case .fits, .tight: return false
        case .wontFit, .unknown: return true
        }
    }
}

/// One row in Settings › Models. A flattened, already-formatted view of a catalog
/// entry so the SwiftUI body stays declarative.
struct SettingsModelRow: Identifiable, Equatable {
    let id: String
    let displayName: String
    let detail: String
    let source: ModelSource
    let verdict: ModelFitVerdict
    let estimatedBytes: UInt64
    let isInstalled: Bool
    let isActive: Bool
    let isDefault: Bool

    /// The running model is not removable — switch away from it first. The shipped
    /// default used to be exempt too, which stranded it: a user who downloaded the
    /// 5.34 GB default to compare it against the base, preferred the base and
    /// switched back had no Remove button for it and no way to reclaim the space
    /// short of Finder. Being the default is not a reason to keep a file the user
    /// does not want; it stays re-downloadable from its own row either way.
    var isRemovable: Bool { isInstalled && !isActive }

    /// Only curated rows offer a download button: the app knows their URL and
    /// checksum. A Hugging Face row exists precisely because its file was already
    /// downloaded, so there is nothing to fetch.
    var isDownloadable: Bool { source == .curated && !isInstalled }

    /// The one control the row offers, alongside its badges.
    enum PrimaryControl: Equatable {
        case download
        case use
        /// No control: the row is already the running model.
        case inUse
        /// No control available — a Hugging Face row whose file has gone missing
        /// has no URL the app can re-fetch from.
        case none
    }

    /// Download outranks "In use", and that order is the whole point.
    ///
    /// `selectedModelID` defaults to the recommended model, so the default row is
    /// active from first launch — before it is downloaded, and again if its file
    /// is deleted from disk. Ranking `isActive` first left that row showing an
    /// "In use" badge, no Download button, and no Remove either (an active row is
    /// not removable), while every message failed with `modelNotInstalled`. There
    /// was no route back inside the app.
    var primaryControl: PrimaryControl {
        if isDownloadable { return .download }
        if isActive { return .inUse }
        if isInstalled { return .use }
        return .none
    }

    var estimatedText: String {
        ByteCountFormatter.string(fromByteCount: Int64(estimatedBytes), countStyle: .file)
    }
}

struct SettingsHardwareSummary: Equatable {
    let memoryText: String
    let budgetText: String
    let diskText: String

    init(budget: HardwareBudget) {
        // `.memory`, not `.file`: these are RAM figures (binary GiB, as System
        // Information reports them), not decimal file sizes — `.file`'s 1000-based
        // divisor would show a 36 GiB Mac as "38.65 GB".
        func format(_ bytes: UInt64) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
        }
        memoryText = format(budget.totalMemoryBytes)
        budgetText = format(budget.usableBytes)
        diskText = format(budget.freeDiskBytes)
    }
}

/// Resolves a persisted `selectedModelID` to the name the chat should call it.
///
/// Curated first, then the user's own installs, then the default. The fallback
/// matters: an id can outlive its model — removed on a previous launch, or a
/// custom model whose file was deleted from Finder — and the chat must still have
/// something to call itself rather than going blank.
enum ActiveModelNaming {
    static func displayName(
        forModelID id: String,
        curated: [LocalAIModel] = LocalAIModel.curated,
        installed: [InstalledModel]
    ) -> String {
        if let model = curated.first(where: { $0.id == id }) { return model.name }
        if let model = installed.first(where: { $0.id == id }) { return model.displayName }
        return LocalAIModel.recommended.name
    }
}
