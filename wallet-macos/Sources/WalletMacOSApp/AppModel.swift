import Foundation
import LocalAuthentication
import WalletToolLayer
import WalletSignature

// AppModel drives the signed macOS demo shell. It is intentionally opinionated
// around the current demo scope (Sepolia, ETH transfer first, local wallet-node)
// and should not be treated as the final wallet product architecture.
@MainActor
final class AppModel: ObservableObject {
    struct UserOperationSendResult: Equatable {
        let userOpHash: String
        let transactionHash: String?
        let success: Bool?
    }

    @Published private(set) var walletRecord: WalletRecord?
    @Published private(set) var bridgeStatus = "Not checked"
    @Published private(set) var lastError: String?
    @Published private(set) var isBootstrapping = false
    @Published private(set) var isRunningDemo = false
    @Published private(set) var isRefreshingBalance = false
    @Published private(set) var isBuildingUserOperation = false
    @Published private(set) var isSendingUserOperation = false
    @Published private(set) var configuration: DemoAppConfiguration
    @Published private(set) var accountInspection: AccountInspection?
    @Published private(set) var transactionComposer = TransactionComposerState()
    @Published private(set) var builtUserOperationDraft: UserOperationDraft?
    @Published private(set) var lastUserOperationBuildError: String?
    @Published private(set) var activeBundlerStatus = "Bundler not checked"
    @Published private(set) var lastSubmittedUserOperationHash: String?
    @Published private(set) var lastBundledTransactionHash: String?
    @Published private(set) var debugLogText = ""
    @Published private(set) var localRelayerStatus: WalletNodeClient.RelayerStatus?
    @Published private(set) var localRelayerMessage = "Local daemon not connected"
    @Published private(set) var isRefreshingLocalRelayer = false
    @Published private(set) var isRotatingLocalRelayer = false
    @Published private(set) var isExportingLocalRelayer = false
    @Published private(set) var isDeletingLocalRelayer = false
    @Published private(set) var unlockRelayerOnLaunch: Bool
    @Published private(set) var liveGasPrice: WalletNodeClient.UserOperationGasPrice?
    @Published private(set) var liveBaseFeeWei: Data?
    @Published private(set) var liveGasUpdatedAt: Date?
    @Published private(set) var reconcilerUpdatedAt: Date?

    var activeChain: ChainConfiguration {
        configuration.activeChain
    }

    var networkSettings: DemoNetworkSettings {
        configuration.networkSettings
    }

    var hasLocalRelayerClient: Bool {
        walletNodeClient != nil || WalletNodeClient.Configuration.fromEnvironment() == nil
    }

    var canChangeNetworkSettings: Bool {
        NetworkSettingsGate.allowed(
            isBootstrapping: isBootstrapping,
            isRunningDemo: isRunningDemo,
            isRefreshingBalance: isRefreshingBalance,
            isBuildingUserOperation: isBuildingUserOperation,
            isSendingUserOperation: isSendingUserOperation
        )
    }

    private let keyStore: KeyStore
    private let metadataStore: WalletMetadataStore
    private let settingsStore: DemoSettingsStore
    private let onboardingSettingsStore: OnboardingSettingsStore
    private let kernelAccountAddressPredictor: KernelAccountAddressPredictor
    private var walletNodeClient: WalletNodeClient?
    private var walletNodeDaemon: WalletNodeDaemon?
    private var walletNodeLaunchTask: Task<WalletNodeDaemon, Error>?
    private var walletNodeLaunchFailure: WalletNodeLaunchFailure?
    private var optimisticNextNonce: [String: UInt64] = [:]
    private var pendingSessionInstallByUserOpHash: [String: SessionRecord] = [:]
    private var reconcilerTask: Task<Void, Never>?
    private let userOperationBuilder: UserOperationBuilder
    private let walletHistoryStore: WalletTransactionHistoryStore
    private static let startupInspectionRetryDelays: [UInt64] = [
        500_000_000,
        1_250_000_000,
        2_000_000_000,
    ]
    private static let walletNodeWarmupRetryDelays: [UInt64] = [
        500_000_000,
        1_250_000_000,
        2_000_000_000,
    ]
    private static let walletNodeLaunchFailureCooldownSeconds: TimeInterval = 4
    private static let relayerBalanceRetryDelays: [UInt64] = [
        400_000_000,
        900_000_000,
        1_500_000_000,
    ]
    static let reconcilerBackoffDelays: [UInt64] = [
        2_000_000_000,
        4_000_000_000,
        8_000_000_000,
        15_000_000_000,
        30_000_000_000,
    ]

    static func reconcilerDelay(forAttempt attempt: Int) -> UInt64 {
        reconcilerBackoffDelays[min(max(attempt, 0), reconcilerBackoffDelays.count - 1)]
    }

    init(
        keyStore: KeyStore = KeyStore(),
        metadataStore: WalletMetadataStore = WalletMetadataStore(),
        settingsStore: DemoSettingsStore = DemoSettingsStore(),
        onboardingSettingsStore: OnboardingSettingsStore = OnboardingSettingsStore(),
        kernelAccountAddressPredictor: KernelAccountAddressPredictor = KernelAccountAddressPredictor(),
        walletNodeClient: WalletNodeClient? = WalletNodeClient.Configuration.fromEnvironment().map {
            WalletNodeClient(configuration: $0)
        },
        userOperationBuilder: UserOperationBuilder = UserOperationBuilder(),
        walletHistoryStore: WalletTransactionHistoryStore = WalletTransactionHistoryStore()
    ) {
        self.keyStore = keyStore
        self.metadataStore = metadataStore
        self.settingsStore = settingsStore
        self.onboardingSettingsStore = onboardingSettingsStore
        self.kernelAccountAddressPredictor = kernelAccountAddressPredictor
        self.walletNodeClient = walletNodeClient
        self.userOperationBuilder = userOperationBuilder
        self.walletHistoryStore = walletHistoryStore
        self.configuration = DemoAppConfiguration(networkSettings: settingsStore.networkSettings)
        self.unlockRelayerOnLaunch = settingsStore.unlockRelayerOnLaunch
        self.localRelayerMessage = walletNodeClient == nil
            ? "Local wallet-node daemon will start on refresh."
            : "Local wallet-node daemon configured from environment."
    }

    func bootstrap() {
        guard !isBootstrapping else {
            return
        }

        appendSection("Bootstrap")

        isBootstrapping = true
        lastError = nil
        accountInspection = nil
        builtUserOperationDraft = nil
        lastUserOperationBuildError = nil
        activeBundlerStatus = "Bundler not checked"
        lastSubmittedUserOperationHash = nil
        lastBundledTransactionHash = nil

        var shouldInspectAfterBootstrap = false

        do {
            appendLog("bootstrap: active chain \(activeChain.name) (\(activeChain.id))")
            appendLog("bootstrap: key tag \(keyStore.keyTag)")

            let now = Date()

            if let existing = try metadataStore.load() {
                appendLog("bootstrap: loaded wallet metadata for \(existing.walletId.uuidString)")

                if existing.keyTag != keyStore.keyTag {
                    appendLog("bootstrap: stored metadata does not match the current Secure Enclave key")

                    let hasExistingKey = try keyStore.loadKey() != nil
                    guard !hasExistingKey else {
                        appendLog("bootstrap: refusing automatic recovery because an existing key was loaded")
                        throw AppError.metadataKeyMismatch
                    }

                    let coordinates = try keyStore.publicKeyCoordinates()
                    appendLog("bootstrap: public key x=\(coordinates.x.shortHex) y=\(coordinates.y.shortHex)")

                    appendLog("bootstrap: replacing stale metadata for the newly created key")
                    try metadataStore.clear()

                    let created = try createFreshWalletRecord(coordinates: coordinates, now: now)
                    try metadataStore.save(created)
                    walletRecord = created
                        appendLog("bootstrap: stored new wallet record with predicted account \(created.kernelAccountAddress ?? "unavailable")")
                    shouldInspectAfterBootstrap = true
                } else {
                    let coordinates = PublicKeyCoordinates(
                        x: existing.pubkeyX,
                        y: existing.pubkeyY
                    )
                    appendLog("bootstrap: using cached public key x=\(coordinates.x.shortHex) y=\(coordinates.y.shortHex)")

                    let predictedAddress = try kernelAccountAddressPredictor.predictedAddress(
                        chain: activeChain,
                        publicKey: coordinates,
                        authenticatorIdHash: existing.authenticatorIdHash,
                        salt: existing.kernelSalt
                    )

                    let refreshed = WalletRecord(
                        walletId: existing.walletId,
                        keyTag: existing.keyTag,
                        pubkeyX: existing.pubkeyX,
                        pubkeyY: existing.pubkeyY,
                        chainId: activeChain.id,
                        kernelAccountAddress: predictedAddress,
                        authenticatorIdHash: existing.authenticatorIdHash,
                        kernelSalt: existing.kernelSalt,
                        sessionRecords: existing.sessionRecords,
                        isDeployed: existing.isDeployed,
                        createdAt: existing.createdAt,
                        updatedAt: now
                    )
                    try metadataStore.save(refreshed)
                    walletRecord = refreshed
                    appendLog("bootstrap: refreshed predicted account \(predictedAddress)")
                    shouldInspectAfterBootstrap = true
                }
            } else {
                appendLog("bootstrap: metadata store empty; creating the first wallet record")

                let hasExistingKey = try keyStore.loadKey() != nil
                appendLog(
                    hasExistingKey
                        ? "bootstrap: found existing Secure Enclave key reference in Keychain"
                        : "bootstrap: no existing Secure Enclave key found; creating a new device-bound key"
                )

                let coordinates = try keyStore.publicKeyCoordinates()
                appendLog("bootstrap: public key x=\(coordinates.x.shortHex) y=\(coordinates.y.shortHex)")

                let created = try createFreshWalletRecord(coordinates: coordinates, now: now)
                try metadataStore.save(created)
                walletRecord = created
                appendLog("bootstrap: stored new wallet record with predicted account \(created.kernelAccountAddress ?? "unavailable")")
                shouldInspectAfterBootstrap = true
            }

            bridgeStatus = "Demo wallet ready. The app will inspect the smart account and let you compose a test transaction."
            appendLog("bootstrap: completed successfully")
        } catch {
            lastError = error.localizedDescription
            bridgeStatus = "Bootstrap failed"
            appendLog("bootstrap: failed — \(error.localizedDescription)")
        }

        isBootstrapping = false

        if shouldInspectAfterBootstrap {
            runDemo()
        }
        if unlockRelayerOnLaunch {
            refreshLocalRelayerStatus()
        } else {
            localRelayerMessage = "Local relayer unlock on launch is disabled."
        }
    }

    private func createFreshWalletRecord(coordinates: PublicKeyCoordinates, now: Date) throws -> WalletRecord {
        let authenticatorIdHash = KernelAccountAddressPredictor.defaultAuthenticatorIdHash
        let kernelSalt = KernelAccountAddressPredictor.defaultSalt
        let predictedAddress = try kernelAccountAddressPredictor.predictedAddress(
            chain: activeChain,
            publicKey: coordinates,
            authenticatorIdHash: authenticatorIdHash,
            salt: kernelSalt
        )

        return WalletRecord(
            walletId: UUID(),
            keyTag: keyStore.keyTag,
            pubkeyX: coordinates.x,
            pubkeyY: coordinates.y,
            chainId: activeChain.id,
            kernelAccountAddress: predictedAddress,
            authenticatorIdHash: authenticatorIdHash,
            kernelSalt: kernelSalt,
            isDeployed: false,
            createdAt: now,
            updatedAt: now
        )
    }

