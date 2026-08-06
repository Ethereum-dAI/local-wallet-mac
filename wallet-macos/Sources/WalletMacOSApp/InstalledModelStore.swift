import Foundation

struct InstalledModel: Codable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let repoID: String
    let fileName: String
    var path: String
    let sizeBytes: UInt64
    let sha256: String?
    var profile: ModelMemoryProfile?
}

/// Replaces the two legacy single-slot defaults keys
/// (`…installed-model-id` / `…installed-model-path`) with a list, so more than one
/// model can be on disk at a time.
final class InstalledModelStore {
    private enum Keys {
        static let installed = "com.localwallet.models.installed"
        static let corruptBackup = "com.localwallet.models.installed.corrupt-backup"
        static let migrated = "com.localwallet.models.legacy-migrated"
        static let legacyID = "com.localwallet.demo.onboarding.installed-model-id"
        static let legacyPath = "com.localwallet.demo.onboarding.installed-model-path"
    }

    private let defaults: UserDefaults
    private(set) var installed: [InstalledModel] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        migrateLegacySlotIfNeeded()
    }

    func model(id: String) -> InstalledModel? {
        installed.first { $0.id == id }
    }

    func add(_ model: InstalledModel) {
        installed.removeAll { $0.id == model.id }
        installed.append(model)
        save()
    }

    func remove(id: String) {
        installed.removeAll { $0.id == id }
        save()
    }

    /// Decodes leniently so one bad entry (a truncated write, a field added by a
    /// future schema change) cannot take the rest of the list down with it, and
    /// so an undecodable blob is never silently replaced by an empty list.
    private func load() {
        guard let data = defaults.data(forKey: Keys.installed) else { return }

        if let decoded = try? JSONDecoder().decode([InstalledModel].self, from: data) {
            installed = decoded
            return
        }

        guard let rawArray = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            // Not JSON at all, or not a top-level array — there is nothing to
            // salvage entry-by-entry. Back up the original bytes before any
            // `save()` call can overwrite this key, so the data is recoverable
            // by hand instead of silently gone.
            defaults.set(data, forKey: Keys.corruptBackup)
            return
        }

        let decoder = JSONDecoder()
        installed = rawArray.compactMap { element -> InstalledModel? in
            guard let elementData = try? JSONSerialization.data(withJSONObject: element) else { return nil }
            return try? decoder.decode(InstalledModel.self, from: elementData)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(installed) else { return }
        defaults.set(data, forKey: Keys.installed)
    }

    /// One-shot adoption of a pre-existing install. Guarded by its own flag so a
    /// user who deliberately removes the migrated model does not get it back.
    private func migrateLegacySlotIfNeeded() {
        guard !defaults.bool(forKey: Keys.migrated) else { return }
        defaults.set(true, forKey: Keys.migrated)

        guard let legacyID = defaults.string(forKey: Keys.legacyID),
              let legacyPath = defaults.string(forKey: Keys.legacyPath),
              !legacyPath.isEmpty,
              installed.contains(where: { $0.id == legacyID }) == false,
              let curated = LocalAIModel.available.first(where: { $0.id == legacyID })
        else { return }

        add(InstalledModel(
            id: curated.id,
            displayName: curated.name,
            repoID: curated.artifactRepo,
            fileName: curated.artifactFileName,
            path: legacyPath,
            sizeBytes: curated.memoryProfile.weightBytes,
            sha256: curated.sha256,
            profile: curated.memoryProfile
        ))
    }
}
