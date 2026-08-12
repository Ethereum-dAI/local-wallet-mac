import Foundation
import LocalAuthentication
import Security
import WalletSignature

struct BundlerSecretRecord: Sendable {
    let keyRef: String
    let secret: Data
}

struct BundlerKeyStore {
    static let shared = BundlerKeyStore()

    // `.userPresence` (biometry *or* the login password), not `.biometryCurrentSet`.
    // `.biometryCurrentSet` binds the item to the exact biometric set enrolled when it was
    // written and offers no fallback, so re-enrolling a fingerprint, running without Touch ID,
    // or one failed prompt made the relayer key permanently unreadable — onboarding
    // dead-ended on errSecAuthFailed. This also matches the policy on the Secure Enclave
    // wallet key (KeyStore.KeyAccessPolicy.standardWallet); the relayer key should not be
    // protected more strictly than the key that actually controls the funds.
    static let secretAccessFlags: SecAccessControlCreateFlags = [.userPresence]

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

    func createIfNeeded(
        keyRef: String,
        reason: String = "Unlock the local relayer key",
        authenticationContext: LAContext? = nil
    ) throws -> BundlerSecretRecord {
        try withAuthenticationContext(authenticationContext, reason: reason) { context in
            try load(
                keyRef: keyRef,
                createIfMissing: true,
                reason: reason,
                authenticationContext: context
            )
        }
    }

    // Attribute-only query: enumerating accounts does not evaluate the items'
    // biometric access control, so this never prompts.
    func listKeyRefs() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw mapSecurityStatus(status)
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func load(
        keyRef: String,
        createIfMissing: Bool,
        reason: String,
        authenticationContext: LAContext
    ) throws -> BundlerSecretRecord {
        if try hasKey(forKeyRef: keyRef) {
            return try read(
                keyRef: keyRef,
                reason: reason,
                authenticationContext: authenticationContext
            )
        }

        guard createIfMissing else {
            throw AppError.localRelayerKeyMissing
        }
        let generated = try WalletSignature.generateBundlerSecret()
        try add(keyRef: keyRef, secret: generated.secret)
        return try read(
            keyRef: keyRef,
            reason: reason,
            authenticationContext: authenticationContext
        )
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
            Self.secretAccessFlags,
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

    func read(
        keyRef: String,
        reason: String,
        authenticationContext: LAContext? = nil
    ) throws -> BundlerSecretRecord {
        try withAuthenticationContext(authenticationContext, reason: reason) { context in
            try read(
                keyRef: keyRef,
                authenticationContext: context
            )
        }
    }

    func delete(keyRef: String) throws {
        BiometricAuthenticationContexts.shared.invalidate(.relayerLaunch)
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

    private func read(
        keyRef: String,
        authenticationContext: LAContext
    ) throws -> BundlerSecretRecord {
        var query = baseQuery(keyRef: keyRef)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = authenticationContext

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

    private func withAuthenticationContext<Result>(
        _ authenticationContext: LAContext?,
        reason: String,
        operation: (LAContext) throws -> Result
    ) rethrows -> Result {
        let ownsContext = authenticationContext == nil
        let context = authenticationContext ?? LAContext()
        if ownsContext {
            context.localizedReason = reason
        }
        defer {
            if ownsContext {
                context.invalidate()
            }
        }
        return try operation(context)
    }

    private func baseQuery(keyRef: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyRef,
        ]
    }

    private func mapSecurityStatus(_ status: OSStatus) -> Error {
        Self.describeSecurityStatus(status)
    }

    // Security.framework failures used to pass straight through as NSError, so the UI showed
    // a bare "OSStatus error -25293" with no hint about which operation failed or how to
    // recover. Name the operation and the way out for the statuses a user can actually hit;
    // anything unrecognized keeps its OSStatus so it stays diagnosable.
    static func describeSecurityStatus(_ status: OSStatus) -> Error {
        switch status {
        case errSecMissingEntitlement:
            return AppError.missingEntitlement
        case errSecUserCanceled:
            return AppError.userAuthorizationCancelled
        case errSecAuthFailed:
            return AppError.localRelayerKeyAuthorizationFailed
        default:
            return NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

enum BundlerLaunchKeyPolicy {
    static func chainId(ofKeyRef keyRef: String) -> UInt64? {
        components(ofKeyRef: keyRef)?.chainId
    }

    // keyRef format: bundler-eoa:<ownerScope>:<chainId>:<index>
    private static func components(ofKeyRef keyRef: String) -> (chainId: UInt64, index: UInt64)? {
        let parts = keyRef.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == "bundler-eoa",
              !parts[1].isEmpty,
              let chainId = UInt64(parts[2]),
              let index = UInt64(parts[3]) else {
            return nil
        }
        return (chainId, index)
    }
}

extension Data {
    var lowercaseHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
