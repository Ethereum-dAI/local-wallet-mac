import Foundation
import WalletToolLayer
import WalletSignature

enum SessionSigningPreviewMode: Equatable {
    case install
    case active
}

enum SessionSigningPasskeyReason: Equatable {
    case sessionOff
    case accountNotDeployed
    case noSessionRecord
    case pendingRevoke
    case expired(SessionExpiryReason)
    case missingSigningArtifacts
    case policy(SessionPolicyMirror.RejectionReason)
}

enum SessionSigningPreview: Equatable {
    case session(SessionSigningPreviewMode)
    case passkey(SessionSigningPasskeyReason)
}

enum WalletResetDestination: Equatable {
    case dashboard
    case onboarding

    var recreatesRelayer: Bool { self == .dashboard }
    var rebootstrapsWallet: Bool { self == .dashboard }
    var marksOnboardingIncomplete: Bool { self == .onboarding }
}

private enum UserOperationExecutionPurpose {
    case standard
    case bundlerTopUp(expectedIdentity: VerifiedRelayerIdentity)

    var allowsSessionSigning: Bool {
        if case .standard = self { return true }
        return false
    }
}

// AppModel drives the signed macOS demo shell. It is intentionally opinionated
// around the current demo scope (Sepolia, ETH transfer first, local wallet-node)
// and should not be treated as the final wallet product architecture.
@MainActor
final class AppModel: ObservableObject {
    struct UserOperationSendResult: Equatable {
        let userOpHash: String
        let transactionHash: String?
        let success: Bool?
        let signedBySession: Bool

        init(
            userOpHash: String,
            transactionHash: String?,
            success: Bool?,
            signedBySession: Bool = false
        ) {
            self.userOpHash = userOpHash
            self.transactionHash = transactionHash
            self.success = success
            self.signedBySession = signedBySession
        }
    }

    @Published private(set) var walletRecord: WalletRecord?
    @Published private(set) var walletRecoveryReason: WalletKeyRecoveryReason?
    @Published private(set) var bridgeStatus = "Not checked"
    @Published private(set) var lastError: String?
    @Published private(set) var isBootstrapping = false
    @Published private(set) var isRunningDemo = false
    @Published private(set) var isRefreshingBalance = false
    @Published private(set) var isBuildingUserOperation = false
    @Published private(set) var isSendingUserOperation = false
    @Published private(set) var isResettingWallet = false
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
    @Published private(set) var relayerAccessState: RelayerAccessState = .locked
    @Published private(set) var isRefreshingLocalRelayer = false
    @Published private(set) var isRotatingLocalRelayer = false
    @Published private(set) var isExportingLocalRelayer = false
    @Published private(set) var isDeletingLocalRelayer = false
    @Published private(set) var isReplacingPendingOperation = false
    @Published private(set) var swapSlippageBps: UInt64
    @Published private(set) var liveGasPrice: WalletNodeClient.UserOperationGasPrice?
    @Published private(set) var liveBaseFeeWei: Data?
    @Published private(set) var liveGasUpdatedAt: Date?
    @Published private(set) var reconcilerUpdatedAt: Date?
    @Published var hardwareBudget: HardwareBudget?
    @Published var modelActionMessage: String?

    var activeChain: ChainConfiguration {
        configuration.activeChain
    }

    var networkSettings: DemoNetworkSettings {
        configuration.networkSettings
    }

    var sessionKeysEnabled: Bool {
        settingsStore.sessionKeysEnabled
    }

    var sessionPolicy: SessionPolicyConfig {
        settingsStore.sessionPolicy
    }

    var hasLocalRelayerClient: Bool {
        walletNodeClient != nil || WalletNodeClient.Configuration.fromEnvironment() == nil
    }

    /// No wallet operation is in flight, so it is safe to start one that needs the daemon
    /// connection and writes `accountInspection`/`walletRecord`. Single source of truth for that
    /// five-flag condition — it was open-coded in three places plus `WalletIdleGate`, so a sixth
    /// in-flight flag would have had to be added to each of them.
    var isWalletIdle: Bool {
        !isResettingWallet && WalletIdleGate.allowed(
            isBootstrapping: isBootstrapping,
            isRunningDemo: isRunningDemo,
            isRefreshingBalance: isRefreshingBalance,
            isBuildingUserOperation: isBuildingUserOperation,
            isSendingUserOperation: isSendingUserOperation
        )
    }

    var canChangeNetworkSettings: Bool {
        isWalletIdle
    }

