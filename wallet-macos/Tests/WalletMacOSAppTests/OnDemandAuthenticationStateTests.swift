import Testing
@testable import WalletMacOSApp

@Suite struct OnDemandAuthenticationStateTests {
    @Test func daemonRestartAlwaysRelocksTheRelayer() {
        #expect(RelayerAccessState.available(generation: 4).isAvailable(for: 4))
        #expect(!RelayerAccessState.available(generation: 4).isAvailable(for: 5))
        #expect(RelayerAccessState.available(generation: 4).afterDaemonRestart() == .locked)
        #expect(RelayerAccessState.installing(generation: 4).afterDaemonRestart() == .locked)
    }

    @Test func privacyCancellationReturnsToAnOrdinaryLockedState() {
        #expect(PrivacyUnlockState.unlocking.afterCancellation() == .locked)
        #expect(PrivacyUnlockState.failed("cancelled").afterCancellation() == .locked)
    }

    @Test func transientPrivacyBalanceFailuresKeepAnUnlockedHelperRetryable() {
        let errors: [Error] = [
            RailgunHelperClient.ClientError.rpcError(code: "upstreamUnavailable", message: "try again"),
            RailgunHelperClient.ClientError.ioFailed("read timed out"),
            RailgunHelperClient.ClientError.httpError("temporary response"),
            RailgunHelperClient.ClientError.decodeFailed("temporary payload"),
        ]

        for error in errors {
            #expect(!PrivacyBalanceRefreshFailurePolicy.requiresHelperReload(error))
            #expect(PrivacyBalanceRefreshFailurePolicy.nextUnlockState(after: error) == .loaded)
        }
    }

    @Test func unavailablePrivacyHelperRelocksBeforeSecretReload() {
        let errors: [Error] = [
            AppError.privacyAccountLocked,
            RailgunHelperClient.ClientError.connectFailed("socket disappeared"),
        ]

        for error in errors {
            #expect(PrivacyBalanceRefreshFailurePolicy.requiresHelperReload(error))
            #expect(PrivacyBalanceRefreshFailurePolicy.nextUnlockState(after: error) == .locked)
        }
    }

    @Test func relayerInstallLoadsOnlyActiveAndStillRetiringKeys() {
        let refs = RelayerKeyInstallPolicy.relevantKeyRefs(
            activeKeyRef: "active",
            fallbackKeyRef: "stale-cache",
            history: [
                .init(keyRef: "pending", lifecycle: "pending_funding"),
                .init(keyRef: "retiring", lifecycle: "retiring"),
                .init(keyRef: "retired", lifecycle: "retired"),
                .init(keyRef: "active", lifecycle: "active"),
            ]
        )
        #expect(refs == ["active", "retiring"])
    }

    @Test func relayerInstallUsesProvisionedFallbackBeforeFirstDaemonRecord() {
        #expect(RelayerKeyInstallPolicy.relevantKeyRefs(
            activeKeyRef: nil,
            fallbackKeyRef: "provisioned",
            history: []
        ) == ["provisioned"])
    }

    @Test func staleDaemonResultsNeverApplyToANewerGeneration() {
        #expect(RelayerGenerationGate.accepts(resultGeneration: 7, currentGeneration: 7))
        #expect(!RelayerGenerationGate.accepts(resultGeneration: 7, currentGeneration: 8))
    }

    @Test func resetPreflightAllowsManagedDaemonBinaryOverrides() throws {
        try WalletResetPreflight.ensureNoExternalSecretRuntimes(environment: [
            "LOCAL_WALLET_NODE_BIN": "/tmp/wallet-node",
            "WALLET_NODE_BIN": "/tmp/wallet-node",
        ])
    }

    @Test func resetPreflightRejectsAnExternallyManagedWalletNode() {
        #expect(throws: AppError.self) {
            try WalletResetPreflight.ensureNoExternalSecretRuntimes(environment: [
                "LOCAL_WALLET_NODE_HTTP_URL": "http://127.0.0.1:8080",
                "LOCAL_WALLET_NODE_TOKEN": "secret",
            ])
        }
    }

    @Test func externalWalletNodeTransportRequiresTLSOrLiteralLoopback() throws {
        let accepted = [
            "https://wallet-node.example/rpc",
            "http://127.0.0.1:8080",
            "http://127.42.0.9:8080",
            "http://[::1]:8080",
        ]
        for endpoint in accepted {
            let configuration = WalletNodeClient.Configuration.fromEnvironment(environment: [
                "LOCAL_WALLET_NODE_HTTP_URL": endpoint,
                "LOCAL_WALLET_NODE_TOKEN": "secret",
            ])
            #expect(configuration != nil, "expected \(endpoint) to be accepted")
        }

        let rejected = [
            "http://wallet-node.example/rpc",
            "http://localhost:8080",
            "http://localhost.:8080",
            "http://0.0.0.0:8080",
            "http://192.168.1.10:8080",
            "ftp://127.0.0.1:8080",
            "https://user:password@wallet-node.example/rpc",
        ]
        for endpoint in rejected {
            let configuration = WalletNodeClient.Configuration.fromEnvironment(environment: [
                "LOCAL_WALLET_NODE_HTTP_URL": endpoint,
                "LOCAL_WALLET_NODE_TOKEN": "secret",
            ])
            #expect(configuration == nil, "expected \(endpoint) to be rejected")
        }
    }

    @Test func resetPreflightRejectsAnyExternalPrivacyHelperConfiguration() {
        #expect(throws: AppError.self) {
            try WalletResetPreflight.ensureNoExternalSecretRuntimes(environment: [
                "LOCAL_WALLET_PRIVACY_SOCKET": "/tmp/privacy.sock",
            ])
        }
        #expect(throws: AppError.self) {
            try WalletResetPreflight.ensureNoExternalSecretRuntimes(environment: [
                "LOCAL_WALLET_PRIVACY_TOKEN": "secret",
            ])
        }
    }

    @Test @MainActor func resetPreflightRejectsAnotherLocalWalletProcess() throws {
        try WalletResetPreflight.ensureNoOtherLocalWalletInstance(
            currentProcessID: 101,
            runningProcessIDs: [101]
        )
        #expect(throws: AppError.self) {
            try WalletResetPreflight.ensureNoOtherLocalWalletInstance(
                currentProcessID: 101,
                runningProcessIDs: [101, 202]
            )
        }
    }
}
