import Foundation
import Security

/// One-way cleanup for the removed RAILGUN privacy feature.
///
/// Alpha builds stored a 32-byte spending entropy in the Keychain (biometric-gated,
/// device-only) plus a small amount of sidecar state on disk. The feature and every
/// type that could read that material are gone, so on those installs the entropy
/// would otherwise sit in the Keychain forever with nothing left that knows what it
/// is or how to delete it. This enum exists only to take it out.
///
/// It is deliberately a purge and nothing else: there is no load path, no migration,
/// and no way back. Once no install can predate the removal — i.e. every user has
/// launched a build that ran `purgeOnceAtLaunch()` at least once — this whole file
/// and its call sites can be deleted.
///
/// Every coordinate is injectable purely so the tests can exercise the real delete
/// paths against a scratch service/account and a scratch directory. Production always
/// takes the defaults.
enum LegacyRailgunSecretsCleanup {
    /// The exact Keychain coordinates the removed `RailgunSecretsStore` wrote:
    /// a generic password under this service/account pair. Nothing else keyed the
    /// item, so class + service + account is the whole identity — and matching on
    /// exactly those three is what keeps the purge from touching any other item
    /// the app owns.
    static let defaultService = "com.localwallet.railgun-seed.app"
    static let defaultAccount = "railgun-seed:v1"

    /// The plaintext-JSON store that predated the Keychain one, under
    /// `<Application Support>/LocalWallet/`. The removed store deleted it on every
    /// load and on every clear; the purge inherits that so a two-generations-old
    /// install is cleaned up in one pass too.
    static let legacyPlaintextPathComponents = ["LocalWallet", "railgun-secrets.json"]

    /// The sidecar's state directory (`<Application Support>/Local Wallet/railgun-helper`),
    /// which held the persisted per-exit rotation counter. Not secret, but it is
    /// state for a feature that no longer exists.
    static let legacySidecarDirectoryComponents = ["Local Wallet", "railgun-helper"]

    static let purgedDefaultsKey = "localwallet.legacyRailgunSecretsPurged"

    /// Deletes the leftovers. Idempotent, and a no-op on a machine that never ran a
    /// build with the feature: `errSecItemNotFound` is the expected result there, so
    /// it is treated as success rather than surfaced as an error.
    static func purge(
        service: String = defaultService,
        account: String = defaultAccount,
        applicationSupport: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        if let support = applicationSupport ?? applicationSupportDirectory(fileManager: fileManager) {
            deleteLegacyPlaintextFile(in: support, fileManager: fileManager)
            deleteLegacySidecarState(in: support, fileManager: fileManager)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PurgeError.keychain(status)
        }
    }

    /// Runs `purge()` at most once per install. The Keychain call is cheap but not
    /// free, and there is nothing to find after the first success, so a `UserDefaults`
    /// flag keeps every later launch at the cost of one defaults read.
    ///
    /// A failed purge deliberately does not set the flag: the next launch retries.
    /// Failure is otherwise ignored — leftover state from a removed feature is not a
    /// reason to block startup, and the in-app reset runs the same purge again.
    static func purgeOnceAtLaunch(
        defaults: UserDefaults = .standard,
        purge: () throws -> Void = { try LegacyRailgunSecretsCleanup.purge() }
    ) {
        guard !defaults.bool(forKey: purgedDefaultsKey) else {
            return
        }
        do {
            try purge()
            defaults.set(true, forKey: purgedDefaultsKey)
        } catch {
            // Retried on the next launch.
        }
    }

    enum PurgeError: LocalizedError {
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                return "legacy railgun secrets: keychain error \(status)"
            }
        }
    }

    // MARK: internals

    private static func applicationSupportDirectory(fileManager: FileManager) -> URL? {
        try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
    }

    private static func deleteLegacyPlaintextFile(in support: URL, fileManager: FileManager) {
        let legacy = legacyPlaintextPathComponents.enumerated().reduce(support) { url, element in
            let isDirectory = element.offset < legacyPlaintextPathComponents.count - 1
            return url.appendingPathComponent(element.element, isDirectory: isDirectory)
        }
        try? fileManager.removeItem(at: legacy)
    }

    private static func deleteLegacySidecarState(in support: URL, fileManager: FileManager) {
        let directory = legacySidecarDirectoryComponents.reduce(support) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        try? fileManager.removeItem(at: directory)
    }
}