    private let keyStore: KeyStore
    private let walletKeyValidator: WalletKeyValidator
    private let metadataStore: WalletMetadataStore
    private let settingsStore: DemoSettingsStore
    private let onboardingSettingsStore: OnboardingSettingsStore
    private let kernelAccountAddressPredictor: KernelAccountAddressPredictor
    private var walletNodeClient: WalletNodeClient?
    private var walletNodeDaemon: WalletNodeDaemon?
    private var walletNodeLaunchTask: Task<WalletNodeDaemon, Error>?
    private var walletNodeLaunchID: UUID?
    private var walletNodeLaunchFailure: WalletNodeLaunchFailure?
    private var walletNodeGeneration: UInt64 = 0
    private var relayerInstallTask: Task<WalletNodeClient, Error>?
    private var relayerStatusRefreshToken = UUID()
    private var optimisticNextNonce: [String: UInt64] = [:]
    private var pendingSessionInstallByUserOpHash: [String: SessionRecord] = [:]
    private var pendingSessionRevokeByUserOpHash: [String: SessionRecord] = [:]
    private var reconcilerTask: Task<Void, Never>?
    private var secretResetQuiescenceHandler: (@MainActor () async throws -> Void)?
    private var secretRuntimeLockHandler: (@MainActor () async -> Void)?
    /// Last event-driven balance read, for the coalescing floor in `refreshAccountBalanceQuietly`.
    private var lastBackgroundBalanceReadAt: Date?
    private var lastGasIndicatorReadAt: Date?
    /// True once a balance read has failed and the failure has been logged; cleared on the next
    /// success so a fresh run of failures logs again exactly once.
    private var suppressedBalanceReadFailure = false
    private let userOperationBuilder: UserOperationBuilder
    private let walletHistoryStore: WalletTransactionHistoryStore
    let installedModelStore = InstalledModelStore()
    private let huggingFaceRepository = HuggingFaceRepository()
    private let modelDownloadManager = LocalAIModelDownloadManager()
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
    /// Floor between event-driven balance reads. Activation is the most frequent trigger and a
    /// cmd-tab away and straight back shouldn't cost a chain read, so coalesce anything closer
    /// together than this. Mirrors `sessionUserActivityPersistenceMinInterval`'s rate-limiting.
    private static let backgroundBalanceReadMinInterval: TimeInterval = 5
    /// Long enough that re-focusing the app repeatedly does not re-read, short
    /// enough that the pill is not obviously stale when you come back to it.
    private static let gasIndicatorMinRefreshInterval: TimeInterval = 20
    private static let sessionUserActivityPersistenceMinInterval: TimeInterval = 15
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
        walletKeyValidator: WalletKeyValidator? = nil,
        kernelAccountAddressPredictor: KernelAccountAddressPredictor = KernelAccountAddressPredictor(),
        walletNodeClient: WalletNodeClient? = WalletNodeClient.Configuration.fromEnvironment().map {
            WalletNodeClient(configuration: $0)
        },
        userOperationBuilder: UserOperationBuilder = UserOperationBuilder(),
        walletHistoryStore: WalletTransactionHistoryStore = WalletTransactionHistoryStore()
    ) {
        self.keyStore = keyStore
        self.walletKeyValidator = walletKeyValidator ?? WalletKeyValidator(keyStore: keyStore)
        self.metadataStore = metadataStore
        self.settingsStore = settingsStore
        self.onboardingSettingsStore = onboardingSettingsStore
        self.kernelAccountAddressPredictor = kernelAccountAddressPredictor
        self.walletNodeClient = walletNodeClient
        self.userOperationBuilder = userOperationBuilder
        self.walletHistoryStore = walletHistoryStore
        self.configuration = DemoAppConfiguration(networkSettings: settingsStore.networkSettings)
        self.swapSlippageBps = settingsStore.swapSlippageBps
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
        walletRecoveryReason = nil
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

                switch try walletKeyValidator.validate(existing) {
                case .available:
                    let coordinates = PublicKeyCoordinates(
                        x: existing.pubkeyX,
                        y: existing.pubkeyY
                    )
                    appendLog("bootstrap: validated accessible wallet key x=\(coordinates.x.shortHex) y=\(coordinates.y.shortHex)")

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
                case let .recoveryRequired(reason):
                    walletRecord = nil
                    walletRecoveryReason = reason
                    appendLog("bootstrap: wallet key validation requires explicit recovery")
                    throw AppError.walletKeyRecoveryRequired(reason)
                }
            } else {
                appendLog("bootstrap: metadata store empty; creating the first wallet record")

                let hasExistingKey = try keyStore.loadKey() != nil
                appendLog(
                    hasExistingKey
                        ? "bootstrap: found existing Secure Enclave key reference in Keychain"
                        : "bootstrap: no existing Secure Enclave key found; creating a new device-bound key"
                )

                let coordinates = try keyStore.createOrLoadPublicKeyCoordinates()
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
            appendLog("bootstrap: failed: \(error.localizedDescription)")
        }

        expireExpiredSessionIfNeeded(now: Date(), logContext: "bootstrap")
        isBootstrapping = false

        if shouldInspectAfterBootstrap {
            runDemo()
        }
        localRelayerMessage = "Local relayer locked until a transaction needs it."
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
        Task {
            do {
                try await resetDemoWalletAuthorized()
            } catch {
                lastError = error.localizedDescription
                bridgeStatus = "Demo wallet reset cancelled"
                appendLog("reset: authorization failed: \(error.localizedDescription)")
            }
        }
    }

    /// The dashboard owns privacy-sidecar state, while this model owns the wallet-node sidecar.
    /// Registering one quiescence hook keeps every reset entry point (settings and app menu)
    /// on the same destructive-reset path without making either model retain the other.
    func registerSecretResetQuiescenceHandler(
        _ handler: @escaping @MainActor () async throws -> Void
    ) {
        secretResetQuiescenceHandler = handler
    }

    func registerSecretRuntimeLockHandler(
        _ handler: @escaping @MainActor () async -> Void
    ) {
        secretRuntimeLockHandler = handler
    }

    /// A real macOS session lock is a security boundary; an ordinary app focus change is not.
    /// Drop only in-memory secrets here. Durable metadata and Keychain items remain intact, so
    /// the next explicit money action can unlock once and continue normally.
    func lockSecretRuntimesForSystemSession() async {
        await secretRuntimeLockHandler?()
        walletNodeLaunchTask?.cancel()
        walletNodeLaunchTask = nil
        walletNodeLaunchID = nil
        walletNodeLaunchFailure = nil
        relayerInstallTask?.cancel()
        relayerInstallTask = nil
        relayerStatusRefreshToken = UUID()
        isRefreshingLocalRelayer = false
        let daemon = walletNodeDaemon
        walletNodeDaemon = nil
        walletNodeClient = WalletNodeClient.Configuration.fromEnvironment().map {
            WalletNodeClient(configuration: $0)
        }
        walletNodeGeneration &+= 1
        relayerAccessState = .locked
        localRelayerStatus = nil
        localRelayerMessage = "Local relayer locked after the macOS session was secured."
        do {
            try await daemon?.terminateAndWait()
        } catch {
            daemon?.terminate()
            appendLog("security: wallet-node shutdown after session lock was not confirmed: \(error.localizedDescription)")
        }
    }

    func resetDemoWalletAuthorized() async throws {
        try await resetDemoWalletAuthorized(destination: .dashboard)
    }

    func resetWalletForRecoveryAuthorized() async throws {
        try await resetDemoWalletAuthorized(destination: .onboarding)
    }

    private func resetDemoWalletAuthorized(destination: WalletResetDestination) async throws {
        guard !isResettingWallet, hasNoSecretResetConflict else {
            appendLog("reset: ignored because another wallet operation is still running")
            throw AppError.walletOperationInProgress
        }

        isResettingWallet = true
        defer { isResettingWallet = false }

        appendSection("Reset Demo Wallet")

        if let warning = SessionResetPolicy.unexpiredSessionWarning(
            records: walletRecord?.sessionRecords ?? [],
            now: Date()
        ) {
            appendLog("reset: warning: \(warning)")
        }

        // Static ownership validation is non-secret. Do it before Touch ID so an external
        // sidecar that this app cannot securely erase never causes a pointless prompt.
        try WalletResetPreflight.ensureNoOtherLocalWalletInstance()
        try WalletResetPreflight.ensureNoExternalSecretRuntimes()

        let authentication = DeviceOwnerAuthenticationSession(
            reason: "Reset this wallet and delete its local keys"
        )
        defer { authentication.invalidate() }
        try await authentication.authorize()

        // Authentication suspends this actor. Recheck before crossing the destructive boundary
        // in case an operation was already queued when reset claimed its gate.
        guard hasNoSecretResetConflict else {
            appendLog("reset: cancelled because a wallet operation started during authorization")
            throw AppError.walletOperationInProgress
        }
        var localCleanupStarted = false
        do {
            try await secretResetQuiescenceHandler?()
            try await quiesceManagedWalletNodeForSecretReset()

            // This is explicitly a Demo Wallet factory reset. The daemon database contains the
            // old relayer address/keyRef mapping; preserving it while replacing the Keychain
            // secret makes the replacement impossible to install. Clear only its SQLite store
            // (not logs/config/Helios data) after the managed process has been terminated.
            try WalletNodeManagedStoreCleanup.clear()

            localCleanupStarted = true
            try WalletResetCleanup.standard(
                keyStore: keyStore,
                metadataStore: metadataStore,
                onboardingSettingsStore: onboardingSettingsStore
            ).run { step in
                appendLog("reset: cleared \(step)")
            }

            if destination.recreatesRelayer {
                // The user remains past onboarding after a settings reset. Recreate the relayer
                // identity inside this already-authorized action so the next transaction does not
                // dead-end with an empty Keychain and no funding address.
                let replacementRelayerKeyRef = "bundler-eoa:default:\(activeChain.id):1"
                let replacementRelayer = try BundlerKeyStore.shared.createIfNeeded(
                    keyRef: replacementRelayerKeyRef,
                    reason: authentication.reason,
                    authenticationContext: authentication.context
                )
                syncUnlockedRelayerAddress(
                    keyRef: replacementRelayerKeyRef,
                    secret: replacementRelayer.secret
                )
                appendLog("reset: created fresh relayer identity")
            }

            clearInMemoryWalletStateAfterReset()
            if destination.marksOnboardingIncomplete {
                onboardingSettingsStore.markIncomplete()
            }
            if destination == .dashboard {
                walletRecoveryReason = nil
            }
            lastError = nil
            bridgeStatus = destination == .dashboard
                ? "Demo wallet reset. Creating a fresh Secure Enclave key…"
                : "Local wallet reset. Return to onboarding to create a new identity."
            appendLog(
                destination == .dashboard
                    ? "reset: starting fresh bootstrap"
                    : "reset: returning to onboarding without creating replacement keys"
            )
        } catch {
            // The cleanup runner is intentionally best-effort. Once any irreversible local-key
            // deletion has started, never leave the old wallet record presented as usable.
            if localCleanupStarted {
                clearInMemoryWalletStateAfterReset()
            }
            lastError = error.localizedDescription
            bridgeStatus = "Demo wallet reset failed"
            appendLog("reset: failed: \(error.localizedDescription)")
            throw error
        }

        if destination.rebootstrapsWallet {
            bootstrap()
        }
    }

    private var hasNoSecretResetConflict: Bool {
        WalletIdleGate.allowed(
            isBootstrapping: isBootstrapping,
            isRunningDemo: isRunningDemo,
            isRefreshingBalance: isRefreshingBalance,
            isBuildingUserOperation: isBuildingUserOperation,
            isSendingUserOperation: isSendingUserOperation
        ) && !isRotatingLocalRelayer
            && !isExportingLocalRelayer
            && !isDeletingLocalRelayer
            && !isReplacingPendingOperation
    }

    private func quiesceManagedWalletNodeForSecretReset() async throws {
        stopUserOperationReconciler()
        walletNodeLaunchTask?.cancel()
        walletNodeLaunchTask = nil
        walletNodeLaunchID = nil
        relayerInstallTask?.cancel()
        relayerInstallTask = nil
        relayerStatusRefreshToken = UUID()
        isRefreshingLocalRelayer = false
        try await walletNodeDaemon?.terminateAndWait()
        walletNodeDaemon = nil
        walletNodeGeneration &+= 1
        relayerAccessState = .locked
        walletNodeClient = WalletNodeClient.Configuration.fromEnvironment().map {
            WalletNodeClient(configuration: $0)
        }
        walletNodeLaunchFailure = nil
        localRelayerStatus = nil
        localRelayerMessage = "Local relayer locked until a transaction needs it."
        optimisticNextNonce.removeAll()
    }

    private func clearInMemoryWalletStateAfterReset() {
        walletRecord = nil
        accountInspection = nil
        builtUserOperationDraft = nil
        lastUserOperationBuildError = nil
        lastSubmittedUserOperationHash = nil
        lastBundledTransactionHash = nil
        activeBundlerStatus = "Bundler not checked"
        relayerInstallTask?.cancel()
        relayerInstallTask = nil
        relayerStatusRefreshToken = UUID()
        isRefreshingLocalRelayer = false
        relayerAccessState = .locked
    }

    func runDemo() {
        guard !isResettingWallet, !isRunningDemo, !isRefreshingBalance, walletRecord != nil else {
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
                appendLog("inspect: failed: \(error.localizedDescription)")
            }

            isRunningDemo = false
        }
    }

    func refreshBalance() {
        guard isWalletIdle else {
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
                appendLog("refresh-balance: failed: \(error.localizedDescription)")
            }

            isRefreshingBalance = false
        }
    }

    func refreshOnchainAccountStatus() {
        appendSection("Refresh Onchain Status")
        refreshBalance()
        refreshLocalRelayerStatus()
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
        appendLog("network: read verification \(validated.isHeliosVerificationActive ? "helios" : "execution_rpc")")
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
        // `resetWalletNodeConnectionAfterNetworkChange` clears the pill so the new
        // chain does not inherit the old chain's number. Something then has to put
        // a number back: the app-only branch above does it, but this branch left it
        // to the app-became-active trigger, which does not fire for a switch made
        // inside the running app — so the pill read "— gwei" for the rest of the
        // session. `refreshLiveGasPrices` goes through `withWalletNodeClient`, so it
        // waits for the daemon `bootstrap()` is bringing up. Unlike the poll this
        // replaced, it is one read caused by a deliberate user action, not a timer
        // that can resurrect a daemon nobody asked for.
        Task { await refreshLiveGasPricesNow() }
    }

    func updateSessionPolicy(_ policy: SessionPolicyConfig) throws {
        settingsStore.setSessionPolicy(try policy.validated())
        appendLog("session: updated local session policy")
    }

    func sessionSigningPreview(for intent: TransactionIntent, now: Date = Date()) -> SessionSigningPreview {
        guard settingsStore.sessionKeysEnabled else {
            return .passkey(.sessionOff)
        }
        guard let walletRecord else {
            return .passkey(.noSessionRecord)
        }
        guard walletRecord.isDeployed || accountInspection?.isDeployed == true else {
            return .passkey(.accountNotDeployed)
        }
        guard let sessionRecord = walletRecord.sessionRecords.first(where: { $0.chainId == activeChain.id }) else {
            return .passkey(.noSessionRecord)
        }
        if pendingSessionRevokeByUserOpHash.values.contains(where: {
            $0.chainId == sessionRecord.chainId && $0.permissionId == sessionRecord.permissionId
        }) {
            return .passkey(.pendingRevoke)
        }
        if let reason = SessionLifecycle.expiryReason(record: sessionRecord, now: now) {
            return .passkey(.expired(reason))
        }
        guard let plan = SessionUserOperationPlan(record: sessionRecord) else {
            return .passkey(.missingSigningArtifacts)
        }
        let context = SessionPolicyContext(sessionRecord: sessionRecord, now: now)
        if let reason = SessionPolicyMirror.rejectionReason(
            intent: intent,
            config: sessionRecord.policyConfigSnapshot,
            context: context
        ) {
            return .passkey(.policy(reason))
        }
        return .session(plan.record.installedOnChain ? .active : .install)
    }

    func handleAppBecameActive(now: Date = Date()) {
        expireExpiredSessionIfNeeded(now: now, logContext: "session-resume")
        // Returning to the app is the trigger that covers an externally-funded deposit: the user
        // left, funded the account from a faucet or another wallet, and came back to check. With
        // no poll, this is the only trigger that catches money the app didn't move itself.
        Task { await refreshAccountBalanceQuietly(logContext: "balance-resume") }
        // Relayer status is public state. Refresh it without unlocking the relayer so returning
        // from a faucet updates the funding UI without asking for Touch ID.
        refreshLocalRelayerStatus()
        // Same reasoning as the balance: coming back is when a stale gas number is
        // most likely to be looked at, and about to be acted on.
        Task { await refreshLiveGasPricesIfStale(now: now) }
    }

    func recordSessionUserActivity(now: Date = Date()) {
        recordSessionActivity(now: now, source: "UI interaction", isUserInput: true)
    }

    func setSwapSlippageBps(_ bps: UInt64) {
        let clamped = SwapSlippage.clampBps(bps)
        guard swapSlippageBps != clamped else { return }
        settingsStore.setSwapSlippageBps(clamped)
        swapSlippageBps = clamped
        appendLog("transactions: swap slippage set to \(SwapSlippage.percent(fromBps: clamped))%")
    }

    func setContextWindowTokens(_ tokens: Int) {
        let model = LocalAIModel.curated.first { $0.id == onboardingSettingsStore.selectedModelID } ?? .recommended
        let clamped = ContextWindowPresets.clamp(tokens, maxTokens: model.maxContextTokens)
        guard onboardingSettingsStore.contextWindowTokens != clamped else { return }
        onboardingSettingsStore.contextWindowTokens = clamped
        appendLog("models: context window set to \(clamped) tokens (applies from the next message)")
    }

    var modelCatalog: ModelCatalog {
        ModelCatalog(installedStore: installedModelStore, downloadManager: modelDownloadManager)
    }

    func refreshHardwareBudget() async {
        hardwareBudget = await LocalHardwareInspector().budget()
    }

    func fitVerdict(for entry: ModelCatalogEntry) -> ModelFitVerdict {
        guard let hardwareBudget else { return .unknown }
        return ModelSelectionPolicy.verdict(
            entry: entry,
            contextTokens: onboardingSettingsStore.contextWindowTokens,
            budget: hardwareBudget
        )
    }

    /// Persists the choice and returns what the dashboard should activate. Takes
    /// effect on the next message; the current conversation keeps its history.
    /// AppModel deliberately does not touch the runtime — see the ownership note.
    ///
    /// The disk-presence check is the one impure input; `ModelActivationPlanner`
    /// makes the actual decision (installed-or-not, and what URL/context to
    /// activate with) so that logic is unit-testable without a real file on disk.
    func selectModel(id: String) throws -> ActiveModelSelection {
        let entry = modelCatalog.entries.first(where: { $0.id == id })
        let fileExists = entry?.installedPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        guard case let .activate(selection) = ModelActivationPlanner.decide(
            entry: entry,
            fileExists: fileExists,
            currentContextTokens: onboardingSettingsStore.contextWindowTokens
        ) else {
            throw AppError.modelNotInstalled
        }
        onboardingSettingsStore.selectedModelID = id
        onboardingSettingsStore.installedModelPath = selection.url.path
        onboardingSettingsStore.contextWindowTokens = selection.contextTokens
        modelActionMessage = "\(selection.displayName) is now active."
        appendLog("models: active model set to \(selection.displayName) at \(selection.contextTokens) tokens")
        return selection
    }

    func resolveHuggingFaceRepo(_ repoID: String) async throws -> HuggingFaceRepositoryInfo {
        try await huggingFaceRepository.info(repoID: repoID)
    }

    /// Stops the download in flight. The awaiting `downloadModel` call throws
    /// `.cancelled`, so nothing is recorded as installed and no partial file is
    /// left behind. Returns false when there was nothing to cancel.
    @discardableResult
    func cancelModelDownload() -> Bool {
        let cancelled = modelDownloadManager.cancelActiveDownload()
        if cancelled { appendLog("models: download cancelled") }
        return cancelled
    }

    /// Reads a candidate file's GGUF header over a ranged request — tens of
    /// megabytes, not the whole model — so the fit verdict is on screen *before*
    /// the user commits to a multi-gigabyte download.
    ///
    /// Never throws: a host that will not serve a partial read, or a header this
    /// parser does not understand, degrades to the "size unknown" summary carrying
    /// whatever reason there was. Not being able to predict the fit is not a reason
    /// to refuse the download.
    func inspectRemoteModel(_ file: HuggingFaceGGUFFile) async -> RemoteModelFit {
        do {
            let header = try await GGUFHeaderReader.fetch(from: file.downloadURL)
            return RemoteModelFitDescriber.describe(
                profile: header.memoryProfile(weightBytes: file.sizeBytes),
                contextTokens: onboardingSettingsStore.contextWindowTokens,
                budget: hardwareBudget
            )
        } catch {
            return RemoteModelFitDescriber.unknown(reason: error.localizedDescription)
        }
    }

    /// Downloads, verifies, reads the GGUF header from the downloaded file for a fit
    /// profile, and records the install. Does not activate the model — that is a
    /// separate, explicit step.
    ///
    /// Reads the header from the local file rather than re-fetching a ranged
    /// request over the network: the download already pulled the whole file to
    /// disk, so re-requesting up to `GGUFHeaderReader.headerProbeBytes` (24 MB)
    /// from the remote host would be a wasted round trip for bytes already
    /// sitting on disk. Failure behavior is unchanged: if the header can't be
    /// read or parsed, `profile` is nil and the install still succeeds — a nil
    /// profile surfaces later as the "Size unknown" verdict, by design.
    func downloadModel(
        _ request: ModelDownloadRequest,
        progress: @escaping LocalAIModelDownloadProgressHandler
    ) async throws {
        if let hardwareBudget {
            try LocalAIModelDownloadManager.assertDiskSpace(neededBytes: request.sizeBytes, budget: hardwareBudget)
        }
        let fileURL = try await modelDownloadManager.download(request, progress: progress)
        let profile = Self.readMemoryProfile(fileURL: fileURL, weightBytes: request.sizeBytes)
        installedModelStore.add(InstalledModel(
            id: request.modelID,
            displayName: request.displayName,
            repoID: request.repoID,
            fileName: request.fileName,
            path: fileURL.path,
            sizeBytes: request.sizeBytes,
            sha256: request.expectedSHA256,
            profile: profile
        ))
        modelActionMessage = "\(request.displayName) downloaded."
        appendLog("models: installed \(request.modelID) at \(fileURL.path)")
    }

    /// Reads the leading `GGUFHeaderReader.headerProbeBytes` of an already-downloaded
    /// file and parses it for a memory profile. Returns nil (never throws) on any
    /// failure — a missing/unparsable header degrades to the "Size unknown" verdict
    /// rather than blocking the install that already succeeded.
    private static func readMemoryProfile(fileURL: URL, weightBytes: UInt64) -> ModelMemoryProfile? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: GGUFHeaderReader.headerProbeBytes) else { return nil }
        guard let header = try? GGUFHeaderReader.parse(prefix) else { return nil }
        return header.memoryProfile(weightBytes: weightBytes)
    }

    /// Removes a custom model's file and its catalog entry. The default model can be
    /// removed too, but selection falls back to it, so the UI keeps it non-removable.
    ///
    /// The store entry is only forgotten once the file is actually gone —
    /// `ModelRemovalPlanner.mayForgetEntry` makes that call from the deletion
    /// attempt's outcome. Swallowing a deletion failure here would leave a
    /// multi-gigabyte file on disk with no remaining catalog row to find or
    /// delete it from, so a real failure is surfaced and the entry kept.
    ///
    /// What it removes is decided by `ModelRemovalPlanner.target`, not by the
    /// presence of a store record. This used to open with `guard let installed =
    /// installedModelStore.model(id: id) else { return }`, and that early return was
    /// silent: a curated model whose file `ModelCatalog` had found through its
    /// `localFileURL`/`bundledFileURL` fallbacks has no record, so Remove did
    /// nothing at all while the caller went on to report success from a stale
    /// `modelActionMessage`. Every outcome now either deletes something or throws.
    func removeModel(id: String) throws {
        guard !ModelRemovalPlanner.isBlockedBecauseActive(
            id: id,
            selectedModelID: onboardingSettingsStore.selectedModelID
        ) else {
            throw AppError.localDaemonLaunchFailed("Switch to another model before removing this one.")
        }

        let curated = LocalAIModel.curated.first { $0.id == id }
        let downloadedCopyPath = curated
            .flatMap { try? modelDownloadManager.localFileURL(for: $0) }
            .map(\.path)
            .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        let bundledCopyPath = curated
            .flatMap { modelDownloadManager.bundledFileURL(for: $0) }
            .map(\.path)
            .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }

        switch ModelRemovalPlanner.target(
            record: installedModelStore.model(id: id),
            curated: curated,
            downloadedCopyPath: downloadedCopyPath,
            bundledCopyPath: bundledCopyPath
        ) {
        case .nothingToRemove:
            throw AppError.localDaemonLaunchFailed(
                "There is nothing to remove. No file for this model is on disk."
            )
        case .bundledOnly(let displayName):
            throw AppError.localDaemonLaunchFailed(
                "\(displayName) ships inside the app bundle, so it cannot be removed here."
            )
        case .tracked(let path, let displayName):
            try deleteModelFile(at: path, displayName: displayName)
            installedModelStore.remove(id: id)
            modelActionMessage = "\(displayName) removed."
            appendLog("models: removed \(id)")
        case .untracked(let path, let displayName):
            try deleteModelFile(at: path, displayName: displayName)
            modelActionMessage = "\(displayName) removed."
            appendLog("models: removed untracked file for \(id) at \(path)")
        }
    }

    /// Deletes a model file, treating an already-missing file as success so a stale
    /// record can still be cleared, and surfacing a real failure so the caller never
    /// forgets an entry whose gigabytes are still on disk.
    private func deleteModelFile(at path: String, displayName: String) throws {
        // Refuse anything inside the .app regardless of which target resolved it: a
        // stored record can point at the embedded GGUF, and removing that would
        // break the running application's signature with no in-app recovery.
        guard !ModelRemovalPlanner.isInsideBundle(path: path, bundlePath: Bundle.main.bundlePath) else {
            throw AppError.localDaemonLaunchFailed(
                "\(displayName) ships inside the app bundle, so it cannot be removed here."
            )
        }
        let fileExistedBeforeAttempt = FileManager.default.fileExists(atPath: path)
        var deletionError: Error?
        if fileExistedBeforeAttempt {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                deletionError = error
            }
        }
        guard ModelRemovalPlanner.mayForgetEntry(
            fileExistedBeforeAttempt: fileExistedBeforeAttempt,
            deletionSucceeded: deletionError == nil
        ) else {
            throw AppError.localDaemonLaunchFailed(
                "Could not delete \(displayName) at \(path): "
                    + (deletionError?.localizedDescription ?? "unknown error")
            )
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
        walletNodeLaunchID = nil
        walletNodeLaunchFailure = nil
        walletNodeDaemon?.terminate()
        walletNodeDaemon = nil
        walletNodeGeneration &+= 1
        relayerInstallTask?.cancel()
        relayerInstallTask = nil
        relayerStatusRefreshToken = UUID()
        isRefreshingLocalRelayer = false
        relayerAccessState = .locked
        walletNodeClient = WalletNodeClient.Configuration.fromEnvironment().map {
            WalletNodeClient(configuration: $0)
        }
        optimisticNextNonce.removeAll()
        liveGasPrice = nil
        liveBaseFeeWei = nil
        liveGasUpdatedAt = nil
        // The new chain's first reading must not be suppressed as "refreshed just
        // now" by the old chain's timestamp.
        lastGasIndicatorReadAt = nil
        localRelayerStatus = nil
        localRelayerMessage = walletNodeClient == nil
            ? "Local wallet-node will restart read-only; relayer stays locked until needed."
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
            "consensusRPC=\(activeChain.consensusRPCURL?.absoluteString ?? "Not set")",
            "readVerification=\(networkSettings.isHeliosVerificationActive ? "helios" : "execution_rpc")",
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
        // Answers "why did it ask me for Touch ID so many times?" with the reasons
        // and their counts, rather than leaving it to be guessed at from the source.
        lines.append("[biometricAuthorisations]")
        lines.append(contentsOf: BiometricPromptLog.shared.reportLines(formatter: Self.debugReportDateFormatter))
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
                "readVerification=\(status.readVerification.mode)",
                "readsVerified=\(status.readVerification.verified)",
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
            let (status, generation) = try await fetchLocalRelayerStatusWithBalanceRetry()
            guard publishLocalRelayerStatus(status, expectedGeneration: generation) else {
                throw AppError.localDaemonLaunchFailed("wallet-node status became stale")
            }
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
        guard !isRefreshingLocalRelayer, !isResettingWallet else {
            return
        }

        let refreshToken = UUID()
        relayerStatusRefreshToken = refreshToken
        isRefreshingLocalRelayer = true
        Task {
            do {
                let (status, generation) = try await fetchLocalRelayerStatusWithBalanceRetry()
                guard relayerStatusRefreshToken == refreshToken else { return }
                guard publishLocalRelayerStatus(status, expectedGeneration: generation) else { return }
                appendLog("relayer: status \(status.lifecycle) \(status.eoa.shortAddress)")
            } catch {
                guard relayerStatusRefreshToken == refreshToken else { return }
                localRelayerStatus = nil
                localRelayerMessage = "Local relayer locked until a transaction needs it."
                appendLog("relayer: status failed: \(error.localizedDescription)")
            }
            if relayerStatusRefreshToken == refreshToken {
                isRefreshingLocalRelayer = false
            }
        }
    }

    func checkLocalRelayerStatusForDiagnostics() async throws -> WalletNodeClient.RelayerStatus {
        let (status, generation) = try await fetchLocalRelayerStatusWithBalanceRetry()
        guard publishLocalRelayerStatus(status, expectedGeneration: generation) else {
            throw AppError.localDaemonLaunchFailed("wallet-node status became stale")
        }
        appendLog("relayer: diagnostic status \(status.lifecycle) \(status.eoa.shortAddress)")
        return status
    }

    func monitorHeliosCheckpointAfterNetworkSettingsChange(
        _ settings: DemoNetworkSettings,
        timeout: TimeInterval = 120
    ) async throws -> SettingsHeliosCheckpointResult {
        let validated = try settings.validated()
        guard validated.isHeliosVerificationActive else {
            throw AppError.localDaemonLaunchFailed("Helios verification is not active for the selected network.")
        }

        let deadline = Date().addingTimeInterval(timeout)
        var lastStatus: WalletNodeClient.NetworkStatus?
        appendSection("Helios Checkpoint Resync")
        appendLog("network: waiting for Helios checkpoint on \(validated.activeNetworkName)")

        while true {
            let status = try await withWalletNodeClient(operation: "helios checkpoint resync") { client in
                try await client.networkStatus()
            }
            lastStatus = status
            appendLog(
                "network: helios status mode=\(status.readVerification.mode) checkpointLoaded=\(status.helios.checkpointLoaded) ready=\(status.helios.ready)"
            )

            if status.readVerification.mode == "helios", status.helios.checkpointLoaded {
                return SettingsHeliosCheckpointResult(status: status)
            }

            guard Date() < deadline else {
                let last = lastStatus.map { "\($0.status) on \($0.networkProfile)" } ?? "no status"
                throw AppError.localDaemonLaunchFailed("Timed out waiting for Helios checkpoint; last status: \(last).")
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func fetchLocalRelayerStatusWithBalanceRetry() async throws -> (
        status: WalletNodeClient.RelayerStatus,
        generation: UInt64
    ) {
        var observation = try await withWalletNodeClientGeneration(operation: "status") { client in
            try await client.bundlerStatus()
        }
        var status = observation.value
        var generation = observation.generation
        for delay in Self.relayerBalanceRetryDelays
        where status.keyLoaded && Self.isRelayerBalanceUnavailable(status.balance) {
            if RelayerGenerationGate.accepts(
                resultGeneration: generation,
                currentGeneration: walletNodeGeneration
            ) {
                publishLocalRelayerStatus(status, expectedGeneration: generation)
                localRelayerMessage = "Checking local relayer balance..."
                appendLog("relayer: status returned without balance; retrying")
            }
            try await Task.sleep(nanoseconds: delay)
            observation = try await withWalletNodeClientGeneration(operation: "status retry") { client in
                try await client.bundlerStatus()
            }
            status = observation.value
            generation = observation.generation
        }
        return (status, generation)
    }

    @discardableResult
    private func publishLocalRelayerStatus(
        _ status: WalletNodeClient.RelayerStatus,
        expectedGeneration: UInt64
    ) -> Bool {
        guard RelayerGenerationGate.accepts(
            resultGeneration: expectedGeneration,
            currentGeneration: walletNodeGeneration
        ) else {
            return false
        }
        localRelayerStatus = status
        if !status.keyLoaded, case .installing = relayerAccessState {
            // Do not let a racing passive poll overwrite an install already in progress.
        } else if !status.keyLoaded {
            relayerAccessState = .locked
        }

        switch status.reason {
        case "bundler_eoa_missing", "bundler_eoa_locked":
            localRelayerMessage = "Local relayer locked until a transaction needs it."
        default:
            localRelayerMessage = status.ready
                ? "Local relayer ready on \(status.networkProfile)."
                : "Local relayer needs funding or attention."
        }
        return true
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
        let authentication = DeviceOwnerAuthenticationSession(reason: challenge.summary)
        defer { authentication.invalidate() }
        try await authentication.authorize()
        let record = try BundlerKeyStore.shared.createIfNeeded(
            keyRef: keyRef,
            reason: challenge.summary,
            authenticationContext: authentication.context
        )
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
        guard !isResettingWallet else {
            throw AppError.walletOperationInProgress
        }
        guard let status = localRelayerStatus, let keyRef = targetKeyRef ?? status.keyRef else {
            throw AppError.localRelayerKeyMissing
        }
        guard !isExportingLocalRelayer else {
            throw AppError.localRelayerKeyMissing
        }

        isExportingLocalRelayer = true
        defer { isExportingLocalRelayer = false }
        appendSection("Export Local Relayer")
        let authentication = DeviceOwnerAuthenticationSession(
            reason: "Reveal the local relayer private key"
        )
        defer { authentication.invalidate() }
        let record = try BundlerKeyStore.shared.read(
            keyRef: keyRef,
            reason: authentication.reason,
            authenticationContext: authentication.context
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
        let authentication = DeviceOwnerAuthenticationSession(reason: challenge.summary)
        defer { authentication.invalidate() }
        try await authentication.authorize()
        try await walletNodeClient.deleteBundlerEOA(
            keyRef: keyRef,
            unsafeReset: unsafeReset,
            authorization: WalletNodeClient.AdminAuthorization(
                adminActionId: challenge.adminActionId,
                nonce: challenge.nonce
            )
        )
        try BundlerKeyStore.shared.delete(keyRef: keyRef)
        relayerInstallTask?.cancel()
        relayerInstallTask = nil
        relayerAccessState = .locked
        localRelayerStatus = nil
        localRelayerMessage = unsafeReset
            ? "Relayer key reset. Submissions stay blocked until a funded relayer exists."
            : "Relayer key deleted. Submissions stay blocked until a funded relayer exists."
        appendLog("relayer: \(unsafeReset ? "unsafe reset" : "delete") completed for \(targetLabel ?? status.eoa.shortAddress)")
        refreshLocalRelayerStatus()
    }

    @discardableResult
    func cancelPendingOperation(userOpHash: String) async -> Bool {
        guard !isResettingWallet, !isReplacingPendingOperation else { return false }
        isReplacingPendingOperation = true
        defer { isReplacingPendingOperation = false }
        defer { refreshLocalRelayerStatus() }
        do {
            appendSection("Cancel Pending Operation")
            let authentication = DeviceOwnerAuthenticationSession(
                reason: "Cancel the pending wallet operation"
            )
            defer { authentication.invalidate() }
            try await authentication.authorize()
            let txHash = try await withPrivilegedWalletNodeClient(
                operation: "cancel pending",
                authenticationSession: authentication
            ) {
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
        guard !isResettingWallet, !isReplacingPendingOperation else { return false }
        isReplacingPendingOperation = true
        defer { isReplacingPendingOperation = false }
        defer { refreshLocalRelayerStatus() }
        do {
            appendSection("Speed Up Pending Operation")
            let authentication = DeviceOwnerAuthenticationSession(
                reason: "Speed up the pending wallet operation"
            )
            defer { authentication.invalidate() }
            try await authentication.authorize()
            let txHash = try await withPrivilegedWalletNodeClient(
                operation: "speed up pending",
                authenticationSession: authentication
            ) {
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
        guard !isResettingWallet else {
            throw AppError.walletOperationInProgress
        }
        if let walletNodeClient {
            return walletNodeClient
        }
        if let walletNodeLaunchTask, let walletNodeLaunchID {
            return try await finishWalletNodeLaunch(walletNodeLaunchTask, launchID: walletNodeLaunchID)
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

        localRelayerMessage = "Starting local wallet-node daemon in read-only mode..."
        let chain = activeChain
        let gasPolicy = networkSettings.resolvedDaemonGasPolicy
        let heliosVerificationEnabled = networkSettings.isHeliosVerificationActive
        let launchTask = Task {
            return try await WalletNodeDaemon.launch(
                bundlerSecrets: [],
                chain: chain,
                gasPolicy: gasPolicy,
                heliosVerificationEnabled: heliosVerificationEnabled
            )
        }
        let launchID = UUID()
        walletNodeLaunchTask = launchTask
        walletNodeLaunchID = launchID
        return try await finishWalletNodeLaunch(launchTask, launchID: launchID)
    }

    private func finishWalletNodeLaunch(
        _ task: Task<WalletNodeDaemon, Error>,
        launchID: UUID
    ) async throws -> WalletNodeClient {
        do {
            let daemon = try await task.value

            // A cancelled detached launch can still finish. Only the launch that still owns the
            // current token may publish a daemon. Another waiter may already have adopted the
            // exact same result, which is also safe.
            guard walletNodeLaunchID == launchID || walletNodeDaemon === daemon else {
                daemon.terminate()
                throw AppError.localDaemonLaunchFailed(
                    "wallet-node launch became stale after a connection reset"
                )
            }
            if walletNodeDaemon !== daemon {
                walletNodeLaunchTask = nil
                walletNodeLaunchID = nil
                walletNodeLaunchFailure = nil
                adoptManagedWalletNodeDaemon(daemon)
            }
            return daemon.client
        } catch {
            guard walletNodeLaunchID == launchID else {
                throw error
            }
            walletNodeLaunchTask = nil
            walletNodeLaunchID = nil
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

    private func adoptManagedWalletNodeDaemon(_ daemon: WalletNodeDaemon) {
        guard walletNodeDaemon !== daemon else { return }
        walletNodeDaemon = daemon
        walletNodeClient = daemon.client
        walletNodeGeneration &+= 1
        relayerInstallTask?.cancel()
        relayerInstallTask = nil
        relayerAccessState = .locked
        localRelayerMessage = "Local wallet-node connected; relayer locked until needed."
        appendLog("relayer: wallet-node daemon started read-only")
        if let logURL = WalletNodeDaemon.managedLogFileURL() {
            appendLog("relayer: wallet-node logs \(logURL.path)")
        }
    }

    /// Installs only the relayer keys needed by the active daemon generation. The managed
    /// daemon deliberately starts without secrets, so reads remain prompt-free; the first
    /// privileged action supplies its short-lived authentication context here.
    private func ensureRelayerUnlocked(
        using authenticationSession: DeviceOwnerAuthenticationSession
    ) async throws -> WalletNodeClient {
        let (client, generation) = try await ensureWalletNodeClientWithGeneration()
        guard client.usesUnixSocketTransport, walletNodeDaemon != nil else {
            // An externally managed daemon owns its own relayer-key lifecycle.
            return client
        }
        if relayerAccessState.isAvailable(for: walletNodeGeneration) {
            return client
        }
        if let relayerInstallTask {
            return try await relayerInstallTask.value
        }

        relayerAccessState = .installing(generation: generation)
        localRelayerMessage = "Unlocking the local relayer for this action..."
        let task = Task { @MainActor [self] in
            let observedStatus = try await client.bundlerStatus()
            guard walletNodeGeneration == generation else {
                throw AppError.localDaemonLaunchFailed(
                    "wallet-node restarted while the relayer was being unlocked. Retry the action."
                )
            }
            publishLocalRelayerStatus(observedStatus, expectedGeneration: generation)

            let keyRefs = relevantRelayerKeyRefs(status: observedStatus)
            guard !keyRefs.isEmpty else {
                throw AppError.localRelayerKeyMissing
            }

            var latestStatus = observedStatus
            for keyRef in keyRefs {
                try Task.checkCancellation()
                guard walletNodeGeneration == generation else {
                    throw AppError.localDaemonLaunchFailed(
                        "wallet-node restarted while the relayer was being unlocked. Retry the action."
                    )
                }
                let challenge = try await client.beginAdminAction(
                    action: "install_bundler_eoa",
                    chainId: Int(activeChain.id),
                    keyRef: keyRef
                )
                let record = try BundlerKeyStore.shared.read(
                    keyRef: keyRef,
                    reason: authenticationSession.reason,
                    authenticationContext: authenticationSession.context
                )
                // Only the first ref is the active identity. Retiring keys are loaded solely so
                // pending replacements remain signable and must never overwrite the cached
                // funding address shown before the next daemon has status metadata.
                if keyRef == keyRefs.first {
                    syncUnlockedRelayerAddress(keyRef: keyRef, secret: record.secret)
                }
                latestStatus = try await client.installBundlerEOA(
                    keyRef: keyRef,
                    secret: record.secret,
                    authorization: WalletNodeClient.AdminAuthorization(
                        adminActionId: challenge.adminActionId,
                        nonce: challenge.nonce
                    )
                )
            }

            guard walletNodeGeneration == generation else {
                throw AppError.localDaemonLaunchFailed(
                    "wallet-node restarted while the relayer was being unlocked. Retry the action."
                )
            }
            publishLocalRelayerStatus(latestStatus, expectedGeneration: generation)
            relayerAccessState = .available(generation: generation)
            localRelayerMessage = "Local relayer available for this wallet-node session."
            appendLog("relayer: installed \(keyRefs.count) relevant key(s) for daemon generation \(generation)")
            return client
        }
        relayerInstallTask = task

        do {
            let installedClient = try await task.value
            relayerInstallTask = nil
            return installedClient
        } catch {
            relayerInstallTask = nil
            if walletNodeGeneration == generation {
                relayerAccessState = .failed(
                    generation: generation,
                    message: error.localizedDescription
                )
                localRelayerMessage = error.localizedDescription
            }
            throw error
        }
    }

    /// Active always comes first. A retiring key is still relevant while one of its submitted
    /// transactions may need cancellation or replacement; pending-funding and retired keys are
    /// intentionally left locked.
    private func relevantRelayerKeyRefs(
        status: WalletNodeClient.RelayerStatus?
    ) -> [String] {
        RelayerKeyInstallPolicy.relevantKeyRefs(
            activeKeyRef: status?.keyRef,
            fallbackKeyRef: onboardingSettingsStore.bundlerKeyRef(chainId: activeChain.id),
            history: (status?.keyHistory ?? []).map {
                RelayerKeyInstallPolicy.HistoryEntry(
                    keyRef: $0.keyRef,
                    lifecycle: $0.lifecycle
                )
            }
        )
    }

    private func syncUnlockedRelayerAddress(keyRef: String, secret: Data) {
        guard let chainId = BundlerLaunchKeyPolicy.chainId(ofKeyRef: keyRef) else {
            appendLog("relayer: could not sync cached relayer address - unrecognized keyRef \(keyRef)")
            return
        }
        do {
            let address = try RelayerAddressCachePolicy.address(fromSecret: secret)
            onboardingSettingsStore.setBundlerKeyRef(keyRef, chainId: chainId)
            guard RelayerAddressCachePolicy.shouldUpdate(
                cached: onboardingSettingsStore.bundlerAddress(chainId: chainId),
                unlocked: address
            ) else {
                return
            }

            onboardingSettingsStore.setBundlerAddress(address, chainId: chainId)
            appendLog("relayer: synced cached relayer address \(address.shortAddress)")
        } catch {
            appendLog("relayer: could not sync cached relayer address - \(error.localizedDescription)")
        }
    }

    private func ensureWalletNodeClientWithGeneration() async throws -> (
        client: WalletNodeClient,
        generation: UInt64
    ) {
        let client = try await ensureWalletNodeClient()
        let generation = walletNodeGeneration
        guard walletNodeClient?.hasSameConnection(as: client) == true else {
            throw AppError.localDaemonLaunchFailed(
                "wallet-node connection changed before the operation could start"
            )
        }
        return (client, generation)
    }

    private func withWalletNodeClientGeneration<T: Sendable>(
        operation: String,
        _ body: (WalletNodeClient) async throws -> T
    ) async throws -> (value: T, generation: UInt64) {
        try await withWalletNodeClient(operation: operation) { client in
            let value = try await body(client)
            return (value, self.walletNodeGeneration)
        }
    }

    private func withWalletNodeClient<T: Sendable>(
        operation: String,
        afterRelaunch: ((WalletNodeClient) async throws -> Void)? = nil,
        _ body: (WalletNodeClient) async throws -> T
    ) async throws -> T {
        let client = try await ensureWalletNodeClient()
        let generation = walletNodeGeneration

        do {
            let result = try await body(client)
            guard walletNodeGeneration == generation else {
                throw AppError.localDaemonLaunchFailed(
                    "wallet-node connection changed while \(operation) was in flight"
                )
            }
            return result
        } catch {
            guard client.usesUnixSocketTransport,
                  walletNodeDaemon != nil,
                  WalletNodeClient.isRecoverableUnixSocketFailure(error)
            else {
                throw error
            }

            appendLog("relayer: \(operation) lost wallet-node socket; relaunching daemon and retrying once")
            walletNodeLaunchTask = nil
            walletNodeLaunchID = nil
            walletNodeClient = nil
            walletNodeDaemon?.terminate()
            walletNodeDaemon = nil
            walletNodeGeneration &+= 1
            relayerInstallTask?.cancel()
            relayerInstallTask = nil
            relayerAccessState = .locked

            let relaunchedClient = try await ensureWalletNodeClient()
            let relaunchedGeneration = walletNodeGeneration
            try await afterRelaunch?(relaunchedClient)
            let result = try await body(relaunchedClient)
            guard walletNodeGeneration == relaunchedGeneration else {
                throw AppError.localDaemonLaunchFailed(
                    "wallet-node connection changed while retrying \(operation)"
                )
            }
            return result
        }
    }

    private func withPrivilegedWalletNodeClient<T: Sendable>(
        operation: String,
        authenticationSession: DeviceOwnerAuthenticationSession,
        _ body: (WalletNodeClient) async throws -> T
    ) async throws -> T {
        _ = try await withWalletNodeClient(operation: "\(operation) relayer unlock") { _ in
            try await self.ensureRelayerUnlocked(using: authenticationSession)
        }
        return try await withWalletNodeClient(
            operation: operation,
            afterRelaunch: { [self] _ in
                _ = try await ensureRelayerUnlocked(using: authenticationSession)
            },
            body
        )
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
            intent: intent,
            sessionMode: nonceKey192 != nil
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
        guard !isResettingWallet, !isBootstrapping, !isBuildingUserOperation, !isSendingUserOperation else {
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

                let usePrecompiled = await resolveUsePrecompiled(logContext: "build")
                let enrichedDraft = try await enrichDraftWithLocalBundlerEstimation(
                    draft,
                    logContext: "build",
                    usePrecompiled: usePrecompiled
                ).draft
                builtUserOperationDraft = enrichedDraft

                let initCodeMode = enrichedDraft.initCode.isEmpty ? "existing account path" : "deployment path included"
                bridgeStatus = "Unsigned UserOperation draft built for \(activeChain.name) with \(initCodeMode). Gas estimated through local wallet-node."

                appendLog("build: completed successfully")
            } catch {
                lastUserOperationBuildError = error.localizedDescription
                activeBundlerStatus = "Bundler check failed"
                bridgeStatus = "UserOperation draft build failed"
                appendLog("build: failed: \(error.localizedDescription)")
            }

            isBuildingUserOperation = false
        }
    }

    func sendCurrentUserOperation() {
        guard !isResettingWallet, !isBootstrapping, !isBuildingUserOperation, !isSendingUserOperation else {
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
                appendLog("send: failed: \(error.localizedDescription)")
            }

            isSendingUserOperation = false
        }
    }

    @discardableResult
    func enableSessionKeys(now: Date = Date()) async throws -> SessionRecord {
        guard !isResettingWallet, !isBootstrapping, !isBuildingUserOperation, !isSendingUserOperation else {
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

        let usePrecompiled = await resolveUsePrecompiled(logContext: "session-enable")
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
                    reason: "Enable session keys for \(activeChain.name)",
                    usePrecompiled: usePrecompiled
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

    @discardableResult
    func revokeSessionKeys() async throws -> UserOperationSendResult {
        guard !isResettingWallet, !isBootstrapping, !isBuildingUserOperation, !isSendingUserOperation else {
            throw AppError.walletOperationInProgress
        }
        if walletRecord == nil {
            bootstrap()
        }
        guard let record = walletRecord,
              let accountAddress = record.kernelAccountAddress
        else {
            throw AppError.corruptedMetadataStore
        }
        guard let sessionRecord = record.sessionRecords.first(where: { $0.chainId == activeChain.id }) else {
            throw AppError.sessionKeysNotEnabled
        }
        if !settingsStore.sessionKeysEnabled {
            appendLog("session-revoke: local toggle is off, but a session record exists; revoking anyway")
        }
        guard sessionRecord.installedOnChain else {
            try clearPendingSessionKeyLocally(
                sessionRecord,
                from: record,
                now: Date(),
                logContext: "session-revoke",
                reason: "cleared pending session key locally; no onchain permission was installed"
            )
            return UserOperationSendResult(
                userOpHash: "local-session-key-clear",
                transactionHash: nil,
                success: true,
                signedBySession: false
            )
        }

        let deinitData = try WalletSignature.sessionEmptyPermissionDeinitData(enableData: sessionRecord.enableData)
        let execution = try SessionRevokeAssembler.executionRequest(
            accountAddress: accountAddress,
            permissionId: sessionRecord.permissionId,
            deinitData: deinitData,
            calldataBuilder: { permissionId, deinitData in
                try WalletSignature.sessionUninstallPermissionCalldata(
                    permissionId: permissionId,
                    deinitData: deinitData
                )
            }
        )

        return try await executeUserOperation(
            logContext: "session-revoke",
            signingReason: "Revoke session keys for \(activeChain.name)",
            intent: nil,
            callValue: UserOperationCallValue.zero,
            historyDraft: SessionRevokeAssembler.historyDraft(
                accountAddress: accountAddress,
                validationNonce: sessionRecord.validationNonce
            ),
            afterSubmit: { [self] userOpHash in
                pendingSessionRevokeByUserOpHash[userOpHash.lowercased()] = sessionRecord
                objectWillChange.send()
                settingsStore.setSessionKeysEnabled(false)
                appendLog("session-revoke: disabled local session signing while waiting for revoke receipt")
            }
        ) { [self] buildContext in
            guard buildContext.isDeployed else {
                throw AppError.sessionKeysRequireDeployedAccount
            }
            return try await buildUserOperationDraft(
                executions: [execution],
                isDeployedOverride: true,
                nonceKey192: nil
            )
        }
    }

    @discardableResult
    func revokeSessionKeysAndWaitForReceipt() async throws -> UserOperationSendResult {
        let chainID = activeChain.id
        let submitted = try await revokeSessionKeys()
        if submitted.success != nil {
            activeBundlerStatus = "Session key disabled"
            bridgeStatus = "Session key disabled locally."
            return submitted
        }
        bridgeStatus = "Session key revoke submitted. Waiting for the receipt."
        activeBundlerStatus = "Waiting for revoke receipt"

        let receipt = try await waitForLocalReceipt(
            userOpHash: submitted.userOpHash,
            chainID: chainID,
            logContext: "session-revoke"
        )

        recordReceiptHistory(receipt, chainID: chainID, logContext: "session-revoke")
        guard receipt.success else {
            activeBundlerStatus = "Revoke reverted"
            bridgeStatus = "Session key revoke reverted."
            let reason: String
            if let revertReason = receipt.revertReason, !revertReason.isEmpty {
                reason = "Session key revoke reverted: \(revertReason)"
            } else {
                reason = "Session key revoke reverted onchain."
            }
            throw AppError.userOperationReceiptReverted(reason)
        }

        activeBundlerStatus = "Session key disabled"
        bridgeStatus = "Session key revoke confirmed onchain."
        return UserOperationSendResult(
            userOpHash: receipt.userOpHash,
            transactionHash: receipt.txHash,
            success: receipt.success,
            signedBySession: submitted.signedBySession
        )
    }

    /// Installs the session permission on-chain via a passkey(root)-validated user
    /// op before its first use. The install (installValidations + grantAccess) runs
    /// in the execution phase, so it is paid as a normal transaction and is NOT
    /// charged against the permission's GasPolicy. Blocks until the receipt confirms;
    /// afterwards the permission validates in installed mode. No-op when there is no
    /// applicable session plan or it is already installed.
    private func installSessionPermissionIfNeeded(
        for intent: TransactionIntent,
        logContext: String
    ) async throws {
        let now = Date()
        guard let plan = activeSessionPlan(for: intent, now: now), !plan.record.installedOnChain else {
            return
        }
        guard let currentRecord = walletRecord,
              let accountAddress = currentRecord.kernelAccountAddress
        else {
            return
        }
        let sessionRecord = plan.record
        appendLog("\(logContext): session permission not installed onchain; installing via passkey before first use")

        // installValidations requires config.nonce == the account's current install
        // nonce, so read it fresh rather than trusting the stored value.
        let installNonce = try await withWalletNodeWarmupRetry(
            operation: "\(logContext) session-install currentNonce"
        ) {
            try await withWalletNodeClient(
                operation: "\(logContext) session-install currentNonce"
            ) { client in
                try await client.kernelCurrentNonce(accountAddress: accountAddress)
            }
        }

        let installCalldata = try WalletSignature.sessionInstallValidationsCalldata(
            permissionId: sessionRecord.permissionId,
            nonce: installNonce,
            validationData: sessionRecord.enableData
        )
        let grantCalldata = try WalletSignature.sessionGrantAccessCalldata(
            permissionId: sessionRecord.permissionId,
            selector: Data([0xe9, 0xae, 0x5c, 0x53])
        )
        let executions = try SessionInstallAssembler.executions(
            accountAddress: accountAddress,
            installCalldata: installCalldata,
            grantCalldata: grantCalldata
        )

        bridgeStatus = "Preparing session key (one-time on-chain setup)…"
        activeBundlerStatus = "Installing session key"
        let submitted = try await executeUserOperation(
            logContext: "\(logContext) session-install",
            signingReason: "Activate session key for \(activeChain.name)",
            intent: nil,
            callValue: UserOperationCallValue.zero,
            historyDraft: SessionInstallAssembler.historyDraft(
                accountAddress: accountAddress,
                validationNonce: installNonce
            )
        ) { [self] buildContext in
            guard buildContext.isDeployed else {
                throw AppError.sessionKeysRequireDeployedAccount
            }
            return try await buildUserOperationDraft(
                executions: executions,
                isDeployedOverride: true,
                nonceKey192: nil
            )
        }

        let chainID = activeChain.id
        if submitted.success == nil {
            bridgeStatus = "Session key setup submitted. Waiting for confirmation…"
            activeBundlerStatus = "Waiting for session key setup"
            let receipt = try await waitForLocalReceipt(
                userOpHash: submitted.userOpHash,
                chainID: chainID,
                logContext: "\(logContext) session-install"
            )
            recordReceiptHistory(receipt, chainID: chainID, logContext: "\(logContext) session-install")
            guard receipt.success else {
                let reason: String
                if let revertReason = receipt.revertReason, !revertReason.isEmpty {
                    reason = "Session key setup reverted: \(revertReason)"
                } else {
                    reason = "Session key setup reverted onchain."
                }
                throw AppError.userOperationReceiptReverted(reason)
            }
        }

        guard let latestRecord = walletRecord else { return }
        var installedRecord = latestRecord.sessionRecords.first {
            $0.chainId == chainID && $0.permissionId == sessionRecord.permissionId
        } ?? sessionRecord
        installedRecord.installedOnChain = true
        let refreshed = latestRecord.replacingSessionRecord(
            installedRecord,
            isDeployed: latestRecord.isDeployed,
            updatedAt: Date()
        )
        try metadataStore.save(refreshed)
        self.walletRecord = refreshed
        appendLog("\(logContext): session permission installed onchain; send will use installed mode")
    }

    func executeNativeTransfer(
        recipient: String,
        amountETH: String,
        logContext: String = "transfer",
        signingReason: String? = nil,
        acknowledgedCallGasLimit: UInt64? = nil
    ) async throws -> UserOperationSendResult {
        try await executeTransfer(
            intent: .nativeTransfer(recipient: recipient, amountETH: amountETH),
            logContext: logContext,
            signingReason: signingReason ?? "Authorize ETH transfer on \(activeChain.name)",
            acknowledgedCallGasLimit: acknowledgedCallGasLimit
        )
    }

    /// A Kernel-funded relayer top-up is always owner-authorized. Before any
    /// authentication, its finalized UserOperation is checked against a fresh
    /// daemon balance using the same outer-transaction gas formula as wallet-node.
    func executeBundlerTopUp(
        identity: VerifiedRelayerIdentity,
        amountETH: String,
        logContext: String,
        signingReason: String
    ) async throws -> UserOperationSendResult {
        try await executeTransfer(
            intent: .nativeTransfer(recipient: identity.address, amountETH: amountETH),
            logContext: logContext,
            signingReason: signingReason,
            purpose: .bundlerTopUp(expectedIdentity: identity)
        )
    }

    struct BundlerTopUpSendResult: Equatable {
        let recipient: String
        let sendResult: UserOperationSendResult
    }

    /// Resolves the current relayer from trusted daemon state and refuses an
    /// intent whose reviewed destination is no longer current. The delegated
    /// send performs the exact relay-cost check again before authentication.
    func executeCurrentBundlerTopUp(
        expectedIdentity: VerifiedRelayerIdentity,
        amountETH: String,
        logContext: String,
        signingReason: String
    ) async throws -> BundlerTopUpSendResult {
        guard expectedIdentity.chainID == activeChain.id,
              try BundlerKeyStore.shared.verifiedIdentity(
                  forKeyRef: expectedIdentity.keyRef
              ) == expectedIdentity else {
            throw AppError.bundlerRelayPreflightUnavailable(
                "The reviewed relayer identity is no longer available in Keychain."
            )
        }
        let observation = try await fetchLocalRelayerStatusWithBalanceRetry()
        guard publishLocalRelayerStatus(
            observation.status,
            expectedGeneration: observation.generation
        ) else {
            throw AppError.bundlerRelayPreflightUnavailable(
                "The local relayer status changed while preparing the top-up."
            )
        }
        do {
            try RelayerIdentityBindingPolicy.verify(
                status: observation.status,
                against: expectedIdentity
            )
        } catch {
            throw AppError.bundlerRelayPreflightUnavailable(
                "The local relayer identity changed while preparing the top-up."
            )
        }

        let sendResult = try await executeBundlerTopUp(
            identity: expectedIdentity,
            amountETH: amountETH,
            logContext: logContext,
            signingReason: signingReason
        )
        return BundlerTopUpSendResult(
            recipient: expectedIdentity.address,
            sendResult: sendResult
        )
    }

    /// One authoritative gate shared before and after authentication. The second call catches
    /// daemon restarts, relayer rotation, compromise flags, and balance movement during the
    /// Touch ID window without duplicating the identity or relay-cost policy.
    private func verifiedBundlerRelayDecision(
        expectedIdentity: VerifiedRelayerIdentity,
        gasPlan: UserOperationGasPlan,
        requiredPrefund: Data,
        logContext: String,
        phase: String
    ) async throws -> BundlerRelayPrecheck.Decision {
        do {
            guard expectedIdentity.chainID == activeChain.id,
                  try BundlerKeyStore.shared.verifiedIdentity(
                      forKeyRef: expectedIdentity.keyRef
                  ) == expectedIdentity else {
                throw AppError.bundlerRelayPreflightUnavailable(
                    "The reviewed relayer identity is no longer available in Keychain."
                )
            }
        } catch let error as AppError {
            throw error
        } catch {
            appendLog("\(logContext): \(phase) Keychain identity rejected: \(error.localizedDescription)")
            throw AppError.bundlerRelayPreflightUnavailable(
                "The app could not verify the reviewed relayer identity in Keychain."
            )
        }

        let observation: (status: WalletNodeClient.RelayerStatus, generation: UInt64)
        do {
            observation = try await fetchLocalRelayerStatusWithBalanceRetry()
        } catch {
            appendLog("\(logContext): \(phase) relayer status unavailable: \(error.localizedDescription)")
            throw AppError.bundlerRelayPreflightUnavailable(
                "Could not verify the local relayer status."
            )
        }
        guard publishLocalRelayerStatus(
            observation.status,
            expectedGeneration: observation.generation
        ) else {
            throw AppError.bundlerRelayPreflightUnavailable(
                "The local relayer status changed while checking the top-up."
            )
        }

        do {
            try RelayerIdentityBindingPolicy.verify(
                status: observation.status,
                against: expectedIdentity
            )
        } catch {
            appendLog("\(logContext): \(phase) relayer identity rejected: \(String(describing: error))")
            throw AppError.bundlerRelayPreflightUnavailable(
                "The local relayer identity or safety state changed."
            )
        }

        do {
            return try BundlerRelayPrecheck.evaluate(
                gasPlan: gasPlan,
                requiredPrefund: requiredPrefund,
                status: observation.status,
                expectedChainID: activeChain.id,
                expectedEOA: expectedIdentity.address
            )
        } catch {
            appendLog("\(logContext): \(phase) relay data rejected: \(String(describing: error))")
            throw AppError.bundlerRelayPreflightUnavailable(
                "The local relayer returned inconsistent balance or gas data."
            )
        }
    }

    func executeERC20Transfer(
        token: WalletToken,
        recipient: String,
        amount: String,
        logContext: String = "transfer",
        signingReason: String? = nil,
        acknowledgedCallGasLimit: UInt64? = nil
    ) async throws -> UserOperationSendResult {
        try await executeTransfer(
            intent: .erc20Transfer(token: token, recipient: recipient, amount: amount),
            logContext: logContext,
            signingReason: signingReason ?? "Authorize \(amount) \(token.symbol) transfer on \(activeChain.name)",
            acknowledgedCallGasLimit: acknowledgedCallGasLimit
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
        slippageBps: UInt64? = nil
    ) async throws -> SwapQuote {
        let resolvedSlippageBps = slippageBps ?? swapSlippageBps
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
                slippageBps: resolvedSlippageBps,
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
        signingReason: String? = nil,
        acknowledgedCallGasLimit: UInt64? = nil
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
            signingReason: signingReason ?? defaultSigningReason,
            acknowledgedCallGasLimit: acknowledgedCallGasLimit
        )
    }

    func executeBatch(
        executions: [KernelExecutionRequest],
        logContext: String = "batch",
        signingReason: String? = nil,
        acknowledgedCallGasLimit: UInt64? = nil
    ) async throws -> UserOperationSendResult {
        let callValue = try UserOperationCallValue.wei(for: executions)
        return try await executeUserOperation(
            logContext: logContext,
            signingReason: signingReason ?? "Authorize \(executions.count) transaction batch on \(activeChain.name)",
            intent: nil,
            callValue: callValue,
            historyDraft: WalletTransactionDraft(
                operation: .batch,
                amount: String(executions.count),
                token: executions.count == 1 ? "call" : "calls"
            ),
            acknowledgedCallGasLimit: acknowledgedCallGasLimit
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
        signingReason: String,
        acknowledgedCallGasLimit: UInt64? = nil,
        purpose: UserOperationExecutionPurpose = .standard
    ) async throws -> UserOperationSendResult {
        // Lazily install the session permission on its first use (a separate
        // passkey-validated op) so the one-time install runs in execution and is
        // not charged to the session GasPolicy. Afterwards this send is installed-mode.
        if purpose.allowsSessionSigning {
            try await installSessionPermissionIfNeeded(for: intent, logContext: logContext)
        }
        let callValue = try UserOperationCallValue.wei(for: intent)
        return try await executeUserOperation(
            logContext: logContext,
            signingReason: signingReason,
            intent: intent,
            callValue: callValue,
            historyDraft: historyDraft(for: intent),
            purpose: purpose,
            acknowledgedCallGasLimit: acknowledgedCallGasLimit
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
        callValue: Data,
        historyDraft: WalletTransactionDraft?,
        purpose: UserOperationExecutionPurpose = .standard,
        afterSubmit: ((String) -> Void)? = nil,
        acknowledgedCallGasLimit: UInt64? = nil,
        buildDraft: @escaping (_ buildContext: UserOperationBuildContext) async throws -> UserOperationDraft
    ) async throws -> UserOperationSendResult {
        guard !isResettingWallet, !isBootstrapping, !isBuildingUserOperation, !isSendingUserOperation else {
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
                callValue: callValue,
                historyDraft: historyDraft,
                purpose: purpose,
                afterSubmit: afterSubmit,
                acknowledgedCallGasLimit: acknowledgedCallGasLimit,
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
        callValue: Data,
        historyDraft: WalletTransactionDraft?,
        purpose: UserOperationExecutionPurpose,
        afterSubmit: ((String) -> Void)? = nil,
        acknowledgedCallGasLimit: UInt64? = nil,
        buildDraft: (_ buildContext: UserOperationBuildContext) async throws -> UserOperationDraft
    ) async throws -> UserOperationSendResult {
        appendLog("\(logContext): preparing transaction on \(activeChain.name)")

        let liveInspection = try await refreshAccountInspectionWithRetry(logContext: "\(logContext)-preflight")
        appendLog("\(logContext): using \(liveInspection.isDeployed ? "deployed" : "precomputed") account path")

        var sessionPlan = purpose.allowsSessionSigning
            ? intent.flatMap {
                liveInspection.isDeployed ? activeSessionPlan(for: $0, now: Date()) : nil
            }
            : nil
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
        var draft: UserOperationDraft
        do {
            draft = try await buildDraft(buildContext)
        } catch {
            clearPendingSessionInstallAfterPreSubmitFailure(sessionPlan, logContext: logContext)
            throw error
        }
        appendDraftLogSummary(draft, context: logContext)

        let usePrecompiled = await resolveUsePrecompiled(logContext: logContext)

        func rebuildFreshOwnerOperation(
            context: String
        ) async throws -> (UserOperationDraft, EnrichedUserOperation) {
            let ownerDraft = try await buildDraft(
                UserOperationBuildContext(
                    isDeployed: liveInspection.isDeployed,
                    sessionPlan: nil
                )
            )
            appendDraftLogSummary(ownerDraft, context: context)
            let ownerOperation = try await enrichDraftWithLocalBundlerEstimation(
                ownerDraft,
                logContext: context,
                usePrecompiled: usePrecompiled,
                sessionPlan: nil,
                acknowledgedCallGasLimit: acknowledgedCallGasLimit
            )
            return (ownerDraft, ownerOperation)
        }

        var enriched: EnrichedUserOperation
        do {
            enriched = try await enrichDraftWithLocalBundlerEstimation(
                draft,
                logContext: logContext,
                usePrecompiled: usePrecompiled,
                sessionPlan: sessionPlan,
                acknowledgedCallGasLimit: acknowledgedCallGasLimit
            )
        } catch {
            guard SessionGasAuthorizationFallback.requiresFreshOwnerDraft(
                after: error,
                hadSessionPlan: sessionPlan != nil
            ) else {
                clearPendingSessionInstallAfterPreSubmitFailure(sessionPlan, logContext: logContext)
                throw error
            }

            // A session nonce/signature shape is not valid input to the owner
            // signer. Throw it away and rebuild from the original intent using
            // the root nonce path, then obtain a fresh fee quote and authorize
            // that distinct operation independently.
            appendLog(
                "\(logContext): session gas liability exceeds its local budget; rebuilding a fresh owner operation"
            )
            clearPendingSessionInstallAfterPreSubmitFailure(sessionPlan, logContext: logContext)
            sessionPlan = nil
            (draft, enriched) = try await rebuildFreshOwnerOperation(
                context: "\(logContext)-owner-fallback"
            )
        }

        // Estimation can itself take long enough for the fee quote to age. Do
        // one complete rebuild before prompting. This avoids asking for Touch ID
        // and only then discovering that the operation was already stale.
        do {
            for refreshAttempt in 0..<2 {
                let head = try await ExecutionFeeOracle().currentBlockNumber(
                    rpcURL: activeChain.rpcURL,
                    expectedChainID: activeChain.id
                )
                do {
                    try enriched.operation.feeQuote.validateFreshness(
                        now: Date(),
                        currentBlockNumber: head
                    )
                    break
                } catch {
                    guard refreshAttempt == 0,
                          FeeAuthorizationRefreshPolicy.shouldRefresh(after: error)
                    else {
                        throw error
                    }
                    appendLog(
                        "\(logContext): fee quote aged during estimation; rebuilding authorization before key access"
                    )
                    do {
                        enriched = try await enrichDraftWithLocalBundlerEstimation(
                            draft,
                            logContext: "\(logContext)-fee-refresh",
                            usePrecompiled: usePrecompiled,
                            sessionPlan: sessionPlan,
                            acknowledgedCallGasLimit: acknowledgedCallGasLimit
                        )
                    } catch {
                        guard SessionGasAuthorizationFallback.requiresFreshOwnerDraft(
                            after: error,
                            hadSessionPlan: sessionPlan != nil
                        ) else {
                            throw error
                        }
                        clearPendingSessionInstallAfterPreSubmitFailure(
                            sessionPlan,
                            logContext: logContext
                        )
                        sessionPlan = nil
                        (draft, enriched) = try await rebuildFreshOwnerOperation(
                            context: "\(logContext)-fee-refresh-owner-fallback"
                        )
                    }
                }
            }
        } catch {
            clearPendingSessionInstallAfterPreSubmitFailure(sessionPlan, logContext: logContext)
            throw error
        }
        let enrichedDraft = enriched.draft
        builtUserOperationDraft = enrichedDraft

        // Every operation must be affordable at its locally authorized maximum
        // liability, including native value sent by the call, before any signing
        // key is touched. callGasLimit is inside the UserOperation hash, so
        // nothing downstream can change it without invalidating the signature
        // we are about to request.
        switch await PrefundPrecheck.decision(
            requiredPrefund: enriched.requiredPrefund,
            callValue: callValue,
            callGasLimit: enrichedDraft.gasPlan.callGasLimit,
            maxFeePerGas: enrichedDraft.gasPlan.maxFeePerGas,
            feeQuoteAtPolicyCeiling: false,
            readWalletStatus: {
                try await withWalletNodeClient(operation: "\(logContext) wallet status") { client in
                    try await client.walletStatus(smartAccount: enrichedDraft.sender)
                }
            }
        ) {
        case .proceed:
            break
        case let .statusUnavailable(error):
            appendLog(
                "\(logContext): wallet status unavailable (\(error.localizedDescription)); declining before signature"
            )
            clearPendingSessionInstallAfterPreSubmitFailure(sessionPlan, logContext: logContext)
            throw AppError.localDaemonLaunchFailed(
                "Could not verify the account balance and EntryPoint deposit before signing. Retry when wallet-node is available."
            )
        case let .decline(report):
            appendLog(
                "\(logContext): declining before signature: requiredPrefund=\(report.requiredPrefundWeiHex) available=\(report.availableWeiHex) deficit=\(report.deficitWeiHex)"
            )
            clearPendingSessionInstallAfterPreSubmitFailure(sessionPlan, logContext: logContext)
            throw AppError.prefundShortfall(report)
        case let .accountBalanceDecline(report):
            appendLog(
                "\(logContext): declining native-value operation before signature: callValue=\(report.callValueWeiHex) gasBalanceRequired=\(report.gasBalanceRequiredWeiHex) minimumAccountBalance=\(report.minimumAccountBalanceWeiHex) accountBalance=\(report.accountBalanceWeiHex) deficit=\(report.deficitWeiHex)"
            )
            clearPendingSessionInstallAfterPreSubmitFailure(sessionPlan, logContext: logContext)
            throw AppError.accountBalanceShortfall(report)
        }

        if case let .bundlerTopUp(expectedIdentity) = purpose {
            let relayDecision: BundlerRelayPrecheck.Decision
            do {
                relayDecision = try await verifiedBundlerRelayDecision(
                    expectedIdentity: expectedIdentity,
                    gasPlan: enrichedDraft.gasPlan,
                    requiredPrefund: enriched.requiredPrefund,
                    logContext: logContext,
                    phase: "pre-auth"
                )
            } catch {
                clearPendingSessionInstallAfterPreSubmitFailure(
                    sessionPlan,
                    logContext: logContext
                )
                throw error
            }

            switch relayDecision {
            case .proceed:
                appendLog("\(logContext): exact relayer-cost preflight passed")
            case .externalFundingRequired(let report):
                appendLog(
                    "\(logContext): relayer preflight declined: balance=\(report.balanceWeiHex) required=\(report.requiredBalanceWeiHex) deficit=\(report.deficitWeiHex)"
                )
                clearPendingSessionInstallAfterPreSubmitFailure(
                    sessionPlan,
                    logContext: logContext
                )
                throw AppError.bundlerRelayShortfall(report)
            }
        }

        // Everything above is non-secret preflight. Only now, once the operation is known to be
        // buildable and affordable, create the action context and make the relayer available.
        // A session-key send with an already-running relayer therefore remains prompt-free;
        // passkey sends reuse this same context for the Secure Enclave signature below.
        // Never accept a previously authorized context here. Some upstream
        // workflows must unlock a different secret before the gas envelope can
        // be known. Reusing that context would let an owner signature happen
        // without ever presenting the exact locally authorized liability.
        let actionAuthentication = DeviceOwnerAuthenticationSession.ownerUserOperation(
            action: signingReason,
            maximumLiability: enriched.requiredPrefund
        )
        let gasAwareSigningReason = actionAuthentication.reason
        defer { actionAuthentication.invalidate() }
        _ = try await ensureRelayerUnlocked(using: actionAuthentication)

        if case let .bundlerTopUp(expectedIdentity) = purpose {
            // Re-derive the destination from the protected secret with this action's context.
            // This binds the owner signature below to secret material, not public metadata.
            let record = try BundlerKeyStore.shared.read(
                keyRef: expectedIdentity.keyRef,
                reason: actionAuthentication.reason,
                authenticationContext: actionAuthentication.context
            )
            let authenticatedIdentity = try VerifiedRelayerIdentity.derive(
                keyRef: record.keyRef,
                secret: record.secret
            )
            guard authenticatedIdentity == expectedIdentity else {
                throw AppError.bundlerRelayPreflightUnavailable(
                    "The authenticated relayer secret does not match the reviewed destination."
                )
            }

            switch try await verifiedBundlerRelayDecision(
                expectedIdentity: expectedIdentity,
                gasPlan: enrichedDraft.gasPlan,
                requiredPrefund: enriched.requiredPrefund,
                logContext: logContext,
                phase: "post-auth"
            ) {
            case .proceed:
                appendLog("\(logContext): post-auth relayer identity and cost recheck passed")
            case .externalFundingRequired(let report):
                throw AppError.bundlerRelayShortfall(report)
            }
        }

        // Re-read the independent execution-RPC head after any relayer unlock or
        // biometric delay. UserOperationSigning repeats the time/block check
        // before touching either owner or session key.
        let feeQuoteHead = try await ExecutionFeeOracle().currentBlockNumber(
            rpcURL: activeChain.rpcURL,
            expectedChainID: activeChain.id
        )

        let signatureResult: SignedUserOperation
        do {
            signatureResult = try UserOperationSigning.signForSend(
                operation: enriched.operation,
                currentBlockNumber: feeQuoteHead,
                session: sessionPlan?.signingContext,
                passkeySigner: { [self] preimage in
                    appendLog("\(logContext): computed signing preimage (\(preimage.count) bytes)")
                    appendLog("\(logContext): requesting Secure Enclave signature")
                    let signature = try keyStore.sign(
                        preimage: preimage,
                        reason: gasAwareSigningReason,
                        authenticationContext: actionAuthentication.context
                    )
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
                        usePrecompiled: usePrecompiled
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
        } catch {
            clearPendingSessionInstallAfterPreSubmitFailure(sessionPlan, logContext: logContext)
            throw error
        }
        appendLog("\(logContext): final userOpHash \(signatureResult.userOpHash.shortHex)")
        if signatureResult.usedSession {
            recordSessionActivity(now: Date(), source: "session signing", isUserInput: false)
        }
        let submittedHistoryDraft = historyDraft.map {
            signedHistoryDraft($0, signedBySession: signatureResult.usedSession)
        }

        bridgeStatus = "Submitting UserOperation to local wallet-node on \(activeChain.name)..."
        activeBundlerStatus = "Submitting UserOperation"

        let sentUserOpHash: String
        do {
            sentUserOpHash = try await withPrivilegedWalletNodeClient(
                operation: "\(logContext) submit",
                authenticationSession: actionAuthentication
            ) { client in
                try await UserOperationSubmission.submit(
                    operation: signatureResult,
                    rpcURL: activeChain.rpcURL,
                    expectedChainID: activeChain.id,
                    transport: { operation in
                        try await client.sendUserOperation(operation: operation)
                    }
                )
            }
        } catch {
            clearPendingSessionInstallAfterPreSubmitFailure(sessionPlan, logContext: logContext)
            throw error
        }
        lastSubmittedUserOperationHash = sentUserOpHash
        if let sessionPlan, !sessionPlan.record.installedOnChain {
            pendingSessionInstallByUserOpHash[sentUserOpHash.lowercased()] = sessionPlan.record
        }
        afterSubmit?(sentUserOpHash)
        recordOptimisticNonce(after: enrichedDraft)
        appendLog("\(logContext): local wallet-node accepted userOpHash \(sentUserOpHash)")
        if let submittedHistoryDraft {
            recordSubmittedHistory(
                submittedHistoryDraft,
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
            success: nil,
            signedBySession: signatureResult.usedSession
        )
    }

    private func activeSessionPlan(for intent: TransactionIntent, now: Date) -> SessionUserOperationPlan? {
        if expireExpiredSessionIfNeeded(now: now, logContext: "session-preflight") {
            return nil
        }
        return SessionSigningAvailability.plan(
            settingsEnabled: settingsStore.sessionKeysEnabled,
            sessionRecord: walletRecord?.sessionRecords.first(where: { $0.chainId == activeChain.id }),
            pendingRevokeRecords: Array(pendingSessionRevokeByUserOpHash.values),
            intent: intent,
            now: now
        )
    }

    @discardableResult
    private func expireExpiredSessionIfNeeded(now: Date, logContext: String) -> Bool {
        guard let walletRecord,
              let sessionRecord = walletRecord.sessionRecords.first(where: { $0.chainId == activeChain.id }),
              let reason = SessionLifecycle.expiryReason(record: sessionRecord, now: now)
        else {
            return false
        }
        expireLocalSession(
            record: sessionRecord,
            reason: reason,
            now: now,
            logContext: logContext
        )
        return true
    }

    private func clearPendingSessionInstallAfterPreSubmitFailure(
        _ sessionPlan: SessionUserOperationPlan?,
        logContext: String
    ) {
        guard let sessionRecord = sessionPlan?.record, !sessionRecord.installedOnChain else {
            return
        }
        do {
            try clearPendingSessionKeyLocally(
                sessionRecord,
                now: Date(),
                logContext: logContext,
                reason: "cleared pending session key locally after pre-submit failure; no onchain permission was installed"
            )
        } catch {
            appendLog("\(logContext): pending session key cleanup failed: \(error.localizedDescription)")
        }
    }

    private func clearPendingSessionKeyLocally(
        _ sessionRecord: SessionRecord,
        from record: WalletRecord? = nil,
        now: Date,
        logContext: String,
        reason: String
    ) throws {
        guard !sessionRecord.installedOnChain else {
            return
        }
        guard let walletRecord = record ?? self.walletRecord else {
            throw AppError.corruptedMetadataStore
        }

        let refreshed = walletRecord.removingSessionRecord(
            chainID: sessionRecord.chainId,
            isDeployed: walletRecord.isDeployed,
            updatedAt: now
        )
        try metadataStore.save(refreshed)
        self.walletRecord = refreshed
        pendingSessionInstallByUserOpHash = pendingSessionInstallByUserOpHash.filter { _, pendingRecord in
            pendingRecord.chainId != sessionRecord.chainId
                || pendingRecord.permissionId != sessionRecord.permissionId
        }
        if sessionRecord.chainId == activeChain.id {
            settingsStore.setSessionKeysEnabled(false)
        }
        do {
            try SessionKeyStore.shared.delete(keyRef: sessionRecord.sessionKeyRef)
        } catch {
            appendLog("\(logContext): pending session key cleanup failed - \(error.localizedDescription)")
        }
        appendLog("\(logContext): \(reason)")
    }

    private func expireLocalSession(
        record sessionRecord: SessionRecord,
        reason: SessionExpiryReason,
        now: Date,
        logContext: String
    ) {
        guard let walletRecord else {
            return
        }

        let refreshed = walletRecord.removingSessionRecord(
            chainID: sessionRecord.chainId,
            isDeployed: walletRecord.isDeployed,
            updatedAt: now
        )
        do {
            try metadataStore.save(refreshed)
            self.walletRecord = refreshed
            if sessionRecord.chainId == activeChain.id {
                settingsStore.setSessionKeysEnabled(false)
            }
            appendLog("\(logContext): \(reason.logLabel); disabled local session signing")
        } catch {
            appendLog("\(logContext): failed to persist expired session cleanup: \(error.localizedDescription)")
        }

        do {
            try SessionKeyStore.shared.delete(keyRef: sessionRecord.sessionKeyRef)
            appendLog("\(logContext): deleted expired session key from Keychain")
        } catch {
            appendLog("\(logContext): expired session key cleanup failed: \(error.localizedDescription)")
        }
    }

    private func recordSessionActivity(now: Date, source: String, isUserInput: Bool) {
        guard settingsStore.sessionKeysEnabled,
              let walletRecord,
              let sessionRecord = walletRecord.sessionRecords.first(where: { $0.chainId == activeChain.id })
        else {
            return
        }
        if let reason = SessionLifecycle.expiryReason(record: sessionRecord, now: now) {
            expireLocalSession(
                record: sessionRecord,
                reason: reason,
                now: now,
                logContext: "session-activity"
            )
            return
        }
        if isUserInput,
           now.timeIntervalSince(sessionRecord.lastActivityAt) < Self.sessionUserActivityPersistenceMinInterval {
            return
        }

        let refreshed = walletRecord.updatingSessionActivity(
            chainID: sessionRecord.chainId,
            activityAt: now,
            isDeployed: walletRecord.isDeployed,
            updatedAt: now
        )
        guard refreshed != walletRecord else {
            return
        }
        do {
            try metadataStore.save(refreshed)
            self.walletRecord = refreshed
            if !isUserInput {
                appendLog("session: refreshed activity after \(source)")
            }
        } catch {
            appendLog("session: failed to persist activity after \(source): \(error.localizedDescription)")
        }
    }

    private func signSessionEnableDigest(_ digest: Data, reason: String, usePrecompiled: Bool) throws -> Data {
        let preimage = try WalletSignature.computeSigningPreimage(userOpHash: digest)
        let signature = try keyStore.sign(preimage: preimage, reason: reason)
        var lowS = signature.s
        try WalletSignature.normaliseLowS(s: &lowS)
        return try WalletSignature.abiEncodeSignature(
            userOpHash: digest,
            r: signature.r,
            s: lowS,
            usePrecompiled: usePrecompiled
        )
    }

    /// - Parameter verbose: `false` suppresses the per-read log lines. Background polls
    ///   (`refreshAccountBalanceQuietly`) run every 30s and would otherwise dominate the
    ///   240-line debug log ring, pushing out the entries that matter.
    private func refreshAccountInspection(
        logContext: String,
        verbose: Bool = true
    ) async throws -> AccountInspection {
        guard let record = walletRecord, let address = record.kernelAccountAddress else {
            throw AppError.invalidCounterfactualAddress
        }

        if verbose {
            appendLog("\(logContext): querying code and balance for \(address.shortAddress) via \(activeChain.shortName)")
        }

        let inspection = try await withWalletNodeClient(operation: "\(logContext) account inspection") { client in
            try await client.inspectAccount(address: address)
        }
        // Both writes are gated on an actual change. `accountInspection` and `walletRecord` are
        // `@Published`, so an unconditional assignment invalidates every observing view — the
        // whole chat transcript included — and the record rewrite also costs a metadata-store
        // write. Harmless when this only ran on explicit user action; not harmless once app
        // activation and receipts call it.
        if inspection != accountInspection {
            accountInspection = inspection
        }

        // `isDeployed` and `chainId` are the only fields this read contributes. `bootstrap()`
        // already syncs `chainId` (and runs on every chain switch), so comparing it here is
        // belt-and-braces rather than load-bearing — but it keeps the guard total, so this can't
        // silently start dropping a field the read is responsible for.
        if inspection.isDeployed != record.isDeployed || activeChain.id != record.chainId {
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
        }

        if verbose {
            appendLog(
                "\(logContext): state=\(inspection.stateTitle), balance=\(inspection.balanceDisplay), codeBytes=\(inspection.codeHex.hexByteCount)"
            )
        }

        return inspection
    }

    /// Best-effort re-read of the Kernel account's balance for the event-driven refresh triggers
    /// (app activation, a receipt landing, the account cards being opened). Unlike
    /// `refreshBalance()` it publishes no status text and swallows failures: a transient RPC
    /// hiccup should leave the last known balance on screen, not an error banner, and the next
    /// trigger retries.
    ///
    /// Deliberately not a timer. The balance updates on something the user did — returning to the
    /// app, confirming a transaction, opening the account cards, hitting Refresh — so the app
    /// never reads the chain on its own schedule. The known gap: ETH arriving from someone else
    /// while the app stays focused is not picked up until one of those happens.
    func refreshAccountBalanceQuietly(
        logContext: String,
        now: Date = Date(),
        bypassThrottle: Bool = false
    ) async {
        guard walletRecord?.kernelAccountAddress != nil else { return }
        // Another operation already owns the daemon connection and will refresh the inspection
        // itself; skipping avoids a redundant chain read and a racing `accountInspection` write.
        guard isWalletIdle else { return }
        guard BackgroundBalanceReadGate.allowed(
            now: now,
            lastReadAt: lastBackgroundBalanceReadAt,
            minInterval: Self.backgroundBalanceReadMinInterval,
            bypassThrottle: bypassThrottle
        ) else { return }
        // Stamped BEFORE the await, so this is also the in-flight guard: two triggers firing
        // together (a receipt landing just as the app is activated) would otherwise issue
        // overlapping reads that can land out of order, leaving the older value published.
        lastBackgroundBalanceReadAt = now

        let previousWeiHex = accountInspection?.balanceWeiHex
        do {
            let inspection = try await refreshAccountInspection(logContext: logContext, verbose: false)
            // Compare raw wei, not `balanceDisplay`: a change below display precision is still a
            // change, and this log line is meant to record that the balance actually moved.
            if inspection.balanceWeiHex != previousWeiHex {
                appendLog("\(logContext): balance now \(inspection.balanceDisplay)")
            }
            suppressedBalanceReadFailure = false
        } catch {
            // No error banner (see the doc comment), but a persistently failing read shouldn't be
            // invisible either. Log the first failure after a run of successes only: repeated
            // activations would otherwise repeat an identical line, and the relaunch path inside
            // `withWalletNodeClient` already logs its own attempt.
            if !suppressedBalanceReadFailure {
                suppressedBalanceReadFailure = true
                appendLog("\(logContext): balance read failed, will retry: \(error.localizedDescription)")
            }
        }
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

    /// Resolve whether this chain's on-chain WebAuthn verification should route
    /// through the RIP-7212 P-256 precompile. The daemon probes the precompile at
    /// startup and reports the effective decision via health; if the status is
    /// unavailable/pending or the query fails, we fall back to the Daimo verifier
    /// (`false`) so a UserOp is never submitted with a signature the chain cannot
    /// verify.
    private func resolveUsePrecompiled(logContext: String) async -> Bool {
        do {
            let status = try await withWalletNodeClient(operation: "\(logContext) p256 precompile status") { client in
                try await client.networkStatus()
            }
            let usePrecompiled = status.p256Precompile?.usePrecompiled ?? false
            appendLog(
                "\(logContext): p256 precompile status=\(status.p256Precompile?.status ?? "unknown") → usePrecompiled=\(usePrecompiled)"
            )
            return usePrecompiled
        } catch {
            appendLog(
                "\(logContext): p256 precompile status unavailable (\(error.localizedDescription)); using Daimo verifier"
            )
            return false
        }
    }

    private func enrichDraftWithLocalBundlerEstimation(
        _ draft: UserOperationDraft,
        logContext: String,
        usePrecompiled: Bool,
        sessionPlan: SessionUserOperationPlan? = nil,
        acknowledgedCallGasLimit: UInt64? = nil
    ) async throws -> EnrichedUserOperation {
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
                usePrecompiled: usePrecompiled
            )
            appendLog("\(logContext): generated session dummy signature for estimation (\(dummySignature.count) bytes)")
        } else {
            dummySignature = try WalletSignature.abiEncodeDummySignature(usePrecompiled: usePrecompiled)
            appendLog("\(logContext): generated dummy signature for estimation (\(dummySignature.count) bytes)")
        }

        let feeQuote = try await suggestedUserOperationFees(logContext: logContext)
        appendLog(
            "\(logContext): fee quote maxPriority=\(feeQuote.maxPriorityFeePerGas.shortHex) maxFee=\(feeQuote.maxFeePerGas.shortHex)"
        )

        // Quote before estimating so simulation sees the same locally selected
        // fees. The daemon's preVerificationGas and requiredPrefund remain
        // diagnostic only and never cross the authorization boundary.
        let gasFees = try UserOperationGasAuthorizer.checkedPackedGasFees(
            maxPriorityFeePerGas: feeQuote.maxPriorityFeePerGas,
            maxFeePerGas: feeQuote.maxFeePerGas
        )
        let pricedDraft = draft.updatingGasPlan(
            UserOperationGasPlan(
                accountGasLimits: draft.gasPlan.accountGasLimits,
                preVerificationGas: draft.gasPlan.preVerificationGas,
                gasFees: gasFees,
                paymasterAndData: draft.gasPlan.paymasterAndData
            )
        )

        let estimate = try await withWalletNodeWarmupRetry(operation: "\(logContext) gas estimate") {
            try await withWalletNodeClient(operation: "\(logContext) gas estimate") { client in
                try await client.estimateUserOperationGas(
                    draft: pricedDraft,
                    dummySignature: dummySignature,
                    acknowledgedCallGasLimit: acknowledgedCallGasLimit
                )
            }
        }
        appendLog(
            "\(logContext): gas estimate call=\(estimate.callGasLimit.shortHex) verification=\(estimate.verificationGasLimit.shortHex) preVerification=\(estimate.preVerificationGas.shortHex) requiredPrefund=\(estimate.requiredPrefund.shortHex)"
        )

        let authorizationScope: WalletSignature.GasAuthorizationScope
        if let gasBudgetWei = sessionPlan?.record.policyConfigSnapshot.gasBudgetWei {
            authorizationScope = .session(
                gasBudget: try Data.quantityString(gasBudgetWei).leftPadded(to: 32)
            )
        } else {
            authorizationScope = .owner
        }
        let authorized = try UserOperationGasAuthorizer.authorize(
            draft: draft,
            callGasLimit: estimate.callGasLimit,
            verificationGasLimit: estimate.verificationGasLimit,
            maxPriorityFeePerGas: feeQuote.maxPriorityFeePerGas,
            maxFeePerGas: feeQuote.maxFeePerGas,
            expectedSignatureLength: dummySignature.count,
            authorizationScope: authorizationScope,
            feeQuote: feeQuote.quote
        )
        appendLog(
            "\(logContext): locally authorized pvg=\(authorized.draft.gasPlan.preVerificationGas.shortHex) maxLiability=\(authorized.maxLiability.shortHex) policy=v\(authorized.gasPolicyVersion); daemon pvg/prefund ignored"
        )

        activeBundlerStatus = "Local wallet-node ready on \(activeChain.name)"

        return EnrichedUserOperation(operation: authorized)
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

    private func waitForLocalReceipt(
        userOpHash: String,
        chainID: UInt64,
        logContext: String
    ) async throws -> WalletNodeClient.UserOperationReceipt {
        appendLog("\(logContext): waiting for local wallet-node receipt for \(userOpHash)")
        var attempt = 1

        while true {
            try Task.checkCancellation()

            let receipt = try await withWalletNodeClient(operation: "\(logContext) receipt poll") { client in
                try await client.getUserOperationReceipt(userOpHash: userOpHash)
            }
            if let receipt {
                appendLog("\(logContext): receipt received on attempt \(attempt)")
                return receipt
            }

            let operationStatus = try await withWalletNodeClient(operation: "\(logContext) status poll") { client in
                try await client.getUserOperationStatus(userOpHash: userOpHash)
            }
            if let terminal = TerminalUserOperationStatus.historyStatus(from: operationStatus) {
                markTerminalHistory(
                    userOpHash: userOpHash,
                    chainID: chainID,
                    status: terminal.status,
                    reason: terminal.reason,
                    logContext: logContext
                )
                activeBundlerStatus = "Revoke \(terminal.status.rawValue)"
                bridgeStatus = "Session key revoke \(terminal.status.rawValue)."
                var message = "Session key revoke did not receive a receipt. wallet-node reported \(terminal.status.rawValue)"
                if let reason = terminal.reason, !reason.isEmpty {
                    message += ": \(reason)"
                } else {
                    message += "."
                }
                throw AppError.userOperationTerminal(message)
            }

            appendLog("\(logContext): receipt pending (attempt \(attempt))")
            attempt += 1
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// Poll the local wallet-node until the given UserOp is included on-chain (or the poll
    /// window elapses). Callers that must reflect post-inclusion state — a fresh balance, or
    /// a follow-up op whose nonce depends on this one having landed — should await this before
    /// proceeding. Returns the receipt if one arrived, else nil (still pending / timed out).
    func awaitUserOperationInclusion(
        userOpHash: String,
        logContext: String
    ) async -> WalletNodeClient.UserOperationReceipt? {
        (try? await pollForLocalReceipt(userOpHash: userOpHash, logContext: logContext)) ?? nil
    }

    func loadWalletHistoryRecords(limit: Int = 200) -> [WalletTransactionRecord] {
        do {
            return try walletHistoryStore.loadRecords(
                accountAddress: walletRecord?.kernelAccountAddress,
                chainID: activeChain.id,
                limit: limit
            )
        } catch {
            appendLog("history: load failed: \(error.localizedDescription)")
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

    /// The only way to run the reconciler. `reconcilerTask` is the single owner of the loop's
    /// lifetime, so every caller must come through here — see `runUserOperationReconciler`.
    func startUserOperationReconcilerIfNeeded() {
        guard reconcilerTask == nil else {
            return
        }
        // `defer`, not a trailing `await MainActor.run`: both this method and the inherited task
        // context are @MainActor, so the reset runs synchronously on the actor with no suspension
        // between the loop returning and the handle clearing. With an awaited reset, a send landing
        // in that gap would see a non-nil handle for an already-finished loop, skip starting, and
        // leave its own UserOperation unwatched until the next send or launch.
        reconcilerTask = Task { [weak self] in
            defer { self?.reconcilerTask = nil }
            await self?.runUserOperationReconciler()
        }
    }

    func stopUserOperationReconciler() {
        reconcilerTask?.cancel()
        reconcilerTask = nil
    }

    /// Deliberately private: the loop must only ever be entered through
    /// `startUserOperationReconcilerIfNeeded()`, whose guard keeps a single loop polling a given
    /// record. Two concurrent loops duplicate receipt polls, history writes, and the
    /// `objectWillChange` traffic those writes publish.
    private func runUserOperationReconciler() async {
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
            // Deliberately no balance refresh on this exit, unlike the one below: reaching here
            // means nothing was pending to begin with, so no receipt landed and the balance can't
            // have moved on our account.
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
                // Everything this loop was watching has finalised, so the balance almost
                // certainly moved. Pick up both sides of the relayed operation now instead of
                // leaving the Kernel or bundler balance stale until a manual refresh.
                await refreshAccountBalanceQuietly(
                    logContext: "balance-receipt",
                    bypassThrottle: true
                )
                refreshLocalRelayerStatus()
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
            appendLog("\(logContext): wallet history record failed: \(error.localizedDescription)")
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
            updatePendingSessionRevoke(
                userOpHash: receipt.userOpHash,
                chainID: chainID,
                success: receipt.success,
                logContext: logContext
            )
        } catch {
            appendLog("\(logContext): wallet history receipt update failed: \(error.localizedDescription)")
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
            appendLog("\(logContext): session permission install update failed: \(error.localizedDescription)")
        }
    }

    private func updatePendingSessionRevoke(
        userOpHash: String,
        chainID: UInt64,
        success: Bool,
        logContext: String
    ) {
        let key = userOpHash.lowercased()
        guard let pendingRecord = pendingSessionRevokeByUserOpHash.removeValue(forKey: key) else {
            return
        }
        guard success else {
            appendLog("\(logContext): session permission revoke was not included")
            return
        }
        guard let walletRecord else {
            return
        }

        do {
            let refreshed = walletRecord.removingSessionRecord(
                chainID: chainID,
                isDeployed: walletRecord.isDeployed,
                updatedAt: Date()
            )
            try metadataStore.save(refreshed)
            self.walletRecord = refreshed
            if chainID == activeChain.id {
                settingsStore.setSessionKeysEnabled(false)
            }
            do {
                try SessionKeyStore.shared.delete(keyRef: pendingRecord.sessionKeyRef)
            } catch {
                appendLog("\(logContext): session key cleanup failed: \(error.localizedDescription)")
            }
            appendLog("\(logContext): cleared local session-key state")
        } catch {
            appendLog("\(logContext): session permission revoke cleanup failed: \(error.localizedDescription)")
        }
    }

    private func markPendingHistory(userOpHash: String, chainID: UInt64, logContext: String) {
        do {
            try walletHistoryStore.markPending(userOpHash: userOpHash, chainID: chainID)
            appendLog("\(logContext): wallet history left pending until receipt is available")
        } catch {
            appendLog("\(logContext): wallet history pending update failed: \(error.localizedDescription)")
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
            appendLog("\(logContext): wallet history terminal update failed: \(error.localizedDescription)")
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

    private func signedHistoryDraft(
        _ draft: WalletTransactionDraft,
        signedBySession: Bool
    ) -> WalletTransactionDraft {
        var fields: [String: String] = [:]
        if let detailsJSON = draft.detailsJSON,
           let data = detailsJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in object {
                fields[key] = "\(value)"
            }
        }
        fields["signingMode"] = signedBySession ? "session" : "passkey"

        var updated = draft
        updated.detailsJSON = historyDetailsJSON(fields)
        return updated
    }

    private func historyDetailsJSON(_ fields: [String: String]) -> String? {
        guard JSONSerialization.isValidJSONObject(fields),
              let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func suggestedUserOperationFees(
        logContext: String
    ) async throws -> (
        quote: ExecutionFeeQuote,
        maxPriorityFeePerGas: Data,
        maxFeePerGas: Data
    ) {
        let quote = try await ExecutionFeeOracle().quote(
            rpcURL: activeChain.rpcURL,
            expectedChainID: activeChain.id
        )
        let settings = networkSettings
        let resolved = try GasPricing.resolveUserOperationFees(
            quote: quote,
            autoEnabled: settings.autoGasModeEnabled,
            autoTier: settings.autoGasTier,
            manualCap: settings.activeGasPolicy
        )
        appendLog("\(logContext): gas fee mode \(settings.autoGasModeEnabled ? "auto/\(settings.autoGasTier.rawValue)" : "manual(capped to \(settings.activeMaxFeePerGasGwei)/\(settings.activeMaxPriorityFeePerGasGwei) gwei)")")
        appendLog(
            "\(logContext): independent fee quote block=\(quote.blockNumber) age=0s six-block ceiling"
        )
        return (quote, resolved.maxPriorityFeePerGas, resolved.maxFeePerGas)
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
            appendLog("gas: live price refresh failed: \(error.localizedDescription)")
        }
    }

    /// An explicit request — tapping the pill — always reads, and stamps the gate so
    /// a follow-on trigger does not immediately read again.
    func refreshLiveGasPricesNow(now: Date = Date()) async {
        lastGasIndicatorReadAt = now
        await refreshLiveGasPrices()
    }

    /// Refreshes the chat gas indicator, unless it was refreshed moments ago.
    ///
    /// This used to be a 30-second poll that ran for the life of the app. It fed
    /// nothing but the header pill and its popover — the fees an operation is
    /// actually signed with come from `suggestedUserOperationFees`, which fetches
    /// its own price when the operation is built. Meanwhile every tick went through
    /// `withWalletNodeClient`, which relaunches the daemon on socket loss, so a
    /// decorative number was able to resurrect a dead daemon and unlock the relayer
    /// key on a fixed schedule with nothing on screen to explain it.
    ///
    /// Now it runs on the things that precede looking at or acting on gas: opening
    /// the popover, returning to the app, and once after launch. The gate keeps a
    /// burst of those from becoming a burst of chain reads.
    func refreshLiveGasPricesIfStale(now: Date = Date()) async {
        guard GasIndicatorRefreshGate.allowed(
            now: now,
            lastReadAt: lastGasIndicatorReadAt,
            minInterval: Self.gasIndicatorMinRefreshInterval
        ) else { return }
        lastGasIndicatorReadAt = now
        await refreshLiveGasPrices()
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

/// "No wallet operation is in flight." Named for the condition rather than one caller: it gates
/// network-settings changes, wallet reset, the manual balance refresh, and the event-driven
/// balance reads, all of which need the daemon connection to be free.
enum WalletIdleGate {
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

/// Coalescing floor for the event-driven balance reads. Pure so the boundary is testable without
/// an `AppModel`; `nil` means nothing has been read yet, which always allows.
/// Coalescing floor for the gas indicator. Same shape as the balance gate, kept
/// separate because the two are refreshed by different triggers and would
/// otherwise suppress each other.
enum GasIndicatorRefreshGate {
    static func allowed(now: Date, lastReadAt: Date?, minInterval: TimeInterval) -> Bool {
        guard let lastReadAt else { return true }
        return now.timeIntervalSince(lastReadAt) >= minInterval
    }
}

enum BackgroundBalanceReadGate {
    static func allowed(
        now: Date,
        lastReadAt: Date?,
        minInterval: TimeInterval,
        bypassThrottle: Bool = false
    ) -> Bool {
        if bypassThrottle { return true }
        guard let lastReadAt else { return true }
        return now.timeIntervalSince(lastReadAt) >= minInterval
    }
}

enum NetworkSettingsChangePolicy {
    static func requiresWalletNodeRestart(
        from old: DemoNetworkSettings,
        to new: DemoNetworkSettings
    ) -> Bool {
        if old.activeRPCURL != new.activeRPCURL
            || old.activeArchiveNodeURL != new.activeArchiveNodeURL
            || old.activeConsensusRPCURL != new.activeConsensusRPCURL {
            return true
        }
        if old.heliosVerificationEnabled != new.heliosVerificationEnabled {
            return true
        }
        return old.resolvedDaemonGasPolicy != new.resolvedDaemonGasPolicy
    }

    static func requiresHeliosCheckpointResync(
        from old: DemoNetworkSettings,
        to new: DemoNetworkSettings
    ) -> Bool {
        guard new.isHeliosVerificationActive else {
            return false
        }
        return old.activeConsensusRPCURL != new.activeConsensusRPCURL
            || old.isHeliosVerificationActive == false
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
        guard case let WalletNodeClient.ClientError.rpcError(_, code, _, reason, _, _) = error,
              code == -32011
        else {
            return false
        }
        return reason == "bundler_account_lifecycle_not_signable"
    }

    static func displayMessage(action: String, error: Error) -> String {
        guard case let WalletNodeClient.ClientError.rpcError(_, code, message, reason, _, _) = error,
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
        guard case let WalletNodeClient.ClientError.rpcError(_, code, message, reason, _, _) = error else {
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
             "gas_estimation_unavailable",
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
