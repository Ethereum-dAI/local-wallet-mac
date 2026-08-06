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
        let curated = LocalAIModel.available.map { model -> ModelCatalogEntry in
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