    func resetDemoWallet() {
        guard !isBootstrapping, !isRunningDemo, !isRefreshingBalance, !isBuildingUserOperation, !isSendingUserOperation else {
            appendLog("reset: ignored because another wallet operation is still running")
            return
        }

        appendSection("Reset Demo Wallet")

        do {
            try keyStore.deleteKey()
            appendLog("reset: deleted Secure Enclave key for tag \(keyStore.keyTag)")
            try BundlerKeyStore.shared.deleteAll()
            appendLog("reset: deleted local relayer keys")
            try metadataStore.clear()
            appendLog("reset: cleared local wallet metadata")

            walletRecord = nil
            accountInspection = nil
            builtUserOperationDraft = nil
            lastUserOperationBuildError = nil
            lastSubmittedUserOperationHash = nil
            lastBundledTransactionHash = nil
            activeBundlerStatus = "Bundler not checked"
            lastError = nil
            bridgeStatus = "Demo wallet reset. Creating a fresh Secure Enclave key…"
            appendLog("reset: starting fresh bootstrap")
        } catch {
            lastError = error.localizedDescription
            bridgeStatus = "Demo wallet reset failed"
            appendLog("reset: failed — \(error.localizedDescription)")
            return
        }

        bootstrap()
    }

    func runDemo() {
        guard !isRunningDemo, !isRefreshingBalance, walletRecord != nil else {
            return
        }

        appendSection("Inspect Account")

        isRunningDemo = true
        lastError = nil
        bridgeStatus = "Checking \(activeChain.name) for smart-account deployment and balance…"

        Task {
            do {
                let inspection = try await refreshAccountInspectionWithRetry(logContext: "inspect")

                bridgeStatus = inspection.isDeployed
                    ? "Account deployed on \(activeChain.name). Balance loaded."
                    : "Account is precomputed on \(activeChain.name). It can be funded now and will be deployed automatically by the first UserOperation."
            } catch {
                lastError = error.localizedDescription
                bridgeStatus = "Account inspection failed"
                appendLog("inspect: failed — \(error.localizedDescription)")
            }

            isRunningDemo = false
        }
    }

    func refreshBalance() {
        guard !isBootstrapping, !isRunningDemo, !isRefreshingBalance, !isBuildingUserOperation, !isSendingUserOperation else {
            appendLog("refresh-balance: ignored because another wallet operation is still running")
            return
        }

        guard walletRecord != nil else {
            appendLog("refresh-balance: ignored because wallet bootstrap has not completed")
            return
        }

        appendSection("Refresh Balance")

        isRefreshingBalance = true

        Task {
            do {
                _ = try await refreshAccountInspection(logContext: "refresh-balance")
                appendLog("refresh-balance: completed quietly")
            } catch {
                appendLog("refresh-balance: failed — \(error.localizedDescription)")
            }

            isRefreshingBalance = false
        }
    }

    func refreshOnchainAccountStatus() {
        appendSection("Refresh Onchain Status")
        refreshBalance()
        refreshLocalRelayerStatus()
    }

    func setTestnetModeEnabled(_ isEnabled: Bool) {
        guard configuration.isTestnetModeEnabled != isEnabled else {
            return
        }

        appendSection("Switch Chain")
        appendLog("chain: toggled testnet mode \(isEnabled ? "on" : "off")")

        var settings = networkSettings
        settings.isTestnetModeEnabled = isEnabled
        settingsStore.setNetworkSettings(settings)
        configuration = DemoAppConfiguration(networkSettings: settings)
        resetWalletNodeConnectionAfterNetworkChange()
        accountInspection = nil
        builtUserOperationDraft = nil
        lastUserOperationBuildError = nil
        activeBundlerStatus = "Bundler not checked"
        lastSubmittedUserOperationHash = nil
        lastBundledTransactionHash = nil
        bootstrap()
    }

    func updateNetworkSettings(_ settings: DemoNetworkSettings) throws {
        let validated = try settings.validated()
        let currentSettings = configuration.networkSettings
        guard currentSettings != validated else {
            return
        }
        guard canChangeNetworkSettings else {
            throw AppError.walletOperationInProgress
        }
        let requiresWalletNodeRestart = NetworkSettingsChangePolicy.requiresWalletNodeRestart(
            from: currentSettings,
            to: validated
        )

        appendSection("Update Network Settings")
        appendLog("network: active profile \(validated.activeNetworkName)")
        appendLog("network: execution RPC \(validated.activeRPCURL)")
        appendLog("network: gas caps max \(validated.activeMaxFeePerGasGwei) gwei, priority \(validated.activeMaxPriorityFeePerGasGwei) gwei")
        settingsStore.setNetworkSettings(validated)
        configuration = DemoAppConfiguration(networkSettings: validated)
        builtUserOperationDraft = nil
        lastUserOperationBuildError = nil

        guard requiresWalletNodeRestart else {
            appendLog("network: applied app-only settings without restarting wallet-node")
            Task { await refreshLiveGasPrices() }
            return
        }

        resetWalletNodeConnectionAfterNetworkChange()
        accountInspection = nil
        activeBundlerStatus = "Bundler not checked"
        lastSubmittedUserOperationHash = nil
        lastBundledTransactionHash = nil
        bootstrap()
    }

    func setUnlockRelayerOnLaunch(_ isEnabled: Bool) {
        guard unlockRelayerOnLaunch != isEnabled else {
            return
        }
        settingsStore.setUnlockRelayerOnLaunch(isEnabled)
        unlockRelayerOnLaunch = isEnabled
        appendLog("security: unlock relayer on launch \(isEnabled ? "enabled" : "disabled")")
        if isEnabled, localRelayerStatus == nil {
            refreshLocalRelayerStatus()
        } else if !isEnabled, localRelayerStatus == nil {
            localRelayerMessage = "Local relayer unlock on launch is disabled."
        }
    }

    func testNetworkSettings(_ settings: DemoNetworkSettings) async throws -> String {
        let validated = try settings.validated()
        let chain = validated.activeChain
        let remoteChainID = try await Self.probeExecutionChainID(rpcURL: chain.rpcURL)
        guard remoteChainID == chain.id else {
            throw AppError.localDaemonLaunchFailed("RPC returned chain ID \(remoteChainID), expected \(chain.id).")
        }
        return "\(chain.name) RPC responded with chain ID \(remoteChainID)."
    }

    private func resetWalletNodeConnectionAfterNetworkChange() {
        walletNodeLaunchTask?.cancel()
        walletNodeLaunchTask = nil
        walletNodeLaunchFailure = nil
        walletNodeDaemon = nil
        walletNodeClient = WalletNodeClient.Configuration.fromEnvironment().map {
            WalletNodeClient(configuration: $0)
        }
        optimisticNextNonce.removeAll()
        liveGasPrice = nil
        liveBaseFeeWei = nil
        liveGasUpdatedAt = nil
        localRelayerStatus = nil
        localRelayerMessage = walletNodeClient == nil
            ? "Local wallet-node daemon will restart with the selected network."
            : "External wallet-node is configured from environment."
    }

    func setTransactionKind(_ kind: DemoTransactionKind) {
        transactionComposer.selectedKind = kind
        builtUserOperationDraft = nil
        lastUserOperationBuildError = nil
        appendLog("composer: selected transaction type \(kind.rawValue)")
    }

    func updateRecipient(_ recipient: String) {
        transactionComposer.recipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        builtUserOperationDraft = nil
        lastUserOperationBuildError = nil
    }

    func updateAmountETH(_ amount: String) {
        transactionComposer.amountETH = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        builtUserOperationDraft = nil
        lastUserOperationBuildError = nil
    }

    func clearDebugLog() {
        debugLogText = ""
        appendLog("log: cleared debug activity panel")
    }

    func debugSessionReport(snapshot: LocalWalletSettingsSnapshot) async -> String {
        appendLog("debug: collecting session report")

        var lines: [String] = [
            "Local Wallet Debug Report",
            "generatedAt=\(Self.debugReportDateFormatter.string(from: Date()))",
            "capturedAt=\(Self.debugReportDateFormatter.string(from: snapshot.capturedAt))",
            "",
            "[app]",
            "version=\(snapshot.appVersion) build=\(snapshot.appBuild)",
            "walletNodeMode=\(snapshot.walletNodeMode)",
            "walletNodeConfig=\(snapshot.walletNodeConfigPath)",
            "walletNodeLog=\(snapshot.walletNodeLogPath)",
            "bridgeStatus=\(bridgeStatus)",
            "activeBundlerStatus=\(activeBundlerStatus)",
            "lastError=\(lastError ?? "None")",
            "",
            "[chain]",
            "name=\(activeChain.name)",
            "chainId=\(activeChain.id)",
            "executionRPC=\(activeChain.rpcURL.absoluteString)",
            "archiveRPC=\(activeChain.archiveRPCURL?.absoluteString ?? "Not set")",
            "consensusRPC=\(activeChain.consensusRPCURL.absoluteString)",
            "entryPoint=\(activeChain.entryPoint)",
            "",
            "[wallet]",
            "kernelAccount=\(walletRecord?.kernelAccountAddress ?? snapshot.kernelAccountAddress)",
            "accountState=\(accountInspection?.stateTitle ?? snapshot.kernelAccountState)",
            "accountBalance=\(accountInspection?.balanceDisplay ?? snapshot.kernelAccountBalance)",
            "lastUserOp=\(lastSubmittedUserOperationHash ?? "None")",
            "lastBundleTx=\(lastBundledTransactionHash ?? "None")",
            "isSendingUserOperation=\(isSendingUserOperation)",
            "isBuildingUserOperation=\(isBuildingUserOperation)",
            "",
            "[networkStatus]",
        ]
        lines.append(contentsOf: await debugNetworkStatusLines())
        lines.append("")
        lines.append("[bundlerStatus]")
        lines.append(contentsOf: await debugBundlerStatusLines())
        lines.append("")
        lines.append("[history]")
        lines.append(contentsOf: debugHistoryLines())
        lines.append("")
        lines.append("[debugLog]")
        lines.append(debugLogText.isEmpty ? "No debug log entries." : debugLogText)
        lines.append("")
        lines.append("[walletNodeLogTail]")
        lines.append(WalletNodeClient.Configuration.fromEnvironment() == nil
            ? WalletNodeDaemon.managedLogTail()
            : "External wallet-node is configured. Inspect the daemon's own configured logs directory.")
        return lines.joined(separator: "\n")
    }

    private func debugNetworkStatusLines() async -> [String] {
        do {
            let status = try await withWalletNodeClient(operation: "debug network status") { client in
                try await client.networkStatus()
            }
            var lines = [
                "status=\(status.status)",
                "reason=\(status.reason ?? "None")",
                "chainId=\(status.chainId)",
                "profile=\(status.networkProfile)",
                "helios.ready=\(status.helios.ready)",
                "helios.checkpointLoaded=\(status.helios.checkpointLoaded)",
                "helios.checkpointAgeDays=\(status.helios.checkpointAgeDays.map { String(format: "%.3f", $0) } ?? "None")",
            ]
            if let head = status.helios.head {
                lines.append("helios.head=#\(head.number) \(head.hash)")
            } else {
                lines.append("helios.head=None")
            }
            if let bundler = status.bundler {
                lines.append("bundler.ready=\(bundler.ready)")
                lines.append("bundler.needsTopup=\(bundler.needsTopup.map(String.init) ?? "None")")
                lines.append("bundler.reason=\(bundler.reason ?? "None")")
                lines.append("bundler.eoa=\(bundler.eoa ?? "None")")
            } else {
                lines.append("bundler=None")
            }
            return lines
        } catch {
            return ["error=\(error.localizedDescription)"]
        }
    }

