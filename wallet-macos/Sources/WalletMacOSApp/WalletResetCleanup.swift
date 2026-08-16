import AppKit
import Darwin
import Foundation
import LocalAuthentication

/// A factory reset can securely wipe only sidecars owned by this app. Environment-configured
/// sidecars may still hold the old relayer or privacy secret in RAM, so fail before asking for
/// device-owner authentication instead of pretending the reset was complete.
enum WalletResetPreflight {
    @MainActor
    static func ensureNoOtherLocalWalletInstance(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        currentProcessID: pid_t = ProcessInfo.processInfo.processIdentifier,
        runningProcessIDs: [pid_t]? = nil
    ) throws {
        let observedProcessIDs: [pid_t]
        if let runningProcessIDs {
            observedProcessIDs = runningProcessIDs
        } else {
            guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
                throw AppError.localDaemonLaunchFailed(
                    "Factory reset could not verify whether another Local Wallet instance is running."
                )
            }
            observedProcessIDs = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .map(\.processIdentifier)
        }

        guard !observedProcessIDs.contains(where: { $0 != currentProcessID }) else {
            throw AppError.localDaemonLaunchFailed(
                "Quit every other Local Wallet window before factory reset so no helper process can retain the old keys in memory."
            )
        }
    }

    static func ensureNoExternalSecretRuntimes(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        if WalletNodeClient.Configuration.fromEnvironment(environment: environment) != nil {
            throw AppError.localDaemonLaunchFailed(
                "Factory reset requires the externally managed wallet-node to be stopped and its LOCAL_WALLET_NODE_HTTP_URL / LOCAL_WALLET_NODE_TOKEN (or WALLET_NODE_* equivalents) unset."
            )
        }

        let privacyKeys = [
            "LOCAL_WALLET_PRIVACY_SOCKET",
            "LOCAL_WALLET_PRIVACY_TOKEN",
        ]
        if privacyKeys.contains(where: { environment[$0] != nil }) {
            throw AppError.localDaemonLaunchFailed(
                "Factory reset requires the externally managed privacy helper to be stopped and its LOCAL_WALLET_PRIVACY_* configuration unset."
            )
        }
    }
}

/// Removes only wallet-node's durable SQLite state for the unreleased Demo Wallet factory-reset
/// flow. Logs, network config, and Helios checkpoints are intentionally preserved. The caller
/// must terminate the managed daemon first; this phase is fail-fast and runs before Keychain
/// deletion so a filesystem failure cannot strand a new secret behind stale relayer metadata.
enum WalletNodeManagedStoreCleanup {
    enum CleanupError: LocalizedError {
        case daemonStillRunning

        var errorDescription: String? {
            "wallet-node is still running. Quit the wallet (and any external wallet-node) before factory reset."
        }
    }

    static let databaseFileNames = ["node.sqlite", "node.sqlite-wal", "node.sqlite-shm"]

    static func clear(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) throws {
        let supportDirectory: URL
        if let applicationSupportDirectory {
            supportDirectory = applicationSupportDirectory
        } else {
            supportDirectory = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let daemonDirectory = supportDirectory
            .appendingPathComponent("Local Wallet", isDirectory: true)
            .appendingPathComponent("wallet-node", isDirectory: true)
        let socketURL = daemonDirectory.appendingPathComponent("wallet-node.sock", isDirectory: false)
        guard !socketAcceptsConnections(at: socketURL.path) else {
            throw CleanupError.daemonStillRunning
        }

        for fileName in databaseFileNames {
            let url = daemonDirectory.appendingPathComponent(fileName, isDirectory: false)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    private static func socketAcceptsConnections(at path: String) -> Bool {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                ) == 0
            }
        }
    }
}

// Wallet reset must clear every key class the app manages: the Secure Enclave
// root key, relayer (bundler EOA) selection journal, public identities and
// secrets, session-key secrets, cached relayer address, and wallet metadata.
// Both reset entry points (the
// in-app reset and the --reset-demo-wallet CLI flag) run through this type so
// a key class cannot silently drop out of one of them again.
struct WalletResetCleanup {
    var deleteRelayerSelectionJournal: () throws -> Void
    var deletePublicRelayerIdentities: () throws -> Void
    var deleteBundlerKeys: () throws -> Void
    var deleteRootKey: () throws -> Void
    var deleteSessionKeys: () throws -> Void
    var clearRelayerAddressCache: () throws -> Void
    var clearMetadata: () throws -> Void
    // The RAILGUN entropy is another key class the app manages (stored in the Keychain; the
    // sidecar's exit-sender key is derived from it, not stored separately). A full reset must
    // wipe it too.
    var deleteRailgunSecrets: () throws -> Void

