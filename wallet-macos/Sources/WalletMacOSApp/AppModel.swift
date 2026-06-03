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
    @Published private(set) var networkHealth: WalletNodeClient.NetworkHealth?

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
        !isBootstrapping
            && !isRunningDemo
            && !isRefreshingBalance
            && !isBuildingUserOperation
            && !isSendingUserOperation
    }

    private let keyStore: KeyStore
    private let metadataStore: WalletMetadataStore
    private let settingsStore: DemoSettingsStore
    private let kernelAccountAddressPredictor: KernelAccountAddressPredictor
    private var walletNodeClient: WalletNodeClient?
    private var walletNodeDaemon: WalletNodeDaemon?
    private var walletNodeLaunchTask: Task<WalletNodeDaemon, Error>?
    private let userOperationBuilder: UserOperationBuilder
    private let walletHistoryStore: WalletTransactionHistoryStore
    private static let startupInspectionRetryDelays: [UInt64] = [
        500_000_000,
        1_250_000_000,
        2_000_000_000,
    ]
    private static let relayerBalanceRetryDelays: [UInt64] = [
        400_000_000,
        900_000_000,
        1_500_000_000,
    ]

    init(
        keyStore: KeyStore = KeyStore(),
        metadataStore: WalletMetadataStore = WalletMetadataStore(),
        settingsStore: DemoSettingsStore = DemoSettingsStore(),
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
        guard configuration.networkSettings != validated else {
            return
        }
        guard canChangeNetworkSettings else {
            throw AppError.walletOperationInProgress
        }

        appendSection("Update Network Settings")
        appendLog("network: active profile \(validated.activeNetworkName)")
        appendLog("network: execution RPC \(validated.activeRPCURL)")
        appendLog("network: gas caps max \(validated.activeMaxFeePerGasGwei) gwei, priority \(validated.activeMaxPriorityFeePerGasGwei) gwei")
        settingsStore.setNetworkSettings(validated)
        configuration = DemoAppConfiguration(networkSettings: validated)
        resetWalletNodeConnectionAfterNetworkChange()
        accountInspection = nil
        builtUserOperationDraft = nil
        lastUserOperationBuildError = nil
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
        walletNodeDaemon = nil
        walletNodeClient = WalletNodeClient.Configuration.fromEnvironment().map {
            WalletNodeClient(configuration: $0)
        }
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

        localRelayerMessage = "Starting local wallet-node daemon..."
        let keyRef = "bundler-eoa:default:\(activeChain.id):1"
        let chain = activeChain
        let gasPolicy = networkSettings.resolvedDaemonGasPolicy
        let launchTask = Task {
            let bundlerSecret = try BundlerKeyStore.shared.createIfNeeded(keyRef: keyRef)
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
            walletNodeDaemon = daemon
            walletNodeClient = daemon.client
            localRelayerMessage = "Local wallet-node daemon connected."
            appendLog("relayer: wallet-node daemon started")
            return daemon.client
        } catch {
            walletNodeLaunchTask = nil
            throw error
        }
    }

    private func withWalletNodeClient<T>(
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
        isDeployedOverride: Bool? = nil
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
        let nonceHex = try await withWalletNodeClient(operation: "EntryPoint nonce read") { client in
            try await client.entryPointNonce(
                entryPoint: activeChain.entryPoint,
                accountAddress: sender,
                nonceKey: 0
            )
        }

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
        isDeployedOverride: Bool? = nil
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
        let nonceHex = try await withWalletNodeClient(operation: "EntryPoint nonce read") { client in
            try await client.entryPointNonce(
                entryPoint: activeChain.entryPoint,
                accountAddress: sender,
                nonceKey: 0
            )
        }

        return try userOperationBuilder.buildDraft(
            walletRecord: walletRecord,
            publicKey: publicKey,
            chain: activeChain,
            isDeployed: isDeployedOverride ?? accountInspection?.isDeployed ?? walletRecord.isDeployed,
            nonceHex: nonceHex,
            executions: executions
        )
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
            historyDraft: WalletTransactionDraft(
                operation: .batch,
                amount: String(executions.count),
                token: executions.count == 1 ? "call" : "calls"
            )
        ) { [self] isDeployed in
            try await buildUserOperationDraft(
                executions: executions,
                isDeployedOverride: isDeployed
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
            historyDraft: historyDraft(for: intent)
        ) { [self] isDeployed in
            try await buildUserOperationDraft(
                intent: intent,
                isDeployedOverride: isDeployed
            )
        }
    }

    private func executeUserOperation(
        logContext: String,
        signingReason: String,
        historyDraft: WalletTransactionDraft?,
        buildDraft: @escaping (_ isDeployed: Bool) async throws -> UserOperationDraft
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
                historyDraft: historyDraft,
                buildDraft: buildDraft
            )
            isSendingUserOperation = false
            return result
        } catch {
            isSendingUserOperation = false
            throw error
        }
    }

    private func sendUserOperation(
        logContext: String,
        signingReason: String,
        historyDraft: WalletTransactionDraft?,
        buildDraft: (_ isDeployed: Bool) async throws -> UserOperationDraft
    ) async throws -> UserOperationSendResult {
        appendLog("\(logContext): preparing transaction on \(activeChain.name)")

        let liveInspection = try await refreshAccountInspection(logContext: "\(logContext)-preflight")
        appendLog("\(logContext): using \(liveInspection.isDeployed ? "deployed" : "precomputed") account path")

        let draft = try await buildDraft(liveInspection.isDeployed)
        appendDraftLogSummary(draft, context: logContext)

        let enrichedDraft = try await enrichDraftWithLocalBundlerEstimation(
            draft,
            logContext: logContext
        )
        builtUserOperationDraft = enrichedDraft

        let finalHash = try enrichedDraft.userOpHash()
        appendLog("\(logContext): final userOpHash \(finalHash.shortHex)")

        let preimage = try WalletSignature.computeSigningPreimage(userOpHash: finalHash)
        appendLog("\(logContext): computed signing preimage (\(preimage.count) bytes)")

        appendLog("\(logContext): requesting Secure Enclave signature")
        let signature = try keyStore.sign(preimage: preimage, reason: signingReason)
        appendLog("\(logContext): signature components r=\(signature.r.shortHex) s=\(signature.s.shortHex)")

        var lowS = signature.s
        let originalS = lowS
        try WalletSignature.normaliseLowS(s: &lowS)
        appendLog(
            "\(logContext): low-s normalization \(originalS == lowS ? "not needed" : "applied")"
        )

        let encodedSignature = try WalletSignature.abiEncodeSignature(
            userOpHash: finalHash,
            r: signature.r,
            s: lowS,
            usePrecompiled: false
        )
        appendLog("\(logContext): encoded Kernel/WebAuthn signature (\(encodedSignature.count) bytes)")

        bridgeStatus = "Submitting UserOperation to local wallet-node on \(activeChain.name)..."
        activeBundlerStatus = "Submitting UserOperation"

        let sentUserOpHash = try await withWalletNodeClient(operation: "\(logContext) submit") { client in
            try await client.sendUserOperation(
                draft: enrichedDraft,
                signature: encodedSignature
            )
        }
        lastSubmittedUserOperationHash = sentUserOpHash
        appendLog("\(logContext): local wallet-node accepted userOpHash \(sentUserOpHash)")
        if let historyDraft {
            recordSubmittedHistory(
                historyDraft,
                userOpHash: sentUserOpHash,
                accountAddress: enrichedDraft.sender,
                logContext: logContext
            )
        }

        bridgeStatus = "UserOperation accepted by local wallet-node on \(activeChain.name). Waiting for inclusion..."

        let receipt = try await pollForLocalReceipt(userOpHash: sentUserOpHash, logContext: logContext)
        if let receipt {
            lastBundledTransactionHash = receipt.txHash
            activeBundlerStatus = receipt.success ? "UserOperation included" : "UserOperation reverted on-chain"

            appendLog("\(logContext): receipt success=\(receipt.success) actualGasUsed=\(receipt.actualGasUsed ?? "nil") actualGasCost=\(receipt.actualGasCost ?? "nil")")
            appendLog("\(logContext): bundle transaction hash \(receipt.txHash)")
            if let revertReason = receipt.revertReason, !revertReason.isEmpty {
                appendLog("\(logContext): revert reason \(revertReason)")
            }
            recordReceiptHistory(receipt, chainID: activeChain.id, logContext: logContext)

            bridgeStatus = receipt.success
                ? "UserOperation included on \(activeChain.name)."
                : "UserOperation included on \(activeChain.name), but execution reverted."

            _ = try? await refreshAccountInspection(logContext: "post-send-refresh")
            refreshLocalRelayerStatus()
            return UserOperationSendResult(
                userOpHash: sentUserOpHash,
                transactionHash: receipt.txHash,
                success: receipt.success
            )
        }

        activeBundlerStatus = "Receipt pending"
        bridgeStatus = "UserOperation submitted to local wallet-node. Receipt still pending."
        appendLog("\(logContext): receipt still pending after polling window")
        markPendingHistory(userOpHash: sentUserOpHash, chainID: activeChain.id, logContext: logContext)
        refreshLocalRelayerStatus()
        return UserOperationSendResult(
            userOpHash: sentUserOpHash,
            transactionHash: nil,
            success: nil
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
        logContext: String
    ) async throws -> UserOperationDraft {
        appendLog("\(logContext): checking local wallet-node entry point support")
        try await withWalletNodeClient(operation: "\(logContext) entry point check") { client in
            try await client.assertEntryPointSupport(activeChain.entryPoint)
        }
        appendLog("\(logContext): local wallet-node supports entry point \(activeChain.entryPoint)")

        let dummySignature = try WalletSignature.abiEncodeDummySignature(usePrecompiled: false)
        appendLog("\(logContext): generated dummy signature for estimation (\(dummySignature.count) bytes)")

        let estimate = try await withWalletNodeClient(operation: "\(logContext) gas estimate") { client in
            try await client.estimateUserOperationGas(
                draft: draft,
                dummySignature: dummySignature
            )
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
        let records = try walletHistoryStore.loadUnfinalizedRecords(
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
            let receipt = try await withWalletNodeClient(operation: "history receipt refresh") { client in
                try await client.getUserOperationReceipt(userOpHash: record.userOpHash)
            }
            if let receipt {
                recordReceiptHistory(receipt, chainID: record.chainID, logContext: "history")
            } else {
                markPendingHistory(userOpHash: record.userOpHash, chainID: record.chainID, logContext: "history")
            }
        }

        return try walletHistoryStore.loadRecords(
            accountAddress: accountAddress,
            chainID: activeChain.id,
            limit: limit
        )
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
                revertReason: receipt.revertReason
            ))
            appendLog("\(logContext): wallet history reconciled receipt \(receipt.success ? "included" : "reverted")")
        } catch {
            appendLog("\(logContext): wallet history receipt update failed — \(error.localizedDescription)")
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
        let gasPrice = try await withWalletNodeClient(operation: "\(logContext) gas price") { client in
            try await client.userOperationGasPrice()
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

    /// Fetch the daemon health snapshot for the light-client sync indicator.
    func refreshNetworkHealth() async {
        do {
            let health = try await withWalletNodeClient(operation: "network health") { client in
                try await client.networkHealth()
            }
            networkHealth = health
        } catch {
            // Leave the prior value; a transient health miss shouldn't flap the UI.
        }
    }

    /// Long-lived health poll: fast (5s) while syncing, slow (30s) once verified-ready.
    func runNetworkHealthUpdates() async {
        while !Task.isCancelled {
            await refreshNetworkHealth()
            let interval: UInt64 = (networkHealth?.isReady == true)
                ? 30_000_000_000
                : 5_000_000_000
            try? await Task.sleep(nanoseconds: interval)
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
