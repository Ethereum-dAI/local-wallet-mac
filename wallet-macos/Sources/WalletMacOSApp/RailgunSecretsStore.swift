import Foundation
import LocalAuthentication
import Security

/// The single secret the railgun-helper needs, delivered over fd-5: the 32-byte entropy that
/// seeds the RAILGUN account. The broadcaster EOA is derived from it in the helper, so it is
/// no longer stored or transmitted separately.
struct RailgunSecrets: Equatable {
    let entropyHex: String
}

/// Stores the RAILGUN entropy in the Keychain, biometric-gated (`.biometryCurrentSet`,
/// device-only), generating it once on first use. Replaces the prior plaintext-JSON store;
/// a legacy `railgun-secrets.json` is deleted on first use.
enum RailgunSecretsStore {
    private static let service = "com.localwallet.railgun-seed.app"
    private static let account = "railgun-seed:v1"

    enum StoreError: LocalizedError {
        case entropy(String)
        case keychain(OSStatus)
        var errorDescription: String? {
            switch self {
            case .entropy(let m): return "railgun secrets: \(m)"
            case .keychain(let s): return "railgun secrets: keychain error \(s)"
            }
        }
    }

    static func loadOrCreate(directory: URL? = nil) throws -> RailgunSecrets {
        deleteLegacyFile(directory: directory)
        if let hex = try readEntropyHex() {
            return RailgunSecrets(entropyHex: hex)
        }
        let hex = try makeEntropyHex()
        try addEntropyHex(hex)
        return RailgunSecrets(entropyHex: hex)
    }

    static func clear(directory: URL? = nil) throws {
        deleteLegacyFile(directory: directory)
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    // MARK: internals

    static func makeEntropyHex() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw StoreError.entropy("SecRandomCopyBytes failed")
        }
        return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func addEntropyHex(_ hex: String) throws {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.biometryCurrentSet],
            &accessError
        ) else {
            throw accessError!.takeRetainedValue() as Error
        }
        var query = baseQuery()
        query[kSecValueData as String] = Data(hex.utf8)
        query[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    private static func readEntropyHex() throws -> String? {
        // Attribute-only presence check first (never prompts).
        var presence = baseQuery()
        presence[kSecMatchLimit as String] = kSecMatchLimitOne
        let hasItem = SecItemCopyMatching(presence as CFDictionary, nil)
        if hasItem == errSecItemNotFound { return nil }
        guard hasItem == errSecSuccess else { throw StoreError.keychain(hasItem) }

        // Biometric-gated read, with the shared reuse-window so one unlock covers a burst.
        let context = LAContext()
        context.localizedReason = "Unlock your RAILGUN privacy account"
        context.touchIDAuthenticationAllowableReuseDuration =
            BundlerSecretPromptReusePolicy.authenticationReuseDuration

        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let hex = String(data: data, encoding: .utf8) else {
            throw StoreError.keychain(status)
        }
        return hex
    }

    static func deleteLegacyFile(directory: URL? = nil) {
        let base: URL
        if let directory {
            base = directory
        } else {
            guard let support = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false
            ) else { return }
            base = support.appendingPathComponent("LocalWallet", isDirectory: true)
        }
        let legacy = base.appendingPathComponent("railgun-secrets.json", isDirectory: false)
        try? FileManager.default.removeItem(at: legacy)
    }
}