    static func standard(
        authenticationContext: LAContext,
        keyStore: KeyStore = KeyStore(),
        metadataStore: WalletMetadataStore = WalletMetadataStore(),
        onboardingSettingsStore: OnboardingSettingsStore = OnboardingSettingsStore(),
        bundlerKeyStore: BundlerKeyStore = .shared,
        relayerPublicIdentityStore: RelayerPublicIdentityStore = .shared,
        relayerChainStateJournalStore: RelayerChainStateJournalStore = .shared
    ) -> WalletResetCleanup {
        WalletResetCleanup(
            deleteRelayerSelectionJournal: {
                try relayerChainStateJournalStore.deleteAll()
            },
            deletePublicRelayerIdentities: {
                try relayerPublicIdentityStore.deleteAll()
            },
            deleteBundlerKeys: {
                try bundlerKeyStore.deleteAll(authenticationContext: authenticationContext)
            },
            deleteRootKey: { try keyStore.deleteKey() },
            deleteSessionKeys: { try SessionKeyStore.shared.deleteAll() },
            clearRelayerAddressCache: {
                onboardingSettingsStore.clearBundlerCache(chainIds: [
                    ChainConfiguration.ethereumSepolia.id,
                ])
            },
            clearMetadata: { try metadataStore.clear() },
            deleteRailgunSecrets: {
                try RailgunSecretsStore.clear()
                // Every key this reset destroyed is gone; a surviving reuse window
                // must not wave through a read of whatever replaces it.
                BiometricAuthenticationContexts.shared.invalidateAll()
            }
        )
    }

    // Relayer authority cleanup is fail-fast and dependency-ordered. If journal deletion fails,
    // preserve both the public identities and protected secrets. If public deletion fails after
    // the journal is gone, preserve protected secrets. Unrelated key classes remain best-effort.
    func run(onStep: (String) -> Void = { _ in }) throws {
        var failures: [WalletResetCleanupError.StepFailure] = []

        @discardableResult
        func runStep(_ label: String, _ action: () throws -> Void) -> Bool {
            do {
                try action()
                onStep(label)
                return true
            } catch {
                failures.append(WalletResetCleanupError.StepFailure(step: label, underlying: error))
                return false
            }
        }

        let journalDeleted = runStep(
            "relayer-selection-journal",
            deleteRelayerSelectionJournal
        )
        if journalDeleted {
            let publicIdentitiesDeleted = runStep(
                "relayer-public-identities",
                deletePublicRelayerIdentities
            )
            if publicIdentitiesDeleted {
                runStep("relayer-keys", deleteBundlerKeys)
            }
        }

        let unrelatedSteps: [(label: String, action: () throws -> Void)] = [
            ("secure-enclave-key", deleteRootKey),
            ("session-keys", deleteSessionKeys),
            ("relayer-address-cache", clearRelayerAddressCache),
            ("metadata", clearMetadata),
            ("railgun-secrets", deleteRailgunSecrets),
        ]
        for step in unrelatedSteps {
            runStep(step.label, step.action)
        }

        guard failures.isEmpty else {
            throw WalletResetCleanupError(failures: failures)
        }
    }
}

struct WalletResetCleanupError: LocalizedError {
    struct StepFailure {
        let step: String
        let underlying: Error
    }

    let failures: [StepFailure]

    var errorDescription: String? {
        let details = failures
            .map { "\($0.step): \($0.underlying.localizedDescription)" }
            .joined(separator: "; ")
        return "Wallet reset finished with errors: \(details)"
    }
}

enum SessionResetPolicy {
    // Deleting local session-key material does not touch the onchain
    // permission; an unexpired installed permission keeps its bounded spend
    // power until validUntil. Surface that before a reset discards the local
    // state needed to revoke it.
    static func unexpiredSessionWarning(records: [SessionRecord], now: Date) -> String? {
        let unexpired = records.filter { record in
            record.installedOnChain && SessionLifecycle.expiryReason(record: record, now: now) == nil
        }
        guard let latestExpiry = unexpired.map(\.expiresAt).max() else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "an onchain session permission stays valid until \(formatter.string(from: latestExpiry)) unless it is revoked; resetting only deletes the local session key material. Disable session keys first to revoke onchain."
    }
}
