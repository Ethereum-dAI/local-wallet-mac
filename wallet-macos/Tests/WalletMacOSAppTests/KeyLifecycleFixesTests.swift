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
        deleteRailgunSecrets: { steps.append("railgun") }
    )

    var completed: [String] = []
    try cleanup.run { completed.append($0) }

    #expect(steps == ["root", "bundler", "session", "relayer-cache", "metadata", "railgun"])
    #expect(completed == ["secure-enclave-key", "relayer-keys", "session-keys", "relayer-address-cache", "metadata", "railgun-secrets"])
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
        deleteRailgunSecrets: { steps.append("railgun") }
    )

    var aggregated: WalletResetCleanupError?
    do {
        try cleanup.run()
    } catch let error as WalletResetCleanupError {
        aggregated = error
    } catch {}

    #expect(steps == ["bundler", "session", "relayer-cache", "metadata", "railgun"])
    #expect(aggregated?.failures.count == 1)
    #expect(aggregated?.failures.first?.step == "secure-enclave-key")
}

@Test func demoFactoryResetClearsOnlyWalletNodeSQLiteState() throws {
    let fileManager = FileManager.default
    let support = fileManager.temporaryDirectory
        .appendingPathComponent("wallet-node-reset-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: support) }
    let daemonDirectory = support
        .appendingPathComponent("Local Wallet", isDirectory: true)
        .appendingPathComponent("wallet-node", isDirectory: true)
    try fileManager.createDirectory(at: daemonDirectory, withIntermediateDirectories: true)

    for fileName in WalletNodeManagedStoreCleanup.databaseFileNames + ["config.toml"] {
        try Data(fileName.utf8).write(to: daemonDirectory.appendingPathComponent(fileName))
    }

    try WalletNodeManagedStoreCleanup.clear(
        fileManager: fileManager,
        applicationSupportDirectory: support
    )

    for fileName in WalletNodeManagedStoreCleanup.databaseFileNames {
        #expect(!fileManager.fileExists(atPath: daemonDirectory.appendingPathComponent(fileName).path))
    }
    #expect(fileManager.fileExists(atPath: daemonDirectory.appendingPathComponent("config.toml").path))
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
        #expect(store.bundlerKeyRef(chainId: 31_337) == nil)
        #expect(store.bundlerAddress(chainId: 31_337) == nil)
    }
}

@Test func legacyBundlerCacheMigratesOnlyToItsOwnChain() {
    withTestDefaults { defaults in
        defaults.set("bundler-eoa:default:11155111:1", forKey: "com.localwallet.demo.onboarding.bundler-key-ref")
        defaults.set("0xabcabcabcabcabcabcabcabcabcabcabcabcabca", forKey: "com.localwallet.demo.onboarding.bundler-address")
        let store = OnboardingSettingsStore(defaults: defaults)

        #expect(store.bundlerKeyRef(chainId: 31_337) == nil)
        #expect(store.bundlerAddress(chainId: 31_337) == nil)

        #expect(store.bundlerKeyRef(chainId: 11_155_111) == "bundler-eoa:default:11155111:1")
        #expect(store.bundlerAddress(chainId: 11_155_111) == "0xabcabcabcabcabcabcabcabcabcabcabcabcabca")

        #expect(defaults.string(forKey: "com.localwallet.demo.onboarding.bundler-key-ref") == nil)
        #expect(defaults.string(forKey: "com.localwallet.demo.onboarding.bundler-address") == nil)
    }
}

@Test func clearBundlerCacheRemovesPerChainAndLegacyEntries() {
    withTestDefaults { defaults in
        let store = OnboardingSettingsStore(defaults: defaults)
        store.setBundlerKeyRef("bundler-eoa:default:31337:1", chainId: 31_337)
        store.setBundlerAddress("0x1111111111111111111111111111111111111111", chainId: 31_337)
        defaults.set("bundler-eoa:default:11155111:1", forKey: "com.localwallet.demo.onboarding.bundler-key-ref")
        defaults.set("0xabcabcabcabcabcabcabcabcabcabcabcabcabca", forKey: "com.localwallet.demo.onboarding.bundler-address")

        store.clearBundlerCache(chainIds: [31_337, 11_155_111])

        #expect(store.bundlerKeyRef(chainId: 31_337) == nil)
        #expect(store.bundlerAddress(chainId: 31_337) == nil)
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