    private func debugBundlerStatusLines() async -> [String] {
        do {
            let status = try await fetchLocalRelayerStatusWithBalanceRetry()
            localRelayerStatus = status
            localRelayerMessage = status.ready
                ? "Local relayer ready on \(status.networkProfile)."
                : "Local relayer needs attention."
            return [
                "ready=\(status.ready)",
                "ownerScope=\(status.ownerScope)",
                "chainId=\(status.chainId)",
                "profile=\(status.networkProfile)",
                "eoa=\(status.eoa)",
                "keyRef=\(status.keyRef ?? "None")",
                "lifecycle=\(status.lifecycle)",
                "balance=\(status.balance)",
                "thresholdLow=\(status.thresholdLow)",
                "needsTopup=\(status.needsTopup)",
                "pendingFundingAddress=\(status.pendingFundingAddress ?? "None")",
                "pendingFundingCount=\(status.pendingFundingCount)",
                "retiringCount=\(status.retiringCount)",
                "latestAuditEvent=\(status.latestAuditEvent ?? "None")",
                "replacement.eligible=\(status.replacement.map { String($0.eligible) } ?? "None")",
                "replacement.blocked=\(status.replacement.map { String($0.blocked) } ?? "None")",
                "replacement.reason=\(status.replacement?.blockedReason ?? "None")",
                "replacement.txHash=\(status.replacement?.txHash ?? "None")",
                "replacement.userOpHash=\(status.replacement?.userOpHash ?? "None")",
            ]
        } catch {
            return ["error=\(error.localizedDescription)"]
        }
    }

    private func debugHistoryLines(limit: Int = 5) -> [String] {
        do {
            let records = try walletHistoryStore.loadRecords(
                accountAddress: walletRecord?.kernelAccountAddress,
                chainID: activeChain.id,
                limit: limit
            )
            guard !records.isEmpty else {
                return ["No local transaction history rows for this account/chain."]
            }
            return records.enumerated().map { index, record in
                [
                    "history[\(index)]",
                    "status=\(record.status.rawValue)",
                    "operation=\(record.operation.rawValue)",
                    "userOp=\(record.userOpHash)",
                    "tx=\(record.transactionHash ?? "None")",
                    "success=\(record.debugSuccessText)",
                    "revertReason=\(record.revertReason ?? "None")",
                ].joined(separator: " ")
            }
        } catch {
            return ["error=\(error.localizedDescription)"]
        }
    }

    func refreshLocalRelayerStatus() {
        guard !isRefreshingLocalRelayer else {
            return
        }

        isRefreshingLocalRelayer = true
        Task {
            do {
                let status = try await fetchLocalRelayerStatusWithBalanceRetry()
                localRelayerStatus = status
                localRelayerMessage = status.ready
                    ? "Local relayer ready on \(status.networkProfile)."
                    : "Local relayer needs attention."
                appendLog("relayer: status \(status.lifecycle) \(status.eoa.shortAddress)")
            } catch {
                localRelayerStatus = nil
                localRelayerMessage = error.localizedDescription
                appendLog("relayer: status failed — \(error.localizedDescription)")
            }
            isRefreshingLocalRelayer = false
        }
    }

    func checkLocalRelayerStatusForDiagnostics() async throws -> WalletNodeClient.RelayerStatus {
        let status = try await fetchLocalRelayerStatusWithBalanceRetry()
        localRelayerStatus = status
        localRelayerMessage = status.ready
            ? "Local relayer ready on \(status.networkProfile)."
            : "Local relayer needs attention."
        appendLog("relayer: diagnostic status \(status.lifecycle) \(status.eoa.shortAddress)")
        return status
    }

    private func fetchLocalRelayerStatusWithBalanceRetry() async throws -> WalletNodeClient.RelayerStatus {
        var status = try await withWalletNodeClient(operation: "status") { client in
            try await client.bundlerStatus()
        }
        for delay in Self.relayerBalanceRetryDelays where Self.isRelayerBalanceUnavailable(status.balance) {
            localRelayerStatus = status
            localRelayerMessage = "Checking local relayer balance..."
            appendLog("relayer: status returned without balance; retrying")
            try await Task.sleep(nanoseconds: delay)
            status = try await withWalletNodeClient(operation: "status retry") { client in
                try await client.bundlerStatus()
            }
        }
        return status
    }

    func rotateLocalRelayerKey() async throws {
        guard !isRotatingLocalRelayer else {
            return
        }

        isRotatingLocalRelayer = true
        defer { isRotatingLocalRelayer = false }
        let walletNodeClient = try await ensureWalletNodeClient()
        appendSection("Rotate Local Relayer")
        let keyRef = nextBundlerKeyRef()
        let challenge = try await walletNodeClient.beginAdminAction(
            action: "install_bundler_eoa",
            chainId: localRelayerStatus?.chainId ?? Int(activeChain.id),
            keyRef: keyRef
        )
        try await authorizeLocalRelayerAdminAction(summary: challenge.summary)
        let record = try BundlerKeyStore.shared.createIfNeeded(keyRef: keyRef)
        let status = try await walletNodeClient.installBundlerEOA(
            keyRef: keyRef,
            secret: record.secret,
            authorization: WalletNodeClient.AdminAuthorization(
                adminActionId: challenge.adminActionId,
                nonce: challenge.nonce
            )
        )
        localRelayerStatus = status
        localRelayerMessage = "New relayer key is waiting for top-up."
        appendLog("relayer: rotation requested; active view \(status.eoa.shortAddress)")
    }

    private func nextBundlerKeyRef() -> String {
        let prefix = "bundler-eoa:default:\(activeChain.id):"
        let existingRefs = ([localRelayerStatus?.keyRef] + (localRelayerStatus?.keyHistory.map(\.keyRef) ?? []))
            .compactMap { $0 }
        let maxSuffix = existingRefs.compactMap { ref -> Int? in
            guard ref.hasPrefix(prefix) else {
                return nil
            }
            return Int(ref.dropFirst(prefix.count))
        }.max() ?? 0
        return "\(prefix)\(maxSuffix + 1)"
    }

    func exportLocalRelayerKey(
        keyRef targetKeyRef: String? = nil,
        label targetLabel: String? = nil
    ) async throws -> String {
        guard let status = localRelayerStatus, let keyRef = targetKeyRef ?? status.keyRef else {
            throw AppError.localRelayerKeyMissing
        }
        guard !isExportingLocalRelayer else {
            throw AppError.localRelayerKeyMissing
        }

        isExportingLocalRelayer = true
        defer { isExportingLocalRelayer = false }
        appendSection("Export Local Relayer")
        let record = try BundlerKeyStore.shared.read(
            keyRef: keyRef,
            reason: "Reveal the local relayer private key"
        )
        let privateKey = "0x" + record.secret.lowercaseHexString
        localRelayerMessage = "Relayer key exported after local authentication."
        appendLog("relayer: exported key for \(targetLabel ?? status.eoa.shortAddress)")
        refreshLocalRelayerStatus()
        return privateKey
    }

    func deleteLocalRelayerKey(
        keyRef targetKeyRef: String? = nil,
        label targetLabel: String? = nil,
        unsafeReset: Bool
    ) async throws {
        let walletNodeClient = try await ensureWalletNodeClient()
        guard let status = localRelayerStatus, let keyRef = targetKeyRef ?? status.keyRef else {
            throw AppError.localRelayerKeyMissing
        }
        guard !isDeletingLocalRelayer else {
            return
        }

        isDeletingLocalRelayer = true
        defer { isDeletingLocalRelayer = false }
        appendSection(unsafeReset ? "Unsafe Reset Local Relayer" : "Delete Local Relayer")
        let challenge = try await walletNodeClient.beginAdminAction(
            action: "delete_bundler_eoa",
            chainId: status.chainId,
            keyRef: keyRef
        )
        try await authorizeLocalRelayerAdminAction(summary: challenge.summary)
        try await walletNodeClient.deleteBundlerEOA(
            keyRef: keyRef,
            unsafeReset: unsafeReset,
            authorization: WalletNodeClient.AdminAuthorization(
                adminActionId: challenge.adminActionId,
                nonce: challenge.nonce
            )
        )
        try BundlerKeyStore.shared.delete(keyRef: keyRef)
        localRelayerStatus = nil
        localRelayerMessage = unsafeReset
            ? "Relayer key reset. Submissions stay blocked until a funded relayer exists."
            : "Relayer key deleted. Submissions stay blocked until a funded relayer exists."
        appendLog("relayer: \(unsafeReset ? "unsafe reset" : "delete") completed for \(targetLabel ?? status.eoa.shortAddress)")
        refreshLocalRelayerStatus()
    }

    @discardableResult
    func cancelPendingOperation(userOpHash: String) async -> Bool {
        defer { refreshLocalRelayerStatus() }
        do {
            appendSection("Cancel Pending Operation")
            let txHash = try await withWalletNodeClient(operation: "cancel pending") {
                try await $0.cancelPendingOperation(userOpHash: userOpHash)
            }
            appendLog("relayer: cancel submitted tx \(txHash ?? "<none>")")
            markCancellationSubmittedInHistory(userOpHash: userOpHash, txHash: txHash)
            clearOptimisticNonceForActiveWallet()
            bridgeStatus = "Cancellation submitted."
        } catch {
            let message = ReplacementActionFailurePolicy.displayMessage(
                action: "Cancellation",
                error: error
            )
            lastError = message
            bridgeStatus = message
            appendLog("relayer: cancel failed - \(message)")
            markReplacementUnavailableInHistory(
                userOpHash: userOpHash,
                error: error,
                logContext: "cancel"
            )
            return false
        }
        return true
    }

    private func markCancellationSubmittedInHistory(userOpHash: String, txHash: String?) {
        do {
            _ = try walletHistoryStore.markCancelled(
                userOpHash: userOpHash,
                chainID: activeChain.id,
                transactionHash: txHash
            )
            appendLog("cancel: marked local history cancelled")
        } catch {
            appendLog("cancel: local history cancellation mark failed - \(error.localizedDescription)")
        }
    }

    @discardableResult
    func speedUpPendingOperation(userOpHash: String) async -> Bool {
        defer { refreshLocalRelayerStatus() }
        do {
            appendSection("Speed Up Pending Operation")
            let txHash = try await withWalletNodeClient(operation: "speed up pending") {
                try await $0.speedUpPendingOperation(userOpHash: userOpHash)
            }
            appendLog("relayer: speed-up submitted tx \(txHash ?? "<none>")")
            bridgeStatus = "Speed-up submitted."
        } catch {
            let message = ReplacementActionFailurePolicy.displayMessage(
                action: "Speed-up",
                error: error
            )
            lastError = message
            bridgeStatus = message
            appendLog("relayer: speed-up failed - \(message)")
            markReplacementUnavailableInHistory(
                userOpHash: userOpHash,
                error: error,
                logContext: "speed-up"
            )
            return false
        }
        return true
    }

