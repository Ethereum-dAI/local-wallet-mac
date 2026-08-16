import AppKit
import Foundation
import LocalAuthentication
import Security
import Testing
@testable import WalletMacOSApp

private final class ResetSecurityItemClient: SecurityItemClient, @unchecked Sendable {
    private(set) var deletions: [[String: Any]] = []
    var deleteStatus: OSStatus = errSecSuccess

    func add(_ attributes: [String: Any]) -> (status: OSStatus, result: Any?) {
        (errSecSuccess, nil)
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: Any?) {
        (errSecItemNotFound, nil)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        deletions.append(query)
        return deleteStatus
    }
}

// MARK: - Wallet reset deletes every key class (S-1)

@Test func walletResetCleanupRunsAllStepsIncludingSessionKeys() throws {
    var steps: [String] = []
    let cleanup = WalletResetCleanup(
        deleteRelayerSelectionJournal: { steps.append("journal") },
        deletePublicRelayerIdentities: { steps.append("public") },
        deleteBundlerKeys: { steps.append("bundler") },
        deleteRootKey: { steps.append("root") },
        deleteSessionKeys: { steps.append("session") },
        clearRelayerAddressCache: { steps.append("relayer-cache") },
        clearMetadata: { steps.append("metadata") },
        invalidateBiometricContexts: { steps.append("biometric") }
    )

    var completed: [String] = []
    try cleanup.run { completed.append($0) }

    #expect(steps == ["journal", "public", "bundler", "root", "session", "relayer-cache", "metadata", "biometric"])
    #expect(completed == [
        "relayer-selection-journal",
        "relayer-public-identities",
        "relayer-keys",
        "secure-enclave-key",
        "session-keys",
        "relayer-address-cache",
        "metadata",
        "biometric-contexts",
    ])
}

// The biometric reuse window has to close even when an earlier step fails: a step that
// throws must not take the invalidation down with it, which is why it is its own step
// rather than a tail call inside another closure.
@Test func walletResetCleanupInvalidatesBiometricContextsEvenWhenAnEarlierStepThrows() {
    struct Boom: Error {}
    var invalidated = false
    let cleanup = WalletResetCleanup(
        deleteRelayerSelectionJournal: {},
        deletePublicRelayerIdentities: {},
        deleteBundlerKeys: {},
        deleteRootKey: {},
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
        deleteRelayerSelectionJournal: { steps.append("journal") },
        deletePublicRelayerIdentities: { steps.append("public") },
        deleteBundlerKeys: { steps.append("bundler") },
        deleteRootKey: { throw Boom() },
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

    #expect(steps == ["journal", "public", "bundler", "session", "relayer-cache", "metadata", "biometric"])
    #expect(aggregated?.failures.count == 1)
    #expect(aggregated?.failures.first?.step == "secure-enclave-key")
}

@Test func walletResetStopsRelayerAuthorityCleanupWhenJournalDeletionFails() {
    struct Boom: Error {}
    var steps: [String] = []
    let cleanup = WalletResetCleanup(
        deleteRelayerSelectionJournal: {
            steps.append("journal")
            throw Boom()
        },
        deletePublicRelayerIdentities: { steps.append("public") },
        deleteBundlerKeys: { steps.append("protected") },
        deleteRootKey: { steps.append("root") },
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

    #expect(!steps.contains("public"))
    #expect(!steps.contains("protected"))
    #expect(steps == ["journal", "root", "session", "relayer-cache", "metadata", "biometric"])
    #expect(aggregated?.failures.map(\.step) == ["relayer-selection-journal"])
}

@Test func walletResetSkipsProtectedRelayerDeletionWhenPublicIdentityDeletionFails() {
    struct Boom: Error {}
    var steps: [String] = []
    let cleanup = WalletResetCleanup(
        deleteRelayerSelectionJournal: { steps.append("journal") },
        deletePublicRelayerIdentities: {
            steps.append("public")
            throw Boom()
        },
        deleteBundlerKeys: { steps.append("protected") },
        deleteRootKey: { steps.append("root") },
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

    #expect(!steps.contains("protected"))
    #expect(steps == ["journal", "public", "root", "session", "relayer-cache", "metadata", "biometric"])
    #expect(aggregated?.failures.map(\.step) == ["relayer-public-identities"])
}

@Test func protectedRelayerResetUsesTheAlreadyAuthorizedContext() throws {
    let client = ResetSecurityItemClient()
    let store = BundlerKeyStore(
        client: client,
        publicIdentityStore: RelayerPublicIdentityStore(client: client)
    )
    let context = LAContext()

    try store.deleteAll(authenticationContext: context)

    let query = try #require(client.deletions.first)
    let suppliedContext = try #require(
        query[kSecUseAuthenticationContext as String] as? LAContext
    )
    #expect(suppliedContext === context)
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
    #expect(BundlerLaunchKeyPolicy.chainId(ofKeyRef: "bundler-eoa:default:011155111:1") == nil)
    #expect(BundlerLaunchKeyPolicy.chainId(ofKeyRef: "bundler-eoa:default:11155111:01") == nil)
    #expect(BundlerLaunchKeyPolicy.chainId(ofKeyRef: "bundler-eoa:default:0:1") == nil)
    #expect(BundlerLaunchKeyPolicy.chainId(ofKeyRef: "bundler-eoa:default:11155111:0") == nil)
    #expect(BundlerLaunchKeyPolicy.chainId(
        ofKeyRef: "bundler-eoa:default:18446744073709551615:18446744073709551615"
    ) == UInt64.max)
    #expect(BundlerLaunchKeyPolicy.chainId(
        ofKeyRef: "bundler-eoa:default:18446744073709551616:1"
    ) == nil)
    #expect(BundlerLaunchKeyPolicy.chainId(
        ofKeyRef: "bundler-eoa:default:11155111:18446744073709551616"
    ) == nil)
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

@Test func malformedLegacyBundlerCacheNeverMigratesIntoCanonicalChainSlot() {
    for malformedKeyRef in [
        "bundler-eoa:default:011155111:1",
        "bundler-eoa:default:11155111:01",
        "bundler-eoa:default:0:1",
        "bundler-eoa:default:11155111:0",
    ] {
        withTestDefaults { defaults in
            defaults.set(
                malformedKeyRef,
                forKey: "com.localwallet.demo.onboarding.bundler-key-ref"
            )
            defaults.set(
                "0xabcabcabcabcabcabcabcabcabcabcabcabcabca",
                forKey: "com.localwallet.demo.onboarding.bundler-address"
            )
            let store = OnboardingSettingsStore(defaults: defaults)

            #expect(store.bundlerKeyRef(chainId: 11_155_111) == nil)
            #expect(store.bundlerAddress(chainId: 11_155_111) == nil)
        }
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
