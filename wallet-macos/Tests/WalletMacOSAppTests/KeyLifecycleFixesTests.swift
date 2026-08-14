import AppKit
import Foundation
import Testing
@testable import WalletMacOSApp

// MARK: - Wallet reset deletes every key class (S-1)

@Test func walletResetCleanupRunsAllStepsIncludingSessionKeys() throws {
    var steps: [String] = []
    let cleanup = WalletResetCleanup(
        deleteRootKey: { steps.append("root") },
        deleteBundlerKeys: { steps.append("bundler") },
        deleteSessionKeys: { steps.append("session") },
        clearRelayerAddressCache: { steps.append("relayer-cache") },
        clearMetadata: { steps.append("metadata") },
        invalidateBiometricContexts: { steps.append("biometric") }
    )

    var completed: [String] = []
    try cleanup.run { completed.append($0) }

    #expect(steps == ["root", "bundler", "session", "relayer-cache", "metadata", "biometric"])
    #expect(completed == ["secure-enclave-key", "relayer-keys", "session-keys", "relayer-address-cache", "metadata", "biometric-contexts"])
}

// The biometric reuse window has to close even when an earlier step fails: a step that
// throws must not take the invalidation down with it, which is why it is its own step
// rather than a tail call inside another closure.
@Test func walletResetCleanupInvalidatesBiometricContextsEvenWhenAnEarlierStepThrows() {
    struct Boom: Error {}
    var invalidated = false
    let cleanup = WalletResetCleanup(
        deleteRootKey: {},
        deleteBundlerKeys: {},
        deleteSessionKeys: {},
        clearRelayerAddressCache: {},
        clearMetadata: { throw Boom() },
        invalidateBiometricContexts: { invalidated = true }
    )

    #expect(throws: WalletResetCleanupError.self) { try cleanup.run() }
    #expect(invalidated)
}

@Test func walletResetCleanupContinuesPastFailuresAndAggregates() {
    struct Boom: Error {}
    var steps: [String] = []
    let cleanup = WalletResetCleanup(
        deleteRootKey: { throw Boom() },
        deleteBundlerKeys: { steps.append("bundler") },
        deleteSessionKeys: { steps.append("session") },
        clearRelayerAddressCache: { steps.append("relayer-cache") },
        clearMetadata: { steps.append("metadata") },
        invalidateBiometricContexts: { steps.append("biometric") }
    )

    var aggregated: WalletResetCleanupError?
    do {
        try cleanup.run()
    } catch let error as WalletResetCleanupError {
        aggregated = error
    } catch {}

    #expect(steps == ["bundler", "session", "relayer-cache", "metadata", "biometric"])
    #expect(aggregated?.failures.count == 1)
    #expect(aggregated?.failures.first?.step == "secure-enclave-key")
}

@Test func resetWarnsWhenUnexpiredOnchainSessionPermissionExists() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let active = SessionRecord(
        chainId: 11_155_111,
        sessionKeyRef: "session-key:11155111:0xabc",
        permissionId: Data([0x01]),
        enableSig: Data(),
        enabledAt: now,
        expiresAt: now.addingTimeInterval(3_600),
        installedOnChain: true
    )

    #expect(SessionResetPolicy.unexpiredSessionWarning(records: [active], now: now) != nil)
}

@Test func resetDoesNotWarnForExpiredNeverInstalledOrAbsentSessions() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let expired = SessionRecord(
        chainId: 11_155_111,
        sessionKeyRef: "session-key:11155111:0xabc",
        permissionId: Data([0x01]),
        enableSig: Data(),
        enabledAt: now.addingTimeInterval(-7_200),
        expiresAt: now.addingTimeInterval(-3_600),
        installedOnChain: true
    )
    let neverInstalled = SessionRecord(
        chainId: 11_155_111,
        sessionKeyRef: "session-key:11155111:0xdef",
        permissionId: Data([0x02]),
        enableSig: Data(),
        enabledAt: now,
        expiresAt: now.addingTimeInterval(3_600),
        installedOnChain: false
    )

    #expect(SessionResetPolicy.unexpiredSessionWarning(records: [], now: now) == nil)
    #expect(SessionResetPolicy.unexpiredSessionWarning(records: [expired], now: now) == nil)
    #expect(SessionResetPolicy.unexpiredSessionWarning(records: [neverInstalled], now: now) == nil)
}

// MARK: - Daemon launch installs every stored relayer key for the chain (B-1)

