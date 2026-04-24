import Foundation
import WalletSignature

// AppModel drives the signed macOS demo shell. It is intentionally opinionated
// around the current demo scope (Sepolia, ETH transfer first, hosted bundler)
// and should not be treated as the final wallet product architecture.
@MainActor
final class AppModel: ObservableObject {
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

    var activeChain: ChainConfiguration {
        configuration.activeChain
    }

    private let keyStore: KeyStore
    private let metadataStore: WalletMetadataStore
    private let settingsStore: DemoSettingsStore
    private let kernelAccountAddressPredictor: KernelAccountAddressPredictor
    private let rpcClient: DemoRPCClient
    private let bundlerClient: BundlerClient
    private let userOperationBuilder: UserOperationBuilder

    init(
        keyStore: KeyStore = KeyStore(),
        metadataStore: WalletMetadataStore = WalletMetadataStore(),
        settingsStore: DemoSettingsStore = DemoSettingsStore(),
        kernelAccountAddressPredictor: KernelAccountAddressPredictor = KernelAccountAddressPredictor(),
        rpcClient: DemoRPCClient = DemoRPCClient(),
        bundlerClient: BundlerClient = BundlerClient(),
        userOperationBuilder: UserOperationBuilder = UserOperationBuilder()
    ) {
        self.keyStore = keyStore
        self.metadataStore = metadataStore
        self.settingsStore = settingsStore
        self.kernelAccountAddressPredictor = kernelAccountAddressPredictor
        self.rpcClient = rpcClient
        self.bundlerClient = bundlerClient
        self.userOperationBuilder = userOperationBuilder
        self.configuration = DemoAppConfiguration(
            isTestnetModeEnabled: true
        )
        self.settingsStore.setTestnetModeEnabled(true)
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

            let hasExistingKey = try keyStore.loadKey() != nil
            appendLog(
                hasExistingKey
                    ? "bootstrap: found existing Secure Enclave key reference in Keychain"
                    : "bootstrap: no existing Secure Enclave key found; creating a new device-bound key"
            )

            let coordinates = try keyStore.publicKeyCoordinates()
            appendLog("bootstrap: public key x=\(coordinates.x.shortHex) y=\(coordinates.y.shortHex)")

            let now = Date()

            if let existing = try metadataStore.load() {
                appendLog("bootstrap: loaded wallet metadata for \(existing.walletId.uuidString)")

                if existing.keyTag != keyStore.keyTag || !existing.matches(coordinates) {
                    appendLog("bootstrap: stored metadata does not match the current Secure Enclave key")

                    guard !hasExistingKey else {
                        appendLog("bootstrap: refusing automatic recovery because an existing key was loaded")
                        throw AppError.metadataKeyMismatch
                    }

                    appendLog("bootstrap: replacing stale metadata for the newly created key")
                    try metadataStore.clear()

                    let created = try createFreshWalletRecord(coordinates: coordinates, now: now)
                    try metadataStore.save(created)
                    walletRecord = created
                    appendLog("bootstrap: stored new wallet record with predicted account \(created.kernelAccountAddress ?? "unavailable")")
                    shouldInspectAfterBootstrap = true
                } else {
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

    func setTestnetModeEnabled(_ isEnabled: Bool) {
        guard isEnabled else {
            appendLog("chain: mainnet mode is disabled in the current demo build; keeping Sepolia active")
            configuration = DemoAppConfiguration(isTestnetModeEnabled: true)
            settingsStore.setTestnetModeEnabled(true)
            return
        }

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

    func buildCurrentUserOperationDraft(isDeployedOverride: Bool? = nil) async throws -> UserOperationDraft {
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
            intent: .nativeTransfer(
                recipient: transactionComposer.recipient,
                amountETH: transactionComposer.amountETH
            )
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

                let enrichedDraft = try await enrichDraftWithBundlerEstimationIfAvailable(
                    draft,
                    logContext: "build"
                )
                builtUserOperationDraft = enrichedDraft

                let initCodeMode = enrichedDraft.initCode.isEmpty ? "existing account path" : "deployment path included"
                if activeChain.bundlerURL != nil {
                    bridgeStatus = "Unsigned UserOperation draft built for \(activeChain.name) with \(initCodeMode). Gas estimated through hosted bundler."
                } else {
                    activeBundlerStatus = "No bundler configured for \(activeChain.name)"
                    bridgeStatus = "Unsigned UserOperation draft built for \(activeChain.name) with \(initCodeMode)."
                }

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

        appendSection("Send UserOperation")

        isSendingUserOperation = true
        lastError = nil
        lastSubmittedUserOperationHash = nil
        lastBundledTransactionHash = nil

        Task {
            do {
                appendLog("send: preparing transaction on \(activeChain.name)")

                let liveInspection = try await refreshAccountInspection(logContext: "send-preflight")
                appendLog("send: using \(liveInspection.isDeployed ? "deployed" : "precomputed") account path")

                let draft = try await buildCurrentUserOperationDraft(
                    isDeployedOverride: liveInspection.isDeployed
                )
                appendDraftLogSummary(draft, context: "send")

                let enrichedDraft = try await enrichDraftWithBundlerEstimationIfAvailable(
                    draft,
                    logContext: "send"
                )
                builtUserOperationDraft = enrichedDraft

                let finalHash = try enrichedDraft.userOpHash()
                appendLog("send: final userOpHash \(finalHash.shortHex)")

                let preimage = try WalletSignature.computeSigningPreimage(userOpHash: finalHash)
                appendLog("send: computed signing preimage (\(preimage.count) bytes)")

                let signingReason = "Authorize \(transactionComposer.selectedKind.rawValue) on \(activeChain.name)"
                appendLog("send: requesting Secure Enclave signature")
                let signature = try keyStore.sign(preimage: preimage, reason: signingReason)
                appendLog("send: signature components r=\(signature.r.shortHex) s=\(signature.s.shortHex)")

                var lowS = signature.s
                let originalS = lowS
                try WalletSignature.normaliseLowS(s: &lowS)
                appendLog(
                    "send: low-s normalization \(originalS == lowS ? "not needed" : "applied")"
                )

                let encodedSignature = try WalletSignature.abiEncodeSignature(
                    userOpHash: finalHash,
                    r: signature.r,
                    s: lowS,
                    usePrecompiled: true
                )
                appendLog("send: encoded Kernel/WebAuthn signature (\(encodedSignature.count) bytes)")

                bridgeStatus = "Submitting UserOperation to hosted bundler on \(activeChain.name)…"
                activeBundlerStatus = "Submitting UserOperation"

                let sentUserOpHash = try await bundlerClient.sendUserOperation(
                    chain: activeChain,
                    draft: enrichedDraft,
                    signature: encodedSignature
                )
                lastSubmittedUserOperationHash = sentUserOpHash
                appendLog("send: bundler accepted userOpHash \(sentUserOpHash)")

                bridgeStatus = "UserOperation accepted by bundler on \(activeChain.name). Waiting for inclusion…"

                let receipt = try await pollForReceipt(userOpHash: sentUserOpHash)
                if let receipt {
                    lastBundledTransactionHash = receipt.receipt?.transactionHash
                    activeBundlerStatus = receipt.success ? "UserOperation included" : "UserOperation reverted on-chain"

                    appendLog("send: receipt success=\(receipt.success) actualGasUsed=\(receipt.actualGasUsed) actualGasCost=\(receipt.actualGasCost)")
                    if let transactionHash = receipt.receipt?.transactionHash {
                        appendLog("send: bundle transaction hash \(transactionHash)")
                    }
                    if let revertReason = receipt.reason, !revertReason.isEmpty {
                        appendLog("send: revert reason \(revertReason)")
                    }

                    bridgeStatus = receipt.success
                        ? "UserOperation included on \(activeChain.name)."
                        : "UserOperation included on \(activeChain.name), but execution reverted."

                    _ = try? await refreshAccountInspection(logContext: "post-send-refresh")
                } else {
                    activeBundlerStatus = "Receipt pending"
                    bridgeStatus = "UserOperation submitted to bundler. Receipt still pending."
                    appendLog("send: receipt still pending after polling window")
                }
            } catch {
                lastError = error.localizedDescription
                bridgeStatus = "UserOperation send failed"
                activeBundlerStatus = "Submission failed"
                appendLog("send: failed — \(error.localizedDescription)")
            }

            isSendingUserOperation = false
        }
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

    private func enrichDraftWithBundlerEstimationIfAvailable(
        _ draft: UserOperationDraft,
        logContext: String
    ) async throws -> UserOperationDraft {
        guard let bundlerURL = activeChain.bundlerURL else {
            appendLog("\(logContext): no bundler configured; keeping placeholder gas values")
            return draft
        }

        appendLog("\(logContext): checking bundler entry point support at \(bundlerURL.absoluteString)")
        try await bundlerClient.assertEntryPointSupport(chain: activeChain)
        appendLog("\(logContext): bundler supports entry point \(activeChain.entryPoint)")

        let dummySignature = try WalletSignature.abiEncodeDummySignature(usePrecompiled: true)
        appendLog("\(logContext): generated dummy signature for estimation (\(dummySignature.count) bytes)")

        let estimate = try await bundlerClient.estimateUserOperationGas(
            chain: activeChain,
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

        activeBundlerStatus = "Bundler ready on \(activeChain.name)"

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

    private func pollForReceipt(userOpHash: String) async throws -> BundlerClient.UserOperationReceipt? {
        appendLog("send: polling bundler receipt for \(userOpHash)")

        for attempt in 1...15 {
            if let receipt = try await bundlerClient.getUserOperationReceipt(
                chain: activeChain,
                userOpHash: userOpHash
            ) {
                appendLog("send: receipt received on attempt \(attempt)")
                return receipt
            }

            appendLog("send: receipt pending (attempt \(attempt)/15)")
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
        guard activeChain.bundlerURL != nil else {
            return try await rpcClient.suggestedGasFees(chain: activeChain)
        }

        do {
            let gasPrice = try await bundlerClient.userOperationGasPrice(chain: activeChain)
            appendLog("\(logContext): using bundler gas price tier 'standard'")
            return (
                maxPriorityFeePerGas: gasPrice.standard.maxPriorityFeePerGas,
                maxFeePerGas: gasPrice.standard.maxFeePerGas
            )
        } catch {
            appendLog("\(logContext): bundler gas price unavailable, falling back to public RPC fees — \(error.localizedDescription)")
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
