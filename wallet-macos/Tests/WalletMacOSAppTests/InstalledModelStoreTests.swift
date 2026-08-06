import Foundation
import Testing
@testable import WalletMacOSApp

struct InstalledModelStoreTests {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "installed-models-\(UUID().uuidString)")!
    }

    private func sample(id: String) -> InstalledModel {
        InstalledModel(
            id: id,
            displayName: "Sample \(id)",
            repoID: "owner/\(id)",
            fileName: "\(id).gguf",
            path: "/tmp/\(id).gguf",
            sizeBytes: 1234,
            sha256: "abc",
            profile: nil
        )
    }

    @Test func startsEmpty() {
        #expect(InstalledModelStore(defaults: suite()).installed.isEmpty)
    }

    @Test func addRoundTripsThroughDefaults() {
        let defaults = suite()
        InstalledModelStore(defaults: defaults).add(sample(id: "one"))
        let reloaded = InstalledModelStore(defaults: defaults)
        #expect(reloaded.installed.count == 1)
        #expect(reloaded.model(id: "one")?.fileName == "one.gguf")
    }

    @Test func addingTheSameIDReplacesRatherThanDuplicates() {
        let store = InstalledModelStore(defaults: suite())
        store.add(sample(id: "one"))
        var updated = sample(id: "one")
        updated.path = "/tmp/moved.gguf"
        store.add(updated)
        #expect(store.installed.count == 1)
        #expect(store.model(id: "one")?.path == "/tmp/moved.gguf")
    }

    @Test func removeDropsTheEntry() {
        let store = InstalledModelStore(defaults: suite())
        store.add(sample(id: "one"))
        store.remove(id: "one")
        #expect(store.installed.isEmpty)
    }

    /// Existing installs recorded only the two legacy single-slot keys. They must
    /// survive the upgrade without a re-download.
    @Test func migratesTheLegacySingleSlotInstall() {
        let defaults = suite()
        defaults.set(LocalAIModel.recommended.id, forKey: "com.localwallet.demo.onboarding.installed-model-id")
        defaults.set("/tmp/gemma-4-E4B-it-Q4_0.gguf", forKey: "com.localwallet.demo.onboarding.installed-model-path")

        let store = InstalledModelStore(defaults: defaults)
        #expect(store.installed.count == 1)
        let migrated = try? #require(store.model(id: LocalAIModel.recommended.id))
        #expect(migrated?.path == "/tmp/gemma-4-E4B-it-Q4_0.gguf")
        #expect(migrated?.displayName == LocalAIModel.recommended.name)
    }

    @Test func migrationRunsOnlyOnce() {
        let defaults = suite()
        defaults.set(LocalAIModel.recommended.id, forKey: "com.localwallet.demo.onboarding.installed-model-id")
        defaults.set("/tmp/gemma.gguf", forKey: "com.localwallet.demo.onboarding.installed-model-path")

        let first = InstalledModelStore(defaults: defaults)
        first.remove(id: LocalAIModel.recommended.id)
        let second = InstalledModelStore(defaults: defaults)
        #expect(second.installed.isEmpty)
    }

    /// Reserializes an already-encoded `InstalledModel` into a loose JSON object
    /// (`[String: Any]`), so tests can splice good and bad entries into the same
    /// raw array the way a corrupted defaults blob would contain them.
    private func jsonObject(for model: InstalledModel) throws -> Any {
        let data = try JSONEncoder().encode(model)
        return try JSONSerialization.jsonObject(with: data)
    }

    private let installedKey = "com.localwallet.models.installed"
    private let corruptBackupKey = "com.localwallet.models.installed.corrupt-backup"

    /// A blob that isn't JSON at all — a truncated write, disk corruption, anything.
    /// The whole list must not vanish into thin air: the raw bytes are recoverable
    /// under a backup key, and a later `add` must not clobber that backup.
    @Test func totallyUndecodableBlobIsBackedUpNotDestroyed() {
        let defaults = suite()
        let garbage = Data("not json at all {{{".utf8)
        defaults.set(garbage, forKey: installedKey)

        let store = InstalledModelStore(defaults: defaults)
        #expect(store.installed.isEmpty)
        #expect(defaults.data(forKey: corruptBackupKey) == garbage)

        store.add(sample(id: "new"))
        #expect(store.installed.count == 1)
        #expect(defaults.data(forKey: corruptBackupKey) == garbage)
    }

    /// One malformed entry in an otherwise-valid array (a field missing, e.g. from a
    /// future schema change) must not take the rest of the list down with it.
    @Test func aBadEntryInTheMiddleIsSkippedNotFatal() throws {
        let defaults = suite()
        let good1 = try jsonObject(for: sample(id: "one"))
        let good3 = try jsonObject(for: sample(id: "three"))
        let bad: [String: Any] = ["id": "two"] // missing every other required field
        let arrayData = try JSONSerialization.data(withJSONObject: [good1, bad, good3])
        defaults.set(arrayData, forKey: installedKey)

        let store = InstalledModelStore(defaults: defaults)
        #expect(store.installed.count == 2)
        #expect(store.model(id: "one") != nil)
        #expect(store.model(id: "three") != nil)
        #expect(store.model(id: "two") == nil)
    }

    /// After a partial-decode load, mutating and reloading must keep exactly the
    /// survivors plus whatever was added — the skipped entry stays gone, but nothing
    /// else is lost in the round trip.
    @Test func roundTripAfterPartialDecodeKeepsSurvivorsPlusNew() throws {
        let defaults = suite()
        let good1 = try jsonObject(for: sample(id: "one"))
        let bad: [String: Any] = ["id": "two"]
        let arrayData = try JSONSerialization.data(withJSONObject: [good1, bad])
        defaults.set(arrayData, forKey: installedKey)

        let store = InstalledModelStore(defaults: defaults)
        store.add(sample(id: "new"))

        let reloaded = InstalledModelStore(defaults: defaults)
        #expect(reloaded.installed.count == 2)
        #expect(reloaded.model(id: "one") != nil)
        #expect(reloaded.model(id: "new") != nil)
        #expect(reloaded.model(id: "two") == nil)
    }

    /// A bare scalar in the array (not an object) is a plausible corruption shape —
    /// a truncated write, or any future producer putting a raw value in a slot.
    /// `JSONSerialization.data(withJSONObject:)` requires a top-level array/dictionary,
    /// so handing it a scalar element raises an uncatchable ObjC exception. This must
    /// not reach that call at all: the two valid entries load, no crash.
    @Test func aBareStringBetweenValidEntriesIsSkippedNotFatal() throws {
        let defaults = suite()
        let good1 = try jsonObject(for: sample(id: "one"))
        let good3 = try jsonObject(for: sample(id: "three"))
        let arrayData = try JSONSerialization.data(withJSONObject: [good1, "garbage", good3])
        defaults.set(arrayData, forKey: installedKey)

        let store = InstalledModelStore(defaults: defaults)
        #expect(store.installed.count == 2)
        #expect(store.model(id: "one") != nil)
        #expect(store.model(id: "three") != nil)
    }

    /// Same hazard, different scalar shapes: `null` and a bare number.
    @Test func nullAndNumberEntriesAreSkippedNotFatal() throws {
        let defaults = suite()
        let good1 = try jsonObject(for: sample(id: "one"))
        let good3 = try jsonObject(for: sample(id: "three"))
        let arrayData = try JSONSerialization.data(withJSONObject: [good1, NSNull(), 42, good3])
        defaults.set(arrayData, forKey: installedKey)

        let store = InstalledModelStore(defaults: defaults)
        #expect(store.installed.count == 2)
        #expect(store.model(id: "one") != nil)
        #expect(store.model(id: "three") != nil)
    }
}