@Test func launchKeyRefsFilterToChainAndSortByIndex() {
    let available = [
        "bundler-eoa:default:11155111:2",
        "bundler-eoa:default:1:1",
        "bundler-eoa:default:11155111:1",
        "bundler-eoa:default:11155111:10",
        "session-key:11155111:0xabc",
        "bundler-eoa:default:11155111",
        "bundler-eoa:default:11155111:x",
    ]

    #expect(BundlerLaunchKeyPolicy.launchKeyRefs(chainId: 11_155_111, available: available) == [
        "bundler-eoa:default:11155111:1",
        "bundler-eoa:default:11155111:2",
        "bundler-eoa:default:11155111:10",
    ])
    #expect(BundlerLaunchKeyPolicy.launchKeyRefs(chainId: 1, available: available) == [
        "bundler-eoa:default:1:1",
    ])
    #expect(BundlerLaunchKeyPolicy.launchKeyRefs(chainId: 5, available: available).isEmpty)
}

@Test func chainIdParsesOnlyFromWellFormedBundlerKeyRefs() {
    #expect(BundlerLaunchKeyPolicy.chainId(ofKeyRef: "bundler-eoa:default:11155111:3") == 11_155_111)
    #expect(BundlerLaunchKeyPolicy.chainId(ofKeyRef: "session-key:11155111:0xabc") == nil)
    #expect(BundlerLaunchKeyPolicy.chainId(ofKeyRef: "bundler-eoa:default:notachain:1") == nil)
    #expect(BundlerLaunchKeyPolicy.chainId(ofKeyRef: "bundler-eoa:default:11155111") == nil)
}

@Test func secretPayloadEncodesAllRecordsInOrder() throws {
    let records = [
        BundlerSecretRecord(keyRef: "bundler-eoa:default:11155111:1", secret: Data(repeating: 0xAB, count: 32)),
        BundlerSecretRecord(keyRef: "bundler-eoa:default:11155111:2", secret: Data(repeating: 0x01, count: 32)),
    ]

    let data = try WalletNodeDaemon.secretPayloadData(records)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let keys = object?["keys"] as? [[String: String]]

    #expect(keys?.count == 2)
    #expect(keys?[0]["keyRef"] == "bundler-eoa:default:11155111:1")
    #expect(keys?[0]["secret"] == "0x" + String(repeating: "ab", count: 32))
    #expect(keys?[1]["keyRef"] == "bundler-eoa:default:11155111:2")
    #expect(keys?[1]["secret"] == "0x" + String(repeating: "01", count: 32))
}

@Test func bundlerKeyStoreListsStoredKeyRefs() throws {
    let store = BundlerKeyStore.shared
    let chainId: UInt64 = 999_000_000_000 + UInt64.random(in: 0..<1_000_000)
    let first = "bundler-eoa:default:\(chainId):1"
    let second = "bundler-eoa:default:\(chainId):2"
    defer {
        try? store.delete(keyRef: first)
        try? store.delete(keyRef: second)
    }

    do {
        try store.add(keyRef: first, secret: Data(repeating: 0x11, count: 32))
        try store.add(keyRef: second, secret: Data(repeating: 0x22, count: 32))
    } catch AppError.missingEntitlement {
        // Biometric-gated items need the data-protection keychain, which an
        // unsigned `swift test` runner cannot write to. The listing query and
        // ordering logic stay covered by the pure policy tests above; run this
        // test from a signed Xcode build for the end-to-end check.
        return
    }

    let listed = try store.listKeyRefs()
    #expect(listed.contains(first))
    #expect(listed.contains(second))
    #expect(BundlerLaunchKeyPolicy.launchKeyRefs(chainId: chainId, available: listed) == [first, second])
}

// MARK: - Relayer identity cache is chain-scoped (B-2)

private func withTestDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suite = "onboarding-settings-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

@Test func bundlerIdentityCacheIsChainScoped() {
    withTestDefaults { defaults in
        let store = OnboardingSettingsStore(defaults: defaults)

        store.setBundlerKeyRef("bundler-eoa:default:11155111:1", chainId: 11_155_111)
        store.setBundlerAddress("0x1111111111111111111111111111111111111111", chainId: 11_155_111)

        #expect(store.bundlerKeyRef(chainId: 11_155_111) == "bundler-eoa:default:11155111:1")
        #expect(store.bundlerAddress(chainId: 11_155_111) == "0x1111111111111111111111111111111111111111")
        #expect(store.bundlerKeyRef(chainId: 1) == nil)
        #expect(store.bundlerAddress(chainId: 1) == nil)
    }
}