    private func markReplacementUnavailableInHistory(
        userOpHash: String,
        error: Error,
        logContext: String
    ) {
        guard ReplacementActionFailurePolicy.shouldMarkLocalHistoryFailed(error) else {
            return
        }
        do {
            guard var record = try walletHistoryStore.loadRecord(
                userOpHash: userOpHash,
                chainID: activeChain.id
            ) else {
                return
            }
            guard !record.status.isTerminal else {
                return
            }
            record.status = .failed
            record.updatedAt = Date()
            try walletHistoryStore.upsert(record)
            appendLog("\(logContext): marked local history failed because replacement cannot be signed")
        } catch {
            appendLog("\(logContext): local history failure mark failed - \(error.localizedDescription)")
        }
    }

    private func ensureWalletNodeClient() async throws -> WalletNodeClient {
        if let walletNodeClient {
            return walletNodeClient
        }
        if let walletNodeLaunchTask {
            let daemon = try await walletNodeLaunchTask.value
            walletNodeDaemon = daemon
            walletNodeClient = daemon.client
            return daemon.client
        }
        if let walletNodeLaunchFailure {
            let now = Date()
            if WalletNodeLaunchFailureGate.shouldBlockRetry(
                now: now,
                retryAfter: walletNodeLaunchFailure.retryAfter
            ) {
                throw walletNodeLaunchFailure.error
            }
            self.walletNodeLaunchFailure = nil
        }

        localRelayerMessage = "Starting local wallet-node daemon..."
        let keyRef = "bundler-eoa:default:\(activeChain.id):1"
        let chain = activeChain
        let gasPolicy = networkSettings.resolvedDaemonGasPolicy
        let launchTask = Task {
            let bundlerSecret = try BundlerKeyStore.shared.unlockForDaemonLaunch(keyRef: keyRef)
            syncUnlockedRelayerAddress(keyRef: keyRef, secret: bundlerSecret.secret)
            return try await WalletNodeDaemon.launch(
                bundlerSecret: bundlerSecret,
                chain: chain,
                gasPolicy: gasPolicy
            )
        }
        walletNodeLaunchTask = launchTask

        do {
            let daemon = try await launchTask.value
            walletNodeLaunchTask = nil
            walletNodeLaunchFailure = nil
            walletNodeDaemon = daemon
            walletNodeClient = daemon.client
            localRelayerMessage = "Local wallet-node daemon connected."
            appendLog("relayer: wallet-node daemon started")
            if let logURL = WalletNodeDaemon.managedLogFileURL() {
                appendLog("relayer: wallet-node logs \(logURL.path)")
            }
            return daemon.client
        } catch {
            walletNodeLaunchTask = nil
            walletNodeLaunchFailure = WalletNodeLaunchFailure(
                error: error,
                retryAfter: WalletNodeLaunchFailureGate.retryAfter(
                    now: Date(),
                    cooldown: Self.walletNodeLaunchFailureCooldownSeconds
                )
            )
            throw error
        }
    }

    private func syncUnlockedRelayerAddress(keyRef: String, secret: Data) {
        do {
            let address = try RelayerAddressCachePolicy.address(fromSecret: secret)
            onboardingSettingsStore.bundlerKeyRef = keyRef
            guard RelayerAddressCachePolicy.shouldUpdate(
                cached: onboardingSettingsStore.bundlerAddress,
                unlocked: address
            ) else {
                return
            }

            onboardingSettingsStore.bundlerAddress = address
            appendLog("relayer: synced cached relayer address \(address.shortAddress)")
        } catch {
            appendLog("relayer: could not sync cached relayer address - \(error.localizedDescription)")
        }
    }

    private func withWalletNodeClient<T: Sendable>(
        operation: String,
        _ body: (WalletNodeClient) async throws -> T
    ) async throws -> T {
        let client = try await ensureWalletNodeClient()

        do {
            return try await body(client)
        } catch {
            guard client.usesUnixSocketTransport,
                  walletNodeDaemon != nil,
                  WalletNodeClient.isRecoverableUnixSocketFailure(error)
            else {
                throw error
            }

            appendLog("relayer: \(operation) lost wallet-node socket; relaunching daemon and retrying once")
            walletNodeLaunchTask = nil
            walletNodeClient = nil
            walletNodeDaemon = nil

            let relaunchedClient = try await ensureWalletNodeClient()
            return try await body(relaunchedClient)
        }
    }

    private func withWalletNodeWarmupRetry<T: Sendable>(
        operation: String,
        _ body: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0...Self.walletNodeWarmupRetryDelays.count {
            do {
                return try await body()
            } catch {
                lastError = error
                guard attempt < Self.walletNodeWarmupRetryDelays.count,
                      WalletNodeWarmupRetryPolicy.isWarmupError(error)
                else {
                    throw error
                }

                appendLog(
                    "relayer: \(operation) waiting for verified wallet-node reads; retrying after \(error.localizedDescription)"
                )
                try await Task.sleep(nanoseconds: Self.walletNodeWarmupRetryDelays[attempt])
            }
        }
        throw lastError ?? AppError.localDaemonLaunchFailed("wallet-node warm-up retry ended without an error")
    }

