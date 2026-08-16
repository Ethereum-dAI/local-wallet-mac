import Foundation
import LocalAuthentication
import Security
import WalletSignature

struct BundlerSecretRecord: Sendable {
    let keyRef: String
    let secret: Data
}

enum BundlerSecretInsertionResult: Equatable {
    case inserted
    case existing
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

    /// Reads only public attributes from the protected secret item. Attribute
    /// queries never request `kSecValueData`, so this path stays prompt-free and
    /// is safe for dashboard rendering and pre-auth transaction checks.
    func verifiedIdentity(forKeyRef keyRef: String) throws -> VerifiedRelayerIdentity? {
        var query = baseQuery(keyRef: keyRef)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let attributes = result as? [String: Any] else {
            throw mapSecurityStatus(status)
        }
        guard let metadata = attributes[kSecAttrGeneric as String] as? Data else {
            // Legacy protected item. The next authenticated read derives and
            // migrates this metadata rather than trusting an external cache.
            return nil
        }
        let identity = try VerifiedRelayerIdentity.decodeMetadata(metadata)
        guard identity.keyRef == keyRef else {
            throw VerifiedRelayerIdentity.ValidationError.metadataKeyRefMismatch(
                expected: keyRef,
                actual: identity.keyRef
            )
        }
        return identity
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
        _ = try addIfAbsent(keyRef: keyRef, secret: generated.secret)
        return try read(
            keyRef: keyRef,
            reason: reason,
            authenticationContext: authenticationContext
        )
    }

    func add(keyRef: String, secret: Data) throws {
        guard try addIfAbsent(keyRef: keyRef, secret: secret) == .inserted else {
            throw Self.describeSecurityStatus(errSecDuplicateItem)
        }
    }

    /// Atomically installs a relayer secret without replacing an existing item.
    ///
    /// Keychain uniqueness on `(class, service, account)` is the cross-process
    /// arbitration point. A concurrent provisioning attempt that loses the
    /// `SecItemAdd` race must discard its generated secret and authenticate to
    /// read the winning item before registering wallet-node.
    func addIfAbsent(
        keyRef: String,
        secret: Data
    ) throws -> BundlerSecretInsertionResult {
        guard secret.count == 32 else {
            throw AppError.invalidHexString
        }

        let identity = try VerifiedRelayerIdentity.derive(
            keyRef: keyRef,
            secret: secret
        )

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
        query[kSecAttrGeneric as String] = try identity.encodedMetadata()

        let status = SecItemAdd(query as CFDictionary, nil)
        return try Self.insertionResult(for: status)
    }

    static func insertionResult(for status: OSStatus) throws -> BundlerSecretInsertionResult {
        switch status {
        case errSecSuccess:
            return .inserted
        case errSecDuplicateItem:
            return .existing
        default:
            throw describeSecurityStatus(status)
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

        let derivedIdentity = try VerifiedRelayerIdentity.derive(
            keyRef: keyRef,
            secret: secret
        )
        switch try VerifiedRelayerIdentityMetadataPolicy.decision(
            stored: try verifiedIdentity(forKeyRef: keyRef),
            derived: derivedIdentity
        ) {
        case .current:
            break
        case .migrate(let identity):
            try updateVerifiedIdentity(
                identity,
                authenticationContext: authenticationContext
            )
        }
        return BundlerSecretRecord(keyRef: keyRef, secret: secret)
    }

    private func updateVerifiedIdentity(
        _ identity: VerifiedRelayerIdentity,
        authenticationContext: LAContext
    ) throws {
        var query = baseQuery(keyRef: identity.keyRef)
        query[kSecUseAuthenticationContext as String] = authenticationContext
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecAttrGeneric as String: try identity.encodedMetadata()] as CFDictionary
        )
        guard status == errSecSuccess else {
            throw mapSecurityStatus(status)
        }
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

/// App-owned public identity for a protected local relayer secret.
///
/// The private key remains behind Keychain user-presence access control. This
/// versioned metadata is stored on the same item so prompt-free UI and preflight
/// code can bind wallet-node's public status to an identity the app previously
/// derived from that secret.
struct VerifiedRelayerIdentity: Codable, Equatable, Sendable {
    static let currentVersion = 1

