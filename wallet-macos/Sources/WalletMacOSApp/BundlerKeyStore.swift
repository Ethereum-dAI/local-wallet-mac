import Foundation
import LocalAuthentication
import Security
import WalletSignature

protocol SecurityItemClient: Sendable {
    func add(_ attributes: [String: Any]) -> (status: OSStatus, result: Any?)
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: Any?)
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemSecurityItemClient: SecurityItemClient {
    func add(_ attributes: [String: Any]) -> (status: OSStatus, result: Any?) {
        var result: CFTypeRef?
        let status = SecItemAdd(attributes as CFDictionary, &result)
        return (status, result)
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: Any?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Immutable public identity records for protected local relayer secrets.
///
/// These records deliberately live outside the `.userPresence` item. A caller
/// may render and validate public relayer state without evaluating the secret's
/// access control, while a privileged secret read still re-derives and checks
/// this exact identity before use.
struct RelayerPublicIdentityStore: Sendable {
    static let shared = RelayerPublicIdentityStore()
    static let service = "com.localwallet.bundler-eoa.public-identity"

    enum StoreError: Error, Equatable, LocalizedError {
        case interactionRequired(String)
        case malformedRecord(String)
        case wrongKeyRef(expected: String, actual: String)
        case conflictingIdentity(String)
        case duplicateRecordMissing(String)
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .interactionRequired(let keyRef):
                return "Public relayer identity unexpectedly requires authentication for \(keyRef)."
            case .malformedRecord(let keyRef):
                return "Public relayer identity is malformed for \(keyRef)."
            case let .wrongKeyRef(expected, actual):
                return "Public relayer identity belongs to \(actual), expected \(expected)."
            case .conflictingIdentity(let keyRef):
                return "Public relayer identity conflicts with the authenticated secret for \(keyRef)."
            case .duplicateRecordMissing(let keyRef):
                return "Public relayer identity disappeared while reconciling \(keyRef)."
            case .keychain(let status):
                return "Public relayer identity Keychain operation failed with status \(status)."
            }
        }
    }

    private let client: any SecurityItemClient

    init(client: any SecurityItemClient = SystemSecurityItemClient()) {
        self.client = client
    }

    func identity(forKeyRef keyRef: String) throws -> VerifiedRelayerIdentity? {
        let context = LAContext()
        context.interactionNotAllowed = true
        defer { context.invalidate() }

        var query = baseQuery(keyRef: keyRef)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = context

        let response = client.copyMatching(query)
        if response.status == errSecItemNotFound {
            return nil
        }
        if response.status == errSecInteractionNotAllowed {
            throw StoreError.interactionRequired(keyRef)
        }
        guard response.status == errSecSuccess else {
            throw mapSecurityStatus(response.status)
        }
        guard let data = response.result as? Data else {
            throw StoreError.malformedRecord(keyRef)
        }

        let identity: VerifiedRelayerIdentity
        do {
            identity = try VerifiedRelayerIdentity.decodeMetadata(data)
            guard try identity.encodedMetadata() == data else {
                throw StoreError.malformedRecord(keyRef)
            }
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.malformedRecord(keyRef)
        }
        guard identity.keyRef == keyRef else {
            throw StoreError.wrongKeyRef(expected: keyRef, actual: identity.keyRef)
        }
        return identity
    }

    /// Inserts the identity once. Keychain's unique `(class, service, account)`
    /// tuple is the arbitration point; an exact concurrent winner is
    /// idempotent, while any semantic conflict is a hard failure.
    func insertOrRequireIdentity(_ identity: VerifiedRelayerIdentity) throws {
        var attributes = baseQuery(keyRef: identity.keyRef)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData as String] = try identity.encodedMetadata()

        let response = client.add(attributes)
        switch response.status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            guard let existing = try self.identity(forKeyRef: identity.keyRef) else {
                throw StoreError.duplicateRecordMissing(identity.keyRef)
            }
            guard existing == identity else {
                throw StoreError.conflictingIdentity(identity.keyRef)
            }
        default:
            throw mapSecurityStatus(response.status)
        }
    }

    func delete(keyRef: String) throws {
        let status = client.delete(baseQuery(keyRef: keyRef))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw mapSecurityStatus(status)
        }
    }

    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = client.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw mapSecurityStatus(status)
        }
    }

    private func baseQuery(keyRef: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: keyRef,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func mapSecurityStatus(_ status: OSStatus) -> Error {
        if status == errSecMissingEntitlement {
            return AppError.missingEntitlement
        }
        return StoreError.keychain(status)
    }
}

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

    private static let service = "com.localwallet.bundler-eoa.app"
    private let client: any SecurityItemClient
    private let publicIdentityStore: RelayerPublicIdentityStore

    init(
        client: any SecurityItemClient = SystemSecurityItemClient(),
        publicIdentityStore: RelayerPublicIdentityStore = .shared
    ) {
        self.client = client
        self.publicIdentityStore = publicIdentityStore
    }

    func createIfNeeded(
        keyRef: String,
        reason: String = "Unlock the local relayer key",
        authenticationContext: LAContext? = nil
    ) throws -> BundlerSecretRecord {
        try withAuthenticationContext(authenticationContext, reason: reason) { context in
            let generated = try WalletSignature.generateBundlerSecret()
            switch try addIfAbsent(keyRef: keyRef, secret: generated.secret) {
            case .inserted:
                return BundlerSecretRecord(keyRef: keyRef, secret: generated.secret)
            case .existing:
                return try read(keyRef: keyRef, authenticationContext: context)
            }
        }
    }

    /// Compatibility shim while callers move to `RelayerPublicIdentityStore`.
    /// This never queries the protected service.
    func verifiedIdentity(forKeyRef keyRef: String) throws -> VerifiedRelayerIdentity? {
        try publicIdentityStore.identity(forKeyRef: keyRef)
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

        let result = try Self.insertionResult(for: client.add(query).status)
        if result == .inserted {
            try publicIdentityStore.insertOrRequireIdentity(identity)
        }
        return result
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

    func delete(keyRef: String, authenticationContext: LAContext) throws {
        BiometricAuthenticationContexts.shared.invalidate(.relayerLaunch)
        var query = baseQuery(keyRef: keyRef)
        query[kSecUseAuthenticationContext as String] = authenticationContext
        let status = client.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw mapSecurityStatus(status)
        }
    }

    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
        let status = client.delete(query)
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
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = authenticationContext

        let response = client.copyMatching(query)
        guard response.status == errSecSuccess else {
            throw mapSecurityStatus(response.status)
        }
        guard let attributes = response.result as? [String: Any],
              let secret = attributes[kSecValueData as String] as? Data else {
            throw Self.describeSecurityStatus(errSecDecode)
        }
        guard secret.count == 32 else {
            throw AppError.invalidHexString
        }

        let derivedIdentity = try VerifiedRelayerIdentity.derive(
            keyRef: keyRef,
            secret: secret
        )
        let legacyIdentity: VerifiedRelayerIdentity?
        if let rawMetadata = attributes[kSecAttrGeneric as String] {
            guard let metadata = rawMetadata as? Data else {
                throw VerifiedRelayerIdentity.ValidationError.malformedMetadata
            }
            legacyIdentity = try VerifiedRelayerIdentity.decodeMetadata(metadata)
            guard legacyIdentity?.keyRef == keyRef else {
                throw VerifiedRelayerIdentity.ValidationError.metadataKeyRefMismatch(
                    expected: keyRef,
                    actual: legacyIdentity?.keyRef ?? ""
                )
            }
        } else {
            legacyIdentity = nil
        }
        _ = try VerifiedRelayerIdentityMetadataPolicy.decision(
            stored: legacyIdentity,
            derived: derivedIdentity
        )
        try publicIdentityStore.insertOrRequireIdentity(derivedIdentity)
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
            kSecAttrService as String: Self.service,
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
/// versioned metadata is stored in a separate immutable public record so
/// prompt-free UI and preflight code can bind wallet-node's public status to an
/// identity the app previously derived from that secret.
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
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
