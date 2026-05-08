import Foundation
import LocalAuthentication
import Security
import WalletSignature

struct BundlerSecretRecord {
    let keyRef: String
    let secret: Data
}

struct BundlerKeyStore {
    static let shared = BundlerKeyStore()

    private let service = "com.localwallet.bundler-eoa.app"

    func hasKey(forKeyRef keyRef: String) throws -> Bool {
        var query = baseQuery(keyRef: keyRef)
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound {
            return false
        }
        guard status == errSecSuccess else {
            throw mapSecurityStatus(status)
        }
        return true
    }

    func createIfNeeded(keyRef: String) throws -> BundlerSecretRecord {
        if try hasKey(forKeyRef: keyRef) {
            return try read(keyRef: keyRef, reason: "Unlock the local relayer key")
        }

        let generated = try WalletSignature.generateBundlerSecret()
        try add(keyRef: keyRef, secret: generated.secret)
        return try read(keyRef: keyRef, reason: "Unlock the local relayer key")
    }

    func add(keyRef: String, secret: Data) throws {
        guard secret.count == 32 else {
            throw AppError.invalidHexString
        }

        try delete(keyRef: keyRef)

        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.biometryCurrentSet],
            &accessError
        ) else {
            throw accessError!.takeRetainedValue() as Error
        }

        var query = baseQuery(keyRef: keyRef)
        query[kSecValueData as String] = secret
        query[kSecAttrAccessControl as String] = accessControl

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw mapSecurityStatus(status)
        }
    }

    func read(keyRef: String, reason: String) throws -> BundlerSecretRecord {
        let context = LAContext()
        context.localizedReason = reason

        var query = baseQuery(keyRef: keyRef)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let secret = result as? Data else {
            throw mapSecurityStatus(status)
        }
        guard secret.count == 32 else {
            throw AppError.invalidHexString
        }
        return BundlerSecretRecord(keyRef: keyRef, secret: secret)
    }

    func delete(keyRef: String) throws {
        let status = SecItemDelete(baseQuery(keyRef: keyRef) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw mapSecurityStatus(status)
        }
    }

    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw mapSecurityStatus(status)
        }
    }

    private func baseQuery(keyRef: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyRef,
        ]
    }

    private func mapSecurityStatus(_ status: OSStatus) -> Error {
        if status == errSecMissingEntitlement {
            return AppError.missingEntitlement
        }
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}

extension Data {
    var lowercaseHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