@Test func legacyBundlerCacheMigratesOnlyToItsOwnChain() {
    withTestDefaults { defaults in
        defaults.set("bundler-eoa:default:11155111:1", forKey: "com.localwallet.demo.onboarding.bundler-key-ref")
        defaults.set("0xabcabcabcabcabcabcabcabcabcabcabcabcabca", forKey: "com.localwallet.demo.onboarding.bundler-address")
        let store = OnboardingSettingsStore(defaults: defaults)

        #expect(store.bundlerKeyRef(chainId: 1) == nil)
        #expect(store.bundlerAddress(chainId: 1) == nil)

        #expect(store.bundlerKeyRef(chainId: 11_155_111) == "bundler-eoa:default:11155111:1")
        #expect(store.bundlerAddress(chainId: 11_155_111) == "0xabcabcabcabcabcabcabcabcabcabcabcabcabca")

        #expect(defaults.string(forKey: "com.localwallet.demo.onboarding.bundler-key-ref") == nil)
        #expect(defaults.string(forKey: "com.localwallet.demo.onboarding.bundler-address") == nil)
    }
}

@Test func clearBundlerCacheRemovesPerChainAndLegacyEntries() {
    withTestDefaults { defaults in
        let store = OnboardingSettingsStore(defaults: defaults)
        store.setBundlerKeyRef("bundler-eoa:default:1:1", chainId: 1)
        store.setBundlerAddress("0x1111111111111111111111111111111111111111", chainId: 1)
        defaults.set("bundler-eoa:default:11155111:1", forKey: "com.localwallet.demo.onboarding.bundler-key-ref")
        defaults.set("0xabcabcabcabcabcabcabcabcabcabcabcabcabca", forKey: "com.localwallet.demo.onboarding.bundler-address")

        store.clearBundlerCache(chainIds: [1, 11_155_111])

        #expect(store.bundlerKeyRef(chainId: 1) == nil)
        #expect(store.bundlerAddress(chainId: 1) == nil)
        #expect(store.bundlerKeyRef(chainId: 11_155_111) == nil)
        #expect(store.bundlerAddress(chainId: 11_155_111) == nil)
        #expect(defaults.string(forKey: "com.localwallet.demo.onboarding.bundler-key-ref") == nil)
        #expect(defaults.string(forKey: "com.localwallet.demo.onboarding.bundler-address") == nil)
    }
}

// MARK: - Signing never mints a replacement root key (R-1)

@Test func signingRefusesToMintAReplacementRootKey() throws {
    let configuration = KeyStore.Configuration(
        service: "com.localwallet.tests.keystore-\(UUID().uuidString)",
        account: "missing-key",
        accessPolicy: .standardWallet
    )
    let store = KeyStore(configuration: configuration)
    defer { try? store.deleteKey() }

    var refusedWithMissingKey = false
    do {
        _ = try store.sign(preimage: Data("preimage".utf8), reason: "test signing")
    } catch AppError.missingKeyReference {
        refusedWithMissingKey = true
    } catch {}

    #expect(refusedWithMissingKey)
    #expect(try store.loadKey() == nil)
}

// MARK: - Exported secrets are concealed and auto-cleared (B-3)

@Test @MainActor func concealedCopyMarksSecretForClipboardManagers() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }

    _ = ConcealedPasteboard.copy("0xsecret", to: pasteboard, clearAfter: nil)

    #expect(pasteboard.string(forType: .string) == "0xsecret")
    #expect(pasteboard.string(forType: ConcealedPasteboard.concealedType) != nil)
}

@Test @MainActor func concealedClearRemovesSecretOnlyWhilePasteboardIsUnchanged() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }

    let changeCount = ConcealedPasteboard.copy("0xsecret", to: pasteboard, clearAfter: nil)
    ConcealedPasteboard.clearIfUnchanged(pasteboard: pasteboard, expectedChangeCount: changeCount)
    #expect(pasteboard.string(forType: .string) == nil)

    let staleCount = ConcealedPasteboard.copy("0xsecret", to: pasteboard, clearAfter: nil)
    pasteboard.clearContents()
    pasteboard.setString("user data", forType: .string)
    ConcealedPasteboard.clearIfUnchanged(pasteboard: pasteboard, expectedChangeCount: staleCount)
    #expect(pasteboard.string(forType: .string) == "user data")
}
