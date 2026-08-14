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
enum LegacyRailgunSecretsCleanup {
    /// The exact Keychain coordinates the removed `RailgunSecretsStore` wrote:
    /// a generic password under this service/account pair. Nothing else keyed the
    /// item, so class + service + account is the whole identity — and matching on
    /// exactly those three is what keeps the purge from touching any other item
    /// the app owns.
    private static let service = "com.localwallet.railgun-seed.app"
    private static let account = "railgun-seed:v1"

    /// The plaintext-JSON store that predated the Keychain one. The removed store
    /// deleted it on every load and on every clear; the purge inherits that so a
    /// two-generations-old install is cleaned up in one pass too.
    private static let legacyPlaintextFileName = "railgun-secrets.json"

    /// The sidecar's state directory (`<Application Support>/Local Wallet/railgun-helper`),
    /// which held the persisted per-exit rotation counter. Not secret, but it is
    /// state for a feature that no longer exists.
    private static let legacySidecarDirectoryComponents = ["Local Wallet", "railgun-helper"]

    private static let purgedDefaultsKey = "localwallet.legacyRailgunSecretsPurged"

    /// Deletes the leftovers. Idempotent, and a no-op on a machine that never ran a
    /// build with the feature: `errSecItemNotFound` is the expected result there, so
    /// it is treated as success rather than surfaced as an error.
    static func purge() throws {
        deleteLegacyPlaintextFile()
        deleteLegacySidecarState()

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
    static func purgeOnceAtLaunch(defaults: UserDefaults = .standard) {
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

    private static func deleteLegacyPlaintextFile() {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return }
        let legacy = support
            .appendingPathComponent("LocalWallet", isDirectory: true)
            .appendingPathComponent(legacyPlaintextFileName, isDirectory: false)
        try? FileManager.default.removeItem(at: legacy)
    }

    private static func deleteLegacySidecarState() {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return }
        let directory = legacySidecarDirectoryComponents.reduce(support) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        try? FileManager.default.removeItem(at: directory)
    }
}
