import Foundation
import LocalAuthentication
import Security

struct ShieldedSeedStore {
    private let service = "com.localwallet.wallet-macos.shielded-seed"
    private let account = "privacy-pools-sepolia"  // testnet-tagged

    // NOTE: .biometryCurrentSet invalidates this item on biometric re-enrollment
    // (Face ID reset / fingerprint added or removed) — the entropy is then destroyed
    // and a new seed is generated on next use. Acceptable for a testnet, device-only
    // seed with no backup; MUST be revisited (mnemonic backup / .biometryAny) before
    // any mainnet promotion, where this would mean silent loss of shielded funds.
    static func makeAccessControl(_ error: inout Unmanaged<CFError>?) -> SecAccessControl? {
        SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.biometryCurrentSet], &error)
    }

    static func hexString(from data: Data) -> String { "0x" + data.map { String(format: "%02x", $0) }.joined() }

    func loadOrCreateEntropyHex(reason: String) throws -> String {
        if let existing = try load(reason: reason) { return existing }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let hex = Self.hexString(from: bytes)
        try store(hex)
        return hex
    }

    private func load(reason: String) throws -> String? {
        let context = LAContext(); context.localizedReason = reason
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let s = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return s
    }

    private func store(_ hex: String) throws {
        var acErr: Unmanaged<CFError>?
        guard let ac = Self.makeAccessControl(&acErr) else { throw acErr!.takeRetainedValue() as Error }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: Data(hex.utf8),
            kSecAttrAccessControl as String: ac,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func deleteEntropy() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