    private func authorizeLocalRelayerAdminAction(summary: String) async throws {
        let context = LAContext()
        context.localizedReason = summary
        try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: summary) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? AppError.localRelayerKeyMissing)
                }
            }
        }
    }

    func buildCurrentUserOperationDraft(isDeployedOverride: Bool? = nil) async throws -> UserOperationDraft {
        try await buildUserOperationDraft(
            intent: .nativeTransfer(
                recipient: transactionComposer.recipient,
                amountETH: transactionComposer.amountETH
            ),
            isDeployedOverride: isDeployedOverride
        )
    }

    func buildUserOperationDraft(
        intent: TransactionIntent,
        isDeployedOverride: Bool? = nil,
        nonceKey192: Data? = nil
    ) async throws -> UserOperationDraft {
        guard let walletRecord else {
            throw AppError.corruptedMetadataStore
        }

        let publicKey = PublicKeyCoordinates(
            x: walletRecord.pubkeyX,
            y: walletRecord.pubkeyY
        )
        guard let sender = walletRecord.kernelAccountAddress else {
            throw AppError.invalidCounterfactualAddress
        }

        appendLog("build: reading EntryPoint nonce through local wallet-node")
        let nonceHex = try await resolvedNonceHex(
            entryPoint: activeChain.entryPoint,
            sender: sender,
            nonceKey192: nonceKey192
        )

        return try userOperationBuilder.buildDraft(
            walletRecord: walletRecord,
            publicKey: publicKey,
            chain: activeChain,
            isDeployed: isDeployedOverride ?? accountInspection?.isDeployed ?? walletRecord.isDeployed,
            nonceHex: nonceHex,
            intent: intent
        )
    }

    func buildUserOperationDraft(
        executions: [KernelExecutionRequest],
        isDeployedOverride: Bool? = nil,
        nonceKey192: Data? = nil
    ) async throws -> UserOperationDraft {
        guard let walletRecord else {
            throw AppError.corruptedMetadataStore
        }

        let publicKey = PublicKeyCoordinates(
            x: walletRecord.pubkeyX,
            y: walletRecord.pubkeyY
        )
        guard let sender = walletRecord.kernelAccountAddress else {
            throw AppError.invalidCounterfactualAddress
        }

        appendLog("build: reading EntryPoint nonce through local wallet-node")
        let nonceHex = try await resolvedNonceHex(
            entryPoint: activeChain.entryPoint,
            sender: sender,
            nonceKey192: nonceKey192
        )

        return try userOperationBuilder.buildDraft(
            walletRecord: walletRecord,
            publicKey: publicKey,
            chain: activeChain,
            isDeployed: isDeployedOverride ?? accountInspection?.isDeployed ?? walletRecord.isDeployed,
            nonceHex: nonceHex,
            executions: executions
        )
    }

    private func resolvedNonceHex(
        entryPoint: String,
        sender: String,
        nonceKey192: Data? = nil
    ) async throws -> String {
        let onChainHex = try await withWalletNodeWarmupRetry(operation: "EntryPoint nonce read") {
            try await withWalletNodeClient(operation: "EntryPoint nonce read") { client in
                if let nonceKey192 {
                    return try await client.entryPointNonce(
                        entryPoint: entryPoint,
                        accountAddress: sender,
                        nonceKey192: nonceKey192
                    )
                }
                return try await client.entryPointNonce(entryPoint: entryPoint, accountAddress: sender, nonceKey: 0)
            }
        }
        let onChainData = try Data(hexString: onChainHex).leftPadded(to: 32)
        let onChain = try nonceSequence(from: onChainData)
        let nonceKey = try normalizedNonceKey192(nonceKey192)
        let key = nonceCacheKey(chainID: activeChain.id, sender: sender, nonceKey: nonceKey)
        let effective = NonceClamp.effective(onChain: onChain, optimistic: optimisticNextNonce[key])
        return nonceHex(nonceKey192: nonceKey, sequence: effective)
    }

    private func recordOptimisticNonce(after draft: UserOperationDraft) {
        guard let used = try? nonceSequence(from: draft.nonce) else {
            return
        }
        let nonceKey = nonceKey192(fromFullNonce: draft.nonce)
        let key = nonceCacheKey(chainID: activeChain.id, sender: draft.sender, nonceKey: nonceKey)
        optimisticNextNonce[key] = NonceClamp.next(after: used)
    }

    private func clearOptimisticNonceForActiveWallet() {
        guard let sender = walletRecord?.kernelAccountAddress else {
            return
        }
        let prefix = nonceCacheKeyPrefix(chainID: activeChain.id, sender: sender)
        let matchingKeys = optimisticNextNonce.keys.filter { $0.hasPrefix(prefix) }
        for key in matchingKeys {
            optimisticNextNonce.removeValue(forKey: key)
        }
    }

    private func nonceCacheKeyPrefix(chainID: UInt64, sender: String) -> String {
        "\(chainID):\(sender.lowercased()):"
    }

    private func nonceCacheKey(chainID: UInt64, sender: String, nonceKey: Data) -> String {
        nonceCacheKeyPrefix(chainID: chainID, sender: sender) + nonceKey.hexEncodedString
    }

    private func nonceSequence(from hex: String) throws -> UInt64 {
        try nonceSequence(from: Data(hexString: hex))
    }

    private func nonceSequence(from nonce: Data) throws -> UInt64 {
        let full = nonce.leftPadded(to: 32)
        guard full.count >= 8 else {
            throw AppError.invalidHexString
        }
        return full.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private func normalizedNonceKey192(_ nonceKey: Data?) throws -> Data {
        guard let nonceKey else {
            return Data(repeating: 0, count: 24)
        }
        if nonceKey.count == 24 {
            return nonceKey
        }
        guard nonceKey.count == 32, nonceKey.prefix(8).allSatisfy({ $0 == 0 }) else {
            throw AppError.invalidHexString
        }
        return Data(nonceKey.suffix(24))
    }

    private func nonceKey192(fromFullNonce nonce: Data) -> Data {
        Data(nonce.leftPadded(to: 32).prefix(24))
    }

    private func nonceHex(fromSequence sequence: UInt64) -> String {
        nonceHex(nonceKey192: Data(repeating: 0, count: 24), sequence: sequence)
    }

    private func nonceHex(nonceKey192: Data, sequence: UInt64) -> String {
        "0x" + (nonceKey192 + Data.fromBigEndian(sequence)).hexEncodedString
    }

    func buildUserOperationDraftPreview() {
        guard !isBootstrapping, !isBuildingUserOperation, !isSendingUserOperation else {
            appendLog("build: ignored because another wallet operation is still running")
            return
        }

        appendSection("Build Draft")

        isBuildingUserOperation = true
        lastUserOperationBuildError = nil
        builtUserOperationDraft = nil

        Task {
            do {
                appendLog("build: composing \(transactionComposer.selectedKind.rawValue) on \(activeChain.name)")
                let draft = try await buildCurrentUserOperationDraft()
                appendDraftLogSummary(draft, context: "build")

                let enrichedDraft = try await enrichDraftWithLocalBundlerEstimation(
                    draft,
                    logContext: "build"
                )
                builtUserOperationDraft = enrichedDraft

                let initCodeMode = enrichedDraft.initCode.isEmpty ? "existing account path" : "deployment path included"
                bridgeStatus = "Unsigned UserOperation draft built for \(activeChain.name) with \(initCodeMode). Gas estimated through local wallet-node."

                appendLog("build: completed successfully")
            } catch {
                lastUserOperationBuildError = error.localizedDescription
                activeBundlerStatus = "Bundler check failed"
                bridgeStatus = "UserOperation draft build failed"
                appendLog("build: failed — \(error.localizedDescription)")
            }

            isBuildingUserOperation = false
        }
    }

    func sendCurrentUserOperation() {
        guard !isBootstrapping, !isBuildingUserOperation, !isSendingUserOperation else {
            appendLog("send: ignored because another wallet operation is still running")
            return
        }

        Task {
            do {
                _ = try await executeNativeTransfer(
                    recipient: transactionComposer.recipient,
                    amountETH: transactionComposer.amountETH,
                    logContext: "send",
                    signingReason: "Authorize \(transactionComposer.selectedKind.rawValue) on \(activeChain.name)"
                )
            } catch {
                lastError = error.localizedDescription
                bridgeStatus = "UserOperation send failed"
                activeBundlerStatus = "Submission failed"
                appendLog("send: failed — \(error.localizedDescription)")
            }

            isSendingUserOperation = false
        }
    }

    @discardableResult
    func enableSessionKeys(now: Date = Date()) async throws -> SessionRecord {
        guard !isBootstrapping, !isBuildingUserOperation, !isSendingUserOperation else {
            throw AppError.walletOperationInProgress
        }
        if walletRecord == nil {
            bootstrap()
        }
        guard let record = walletRecord, let accountAddress = record.kernelAccountAddress else {
            throw AppError.corruptedMetadataStore
        }

        appendSection("Enable Session Keys")
        appendLog("session: checking deployed account state")
        let inspection = try await refreshAccountInspectionWithRetry(logContext: "session-enable")
        guard inspection.isDeployed else {
            throw AppError.sessionKeysRequireDeployedAccount
        }

        let keyRef = try SessionEnableAssembler.sessionKeyRef(
            chainID: activeChain.id,
            accountAddress: accountAddress
        )
        appendLog("session: loading session key \(keyRef)")
        let sessionKey = try SessionKeyStore.shared.createIfNeeded(keyRef: keyRef)

        appendLog("session: reading Kernel currentNonce")
        let validationNonce = try await withWalletNodeWarmupRetry(operation: "Kernel currentNonce read") {
            try await withWalletNodeClient(operation: "Kernel currentNonce read") { client in
                try await client.kernelCurrentNonce(accountAddress: accountAddress)
            }
        }

        let policy = settingsStore.sessionPolicy
        let assembly = try SessionEnableAssembler.assemble(
            policy: policy,
            chain: activeChain,
            accountAddress: accountAddress,
            sessionKeyRef: keyRef,
            sessionAddress: sessionKey.address,
            validationNonce: validationNonce,
            now: now,
            composer: { configJSON in
                try SessionPermissionArtifacts(
                    permission: WalletSignature.sessionBuildPermission(configJSON: configJSON)
                )
            },
            enableDigestSigner: { [self] digest in
                try signSessionEnableDigest(
                    digest,
                    reason: "Enable session keys for \(activeChain.name)"
                )
            }
        )

        let refreshed = record.replacingSessionRecord(
            assembly.record,
            isDeployed: inspection.isDeployed,
            updatedAt: now
        )
        try metadataStore.save(refreshed)
        walletRecord = refreshed
        settingsStore.setSessionKeysEnabled(true)
        appendLog("session: stored permission 0x\(assembly.record.permissionId.hexEncodedString)")
        return assembly.record
    }

    func executeNativeTransfer(
        recipient: String,
        amountETH: String,
        logContext: String = "transfer",
        signingReason: String? = nil
    ) async throws -> UserOperationSendResult {
        try await executeTransfer(
            intent: .nativeTransfer(recipient: recipient, amountETH: amountETH),
            logContext: logContext,
            signingReason: signingReason ?? "Authorize ETH transfer on \(activeChain.name)"
        )
    }

    func executeERC20Transfer(
        token: WalletToken,
        recipient: String,
        amount: String,
        logContext: String = "transfer",
        signingReason: String? = nil
    ) async throws -> UserOperationSendResult {
        try await executeTransfer(
            intent: .erc20Transfer(token: token, recipient: recipient, amount: amount),
            logContext: logContext,
            signingReason: signingReason ?? "Authorize \(amount) \(token.symbol) transfer on \(activeChain.name)"
        )
    }

    func resolveName(_ name: String) async throws -> WalletNodeClient.ResolvedName {
        appendLog("ens: resolving \(name) on \(activeChain.name)")
        let resolved = try await withWalletNodeClient(operation: "ENS resolution") { client in
            try await client.resolveName(
                name,
                sendChainId: Int(activeChain.id)
            )
        }
        appendLog("ens: \(resolved.normalizedName) resolved to \(resolved.address) via \(resolved.resolutionChainName)")
        return resolved
    }

    func ethBalance(address: String) async throws -> String {
        try await withWalletNodeClient(operation: "ETH balance read") { client in
            try await client.ethBalance(address: address)
        }
    }

    func erc20Balance(tokenAddress: String, ownerAddress: String) async throws -> String {
        try await withWalletNodeClient(operation: "ERC20 balance read") { client in
            try await client.erc20Balance(
                tokenAddress: tokenAddress,
                ownerAddress: ownerAddress
            )
        }
    }

    func quoteExactInputSwap(
        from tokenIn: WalletToken,
        to tokenOut: WalletToken,
        amount: String,
        slippageBps: UInt64 = 100
    ) async throws -> SwapQuote {
        guard let walletAddress = walletRecord?.kernelAccountAddress else {
            throw AppError.invalidCounterfactualAddress
        }
        guard let wrappedNative = WalletTokenRegistry.wrappedNativeToken(on: activeChain.id),
              let wrappedNativeAddress = wrappedNative.contractAddress
        else {
            throw AppError.invalidExecutionAddress
        }

        let tokenInAddress = tokenIn.contractAddress ?? wrappedNativeAddress
        let tokenOutAddress = tokenOut.contractAddress ?? wrappedNativeAddress
        let amountIn = try EtherAmountParser.units(
            fromDecimalString: amount,
            decimals: tokenIn.decimals
        )
        let intermediates = WalletTokenRegistry.swapIntermediates(on: activeChain.id)
            .compactMap(\.contractAddress)
            .filter {
                $0.caseInsensitiveCompare(tokenInAddress) != .orderedSame
                    && $0.caseInsensitiveCompare(tokenOutAddress) != .orderedSame
            }

        appendLog("swap: quoting \(amount) \(tokenIn.symbol) to \(tokenOut.symbol) on \(activeChain.name)")
        let quote = try await withWalletNodeClient(operation: "swap quote") { client in
            try await client.quoteSwap(
                sendChainId: activeChain.id,
                tokenIn: tokenInAddress,
                tokenOut: tokenOutAddress,
                amountIn: amountIn,
                owner: walletAddress,
                tokenInIsNative: tokenIn.isNative,
                slippageBps: slippageBps,
                intermediates: intermediates
            )
        }
        appendLog("swap: quoted \(quote.hops.count) hop route amountOut=\(quote.quoteAmountOut.shortHex) minOut=\(quote.amountOutMinimum.shortHex)")

        return SwapQuote(
            chainID: quote.chainID,
            factory: quote.factory,
            router: quote.router,
            quoter: quote.quoter,
            tokenIn: quote.tokenIn,
            tokenOut: quote.tokenOut,
            amountIn: quote.amountIn,
            quoteAmountOut: quote.quoteAmountOut,
            amountOutMinimum: quote.amountOutMinimum,
            slippageBps: quote.slippageBps,
            path: quote.path,
            hops: quote.hops,
            gasEstimate: quote.gasEstimate,
            allowance: quote.allowance,
            requiresApproval: quote.requiresApproval
        )
    }

    func executeExactInputSwap(
        quote: SwapQuote,
        from tokenIn: WalletToken,
        to tokenOut: WalletToken,
        logContext: String = "swap",
        signingReason: String? = nil
    ) async throws -> UserOperationSendResult {
        guard let walletAddress = walletRecord?.kernelAccountAddress else {
            throw AppError.invalidCounterfactualAddress
        }
        let request = SwapExecutionRequest(
            quote: quote,
            recipient: walletAddress,
            tokenInIsNative: tokenIn.isNative,
            tokenOutIsNative: tokenOut.isNative
        )
        let defaultSigningReason = quote.requiresApproval && !tokenIn.isNative
            ? "Approve \(tokenIn.symbol) and authorize \(tokenIn.symbol) to \(tokenOut.symbol) swap on \(activeChain.name)"
            : "Authorize \(tokenIn.symbol) to \(tokenOut.symbol) swap on \(activeChain.name)"
        return try await executeTransfer(
            intent: .exactInputSwap(request),
            logContext: logContext,
            signingReason: signingReason ?? defaultSigningReason
        )
    }

    func executeBatch(
        executions: [KernelExecutionRequest],
        logContext: String = "batch",
        signingReason: String? = nil
    ) async throws -> UserOperationSendResult {
        try await executeUserOperation(
            logContext: logContext,
            signingReason: signingReason ?? "Authorize \(executions.count) transaction batch on \(activeChain.name)",
            intent: nil,
            historyDraft: WalletTransactionDraft(
                operation: .batch,
                amount: String(executions.count),
                token: executions.count == 1 ? "call" : "calls"
            )
        ) { [self] buildContext in
            try await buildUserOperationDraft(
                executions: executions,
                isDeployedOverride: buildContext.isDeployed,
                nonceKey192: buildContext.sessionPlan?.nonceKey192
            )
        }
    }

    private func executeTransfer(
        intent: TransactionIntent,
        logContext: String,
        signingReason: String
    ) async throws -> UserOperationSendResult {
        try await executeUserOperation(
            logContext: logContext,
            signingReason: signingReason,
            intent: intent,
            historyDraft: historyDraft(for: intent)
        ) { [self] buildContext in
            try await buildUserOperationDraft(
                intent: intent,
                isDeployedOverride: buildContext.isDeployed,
                nonceKey192: buildContext.sessionPlan?.nonceKey192
            )
        }
    }

    private func executeUserOperation(
        logContext: String,
        signingReason: String,
        intent: TransactionIntent?,
        historyDraft: WalletTransactionDraft?,
        buildDraft: @escaping (_ buildContext: UserOperationBuildContext) async throws -> UserOperationDraft
    ) async throws -> UserOperationSendResult {
        guard !isBootstrapping, !isBuildingUserOperation, !isSendingUserOperation else {
            throw AppError.walletOperationInProgress
        }
        if walletRecord == nil {
            bootstrap()
        }
        guard walletRecord != nil else {
            throw AppError.corruptedMetadataStore
        }

        appendSection("Send UserOperation")

        isSendingUserOperation = true
        lastError = nil
        lastSubmittedUserOperationHash = nil
        lastBundledTransactionHash = nil

        do {
            let result = try await sendUserOperation(
                logContext: logContext,
                signingReason: signingReason,
                intent: intent,
                historyDraft: historyDraft,
                buildDraft: buildDraft
            )
            isSendingUserOperation = false
            return result
        } catch {
            isSendingUserOperation = false
            clearOptimisticNonceForActiveWallet()
            throw error
        }
    }

    private func sendUserOperation(
        logContext: String,
        signingReason: String,
        intent: TransactionIntent?,
        historyDraft: WalletTransactionDraft?,
        buildDraft: (_ buildContext: UserOperationBuildContext) async throws -> UserOperationDraft
    ) async throws -> UserOperationSendResult {
        appendLog("\(logContext): preparing transaction on \(activeChain.name)")

        let liveInspection = try await refreshAccountInspectionWithRetry(logContext: "\(logContext)-preflight")
        appendLog("\(logContext): using \(liveInspection.isDeployed ? "deployed" : "precomputed") account path")

        let sessionPlan = intent.flatMap {
            liveInspection.isDeployed ? activeSessionPlan(for: $0, now: Date()) : nil
        }
        if let sessionPlan {
            let modeLabel = sessionPlan.signatureMode == .installed ? "installed" : "enable"
            appendLog("\(logContext): using silent session-key path (\(modeLabel) mode)")
        } else if intent != nil, settingsStore.sessionKeysEnabled {
            appendLog("\(logContext): session-key path unavailable or out of policy; using passkey")
        }

        let buildContext = UserOperationBuildContext(
            isDeployed: liveInspection.isDeployed,
            sessionPlan: sessionPlan
        )
        let draft = try await buildDraft(buildContext)
        appendDraftLogSummary(draft, context: logContext)

        let enrichedDraft = try await enrichDraftWithLocalBundlerEstimation(
            draft,
            logContext: logContext,
            sessionPlan: sessionPlan
        )
        builtUserOperationDraft = enrichedDraft

        let signatureResult = try UserOperationSigning.signForSend(
            draft: enrichedDraft,
            session: sessionPlan?.signingContext,
            passkeySigner: { [self] preimage in
                appendLog("\(logContext): computed signing preimage (\(preimage.count) bytes)")
                appendLog("\(logContext): requesting Secure Enclave signature")
                let signature = try keyStore.sign(preimage: preimage, reason: signingReason)
                appendLog("\(logContext): signature components r=\(signature.r.shortHex) s=\(signature.s.shortHex)")
                return signature
            },
            passkeyWrapper: { [self] userOpHash, signature in
                var lowS = signature.s
                let originalS = lowS
                try WalletSignature.normaliseLowS(s: &lowS)
                appendLog(
                    "\(logContext): low-s normalization \(originalS == lowS ? "not needed" : "applied")"
                )
                let encoded = try WalletSignature.abiEncodeSignature(
                    userOpHash: userOpHash,
                    r: signature.r,
                    s: lowS,
                    usePrecompiled: false
                )
                appendLog("\(logContext): encoded Kernel/WebAuthn signature (\(encoded.count) bytes)")
                return encoded
            },
            sessionSecretReader: { keyRef in
                try SessionKeyStore.shared.read(keyRef: keyRef).secret
            },
            sessionWrapper: { [self] secret, userOpHash, mode, enableData, selectorData, enableSig in
                let signature = try WalletSignature.sessionSignAndWrap(
                    secret: secret,
                    userOpHash: userOpHash,
                    mode: mode,
                    enableData: enableData,
                    selectorData: selectorData,
                    enableSig: enableSig
                )
                appendLog("\(logContext): encoded session signature (\(signature.count) bytes)")
                return signature
            }
        )
        appendLog("\(logContext): final userOpHash \(signatureResult.userOpHash.shortHex)")

        bridgeStatus = "Submitting UserOperation to local wallet-node on \(activeChain.name)..."
        activeBundlerStatus = "Submitting UserOperation"

        let sentUserOpHash = try await withWalletNodeClient(operation: "\(logContext) submit") { client in
            try await client.sendUserOperation(
                draft: enrichedDraft,
                signature: signatureResult.signature
            )
        }
        lastSubmittedUserOperationHash = sentUserOpHash
        if let sessionPlan, !sessionPlan.record.installedOnChain {
            pendingSessionInstallByUserOpHash[sentUserOpHash.lowercased()] = sessionPlan.record
        }
        recordOptimisticNonce(after: enrichedDraft)
        appendLog("\(logContext): local wallet-node accepted userOpHash \(sentUserOpHash)")
        if let historyDraft {
            recordSubmittedHistory(
                historyDraft,
                userOpHash: sentUserOpHash,
                accountAddress: enrichedDraft.sender,
                logContext: logContext
            )
        }

        activeBundlerStatus = "UserOperation submitted"
        bridgeStatus = "Accepted by local wallet-node. Waiting for inclusion."
        refreshLocalRelayerStatus()
        startUserOperationReconcilerIfNeeded()
        return UserOperationSendResult(
            userOpHash: sentUserOpHash,
            transactionHash: nil,
            success: nil
        )
    }

    private func activeSessionPlan(for intent: TransactionIntent, now: Date) -> SessionUserOperationPlan? {
        guard settingsStore.sessionKeysEnabled,
              let walletRecord,
              let sessionRecord = walletRecord.sessionRecords.first(where: { $0.chainId == activeChain.id }),
              let plan = SessionUserOperationPlan(record: sessionRecord)
        else {
            return nil
        }

        let context = SessionPolicyContext(
            sessionRecord: sessionRecord,
            now: now,
            recentSessionTransactionDates: []
        )
        guard SessionPolicyMirror.isWithinPolicy(
            intent: intent,
            config: sessionRecord.policyConfigSnapshot,
            context: context
        ) else {
            return nil
        }
        return plan
    }

    private func signSessionEnableDigest(_ digest: Data, reason: String) throws -> Data {
        let preimage = try WalletSignature.computeSigningPreimage(userOpHash: digest)
        let signature = try keyStore.sign(preimage: preimage, reason: reason)
        var lowS = signature.s
        try WalletSignature.normaliseLowS(s: &lowS)
        return try WalletSignature.abiEncodeSignature(
            userOpHash: digest,
            r: signature.r,
            s: lowS,
            usePrecompiled: false
        )
    }

    private func refreshAccountInspection(logContext: String) async throws -> AccountInspection {
        guard let record = walletRecord, let address = record.kernelAccountAddress else {
            throw AppError.invalidCounterfactualAddress
        }

        appendLog("\(logContext): querying code and balance for \(address.shortAddress) via \(activeChain.shortName)")

        let inspection = try await withWalletNodeClient(operation: "\(logContext) account inspection") { client in
            try await client.inspectAccount(address: address)
        }
        accountInspection = inspection

        let refreshed = WalletRecord(
            walletId: record.walletId,
            keyTag: record.keyTag,
            pubkeyX: record.pubkeyX,
            pubkeyY: record.pubkeyY,
            chainId: activeChain.id,
            kernelAccountAddress: record.kernelAccountAddress,
            authenticatorIdHash: record.authenticatorIdHash,
            kernelSalt: record.kernelSalt,
            sessionRecords: record.sessionRecords,
            isDeployed: inspection.isDeployed,
            createdAt: record.createdAt,
            updatedAt: Date()
        )
        try metadataStore.save(refreshed)
        walletRecord = refreshed

        appendLog(
            "\(logContext): state=\(inspection.stateTitle), balance=\(inspection.balanceDisplay), codeBytes=\(inspection.codeHex.hexByteCount)"
        )

        return inspection
    }

    private func refreshAccountInspectionWithRetry(logContext: String) async throws -> AccountInspection {
        var lastError: Error?
        for attempt in 0...Self.startupInspectionRetryDelays.count {
            do {
                return try await refreshAccountInspection(logContext: attempt == 0 ? logContext : "\(logContext)-retry-\(attempt)")
            } catch {
                lastError = error
                guard attempt < Self.startupInspectionRetryDelays.count else {
                    break
                }
                appendLog("\(logContext): account inspection unavailable; retrying")
                try await Task.sleep(nanoseconds: Self.startupInspectionRetryDelays[attempt])
            }
        }
        throw lastError ?? AppError.invalidCounterfactualAddress
    }

    private func enrichDraftWithLocalBundlerEstimation(
        _ draft: UserOperationDraft,
        logContext: String,
        sessionPlan: SessionUserOperationPlan? = nil
    ) async throws -> UserOperationDraft {
        appendLog("\(logContext): checking local wallet-node entry point support")
        try await withWalletNodeClient(operation: "\(logContext) entry point check") { client in
            try await client.assertEntryPointSupport(activeChain.entryPoint)
        }
        appendLog("\(logContext): local wallet-node supports entry point \(activeChain.entryPoint)")

        let dummySignature: Data
        if let sessionPlan {
            dummySignature = try WalletSignature.sessionDummySignature(
                mode: sessionPlan.signatureMode,
                enableData: sessionPlan.record.installedOnChain ? Data() : sessionPlan.record.enableData,
                selectorData: sessionPlan.record.installedOnChain ? Data() : sessionPlan.record.selectorData,
                usePrecompiled: false
            )
            appendLog("\(logContext): generated session dummy signature for estimation (\(dummySignature.count) bytes)")
        } else {
            dummySignature = try WalletSignature.abiEncodeDummySignature(usePrecompiled: false)
            appendLog("\(logContext): generated dummy signature for estimation (\(dummySignature.count) bytes)")
        }

        let estimate = try await withWalletNodeWarmupRetry(operation: "\(logContext) gas estimate") {
            try await withWalletNodeClient(operation: "\(logContext) gas estimate") { client in
                try await client.estimateUserOperationGas(
                    draft: draft,
                    dummySignature: dummySignature
                )
            }
        }
        appendLog(
            "\(logContext): gas estimate call=\(estimate.callGasLimit.shortHex) verification=\(estimate.verificationGasLimit.shortHex) preVerification=\(estimate.preVerificationGas.shortHex)"
        )

        let feeQuote = try await suggestedUserOperationFees(logContext: logContext)
        appendLog(
            "\(logContext): fee quote maxPriority=\(feeQuote.maxPriorityFeePerGas.shortHex) maxFee=\(feeQuote.maxFeePerGas.shortHex)"
        )

        activeBundlerStatus = "Local wallet-node ready on \(activeChain.name)"

        return draft.updatingGasPlan(
            UserOperationGasPlan(
                accountGasLimits: pack128(
                    high: estimate.verificationGasLimit,
                    low: estimate.callGasLimit
                ),
                preVerificationGas: estimate.preVerificationGas,
                gasFees: pack128(
                    high: feeQuote.maxPriorityFeePerGas,
                    low: feeQuote.maxFeePerGas
                ),
                paymasterAndData: Data()
            )
        )
    }

    private func pollForLocalReceipt(
        userOpHash: String,
        logContext: String
    ) async throws -> WalletNodeClient.UserOperationReceipt? {
        appendLog("\(logContext): polling local wallet-node receipt for \(userOpHash)")

        for attempt in 1...90 {
            let receipt = try await withWalletNodeClient(operation: "\(logContext) receipt poll") { client in
                try await client.getUserOperationReceipt(userOpHash: userOpHash)
            }
            if let receipt {
                appendLog("\(logContext): receipt received on attempt \(attempt)")
                return receipt
            }

            appendLog("\(logContext): receipt pending (attempt \(attempt)/90)")
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        return nil
    }

    func loadWalletHistoryRecords(limit: Int = 200) -> [WalletTransactionRecord] {
        do {
            return try walletHistoryStore.loadRecords(
                accountAddress: walletRecord?.kernelAccountAddress,
                chainID: activeChain.id,
                limit: limit
            )
        } catch {
            appendLog("history: load failed — \(error.localizedDescription)")
            return []
        }
    }

    func refreshWalletHistoryReceipts(limit: Int = 200) async throws -> [WalletTransactionRecord] {
        let accountAddress = walletRecord?.kernelAccountAddress
        let records = try walletHistoryStore.loadReceiptRefreshCandidates(
            accountAddress: accountAddress,
            chainID: activeChain.id,
            limit: limit
        )
        guard !records.isEmpty else {
            return try walletHistoryStore.loadRecords(
                accountAddress: accountAddress,
                chainID: activeChain.id,
                limit: limit
            )
        }

        appendLog("history: refreshing receipts for \(records.count) pending record\(records.count == 1 ? "" : "s")")
        for record in records {
            await reconcile(record: record)
        }

        return try walletHistoryStore.loadRecords(
            accountAddress: accountAddress,
            chainID: activeChain.id,
            limit: limit
        )
    }

    func reconcile(record: WalletTransactionRecord) async {
        let nestedReceipt = try? await withWalletNodeClient(operation: "reconcile") { client in
            try await client.getUserOperationReceipt(userOpHash: record.userOpHash)
        }
        let operationStatus: WalletNodeClient.UserOperationStatus?
        if nestedReceipt == nil {
            operationStatus = try? await withWalletNodeClient(operation: "reconcile status") { client in
                try await client.getUserOperationStatus(userOpHash: record.userOpHash)
            }
        } else {
            operationStatus = nil
        }
        switch ReconcileDecision.next(for: record, receipt: nestedReceipt ?? nil, status: operationStatus) {
        case .applyReceipt(let receipt):
            recordReceiptHistory(receipt, chainID: record.chainID, logContext: "reconcile")
        case .markTerminal(let status, let reason):
            markTerminalHistory(
                userOpHash: record.userOpHash,
                chainID: record.chainID,
                status: status,
                reason: reason,
                logContext: "reconcile"
            )
        case .markPending:
            // Conservative until the daemon/app persists each UserOperation nonce:
            // nil receipt alone can mean pending, cancelled, dropped, or RPC lag.
            markPendingHistory(userOpHash: record.userOpHash, chainID: record.chainID, logContext: "reconcile")
        case .keep:
            break
        }
        reconcilerUpdatedAt = Date()
    }

    func startUserOperationReconcilerIfNeeded() {
        guard reconcilerTask == nil else {
            return
        }
        reconcilerTask = Task { [weak self] in
            await self?.runUserOperationReconciler()
            await MainActor.run {
                self?.reconcilerTask = nil
            }
        }
    }

    func runUserOperationReconciler() async {
        var attempt = 0
        while !Task.isCancelled {
            let accountAddress = walletRecord?.kernelAccountAddress
            let candidates = (try? walletHistoryStore.loadUnfinalizedRecords(
                accountAddress: accountAddress,
                chainID: activeChain.id
            )) ?? []
            let now = Date()
            let pending = candidates.filter {
                ReconcilerEligibility.shouldPoll($0, now: now)
            }
            guard ReconcilerLoopStep.shouldContinue(pendingCount: pending.count) else {
                return
            }

            for record in pending {
                await reconcile(record: record)
            }

            let stillPendingCandidates = (try? walletHistoryStore.loadUnfinalizedRecords(
                accountAddress: accountAddress,
                chainID: activeChain.id
            )) ?? []
            let stillPending = stillPendingCandidates.contains {
                ReconcilerEligibility.shouldPoll($0)
            }
            attempt = ReconcilerLoopStep.nextAttempt(current: attempt, stillPending: stillPending)
            guard stillPending else {
                return
            }
            try? await Task.sleep(nanoseconds: Self.reconcilerDelay(forAttempt: attempt))
        }
    }

    private func recordSubmittedHistory(
        _ draft: WalletTransactionDraft,
        userOpHash: String,
        accountAddress: String,
        logContext: String
    ) {
        do {
            try walletHistoryStore.recordSubmitted(
                draft,
                userOpHash: userOpHash,
                accountAddress: accountAddress,
                chainID: activeChain.id,
                chainName: activeChain.name
            )
            appendLog("\(logContext): wallet history recorded submitted operation")
        } catch {
            appendLog("\(logContext): wallet history record failed — \(error.localizedDescription)")
        }
    }

    private func recordReceiptHistory(
        _ receipt: WalletNodeClient.UserOperationReceipt,
        chainID: UInt64,
        logContext: String
    ) {
        do {
            try walletHistoryStore.applyReceipt(WalletTransactionReceiptUpdate(
                chainID: chainID,
                userOpHash: receipt.userOpHash,
                transactionHash: receipt.txHash,
                success: receipt.success,
                actualGasCost: receipt.actualGasCost,
                actualGasUsed: receipt.actualGasUsed,
                revertReason: receipt.revertReason,
                tentative: receipt.tentative,
                invalidated: receipt.invalidated
            ))
            appendLog("\(logContext): wallet history reconciled receipt \(receipt.success ? "included" : "reverted")")
            updatePendingSessionInstall(
                userOpHash: receipt.userOpHash,
                chainID: chainID,
                success: receipt.success,
                logContext: logContext
            )
        } catch {
            appendLog("\(logContext): wallet history receipt update failed — \(error.localizedDescription)")
        }
    }

    private func updatePendingSessionInstall(
        userOpHash: String,
        chainID: UInt64,
        success: Bool,
        logContext: String
    ) {
        let key = userOpHash.lowercased()
        guard let pendingRecord = pendingSessionInstallByUserOpHash.removeValue(forKey: key) else {
            return
        }
        guard success else {
            appendLog("\(logContext): session permission install was not included")
            return
        }
        guard let walletRecord else {
            return
        }

        var installedRecord = walletRecord.sessionRecords.first {
            $0.chainId == chainID && $0.permissionId == pendingRecord.permissionId
        } ?? pendingRecord
        installedRecord.installedOnChain = true
        do {
            let refreshed = walletRecord.replacingSessionRecord(
                installedRecord,
                isDeployed: walletRecord.isDeployed,
                updatedAt: Date()
            )
            try metadataStore.save(refreshed)
            self.walletRecord = refreshed
            appendLog("\(logContext): marked session permission installed")
        } catch {
            appendLog("\(logContext): session permission install update failed — \(error.localizedDescription)")
        }
    }

    private func markPendingHistory(userOpHash: String, chainID: UInt64, logContext: String) {
        do {
            try walletHistoryStore.markPending(userOpHash: userOpHash, chainID: chainID)
            appendLog("\(logContext): wallet history left pending until receipt is available")
        } catch {
            appendLog("\(logContext): wallet history pending update failed — \(error.localizedDescription)")
        }
    }

    private func markTerminalHistory(
        userOpHash: String,
        chainID: UInt64,
        status: WalletTransactionStatus,
        reason: String?,
        logContext: String
    ) {
        do {
            try walletHistoryStore.markTerminalWithoutReceipt(
                userOpHash: userOpHash,
                chainID: chainID,
                status: status,
                reason: reason
            )
            appendLog("\(logContext): wallet history marked \(status.rawValue) without receipt")
        } catch {
            appendLog("\(logContext): wallet history terminal update failed — \(error.localizedDescription)")
        }
    }

    private func historyDraft(for intent: TransactionIntent) -> WalletTransactionDraft {
        switch intent {
        case let .nativeTransfer(recipient, amountETH):
            return WalletTransactionDraft(
                operation: .transfer,
                amount: amountETH,
                token: "ETH",
                counterparty: recipient
            )
        case let .erc20Transfer(token, recipient, amount):
            return WalletTransactionDraft(
                operation: .transfer,
                amount: amount,
                token: token.symbol,
                counterparty: recipient
            )
        case let .exactInputSwap(request):
            let input = historyToken(
                address: request.quote.tokenIn,
                isNative: request.tokenInIsNative
            )
            let output = historyToken(
                address: request.quote.tokenOut,
                isNative: request.tokenOutIsNative
            )
            let route = historyRouteLabel(
                from: input.symbol,
                quote: request.quote,
                outputSymbol: output.symbol
            )
            let details = historyDetailsJSON([
                "router": request.quote.router,
                "recipient": request.recipient,
                "tokenIn": request.quote.tokenIn,
                "tokenOut": request.quote.tokenOut,
                "amountIn": "0x" + request.quote.amountIn.hexEncodedString,
                "quoteAmountOut": "0x" + request.quote.quoteAmountOut.hexEncodedString,
                "amountOutMinimum": "0x" + request.quote.amountOutMinimum.hexEncodedString,
                "slippageBps": String(request.quote.slippageBps),
            ])
            return WalletTransactionDraft(
                operation: .swap,
                amount: TokenAmountFormatter.displayString(
                    rawUnits: request.quote.amountIn,
                    decimals: input.decimals,
                    symbol: input.symbol
                ),
                token: "\(input.symbol) -> \(output.symbol)",
                counterparty: request.quote.router,
                counterpartyName: "Uniswap SwapRouter02",
                route: route,
                amountOut: TokenAmountFormatter.displayString(
                    rawUnits: request.quote.quoteAmountOut,
                    decimals: output.decimals,
                    symbol: output.symbol
                ),
                minimumReceived: TokenAmountFormatter.displayString(
                    rawUnits: request.quote.amountOutMinimum,
                    decimals: output.decimals,
                    symbol: output.symbol
                ),
                detailsJSON: details
            )
        }
    }

    private func historyToken(
        address: String,
        isNative: Bool
    ) -> (symbol: String, decimals: Int) {
        if isNative {
            return ("ETH", 18)
        }
        if let token = WalletTokenRegistry.token(matching: address, on: activeChain.id) {
            return (token.symbol, token.decimals)
        }
        return (shortHistoryAddress(address), 18)
    }

    private func historyRouteLabel(
        from inputSymbol: String,
        quote: SwapQuote,
        outputSymbol: String
    ) -> String {
        guard !quote.hops.isEmpty else {
            return "\(inputSymbol) -> \(outputSymbol)"
        }
        var symbols = [inputSymbol]
        for hop in quote.hops {
            symbols.append(
                WalletTokenRegistry.token(
                    matching: hop.tokenOut,
                    on: quote.chainID
                )?.symbol ?? shortHistoryAddress(hop.tokenOut)
            )
        }
        return symbols.joined(separator: " -> ")
    }

    private func shortHistoryAddress(_ value: String) -> String {
        guard value.hasPrefix("0x"), value.count > 18 else {
            return value
        }
        return "\(value.prefix(10))...\(value.suffix(8))"
    }

    private func historyDetailsJSON(_ fields: [String: String]) -> String? {
        guard JSONSerialization.isValidJSONObject(fields),
              let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func pack128(high: Data, low: Data) -> Data {
        high.suffix(16) + low.suffix(16)
    }

    private func suggestedUserOperationFees(
        logContext: String
    ) async throws -> (maxPriorityFeePerGas: Data, maxFeePerGas: Data) {
        let gasPrice = try await withWalletNodeWarmupRetry(operation: "\(logContext) gas price") {
            try await withWalletNodeClient(operation: "\(logContext) gas price") { client in
                try await client.userOperationGasPrice()
            }
        }
        let settings = networkSettings
        let resolved = GasPricing.resolveUserOperationFees(
            gasPrice: gasPrice,
            autoEnabled: settings.autoGasModeEnabled,
            autoTier: settings.autoGasTier,
            manualCap: settings.activeGasPolicy
        )
        appendLog("\(logContext): gas fee mode \(settings.autoGasModeEnabled ? "auto/\(settings.autoGasTier.rawValue)" : "manual(capped to \(settings.activeMaxFeePerGasGwei)/\(settings.activeMaxPriorityFeePerGasGwei) gwei)")")
        return resolved
    }

    /// Fetch the current live gas tiers + base fee for the chat indicator.
    func refreshLiveGasPrices() async {
        do {
            let price = try await withWalletNodeClient(operation: "gas indicator") { client in
                try await client.userOperationGasPrice()
            }
            liveGasPrice = price
            // Derive base fee from the standard tier (gasPrice − tip): exact and
            // independent of the light client, which can't reliably serve blocks.
            liveBaseFeeWei = GasPricing.baseFeeWei(
                standardMaxFee: price.standard.maxFeePerGas,
                standardPriority: price.standard.maxPriorityFeePerGas
            )
            liveGasUpdatedAt = Date()
        } catch {
            appendLog("gas: live price refresh failed — \(error.localizedDescription)")
        }
    }

    /// Long-lived poll driving the chat gas indicator. Cancelled with its Task.
    func runGasPriceUpdates() async {
        while !Task.isCancelled {
            await refreshLiveGasPrices()
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }

    private func appendDraftLogSummary(_ draft: UserOperationDraft, context: String) {
        appendLog(
            "\(context): nonce=\(draft.nonce.shortHex) initCodeBytes=\(draft.initCode.count) callDataBytes=\(draft.callData.count)"
        )
    }

    private func appendSection(_ title: String) {
        appendLog("========== \(title) ==========")
    }

    private func appendLog(_ message: String) {
        let line = "[\(Self.logTimeFormatter.string(from: Date()))] \(message)"
        var entries = debugLogText.isEmpty ? [] : debugLogText.components(separatedBy: "\n")
        entries.append(line)
        if entries.count > 240 {
            entries.removeFirst(entries.count - 240)
        }
        debugLogText = entries.joined(separator: "\n")
    }

    private static func probeExecutionChainID(rpcURL: URL) async throws -> UInt64 {
        let response = try await jsonRPC(method: "eth_chainId", rpcURL: rpcURL)
        guard let hexValue = response["result"] as? String,
              let chainID = UInt64(hexValue.removingHexPrefix, radix: 16) else {
            throw AppError.localDaemonLaunchFailed("Execution RPC returned an invalid eth_chainId response.")
        }
        return chainID
    }

    private static func jsonRPC(method: String, rpcURL: URL) async throws -> [String: Any] {
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": [],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw AppError.localDaemonLaunchFailed("Execution RPC request failed.")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.localDaemonLaunchFailed("Execution RPC returned invalid JSON.")
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown RPC error"
            throw AppError.localDaemonLaunchFailed(message)
        }
        return object
    }

    private static func isRelayerBalanceUnavailable(_ rawBalance: String?) -> Bool {
        guard let rawBalance else {
            return true
        }
        return rawBalance.isEmpty || rawBalance == "unavailable"
    }

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let debugReportDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct WalletNodeLaunchFailure {
    let error: Error
    let retryAfter: Date
}

enum NetworkSettingsGate {
    static func allowed(
        isBootstrapping: Bool,
        isRunningDemo: Bool,
        isRefreshingBalance: Bool,
        isBuildingUserOperation: Bool,
        isSendingUserOperation: Bool
    ) -> Bool {
        !isBootstrapping
            && !isRunningDemo
            && !isRefreshingBalance
            && !isBuildingUserOperation
            && !isSendingUserOperation
    }
}

enum NetworkSettingsChangePolicy {
    static func requiresWalletNodeRestart(
        from old: DemoNetworkSettings,
        to new: DemoNetworkSettings
    ) -> Bool {
        if old.isTestnetModeEnabled != new.isTestnetModeEnabled {
            return true
        }
        if old.activeRPCURL != new.activeRPCURL
            || old.activeArchiveNodeURL != new.activeArchiveNodeURL
            || old.activeConsensusRPCURL != new.activeConsensusRPCURL {
            return true
        }
        return old.resolvedDaemonGasPolicy != new.resolvedDaemonGasPolicy
    }
}

enum WalletNodeLaunchFailureGate {
    static func shouldBlockRetry(now: Date, retryAfter: Date) -> Bool {
        now < retryAfter
    }

    static func retryAfter(now: Date, cooldown: TimeInterval) -> Date {
        now.addingTimeInterval(cooldown)
    }
}

enum ReconcilerEligibility {
    static let maxAutomaticAge: TimeInterval = 15 * 60

    static func shouldPoll(
        _ record: WalletTransactionRecord,
        now: Date = Date(),
        maxAge: TimeInterval = maxAutomaticAge
    ) -> Bool {
        guard record.status.requiresReceiptRefresh else {
            return false
        }
        return now.timeIntervalSince(record.updatedAt) <= maxAge
    }
}

enum ReconcileOutcome: Equatable {
    case applyReceipt(WalletNodeClient.UserOperationReceipt)
    case markTerminal(WalletTransactionStatus, reason: String?)
    case markPending
    case keep
}

enum ReconcileDecision {
    static func next(
        for record: WalletTransactionRecord,
        receipt: WalletNodeClient.UserOperationReceipt?,
        status: WalletNodeClient.UserOperationStatus? = nil
    ) -> ReconcileOutcome {
        if let receipt {
            return .applyReceipt(receipt)
        }
        if record.status.isTerminal {
            return .keep
        }
        if let terminal = TerminalUserOperationStatus.historyStatus(from: status) {
            return .markTerminal(terminal.status, reason: terminal.reason)
        }
        return .markPending
    }
}

enum TerminalUserOperationStatus {
    static func historyStatus(
        from status: WalletNodeClient.UserOperationStatus?
    ) -> (status: WalletTransactionStatus, reason: String?)? {
        guard let status else {
            return nil
        }
        switch status.status {
        case "failed":
            let reason = status.lastError
            if reason?.localizedCaseInsensitiveContains("dropped") == true {
                return (.dropped, reason)
            }
            return (.failed, reason)
        case "reverted":
            return (.failed, status.lastError)
        default:
            return nil
        }
    }
}

enum ReplacementActionFailurePolicy {
    static func shouldMarkLocalHistoryFailed(_ error: Error) -> Bool {
        guard case let WalletNodeClient.ClientError.rpcError(_, code, _, reason, _) = error,
              code == -32011
        else {
            return false
        }
        return reason == "bundler_account_lifecycle_not_signable"
    }

    static func displayMessage(action: String, error: Error) -> String {
        guard case let WalletNodeClient.ClientError.rpcError(_, code, message, reason, _) = error,
              code == -32011
        else {
            return "\(action) failed: \(error.localizedDescription)"
        }

        switch reason {
        case "bundler_account_lifecycle_not_signable":
            return "\(action) unavailable: the relayer key for that transaction is retired."
        case "terminal_state":
            return "\(action) unavailable: the operation is already terminal."
        case "no_pending_bundler_transaction":
            return "\(action) unavailable: wallet-node has no pending transaction to replace."
        case "gas_relay_stuck":
            return "\(action) unavailable: replacement gas would exceed the configured cap."
        case let reason?:
            return "\(action) unavailable: \(reason)."
        case nil:
            return "\(action) unavailable: \(message)."
        }
    }
}

enum RelayerAddressCachePolicy {
    static func address(fromSecret secret: Data) throws -> String {
        "0x" + (try WalletSignature.bundlerAddress(fromSecret: secret)).hexEncodedString
    }

    static func shouldUpdate(cached: String?, unlocked: String) -> Bool {
        guard let unlocked = normalized(unlocked) else {
            return false
        }
        guard let cached = normalized(cached) else {
            return true
        }
        return cached != unlocked
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 42, trimmed.hasPrefix("0x") else {
            return nil
        }
        return trimmed.lowercased()
    }
}

enum ReconcilerLoopStep {
    static func shouldContinue(pendingCount: Int) -> Bool {
        pendingCount > 0
    }

    static func nextAttempt(current: Int, stillPending: Bool) -> Int {
        stillPending ? current + 1 : 0
    }
}

enum WalletNodeWarmupRetryPolicy {
    static func isWarmupError(_ error: Error) -> Bool {
        guard case let WalletNodeClient.ClientError.rpcError(_, code, message, reason, _) = error else {
            return false
        }
        if code == -32010 {
            return true
        }
        guard code == -32002 else {
            return false
        }
        switch reason {
        case "verified_reads_not_ready",
             "verified_reads_stale",
             "helios_error",
             "rpc_error",
             "block_not_found",
             "chain_internal_error",
             "state_override_smoke_pending":
            return true
        case nil:
            return message.localizedCaseInsensitiveContains("verified")
                || message.localizedCaseInsensitiveContains("helios")
                || message.localizedCaseInsensitiveContains("block_not_found")
        default:
            return false
        }
    }
}

enum NonceClamp {
    static func effective(onChain: UInt64, optimistic: UInt64?) -> UInt64 {
        max(onChain, optimistic ?? onChain)
    }

    static func next(after used: UInt64) -> UInt64 {
        used + 1
    }
}

private extension Data {
    var shortHex: String {
        let hex = hexEncodedString
        guard hex.count > 16 else {
            return "0x" + hex
        }
        return "0x" + hex.prefix(8) + "…" + hex.suffix(8)
    }
}

private extension String {
    var removingHexPrefix: String {
        hasPrefix("0x") ? String(dropFirst(2)) : self
    }

    var shortAddress: String {
        guard count > 14 else {
            return self
        }
        return "\(prefix(8))…\(suffix(6))"
    }

    var hexByteCount: Int {
        let normalized = hasPrefix("0x") ? String(dropFirst(2)) : self
        guard !normalized.isEmpty else {
            return 0
        }
        return normalized.count / 2
    }
}

private extension WalletTransactionRecord {
    var debugSuccessText: String {
        switch status {
        case .included:
            return "true"
        case .reverted, .failed, .dropped:
            return "false"
        case .created, .submitted, .pending, .looksIncluded, .cancelled, .unknown:
            return "None"
        }
    }
}
