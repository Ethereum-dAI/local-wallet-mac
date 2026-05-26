import Foundation
import LocalAuthentication
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

    var activeChain: ChainConfiguration {
        configuration.activeChain
    }

    var hasLocalRelayerClient: Bool {
        walletNodeClient != nil || WalletNodeClient.Configuration.fromEnvironment() == nil
    }

    private let keyStore: KeyStore
    private let metadataStore: WalletMetadataStore
    private let settingsStore: DemoSettingsStore
    private let kernelAccountAddressPredictor: KernelAccountAddressPredictor
    private let rpcClient: DemoRPCClient
    private var walletNodeClient: WalletNodeClient?
    private var walletNodeDaemon: WalletNodeDaemon?
    private let userOperationBuilder: UserOperationBuilder

    init(
        keyStore: KeyStore = KeyStore(),
        metadataStore: WalletMetadataStore = WalletMetadataStore(),
        settingsStore: DemoSettingsStore = DemoSettingsStore(),
        kernelAccountAddressPredictor: KernelAccountAddressPredictor = KernelAccountAddressPredictor(),
        rpcClient: DemoRPCClient = DemoRPCClient(),
        walletNodeClient: WalletNodeClient? = WalletNodeClient.Configuration.fromEnvironment().map {
            WalletNodeClient(configuration: $0)
        },
        userOperationBuilder: UserOperationBuilder = UserOperationBuilder()
    ) {
        self.keyStore = keyStore
        self.metadataStore = metadataStore
        self.settingsStore = settingsStore
        self.kernelAccountAddressPredictor = kernelAccountAddressPredictor
        self.rpcClient = rpcClient
        self.walletNodeClient = walletNodeClient
        self.userOperationBuilder = userOperationBuilder
        self.configuration = DemoAppConfiguration(
            isTestnetModeEnabled: settingsStore.isTestnetModeEnabled
        )
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
        refreshLocalRelayerStatus()
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
                let inspection = try await refreshAccountInspection(logContext: "inspect")

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

        settingsStore.setTestnetModeEnabled(isEnabled)
        configuration = DemoAppConfiguration(isTestnetModeEnabled: isEnabled)
        accountInspection = nil
        builtUserOperationDraft = nil
        lastUserOperationBuildError = nil
        activeBundlerStatus = "Bundler not checked"
        lastSubmittedUserOperationHash = nil
        lastBundledTransactionHash = nil
        bootstrap()
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
                let walletNodeClient = try await ensureWalletNodeClient()
                let status = try await walletNodeClient.bundlerStatus()
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
        localRelayerMessage = "Starting local wallet-node daemon..."
        let keyRef = "bundler-eoa:default:\(activeChain.id):1"
        let bundlerSecret = try BundlerKeyStore.shared.createIfNeeded(keyRef: keyRef)
        let daemon = try await WalletNodeDaemon.launch(
            bundlerSecret: bundlerSecret,
            chain: activeChain
        )
        walletNodeDaemon = daemon
        walletNodeClient = daemon.client
        localRelayerMessage = "Local wallet-node daemon connected."
        appendLog("relayer: wallet-node daemon started")
        return daemon.client
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

        return try await userOperationBuilder.buildDraft(
            walletRecord: walletRecord,
            publicKey: publicKey,
            chain: activeChain,
            isDeployed: isDeployedOverride ?? accountInspection?.isDeployed ?? walletRecord.isDeployed,
            intent: intent
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

    private func executeTransfer(
        intent: TransactionIntent,
        logContext: String,
        signingReason: String
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
                intent: intent,
                logContext: logContext,
                signingReason: signingReason
            )
            isSendingUserOperation = false
            return result
        } catch {
            isSendingUserOperation = false
            throw error
        }
    }

    private func sendUserOperation(
        intent: TransactionIntent,
        logContext: String,
        signingReason: String
    ) async throws -> UserOperationSendResult {
        appendLog("\(logContext): preparing transaction on \(activeChain.name)")

        let liveInspection = try await refreshAccountInspection(logContext: "\(logContext)-preflight")
        appendLog("\(logContext): using \(liveInspection.isDeployed ? "deployed" : "precomputed") account path")

        let draft = try await buildUserOperationDraft(
            intent: intent,
            isDeployedOverride: liveInspection.isDeployed
        )
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

        let walletNodeClient = try await ensureWalletNodeClient()
        bridgeStatus = "Submitting UserOperation to local wallet-node on \(activeChain.name)..."
        activeBundlerStatus = "Submitting UserOperation"

        let sentUserOpHash = try await walletNodeClient.sendUserOperation(
            draft: enrichedDraft,
            signature: encodedSignature
        )
        lastSubmittedUserOperationHash = sentUserOpHash
        appendLog("\(logContext): local wallet-node accepted userOpHash \(sentUserOpHash)")

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

        let inspection = try await rpcClient.inspectAccount(
            chain: activeChain,
            address: address
        )
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

    private func enrichDraftWithLocalBundlerEstimation(
        _ draft: UserOperationDraft,
        logContext: String
    ) async throws -> UserOperationDraft {
        let walletNodeClient = try await ensureWalletNodeClient()

        appendLog("\(logContext): checking local wallet-node entry point support")
        try await walletNodeClient.assertEntryPointSupport(activeChain.entryPoint)
        appendLog("\(logContext): local wallet-node supports entry point \(activeChain.entryPoint)")

        let dummySignature = try WalletSignature.abiEncodeDummySignature(usePrecompiled: false)
        appendLog("\(logContext): generated dummy signature for estimation (\(dummySignature.count) bytes)")

        let estimate = try await walletNodeClient.estimateUserOperationGas(
            draft: draft,
            dummySignature: dummySignature
        )
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
        let walletNodeClient = try await ensureWalletNodeClient()
        appendLog("\(logContext): polling local wallet-node receipt for \(userOpHash)")

        for attempt in 1...90 {
            if let receipt = try await walletNodeClient.getUserOperationReceipt(userOpHash: userOpHash) {
                appendLog("\(logContext): receipt received on attempt \(attempt)")
                return receipt
            }

            appendLog("\(logContext): receipt pending (attempt \(attempt)/90)")
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        return nil
    }

    private func pack128(high: Data, low: Data) -> Data {
        high.suffix(16) + low.suffix(16)
    }

    private func suggestedUserOperationFees(
        logContext: String
    ) async throws -> (maxPriorityFeePerGas: Data, maxFeePerGas: Data) {
        do {
            let walletNodeClient = try await ensureWalletNodeClient()
            let gasPrice = try await walletNodeClient.userOperationGasPrice()
            appendLog("\(logContext): using local wallet-node gas price tier 'standard'")
            return (
                maxPriorityFeePerGas: gasPrice.standard.maxPriorityFeePerGas,
                maxFeePerGas: gasPrice.standard.maxFeePerGas
            )
        } catch {
            appendLog("\(logContext): local wallet-node gas price unavailable, falling back to public RPC fees — \(error.localizedDescription)")
            return try await rpcClient.suggestedGasFees(chain: activeChain)
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
