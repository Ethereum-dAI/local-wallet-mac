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
        try loadForDaemonLaunch(keyRef: keyRef, createIfMissing: true)
    }

    // The daemon keeps installed secrets in RAM only, so every stored key for
    // the chain (active and rotated) must be re-delivered at each spawn or
    // rotated relayers become unusable after an app restart.
    func unlockAllForDaemonLaunch(chainId: UInt64) throws -> [BundlerSecretRecord] {
        try unlockAllForLaunch(chainId: chainId, successTTL: BundlerSecretPromptReusePolicy.cacheTTL)
    }

    func unlockAllForOnboardingDaemonLaunch(chainId: UInt64) throws -> [BundlerSecretRecord] {
        try unlockAllForLaunch(
            chainId: chainId,
            successTTL: BundlerSecretPromptReusePolicy.onboardingHandoffCacheTTL
        )
    }

    private func unlockAllForLaunch(chainId: UInt64, successTTL: TimeInterval) throws -> [BundlerSecretRecord] {
        let keyRefs = BundlerLaunchKeyPolicy.launchKeyRefs(chainId: chainId, available: try listKeyRefs())
        guard !keyRefs.isEmpty else {
            throw AppError.localRelayerKeyMissing
        }
        return try keyRefs.map { keyRef in
            try loadForDaemonLaunch(keyRef: keyRef, createIfMissing: false, successTTL: successTTL)
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

    private func loadForDaemonLaunch(
        keyRef: String,
        createIfMissing: Bool,
        successTTL: TimeInterval = BundlerSecretPromptReusePolicy.cacheTTL
    ) throws -> BundlerSecretRecord {
        if let cached = try BundlerSecretPromptCache.shared.begin(keyRef: keyRef) {
            return cached
        }

        do {
            let record: BundlerSecretRecord
            if try hasKey(forKeyRef: keyRef) {
                record = try read(
                    keyRef: keyRef,
                    reason: "Unlock the local relayer key",
                    allowAuthenticationReuse: true
                )
            } else {
                guard createIfMissing else {
                    throw AppError.localRelayerKeyMissing
                }
                let generated = try WalletSignature.generateBundlerSecret()
                try add(keyRef: keyRef, secret: generated.secret)
                record = try read(
                    keyRef: keyRef,
                    reason: "Unlock the local relayer key",
                    allowAuthenticationReuse: true
                )
            }
            BundlerSecretPromptCache.shared.finish(
                keyRef: keyRef,
                result: .success(record),
                successTTL: successTTL
            )
            return record
        } catch {
            BundlerSecretPromptCache.shared.finish(keyRef: keyRef, result: .failure(error))
            throw error
        }
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
        BundlerSecretPromptCache.shared.invalidate(keyRef: keyRef)
    }

    func read(keyRef: String, reason: String) throws -> BundlerSecretRecord {
        try read(keyRef: keyRef, reason: reason, allowAuthenticationReuse: false)
    }

    func delete(keyRef: String) throws {
        let status = SecItemDelete(baseQuery(keyRef: keyRef) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw mapSecurityStatus(status)
        }
        BundlerSecretPromptCache.shared.invalidate(keyRef: keyRef)
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
        BundlerSecretPromptCache.shared.invalidateAll()
    }

    private func read(
        keyRef: String,
        reason: String,
        allowAuthenticationReuse: Bool
    ) throws -> BundlerSecretRecord {
        let context = LAContext()
        context.localizedReason = reason
        if allowAuthenticationReuse {
            context.touchIDAuthenticationAllowableReuseDuration =
                BundlerSecretPromptReusePolicy.authenticationReuseDuration
        }

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

enum BundlerLaunchKeyPolicy {
    static func chainId(ofKeyRef keyRef: String) -> UInt64? {
        components(ofKeyRef: keyRef)?.chainId
    }

    static func launchKeyRefs(chainId: UInt64, available: [String]) -> [String] {
        available
            .compactMap { keyRef -> (keyRef: String, index: UInt64)? in
                guard let parsed = components(ofKeyRef: keyRef), parsed.chainId == chainId else {
                    return nil
                }
                return (keyRef, parsed.index)
            }
            .sorted { $0.index < $1.index }
            .map(\.keyRef)
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

enum BundlerSecretPromptReusePolicy {
    static let cacheTTL: TimeInterval = 10
    static let onboardingHandoffCacheTTL: TimeInterval = 31 * 60
    static let failureCooldown: TimeInterval = 4
    static let authenticationReuseDuration: TimeInterval = 10

    static func shouldUseCached(now: Date, expiresAt: Date) -> Bool {
        now < expiresAt
    }

    static func expiry(now: Date, ttl: TimeInterval = cacheTTL) -> Date {
        now.addingTimeInterval(ttl)
    }

    static func retryAfter(now: Date, cooldown: TimeInterval = failureCooldown) -> Date {
        now.addingTimeInterval(cooldown)
    }
}

private final class BundlerSecretPromptCache: @unchecked Sendable {
    static let shared = BundlerSecretPromptCache()

    private struct CachedRecord {
        let record: BundlerSecretRecord
        let expiresAt: Date
    }

    private struct CachedFailure {
        let error: Error
        let retryAfter: Date
    }

    private let condition = NSCondition()
    private var records: [String: CachedRecord] = [:]
    private var failures: [String: CachedFailure] = [:]
    private var inFlight: Set<String> = []

    func begin(keyRef: String, now: Date = Date()) throws -> BundlerSecretRecord? {
        condition.lock()
        defer { condition.unlock() }

        while true {
            if let cached = records[keyRef] {
                if BundlerSecretPromptReusePolicy.shouldUseCached(
                    now: now,
                    expiresAt: cached.expiresAt
                ) {
                    return cached.record
                }
                records.removeValue(forKey: keyRef)
            }

            if let failure = failures[keyRef] {
                if BundlerSecretPromptReusePolicy.shouldUseCached(
                    now: now,
                    expiresAt: failure.retryAfter
                ) {
                    throw failure.error
                }
                failures.removeValue(forKey: keyRef)
            }

            if !inFlight.contains(keyRef) {
                inFlight.insert(keyRef)
                return nil
            }

            condition.wait()
        }
    }

    func finish(
        keyRef: String,
        result: Result<BundlerSecretRecord, Error>,
        successTTL: TimeInterval = BundlerSecretPromptReusePolicy.cacheTTL,
        now: Date = Date()
    ) {
        condition.lock()
        switch result {
        case .success(let record):
            records[keyRef] = CachedRecord(
                record: record,
                expiresAt: BundlerSecretPromptReusePolicy.expiry(now: now, ttl: successTTL)
            )
            failures.removeValue(forKey: keyRef)
        case .failure(let error):
            records.removeValue(forKey: keyRef)
            failures[keyRef] = CachedFailure(
                error: error,
                retryAfter: BundlerSecretPromptReusePolicy.retryAfter(now: now)
            )
        }
        inFlight.remove(keyRef)
        condition.broadcast()
        condition.unlock()
    }

    func invalidate(keyRef: String) {
        condition.lock()
        records.removeValue(forKey: keyRef)
        failures.removeValue(forKey: keyRef)
        condition.broadcast()
        condition.unlock()
    }

    func invalidateAll() {
        condition.lock()
        records.removeAll()
        failures.removeAll()
        condition.broadcast()
        condition.unlock()
    }
}

extension Data {
    var lowercaseHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
