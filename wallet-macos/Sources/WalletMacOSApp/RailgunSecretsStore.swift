import Foundation
import Security

/// The two secrets the railgun-helper sidecar needs, delivered over fd-5:
/// - `entropyHex`: 32-byte seed for the RAILGUN shielded account (deterministic → recovers
///   the same shielded balance across launches).
/// - `broadcasterKeyHex`: 32-byte EOA private key for the local broadcaster.
struct RailgunSecrets: Equatable {
    let entropyHex: String
    let broadcasterKeyHex: String
}

/// Persists the railgun secrets on disk (Application Support, mode 0600), generating them
/// once on first use.
///
/// TESTNET ONLY. This deliberately mirrors the v1 Privacy-Pools decision to defer
/// biometric/Keychain custody of the shielded seed: a 0600 file is enough for a testnet
/// demo, and Keychain (`.biometryCurrentSet`, device-only) custody is the hardening
/// follow-up — same posture the design doc records for the shielded seed.
enum RailgunSecretsStore {
    enum StoreError: LocalizedError {
        case entropy(String)
        case io(String)
        var errorDescription: String? {
            switch self {
            case .entropy(let m): return "railgun secrets: \(m)"
            case .io(let m): return "railgun secrets: \(m)"
            }
        }
    }

    static func loadOrCreate(
        directory: URL? = nil
    ) throws -> RailgunSecrets {
        let fileURL = try secretsFileURL(directory: directory)
        if let existing = try? load(from: fileURL) {
            return existing
        }
        let secrets = RailgunSecrets(
            entropyHex: try randomHex32(),
            broadcasterKeyHex: try randomHex32()
        )
        try save(secrets, to: fileURL)
        return secrets
    }

    /// Delete the persisted railgun secrets (part of a full wallet reset). No-op if absent.
    static func clear(directory: URL? = nil) throws {
        let fileURL = try secretsFileURL(directory: directory)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: internals

    private static func secretsFileURL(directory: URL?) throws -> URL {
        let base: URL
        if let directory {
            base = directory
        } else {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            base = support.appendingPathComponent("LocalWallet", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("railgun-secrets.json", isDirectory: false)
    }

    private static func load(from url: URL) throws -> RailgunSecrets {
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: String]
        guard let entropy = obj?["entropyHex"], let key = obj?["broadcasterKeyHex"] else {
            throw StoreError.io("malformed secrets file")
        }
        return RailgunSecrets(entropyHex: entropy, broadcasterKeyHex: key)
    }

    private static func save(_ secrets: RailgunSecrets, to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "entropyHex": secrets.entropyHex,
                "broadcasterKeyHex": secrets.broadcasterKeyHex,
            ],
            options: [.sortedKeys]
        )
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func randomHex32() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw StoreError.entropy("SecRandomCopyBytes failed")
        }
        return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}
