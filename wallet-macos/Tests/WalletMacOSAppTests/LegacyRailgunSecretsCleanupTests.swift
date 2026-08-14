import Foundation
import Security
import Testing
@testable import WalletMacOSApp

// The purge is the only thing left that knows where the removed RAILGUN feature put the
// spending entropy, and it reports success both when it deleted the item and when there
// was nothing there (`errSecItemNotFound`). That makes a wrong coordinate or a broken
// delete path silent, so the delete paths are exercised for real here — against a scratch
// service/account and a scratch directory, never the production ones.
//
// Non-prompting only: the items added here carry no biometric ACL, and SecItemAdd/Delete
// do not evaluate one anyway, so this runs unattended.
@Suite struct LegacyRailgunSecretsCleanupTests {
    private static let testService = "com.localwallet.railgun-seed.test"
    private static let testAccount = "railgun-seed:test"

    @Test func purgeDeletesTheKeychainItemAtItsCoordinates() throws {
        try Self.addScratchKeychainItem()
        #expect(Self.scratchKeychainItemExists())

        try LegacyRailgunSecretsCleanup.purge(
            service: Self.testService,
            account: Self.testAccount,
            applicationSupport: Self.makeScratchDirectory()
        )

        #expect(!Self.scratchKeychainItemExists())
    }

    @Test func purgeIsIdempotentWhenNothingIsStored() throws {
        let support = Self.makeScratchDirectory()
        // Both calls must succeed: `errSecItemNotFound` is the expected result on a
        // machine that never ran a build with the feature.
        try LegacyRailgunSecretsCleanup.purge(
            service: Self.testService, account: Self.testAccount, applicationSupport: support
        )
        try LegacyRailgunSecretsCleanup.purge(
            service: Self.testService, account: Self.testAccount, applicationSupport: support
        )
    }

    @Test func purgeDeletesTheLegacyPlaintextFileAndTheSidecarStateDirectory() throws {
        let support = Self.makeScratchDirectory()
        let plaintext = LegacyRailgunSecretsCleanup.legacyPlaintextPathComponents
            .reduce(support) { $0.appendingPathComponent($1) }
        let sidecar = LegacyRailgunSecretsCleanup.legacySidecarDirectoryComponents
            .reduce(support) { $0.appendingPathComponent($1, isDirectory: true) }

        try FileManager.default.createDirectory(
            at: plaintext.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: plaintext)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: sidecar.appendingPathComponent("state.json"))

        try LegacyRailgunSecretsCleanup.purge(
            service: Self.testService, account: Self.testAccount, applicationSupport: support
        )

        #expect(!FileManager.default.fileExists(atPath: plaintext.path))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test func purgeOnceAtLaunchSetsTheFlagAndDoesNotRunTwice() throws {
        let defaults = try Self.makeScratchDefaults()
        var runs = 0

        LegacyRailgunSecretsCleanup.purgeOnceAtLaunch(defaults: defaults) { runs += 1 }
        LegacyRailgunSecretsCleanup.purgeOnceAtLaunch(defaults: defaults) { runs += 1 }

        #expect(runs == 1)
        #expect(defaults.bool(forKey: LegacyRailgunSecretsCleanup.purgedDefaultsKey))
    }

    // The invariant that makes a failure recoverable: a purge that threw must leave the
    // flag clear so the next launch retries, rather than marking the entropy as gone.
    @Test func purgeOnceAtLaunchDoesNotSetTheFlagWhenThePurgeFails() throws {
        struct Boom: Error {}
        let defaults = try Self.makeScratchDefaults()

        LegacyRailgunSecretsCleanup.purgeOnceAtLaunch(defaults: defaults) { throw Boom() }
        #expect(!defaults.bool(forKey: LegacyRailgunSecretsCleanup.purgedDefaultsKey))

        var retried = false
        LegacyRailgunSecretsCleanup.purgeOnceAtLaunch(defaults: defaults) { retried = true }
        #expect(retried)
    }

    // MARK: helpers

    private static func makeScratchDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lw-legacy-railgun-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func makeScratchDefaults() throws -> UserDefaults {
        let name = "lw-legacy-railgun-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService,
            kSecAttrAccount as String: testAccount,
        ]
    }

    private static func addScratchKeychainItem() throws {
        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = Data("0x00".utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        try #require(status == errSecSuccess, "SecItemAdd failed with \(status)")
    }

    private static func scratchKeychainItemExists() -> Bool {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