    enum ValidationError: Error, Equatable, LocalizedError {
        case unsupportedVersion(Int)
        case invalidChainID(UInt64)
        case invalidKeyRef(String)
        case keyRefChainMismatch(expected: UInt64, actual: UInt64)
        case invalidAddress(String)
        case metadataKeyRefMismatch(expected: String, actual: String)
        case malformedMetadata
        case storedIdentityMismatch

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "Unsupported relayer identity metadata version \(version)."
            case .invalidChainID(let chainID):
                return "Invalid relayer identity chain ID \(chainID)."
            case .invalidKeyRef:
                return "Invalid relayer identity key reference."
            case let .keyRefChainMismatch(expected, actual):
                return "Relayer identity key reference belongs to chain \(actual), expected \(expected)."
            case .invalidAddress:
                return "Invalid relayer identity address."
            case .metadataKeyRefMismatch:
                return "Relayer identity metadata does not belong to the requested key reference."
            case .malformedMetadata:
                return "Relayer identity metadata is malformed."
            case .storedIdentityMismatch:
                return "Stored relayer identity does not match the authenticated relayer secret."
            }
        }
    }

    let version: Int
    let chainID: UInt64
    let keyRef: String
    /// Canonical lowercase `0x`-prefixed 20-byte Ethereum address.
    let address: String

    init(
        version: Int = VerifiedRelayerIdentity.currentVersion,
        chainID: UInt64,
        keyRef: String,
        address: String
    ) throws {
        guard version == Self.currentVersion else {
            throw ValidationError.unsupportedVersion(version)
        }
        guard chainID > 0 else {
            throw ValidationError.invalidChainID(chainID)
        }
        guard let keyRefChainID = BundlerLaunchKeyPolicy.chainId(ofKeyRef: keyRef) else {
            throw ValidationError.invalidKeyRef(keyRef)
        }
        guard keyRefChainID == chainID else {
            throw ValidationError.keyRefChainMismatch(expected: chainID, actual: keyRefChainID)
        }

        self.version = version
        self.chainID = chainID
        self.keyRef = keyRef
        self.address = try Self.normalizedAddress(address)
    }

    static func derive(keyRef: String, secret: Data) throws -> VerifiedRelayerIdentity {
        guard secret.count == 32 else {
            throw AppError.invalidHexString
        }
        guard let chainID = BundlerLaunchKeyPolicy.chainId(ofKeyRef: keyRef) else {
            throw ValidationError.invalidKeyRef(keyRef)
        }
        let addressData = try WalletSignature.bundlerAddress(fromSecret: secret)
        return try VerifiedRelayerIdentity(
            chainID: chainID,
            keyRef: keyRef,
            address: "0x" + addressData.hexEncodedString
        )
    }

    static func normalizedAddress(_ raw: String) throws -> String {
        let bytes = Array(raw.utf8)
        guard bytes.count == 42,
              bytes[0] == Character("0").asciiValue,
              bytes[1] == Character("x").asciiValue,
              bytes.dropFirst(2).allSatisfy({ byte in
                  (byte >= 48 && byte <= 57)
                      || (byte >= 65 && byte <= 70)
                      || (byte >= 97 && byte <= 102)
              }) else {
            throw ValidationError.invalidAddress(raw)
        }
        return raw.lowercased()
    }

    func encodedMetadata() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decodeMetadata(_ data: Data) throws -> VerifiedRelayerIdentity {
        do {
            return try JSONDecoder().decode(VerifiedRelayerIdentity.self, from: data)
        } catch let error as ValidationError {
            throw error
        } catch {
            throw ValidationError.malformedMetadata
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            chainID: container.decode(UInt64.self, forKey: .chainID),
            keyRef: container.decode(String.self, forKey: .keyRef),
            address: container.decode(String.self, forKey: .address)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case chainID
        case keyRef
        case address
    }
}

/// Missing metadata is the only state migrated automatically. Once metadata
/// exists, a mismatch with the authenticated secret is a security failure and
/// must not be repaired by adopting either side.
enum VerifiedRelayerIdentityMetadataPolicy {
    enum Decision: Equatable {
        case current
        case migrate(VerifiedRelayerIdentity)
    }

    static func decision(
        stored: VerifiedRelayerIdentity?,
        derived: VerifiedRelayerIdentity
    ) throws -> Decision {
        guard let stored else {
            return .migrate(derived)
        }
        guard stored == derived else {
            throw VerifiedRelayerIdentity.ValidationError.storedIdentityMismatch
        }
        return .current
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
