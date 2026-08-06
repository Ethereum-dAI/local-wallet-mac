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
}
