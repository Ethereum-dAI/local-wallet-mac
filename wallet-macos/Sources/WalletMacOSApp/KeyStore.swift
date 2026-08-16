import CryptoKit
import Foundation
import LocalAuthentication
import Security

// KeyStore owns the device-bound signing key for the demo app. It is the only
// layer that should touch Secure Enclave / Keychain private-key APIs directly.
struct SignatureComponents {
    let rawRepresentation: Data
    let r: Data
    let s: Data
}

struct KeyStore {
    enum KeyAccessPolicy: String, Codable {
        case standardWallet
        case strictBiometric

        var accessFlags: SecAccessControlCreateFlags {
            switch self {
            case .standardWallet:
                return [.privateKeyUsage, .userPresence]
            case .strictBiometric:
                return [.privateKeyUsage, .biometryCurrentSet]
            }
        }
    }

    struct Configuration {
        let service: String
        let account: String
        let accessPolicy: KeyAccessPolicy

        static let `default` = Configuration(
            service: "com.localwallet.wallet-macos.keystore",
            account: "main-signing-key",
            accessPolicy: .standardWallet
        )
    }

    let configuration: Configuration

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    var keyTag: String {
        "\(configuration.service).\(configuration.account)"
    }

    private var applicationTagData: Data {
        Data(keyTag.utf8)
    }

    private func createOrLoadKey(authenticationContext: LAContext? = nil) throws -> SecKey {
        if let existing = try loadKey(authenticationContext: authenticationContext) {
            return existing
        }

        let newKey = try createKey(authenticationContext: authenticationContext)
        return newKey
    }

    func loadKey(authenticationContext: LAContext? = nil) throws -> SecKey? {
        try loadDirectKey(authenticationContext: authenticationContext)
    }

    func loadPublicKeyCoordinates(
        authenticationContext: LAContext? = nil
    ) throws -> PublicKeyCoordinates? {
        guard let key = try loadKey(authenticationContext: authenticationContext) else {
            return nil
        }
        return try publicKeyCoordinates(for: key)
    }

    // Provisioning entry point: the only path allowed to mint a new root key.
    func createOrLoadPublicKeyCoordinates(
        authenticationContext: LAContext? = nil
    ) throws -> PublicKeyCoordinates {
        let key = try createOrLoadKey(authenticationContext: authenticationContext)
        return try publicKeyCoordinates(for: key)
    }

    // Signing must never mint a replacement key: metadata may still describe
    // an account owned by the old key, and a silently regenerated key would
    // produce signatures the account rejects with no local diagnosis.
    func sign(
        preimage: Data,
        reason: String,
        authenticationContext: LAContext? = nil
    ) throws -> SignatureComponents {
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

        guard let key = try loadKey(authenticationContext: context) else {
            throw AppError.missingKeyReference
        }
        return try sign(preimage: preimage, with: key)
    }

    func deleteKey() throws {
        try deleteDirectKey()
    }

    private func loadDirectKey(authenticationContext: LAContext? = nil) throws -> SecKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: applicationTagData,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        if let authenticationContext {
            query[kSecUseAuthenticationContext as String] = authenticationContext
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let secKey = result as! SecKey? else {
            throw mapSecurityStatus(status)
        }

        return secKey
    }

    private func createKey(authenticationContext: LAContext? = nil) throws -> SecKey {
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            configuration.accessPolicy.accessFlags,
            &accessError
        ) else {
            throw accessError!.takeRetainedValue() as Error
        }

        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: applicationTagData,
                kSecAttrAccessControl as String: accessControl,
            ],
        ]

        if let authenticationContext {
            attributes[kSecUseAuthenticationContext as String] = authenticationContext
        }

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let underlyingError = error?.takeRetainedValue() as Error?
            throw mapSecurityError(underlyingError ?? AppError.missingKeyReference)
        }

        return key
    }

    private func deleteDirectKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: applicationTagData,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw mapSecurityStatus(status)
        }
    }

    private func publicKeyCoordinates(for key: SecKey) throws -> PublicKeyCoordinates {
        guard let publicKey = SecKeyCopyPublicKey(key) else {
            throw AppError.missingKeyReference
        }

        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            let underlyingError = error?.takeRetainedValue() as Error?
            throw mapSecurityError(underlyingError ?? AppError.invalidPublicKeyFormat)
        }

        return try PublicKeyCoordinates(x963Representation: representation)
    }

    private func sign(preimage: Data, with key: SecKey) throws -> SignatureComponents {
        let algorithm = SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256
        guard SecKeyIsAlgorithmSupported(key, .sign, algorithm) else {
            throw AppError.unsupportedSigningAlgorithm
        }

        var error: Unmanaged<CFError>?
        guard let derSignature = SecKeyCreateSignature(
            key,
            algorithm,
            preimage as CFData,
            &error
        ) as Data? else {
            let underlyingError = error?.takeRetainedValue() as Error?
            throw mapSecurityError(underlyingError ?? AppError.invalidSignatureFormat)
        }

        let signature = try P256.Signing.ECDSASignature(derRepresentation: derSignature)
        let raw = signature.rawRepresentation
        guard raw.count == 64 else {
            throw AppError.invalidSignatureFormat
        }

        return SignatureComponents(
            rawRepresentation: raw,
            r: raw.subdata(in: 0..<32),
            s: raw.subdata(in: 32..<64)
        )
    }

    private func mapSecurityStatus(_ status: OSStatus) -> Error {
        if status == errSecMissingEntitlement {
            return AppError.missingEntitlement
        }

        return NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }

    private func mapSecurityError(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain, nsError.code == Int(errSecMissingEntitlement) {
            return AppError.missingEntitlement
        }

        return error
    }
}
