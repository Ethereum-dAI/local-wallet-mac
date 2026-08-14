import Foundation

// Wallet reset must clear every key class the app manages: the Secure Enclave
// root key, relayer (bundler EOA) secrets, session-key secrets, the cached
// relayer identity, and the wallet metadata file. Both reset entry points (the
// in-app reset and the --reset-demo-wallet CLI flag) run through this type so
// a key class cannot silently drop out of one of them again.
struct WalletResetCleanup {
    var deleteRootKey: () throws -> Void
    var deleteBundlerKeys: () throws -> Void
    var deleteSessionKeys: () throws -> Void
    var clearRelayerAddressCache: () throws -> Void
    var clearMetadata: () throws -> Void
    // The removed RAILGUN privacy feature left spending entropy in the Keychain on alpha
    // installs. Nothing reads it any more, but a reset that claims to clear every key class
    // has to clear that one too rather than leave it behind for the launch-time purge.
    var deleteLegacyRailgunSecrets: () throws -> Void

    static func standard(
        keyStore: KeyStore = KeyStore(),
        metadataStore: WalletMetadataStore = WalletMetadataStore(),
        onboardingSettingsStore: OnboardingSettingsStore = OnboardingSettingsStore()
    ) -> WalletResetCleanup {
        WalletResetCleanup(
            deleteRootKey: { try keyStore.deleteKey() },
            deleteBundlerKeys: { try BundlerKeyStore.shared.deleteAll() },
            deleteSessionKeys: { try SessionKeyStore.shared.deleteAll() },
            clearRelayerAddressCache: {
                onboardingSettingsStore.clearBundlerCache(chainIds: [
                    ChainConfiguration.ethereum.id,
                    ChainConfiguration.ethereumSepolia.id,
                ])
            },
            clearMetadata: { try metadataStore.clear() },
            deleteLegacyRailgunSecrets: {
                try LegacyRailgunSecretsCleanup.purge()
                // Runs from the last step so it lands after every other key class is
                // gone: a surviving reuse window must not wave through a read of
                // whatever replaces them. If this step is ever dropped — see
                // `LegacyRailgunSecretsCleanup` for when that becomes possible —
                // the invalidation has to move to whichever step ends up last.
                BiometricAuthenticationContexts.shared.invalidateAll()
            }
        )
    }

    // Best-effort: a failing step must not leave later key classes behind, so
    // every step runs and the failures are aggregated at the end.
    func run(onStep: (String) -> Void = { _ in }) throws {
        let steps: [(label: String, action: () throws -> Void)] = [
            ("secure-enclave-key", deleteRootKey),
            ("relayer-keys", deleteBundlerKeys),
            ("session-keys", deleteSessionKeys),
            ("relayer-address-cache", clearRelayerAddressCache),
            ("metadata", clearMetadata),
            ("legacy-railgun-secrets", deleteLegacyRailgunSecrets),
        ]

        var failures: [WalletResetCleanupError.StepFailure] = []
        for step in steps {
            do {
                try step.action()
                onStep(step.label)
            } catch {
                failures.append(WalletResetCleanupError.StepFailure(step: step.label, underlying: error))
            }
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
        return "Wallet reset finished with errors — \(details)"
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
