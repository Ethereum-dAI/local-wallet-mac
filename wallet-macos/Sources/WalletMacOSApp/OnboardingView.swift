import AppKit
import SwiftUI

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case network
    case model
    case keys
    case sync

    var title: String? {
        switch self {
        case .welcome:
            return nil
        case .network:
            return "Connect your chain"
        case .model:
            return "Configure your AI"
        case .keys:
            return "Create your wallet"
        case .sync:
            return "Prepare verified reads"
        }
    }
}

private enum OnboardingNetwork: String, CaseIterable, Identifiable {
    case sepolia = "Sepolia"
    case mainnet = "Mainnet"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .sepolia:
            return "Ethereum Sepolia"
        case .mainnet:
            return "Ethereum Mainnet"
        }
    }
}

@MainActor
private final class OnboardingState: ObservableObject {
    enum InstallState: Equatable {
        case idle
        case installing(Double)
        case installed
        case failed(String)
    }

    enum KeyState: Equatable {
        case idle
        case creating
        case ready(kernelAddress: String, bundlerAddress: String)
        case failed(String)
    }

    enum ChainReadinessState {
        case idle
        case preparing
        case syncing(WalletNodeClient.NetworkStatus?)
        case ready(WalletNodeClient.NetworkStatus)
        case timedOut(WalletNodeClient.NetworkStatus?)
        case failed(String)
    }

    @Published var step: OnboardingStep = .welcome
    @Published var selectedNetworkID: String
    @Published var mainnetRPCURL: String
    @Published var mainnetArchiveNodeURL: String
    @Published var mainnetConsensusRPCURL: String
    @Published var sepoliaRPCURL: String
    @Published var sepoliaArchiveNodeURL: String
    @Published var sepoliaConsensusRPCURL: String
    @Published var selectedModelID: String
    @Published var installState: InstallState = .idle
    @Published var keyState: KeyState = .idle
    @Published var chainReadinessState: ChainReadinessState = .idle
    @Published var chainReadinessElapsed: TimeInterval = 0
    @Published var chainReadinessLog: [String] = []
    @Published var hardwareProfile: LocalHardwareProfile?
    @Published var hardwareBudget: HardwareBudget?

    private let settingsStore: OnboardingSettingsStore
    private let networkSettingsStore: DemoSettingsStore
    private let provisioningService: OnboardingProvisioningService
    private let downloadManager: LocalAIModelDownloadManager
    private let hardwareInspector: LocalHardwareInspector
    private let chainReadinessService: OnboardingChainReadinessService
    let chainReadinessTiming: OnboardingChainReadinessTiming
    private var chainReadinessTask: Task<Void, Never>?
    private var chainReadinessTimerTask: Task<Void, Never>?
    private var chainReadinessRunID: UUID?

    init(
        settingsStore: OnboardingSettingsStore = OnboardingSettingsStore(),
        networkSettingsStore: DemoSettingsStore = DemoSettingsStore(),
        provisioningService: OnboardingProvisioningService = OnboardingProvisioningService(),
        downloadManager: LocalAIModelDownloadManager = LocalAIModelDownloadManager(),
        hardwareInspector: LocalHardwareInspector = LocalHardwareInspector(),
        chainReadinessService: OnboardingChainReadinessService? = nil,
        chainReadinessTiming: OnboardingChainReadinessTiming = .default
    ) {
        self.settingsStore = settingsStore
        self.networkSettingsStore = networkSettingsStore
        self.provisioningService = provisioningService
        self.downloadManager = downloadManager
        self.hardwareInspector = hardwareInspector
        self.chainReadinessService = chainReadinessService ?? OnboardingChainReadinessService(
            onboardingSettingsStore: settingsStore,
            networkSettingsStore: networkSettingsStore
        )
        self.chainReadinessTiming = chainReadinessTiming
        let networkSettings = networkSettingsStore.networkSettings
        self.selectedNetworkID = OnboardingNetwork.sepolia.rawValue
        self.mainnetRPCURL = networkSettings.mainnetRPCURL
        self.mainnetArchiveNodeURL = networkSettings.mainnetArchiveNodeURL
        self.mainnetConsensusRPCURL = networkSettings.mainnetConsensusRPCURL
        self.sepoliaRPCURL = networkSettings.sepoliaRPCURL
        self.sepoliaArchiveNodeURL = networkSettings.sepoliaArchiveNodeURL
        self.sepoliaConsensusRPCURL = networkSettings.sepoliaConsensusRPCURL
        let storedModelID = settingsStore.selectedModelID
        self.selectedModelID = LocalAIModel.available.contains { $0.id == storedModelID }
            ? storedModelID
            : LocalAIModel.recommended.id
        let selectedModel = LocalAIModel.available.first { $0.id == self.selectedModelID } ?? .recommended
        if settingsStore.installedModelID == selectedModel.id && downloadManager.isInstalled(selectedModel) {
            self.installState = .installed
        }

        Task {
            hardwareProfile = await hardwareInspector.inspect()
            hardwareBudget = await hardwareInspector.budget()
        }
    }

    deinit {
        chainReadinessTask?.cancel()
        chainReadinessTimerTask?.cancel()
    }

    var selectedModel: LocalAIModel {
        LocalAIModel.available.first { $0.id == selectedModelID } ?? .recommended
    }

    var selectedNetwork: OnboardingNetwork {
        OnboardingNetwork(rawValue: selectedNetworkID) ?? .sepolia
    }

    var canContinueFromNetwork: Bool {
        Self.isValidRequiredURL(sepoliaRPCURL)
            && Self.isValidOptionalURL(sepoliaConsensusRPCURL)
            && Self.isValidOptionalURL(sepoliaArchiveNodeURL)
            && Self.isValidRequiredURL(mainnetRPCURL)
            && Self.isValidOptionalURL(mainnetConsensusRPCURL)
            && Self.isValidOptionalURL(mainnetArchiveNodeURL)
    }

    var canContinueFromModel: Bool {
        installState == .installed && hardwareMeetsModelRequirement
    }

    /// Advisory only. Setup is never blocked on memory — a Mac that cannot hold the
    /// model is told so, with the numbers, and may install it anyway. See
    /// `OnboardingModelGate`.
    var hardwareMeetsModelRequirement: Bool { true }

    func fitVerdict(for model: LocalAIModel) -> ModelFitVerdict {
        guard let hardwareBudget else { return .unknown }
        return ModelFitEvaluator.verdict(
            profile: model.memoryProfile,
            contextTokens: ContextWindowPresets.fallback,
            budget: hardwareBudget
        )
    }

    /// nil when the selected model fits comfortably; otherwise the sentence to show.
    var hardwareWarning: String? {
        guard let hardwareBudget else { return nil }
        return OnboardingModelGate.warning(verdict: fitVerdict(for: selectedModel), budget: hardwareBudget)
    }

    var canComplete: Bool {
        if case .ready = keyState {
            return true
        }
        return false
    }

    var shouldSkipChainReadiness: Bool {
        sepoliaConsensusRPCURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var chainReadinessIsRunning: Bool {
        switch chainReadinessState {
        case .preparing, .syncing:
            return true
        case .idle, .ready, .timedOut, .failed:
            return false
        }
    }

    var chainReadinessIsTakingLonger: Bool {
        chainReadinessIsRunning
            && chainReadinessTiming.isTakingLonger(elapsed: chainReadinessElapsed)
    }

    var canOpenWalletAfterReadiness: Bool {
        if case .ready = chainReadinessState {
            return true
        }
        return false
    }

    var canRetryChainReadiness: Bool {
        switch chainReadinessState {
        case .timedOut, .failed, .idle:
            return true
        case .preparing, .syncing, .ready:
            return false
        }
    }

    var latestChainReadinessStatus: WalletNodeClient.NetworkStatus? {
        switch chainReadinessState {
        case .syncing(let status), .timedOut(let status):
            return status
        case .ready(let status):
            return status
        case .idle, .preparing, .failed:
            return nil
        }
    }

    func back() {
        guard step.rawValue > 0 else {
            return
        }
        if step == .sync {
            cancelChainReadiness(reset: true)
        }
        step = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome
    }

    func advance() {
        switch step {
        case .network:
            persistNetwork()
        case .model:
            settingsStore.selectedModelID = selectedModelID
        case .welcome, .keys, .sync:
            break
        }

        guard step.rawValue < OnboardingStep.allCases.count - 1 else {
            return
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            step = OnboardingStep(rawValue: step.rawValue + 1) ?? step
        }
    }

    func installSelectedModel() {
        guard installState != .installed else {
            return
        }
        guard hardwareMeetsModelRequirement else {
            return
        }

        settingsStore.selectedModelID = selectedModelID
        installState = .installing(0.08)
        Task {
            do {
                let fileURL = try await downloadManager.download(selectedModel) { progress in
                    self.installState = .installing(progress)
                }
                settingsStore.installedModelID = selectedModelID
                settingsStore.installedModelPath = fileURL.path
                installState = .installed
            } catch {
                settingsStore.installedModelID = nil
                settingsStore.installedModelPath = nil
                installState = .failed(error.localizedDescription)
            }
        }
    }

    func provisionKeys() {
        guard keyState != .creating else {
            return
        }

        cancelChainReadiness(reset: true)
        keyState = .creating
        Task {
            do {
                let result = try provisioningService.createOrLoadIdentity()
                keyState = .ready(
                    kernelAddress: result.kernelAccountAddress,
                    bundlerAddress: result.bundlerAddress
                )
            } catch {
                keyState = .failed(error.localizedDescription)
            }
        }
    }

    func startChainReadinessIfNeeded(force: Bool = false) {
        if chainReadinessIsRunning {
            guard force else {
                return
            }
            cancelChainReadiness(reset: false)
        }
        if canOpenWalletAfterReadiness && !force {
            return
        }

        guard case let .ready(kernelAddress, _) = keyState else {
            chainReadinessState = .failed("Create keys before syncing verified reads.")
            return
        }

        persistNetwork()

        let runID = UUID()
        let startedAt = Date()
        let service = chainReadinessService
        let timing = chainReadinessTiming
        chainReadinessRunID = runID
        chainReadinessElapsed = 0
        chainReadinessLog = []
        chainReadinessState = .preparing
        appendChainReadinessLog("sync: starting readiness check", startedAt: startedAt)
        startChainReadinessTimer(startedAt: startedAt, runID: runID)

        chainReadinessTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                let status = try await service.waitForHeliosReady(
                    kernelAddress: kernelAddress,
                    timing: timing,
                    onEvent: { [weak self] message in
                        guard let self, self.chainReadinessRunID == runID else {
                            return
                        }
                        self.appendChainReadinessLog(message, startedAt: startedAt)
                    },
                    onStatus: { [weak self] status in
                        guard let self, self.chainReadinessRunID == runID else {
                            return
                        }
                        self.chainReadinessState = .syncing(status)
                    }
                )
                guard self.chainReadinessRunID == runID, !Task.isCancelled else {
                    return
                }
                self.chainReadinessElapsed = Date().timeIntervalSince(startedAt)
                self.chainReadinessState = .ready(status)
                self.appendChainReadinessLog("sync: completed successfully", startedAt: startedAt)
                self.stopChainReadinessTimer(runID: runID)
            } catch is CancellationError {
            } catch let readinessError as OnboardingChainReadinessError {
                guard self.chainReadinessRunID == runID else {
                    return
                }
                self.chainReadinessElapsed = Date().timeIntervalSince(startedAt)
                switch readinessError {
                case .timedOut(let lastStatus):
                    self.chainReadinessState = .timedOut(lastStatus)
                    self.appendChainReadinessLog("sync: timed out waiting for verified reads", startedAt: startedAt)
                case .probeFailed(_, _, let lastStatus):
                    self.chainReadinessState = .failed(readinessError.localizedDescription)
                    if let lastStatus {
                        self.appendChainReadinessLog("sync: last status before probe failure \(lastStatus.onboardingDebugSummary)", startedAt: startedAt)
                    }
                    self.appendChainReadinessLog("sync: failed - \(readinessError.localizedDescription)", startedAt: startedAt)
                }
                self.stopChainReadinessTimer(runID: runID)
            } catch {
                guard self.chainReadinessRunID == runID else {
                    return
                }
                self.chainReadinessElapsed = Date().timeIntervalSince(startedAt)
                self.chainReadinessState = .failed(error.localizedDescription)
                self.appendChainReadinessLog("sync: failed - \(error.localizedDescription)", startedAt: startedAt)
                self.stopChainReadinessTimer(runID: runID)
            }
        }
    }

    func complete() {
        cancelChainReadiness(reset: false)
        persistNetwork()
        settingsStore.selectedModelID = selectedModelID
        settingsStore.markCompleted()
    }

    private func cancelChainReadiness(reset: Bool) {
        chainReadinessRunID = nil
        chainReadinessTask?.cancel()
        chainReadinessTask = nil
        chainReadinessTimerTask?.cancel()
        chainReadinessTimerTask = nil
        if reset {
            chainReadinessElapsed = 0
            chainReadinessLog = []
            chainReadinessState = .idle
        }
    }

    private func startChainReadinessTimer(startedAt: Date, runID: UUID) {
        chainReadinessTimerTask?.cancel()
        chainReadinessTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.chainReadinessRunID == runID else {
                    return
                }
                self.chainReadinessElapsed = Date().timeIntervalSince(startedAt)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopChainReadinessTimer(runID: UUID) {
        guard chainReadinessRunID == runID else {
            return
        }
        chainReadinessRunID = nil
        chainReadinessTask = nil
        chainReadinessTimerTask?.cancel()
        chainReadinessTimerTask = nil
    }

    private func appendChainReadinessLog(_ message: String, startedAt: Date) {
        let elapsed = Date().timeIntervalSince(startedAt)
        let line = String(format: "[%06.2fs] %@", elapsed, message)
        chainReadinessLog.append(line)
        if chainReadinessLog.count > 80 {
            chainReadinessLog.removeFirst(chainReadinessLog.count - 80)
        }
    }

    private func persistNetwork() {
        let trimmedMainnetRPC = mainnetRPCURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMainnetArchive = mainnetArchiveNodeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMainnetConsensus = mainnetConsensusRPCURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSepoliaRPC = sepoliaRPCURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSepoliaArchive = sepoliaArchiveNodeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSepoliaConsensus = sepoliaConsensusRPCURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsStore.rpcURL = trimmedSepoliaRPC
        settingsStore.archiveNodeURL = trimmedSepoliaArchive
        settingsStore.consensusRPCURL = trimmedSepoliaConsensus

        var networkSettings = networkSettingsStore.networkSettings
        networkSettings.isTestnetModeEnabled = true
        networkSettings.mainnetRPCURL = trimmedMainnetRPC
        networkSettings.mainnetArchiveNodeURL = trimmedMainnetArchive
        networkSettings.mainnetConsensusRPCURL = trimmedMainnetConsensus
        networkSettings.sepoliaRPCURL = trimmedSepoliaRPC
        networkSettings.sepoliaArchiveNodeURL = trimmedSepoliaArchive
        networkSettings.sepoliaConsensusRPCURL = trimmedSepoliaConsensus
        if let validated = try? networkSettings.validated() {
            networkSettingsStore.setNetworkSettings(validated)
        }
    }

    private static func isValidRequiredURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            return false
        }
        return true
    }

    private static func isValidOptionalURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return true
        }
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            return false
        }
        return true
    }
}

struct LocalWalletOnboardingView: View {
    @StateObject private var state = OnboardingState()
    let onComplete: () -> Void

    var body: some View {
        ZStack {
            OnboardingPalette.background
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    OnboardingPalette.accent.opacity(0.10),
                    Color.clear,
                    OnboardingPalette.panel.opacity(0.20),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                chromeHeader
                bodySlot
                footer
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 26)
        }
        .frame(minWidth: 1180, minHeight: 740)
    }

    private var chromeHeader: some View {
        HStack {
            if state.step != .welcome {
                Button(action: state.back) {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(OnboardingTextButtonStyle())
            } else {
                Color.clear.frame(width: 94, height: 42)
            }

            Spacer()

            if let title = state.step.title {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(OnboardingPalette.primaryText)
            }

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(OnboardingIconButtonStyle())
        }
        .frame(height: 54)
    }

    @ViewBuilder
    private var bodySlot: some View {
        ZStack {
            switch state.step {
            case .welcome:
                WelcomeStep()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .network:
                NetworkStep(state: state)
                    .transition(stepTransition)
            case .model:
                ModelStep(state: state)
                    .transition(stepTransition)
            case .keys:
                KeysStep(state: state)
                    .transition(stepTransition)
            case .sync:
                SyncStep(state: state)
                    .transition(stepTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        ZStack {
            switch state.step {
            case .welcome:
                HStack {
                    Spacer()
                    OnboardingBrandButton(title: "Get Started", systemImage: "arrow.right") {
                        state.advance()
                    }
                    .frame(width: 310)
                    Spacer()
                }
            case .network:
                wizardFooter(
                    caption: "RPC settings are stored locally on this Mac.",
                    primaryTitle: "Continue",
                    enabled: state.canContinueFromNetwork,
                    action: state.advance
                )
            case .model:
                wizardFooter(
                    caption: modelFooterCaption,
                    primaryTitle: modelButtonTitle,
                    enabled: modelButtonEnabled,
                    action: modelPrimaryAction
                )
            case .keys:
                wizardFooter(
                    caption: "Keys stay in Secure Enclave and Keychain. Private material is never shown here.",
                    primaryTitle: keysButtonTitle,
                    enabled: keysButtonEnabled,
                    action: keysPrimaryAction
                )
            case .sync:
                wizardFooter(
                    caption: syncFooterCaption,
                    primaryTitle: syncButtonTitle,
                    systemImage: syncButtonSystemImage,
                    enabled: syncButtonEnabled,
                    action: syncPrimaryAction
                )
            }
        }
        .frame(height: 112)
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 36)),
            removal: .opacity.combined(with: .offset(x: -36))
        )
    }

    private func wizardFooter(
        caption: String,
        primaryTitle: String,
        systemImage: String = "arrow.right",
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 18) {
            OnboardingStepIndicator(current: state.step.rawValue + 1, total: onboardingStepCount)
            Text(caption)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(OnboardingPalette.secondaryText)

            HStack {
                Spacer()
                OnboardingBrandButton(title: primaryTitle, systemImage: systemImage, action: action)
                    .disabled(!enabled)
                    .frame(width: 310)
                    .padding(.trailing, 26)
            }
        }
    }

    private var modelFooterCaption: String {
        guard let hardwareProfile = state.hardwareProfile else {
            return "Checking this Mac before enabling the local model download."
        }
        if let warning = state.hardwareWarning, state.installState == .idle {
            return "\(hardwareProfile.displayName). \(warning)"
        }

        switch state.installState {
        case .idle:
            return "Local only for now. No account, no cloud, no data sent anywhere."
        case .installing(let progress):
            return "Downloading Gemma 4 E4B from Hugging Face. This can take some minutes. \(Int(progress * 100))%"
        case .installed:
            return "Gemma 4 E4B is installed locally and ready for llama.cpp wiring."
        case .failed:
            return "Download failed. Check your connection and retry."
        }
    }

    private var onboardingStepCount: Int {
        state.shouldSkipChainReadiness ? OnboardingStep.allCases.count - 1 : OnboardingStep.allCases.count
    }

    private var modelButtonTitle: String {
        guard let hardwareProfile = state.hardwareProfile else {
            return "Checking Mac"
        }
        _ = hardwareProfile

        switch state.installState {
        case .idle:
            return "Download & Install"
        case .installing(let progress):
            return "Downloading \(Int(progress * 100))%"
        case .installed:
            return "Continue"
        case .failed:
            return "Retry Download"
        }
    }

    private var modelButtonEnabled: Bool {
        guard state.hardwareMeetsModelRequirement else {
            return false
        }
        if case .installing = state.installState {
            return false
        }
        return true
    }

    private func modelPrimaryAction() {
        if state.canContinueFromModel {
            state.advance()
        } else {
            state.installSelectedModel()
        }
    }

    private var keysButtonTitle: String {
        switch state.keyState {
        case .idle, .failed:
            return "Create Keys"
        case .creating:
            return "Creating..."
        case .ready:
            return "Continue"
        }
    }

    private var keysButtonEnabled: Bool {
        state.keyState != .creating
    }

    private func keysPrimaryAction() {
        if state.canComplete {
            if state.shouldSkipChainReadiness {
                state.complete()
                onComplete()
            } else {
                state.advance()
            }
        } else {
            state.provisionKeys()
        }
    }

    private var syncFooterCaption: String {
        switch state.chainReadinessState {
        case .ready:
            return "Verified reads are ready. The dashboard can load live wallet state."
        case .timedOut:
            return "Helios did not report ready within 30 minutes. Check RPC settings or retry."
        case .failed:
            return "Sync failed. You can retry or go back to update RPC settings."
        case .idle, .preparing, .syncing:
            if state.chainReadinessIsTakingLonger {
                return "This is taking longer than usual. Keep the app open; the step stops after 30 minutes."
            }
            return "Starting wallet-node and waiting for Helios verified reads before opening the dashboard."
        }
    }

    private var syncButtonTitle: String {
        switch state.chainReadinessState {
        case .ready:
            return "Open Wallet"
        case .timedOut, .failed:
            return "Retry Sync"
        case .idle:
            return "Start Sync"
        case .preparing, .syncing:
            return "Syncing..."
        }
    }

    private var syncButtonSystemImage: String {
        switch state.chainReadinessState {
        case .timedOut, .failed:
            return "arrow.clockwise"
        case .idle, .preparing, .syncing, .ready:
            return "arrow.right"
        }
    }

    private var syncButtonEnabled: Bool {
        state.canOpenWalletAfterReadiness || state.canRetryChainReadiness
    }

    private func syncPrimaryAction() {
        if state.canOpenWalletAfterReadiness {
            state.complete()
            onComplete()
        } else {
            state.startChainReadinessIfNeeded(force: true)
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 34) {
            Spacer()
            EthereumConstellation()
                .frame(width: 840, height: 260)
            VStack(spacing: 14) {
                Text("Own your wallet AI.")
                    .font(.system(size: 46, weight: .heavy))
                    .foregroundStyle(OnboardingPalette.primaryText)
                Text("Local models, your RPCs, and keys that live on your Mac. Everything important stays with you.")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 760)
                    .lineSpacing(5)
            }
            Spacer()
        }
    }
}

private struct NetworkStep: View {
    @ObservedObject var state: OnboardingState

    var body: some View {
        OnboardingTwoColumn(
            illustration: .network,
            headline: "Choose your nodes",
            bodyText: "Configure Sepolia and Mainnet RPCs for reads and submission prep. Add a consensus RPC only when you want Helios verification."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingSegmentedControl(
                    selection: $state.selectedNetworkID,
                    options: OnboardingNetwork.allCases.map(\.rawValue)
                )
                .frame(height: 54)

                VStack(alignment: .leading, spacing: 14) {
                    Text(state.selectedNetwork.displayName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(OnboardingPalette.primaryText)
                    networkFields(for: state.selectedNetwork)
                }

                OnboardingGlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        InfoRow(icon: "network", title: "Execution RPC", detail: "Used for current EVM state, transaction preparation, submission, balances, and receipts.")
                        InfoRow(icon: "checkmark.shield", title: "Consensus RPC", detail: "Optional for Helios verified reads. Leave blank to skip sync and use execution RPC reads.")
                        InfoRow(icon: "clock.arrow.circlepath", title: "Archive node", detail: "Optional endpoint for historical reads and richer wallet timelines.")
                    }
                    .padding(16)
                }
            }
        }
    }

    @ViewBuilder
    private func networkFields(for network: OnboardingNetwork) -> some View {
        switch network {
        case .sepolia:
            OnboardingTextField(
                label: "Execution RPC URL",
                placeholder: "Required",
                text: $state.sepoliaRPCURL
            )
            OnboardingTextField(
                label: "Consensus RPC URL",
                placeholder: ChainConfiguration.ethereumSepolia.consensusRPCURL?.absoluteString ?? "",
                text: $state.sepoliaConsensusRPCURL
            )
            OnboardingTextField(
                label: "Archive Node URL",
                placeholder: "Optional",
                text: $state.sepoliaArchiveNodeURL
            )
        case .mainnet:
            OnboardingTextField(
                label: "Execution RPC URL",
                placeholder: "Required",
                text: $state.mainnetRPCURL
            )
            OnboardingTextField(
                label: "Consensus RPC URL",
                placeholder: ChainConfiguration.ethereum.consensusRPCURL?.absoluteString ?? "",
                text: $state.mainnetConsensusRPCURL
            )
            OnboardingTextField(
                label: "Archive Node URL",
                placeholder: "Optional",
                text: $state.mainnetArchiveNodeURL
            )
        }
    }
}

private struct ModelStep: View {
    @ObservedObject var state: OnboardingState

    var body: some View {
        OnboardingTwoColumn(
            illustration: .model,
            headline: "Pick a brain",
            bodyText: "Gemma 4 E4B is the only local model for now. The GGUF is downloaded from Hugging Face and kept on this Mac."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Local llama.cpp model - runs entirely on this Mac.")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.secondaryText)

                OnboardingSegmentedControl(selection: .constant("Local"), options: ["Local"])
                    .frame(height: 54)

                VStack(spacing: 12) {
                    ForEach(LocalAIModel.available) { model in
                        ModelCard(
                            model: model,
                            verdict: state.fitVerdict(for: model),
                            isSelected: state.selectedModelID == model.id,
                            isInstalled: state.installState == .installed && state.selectedModelID == model.id
                        ) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                                state.selectedModelID = model.id
                                if state.installState == .installed {
                                    state.installState = .idle
                                }
                            }
                        }
                    }
                }

                ModelInstallStatusCard(installState: state.installState, model: state.selectedModel)
                HardwareRequirementCard(profile: state.hardwareProfile, warning: state.hardwareWarning)
            }
        }
    }
}

private struct KeysStep: View {
    @ObservedObject var state: OnboardingState

    var body: some View {
        OnboardingTwoColumn(
            illustration: .keys,
            headline: "Create your root",
            bodyText: "Create the Secure Enclave wallet key, then create the local bundler key. The predicted Kernel smart-account address appears before deployment."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                switch state.keyState {
                case .idle:
                    setupPreview
                case .creating:
                    creatingView
                case .ready(let kernelAddress, let bundlerAddress):
                    readyView(kernelAddress: kernelAddress, bundlerAddress: bundlerAddress)
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 14) {
                        errorBanner(message)
                        setupPreview
                    }
                }
            }
        }
    }

    private var setupPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            AddressPreviewCard(
                icon: "lock.shield",
                title: "Secure Enclave root key",
                value: "Not created yet",
                badge: "P-256"
            )
            AddressPreviewCard(
                icon: "key.horizontal",
                title: "Bundler key",
                value: "Not created yet",
                badge: "EOA"
            )
            OnboardingGlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    InfoRow(icon: "checkmark.shield", title: "Root key", detail: "Used for the wallet signing path and Kernel address derivation.")
                    InfoRow(icon: "bolt.horizontal", title: "Bundler key", detail: "Local relayer key stored separately in Keychain.")
                }
                .padding(16)
            }
        }
    }

    private var creatingView: some View {
        OnboardingGlassCard {
            HStack(spacing: 14) {
                ProgressView()
                    .scaleEffect(0.85)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Creating keys")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(OnboardingPalette.primaryText)
                    Text("macOS may ask you to authenticate before Secure Enclave access completes.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OnboardingPalette.secondaryText)
                }
                Spacer()
            }
            .padding(18)
        }
    }

    private func readyView(kernelAddress: String, bundlerAddress: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            AddressPreviewCard(
                icon: "lock.shield.fill",
                title: "Kernel smart account",
                value: kernelAddress,
                badge: "READY"
            )
            AddressPreviewCard(
                icon: "key.fill",
                title: "Bundler address",
                value: bundlerAddress,
                badge: "READY"
            )
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(OnboardingPalette.success)
                Text("Wallet setup is ready. Open the dashboard to inspect and test the account.")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.secondaryText)
            }
            .padding(.horizontal, 4)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(OnboardingPalette.warning)
            Text(message)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OnboardingPalette.warning)
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OnboardingPalette.warning.opacity(0.12))
        )
    }
}

private struct SyncStep: View {
    @ObservedObject var state: OnboardingState

    var body: some View {
        OnboardingTwoColumn(
            illustration: .sync,
            headline: "Sync verified reads",
            bodyText: "Local wallet-node starts Helios and waits until Ethereum reads are verified before the dashboard opens."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                ReadinessStatusCard(state: state)
                OnboardingGlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ReadinessProgressRow(
                            icon: "terminal",
                            title: "wallet-node",
                            detail: daemonRowDetail,
                            badge: daemonBadge,
                            color: daemonColor
                        )
                        ReadinessProgressRow(
                            icon: "checkmark.shield",
                            title: "Helios",
                            detail: heliosRowDetail,
                            badge: heliosBadge,
                            color: heliosColor
                        )
                        ReadinessProgressRow(
                            icon: "wallet.pass",
                            title: "Wallet state",
                            detail: walletRowDetail,
                            badge: walletBadge,
                            color: walletColor
                        )
                    }
                    .padding(16)
                }
                ReadinessLogCard(entries: state.chainReadinessLog)
            }
        }
        .task {
            state.startChainReadinessIfNeeded()
        }
    }

    private var daemonRowDetail: String {
        switch state.chainReadinessState {
        case .idle:
            return "Waiting to start the local daemon."
        case .preparing:
            return "Unlocking the bundler key and starting the local daemon."
        case .failed:
            return "Daemon startup or readiness check ended with an error."
        case .syncing, .ready, .timedOut:
            return "Local daemon is reachable over the authenticated local transport."
        }
    }

    private var daemonBadge: String {
        switch state.chainReadinessState {
        case .idle:
            return "WAITING"
        case .preparing:
            return "STARTING"
        case .failed:
            return "ERROR"
        case .syncing, .ready, .timedOut:
            return "DONE"
        }
    }

    private var daemonColor: Color {
        switch state.chainReadinessState {
        case .failed:
            return OnboardingPalette.warning
        case .ready, .syncing, .timedOut:
            return OnboardingPalette.success
        case .idle, .preparing:
            return OnboardingPalette.accent
        }
    }

    private var heliosRowDetail: String {
        if let status = state.latestChainReadinessStatus {
            if let head = status.helios.head {
                return "Verified head #\(head.number) on \(status.networkProfile)."
            }
            return "Status: \(status.status.replacingOccurrences(of: "_", with: " "))."
        }
        switch state.chainReadinessState {
        case .timedOut:
            return "Helios did not report ready before the onboarding timeout."
        case .failed(let message):
            return message
        default:
            return "Waiting for Helios to report verified reads ready."
        }
    }

    private var heliosBadge: String {
        switch state.chainReadinessState {
        case .ready:
            return "READY"
        case .timedOut:
            return "TIMEOUT"
        case .failed:
            return "ERROR"
        case .idle, .preparing, .syncing:
            return state.chainReadinessIsTakingLonger ? "STILL SYNCING" : "SYNCING"
        }
    }

    private var heliosColor: Color {
        switch state.chainReadinessState {
        case .ready:
            return OnboardingPalette.success
        case .timedOut, .failed:
            return OnboardingPalette.warning
        case .idle, .preparing, .syncing:
            return OnboardingPalette.accent
        }
    }

    private var walletRowDetail: String {
        switch state.chainReadinessState {
        case .ready:
            return "Account inspection and gas read run after Helios is ready."
        case .timedOut, .failed:
            return "Dashboard warm-up is blocked until Helios is ready."
        default:
            return "Runs after Helios is ready, so the first dashboard reads do not race sync."
        }
    }

    private var walletBadge: String {
        switch state.chainReadinessState {
        case .ready:
            return "DONE"
        case .timedOut, .failed:
            return "BLOCKED"
        default:
            return "PENDING"
        }
    }

    private var walletColor: Color {
        switch state.chainReadinessState {
        case .ready:
            return OnboardingPalette.success
        case .timedOut, .failed:
            return OnboardingPalette.warning
        default:
            return OnboardingPalette.mutedText
        }
    }
}

private struct ReadinessStatusCard: View {
    @ObservedObject var state: OnboardingState

    var body: some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 14) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(OnboardingPalette.primaryText)
                        Text(detail)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OnboardingPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(elapsedText)
                        .font(.system(size: 17, weight: .black, design: .monospaced))
                        .foregroundStyle(OnboardingPalette.primaryText)
                }

                ProgressView(value: min(state.chainReadinessElapsed, state.chainReadinessTiming.timeout), total: state.chainReadinessTiming.timeout)
                    .progressViewStyle(.linear)
                    .tint(progressColor)

                if state.chainReadinessIsTakingLonger {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(OnboardingPalette.warning)
                        Text("Taking longer than usual. The app will stop this attempt after 30 minutes.")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OnboardingPalette.secondaryText)
                    }
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state.chainReadinessState {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(OnboardingPalette.success)
                .frame(width: 30, height: 30)
        case .timedOut, .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(OnboardingPalette.warning)
                .frame(width: 30, height: 30)
        case .idle, .preparing, .syncing:
            ProgressView()
                .scaleEffect(0.82)
                .frame(width: 30, height: 30)
        }
    }

    private var title: String {
        switch state.chainReadinessState {
        case .idle:
            return "Ready to start"
        case .preparing:
            return "Starting local daemon"
        case .syncing:
            return state.chainReadinessIsTakingLonger ? "Still syncing Helios" : "Syncing Helios"
        case .ready:
            return "Verified reads ready"
        case .timedOut:
            return "Sync timed out"
        case .failed:
            return "Sync failed"
        }
    }

    private var detail: String {
        switch state.chainReadinessState {
        case .idle:
            return "The app will start wallet-node before opening the dashboard."
        case .preparing:
            return "macOS may ask for biometric authentication to unlock the local bundler key."
        case .syncing(let status):
            if let status {
                return "wallet-node reports \(status.status.replacingOccurrences(of: "_", with: " ")) on \(status.networkProfile)."
            }
            return "Waiting for wallet-node to report Helios readiness."
        case .ready(let status):
            if let head = status.helios.head {
                return "Helios is ready on \(status.networkProfile) at block #\(head.number)."
            }
            return "Helios is ready on \(status.networkProfile)."
        case .timedOut:
            return "This attempt reached the onboarding timeout. Retry, or go back and check the RPC URLs."
        case .failed(let message):
            return message
        }
    }

    private var elapsedText: String {
        let elapsed = max(0, Int(state.chainReadinessElapsed.rounded(.down)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var progressColor: Color {
        switch state.chainReadinessState {
        case .ready:
            return OnboardingPalette.success
        case .timedOut, .failed:
            return OnboardingPalette.warning
        case .idle, .preparing, .syncing:
            return OnboardingPalette.accent
        }
    }
}

private struct ReadinessLogCard: View {
    let entries: [String]

    var body: some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(OnboardingPalette.accent)
                    Text("Readiness log")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(OnboardingPalette.primaryText)
                    Spacer()
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            if entries.isEmpty {
                                Text("No readiness events yet.")
                                    .foregroundStyle(OnboardingPalette.mutedText)
                                    .id("empty")
                            } else {
                                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                                    Text(entry)
                                        .textSelection(.enabled)
                                        .id(index)
                                }
                            }
                        }
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(OnboardingPalette.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 112)
                    .onChange(of: entries.count) { _, count in
                        guard count > 0 else {
                            return
                        }
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
            .padding(14)
        }
    }
}

private struct ReadinessProgressRow: View {
    let icon: String
    let title: String
    let detail: String
    let badge: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(OnboardingPalette.primaryText)
                    Text(badge)
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(color.opacity(0.12)))
                }
                Text(detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OnboardingPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

private struct OnboardingTwoColumn<Content: View>: View {
    let illustration: EthereumIllustrationKind
    let headline: String
    let bodyText: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 74) {
            VStack(alignment: .leading, spacing: 22) {
                Spacer()
                EthereumIllustration(kind: illustration)
                    .frame(width: 390, height: 330)
                VStack(alignment: .leading, spacing: 14) {
                    Text(headline)
                        .font(.system(size: 31, weight: .heavy))
                        .foregroundStyle(OnboardingPalette.primaryText)
                    Text(bodyText)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(OnboardingPalette.secondaryText)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .frame(width: 470, alignment: .leading)

            content
                .frame(maxWidth: 660, alignment: .leading)
        }
        .padding(.horizontal, 12)
    }
}

private enum EthereumIllustrationKind {
    case network
    case model
    case keys
    case sync
}

private struct EthereumConstellation: View {
    var body: some View {
        ZStack {
            CircuitLine(points: [
                CGPoint(x: 0.09, y: 0.70),
                CGPoint(x: 0.25, y: 0.42),
                CGPoint(x: 0.42, y: 0.58),
                CGPoint(x: 0.58, y: 0.31),
                CGPoint(x: 0.76, y: 0.52),
                CGPoint(x: 0.92, y: 0.24),
            ])
            .stroke(OnboardingPalette.accent.opacity(0.36), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

            EthereumGlyph(tint: OnboardingPalette.ethereumCyan)
                .frame(width: 126, height: 198)
                .offset(x: -310, y: 32)
                .rotationEffect(.degrees(-10))
            EthereumGlyph(tint: OnboardingPalette.ethereumViolet)
                .frame(width: 178, height: 268)
                .offset(x: -145, y: -10)
            EthereumGlyph(tint: OnboardingPalette.ethereumBlue)
                .frame(width: 132, height: 204)
                .offset(x: 35, y: 38)
                .rotationEffect(.degrees(8))
            EthereumGlyph(tint: OnboardingPalette.ethereumGold)
                .frame(width: 118, height: 184)
                .offset(x: 230, y: -52)
                .rotationEffect(.degrees(-8))
            EthereumGlyph(tint: OnboardingPalette.success)
                .frame(width: 128, height: 198)
                .offset(x: 365, y: 24)
                .rotationEffect(.degrees(12))
        }
    }
}

private struct EthereumIllustration: View {
    let kind: EthereumIllustrationKind

    var body: some View {
        ZStack {
            Circle()
                .fill(OnboardingPalette.accent.opacity(0.10))
                .frame(width: 310, height: 310)
                .blur(radius: 24)

            EthereumGlyph(tint: tint)
                .frame(width: 170, height: 270)

            switch kind {
            case .network:
                NetworkOrbit()
            case .model:
                ModelCore()
            case .keys:
                KeyOrbit()
            case .sync:
                SyncOrbit()
            }
        }
    }

    private var tint: Color {
        switch kind {
        case .network:
            return OnboardingPalette.ethereumCyan
        case .model:
            return OnboardingPalette.ethereumViolet
        case .keys:
            return OnboardingPalette.ethereumGold
        case .sync:
            return OnboardingPalette.success
        }
    }
}

private struct EthereumGlyph: View {
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                PolygonShape(points: [
                    CGPoint(x: 0.50, y: 0.00),
                    CGPoint(x: 0.08, y: 0.50),
                    CGPoint(x: 0.50, y: 0.38),
                ])
                .fill(tint.opacity(0.95))

                PolygonShape(points: [
                    CGPoint(x: 0.50, y: 0.00),
                    CGPoint(x: 0.92, y: 0.50),
                    CGPoint(x: 0.50, y: 0.38),
                ])
                .fill(tint.opacity(0.72))

                PolygonShape(points: [
                    CGPoint(x: 0.08, y: 0.58),
                    CGPoint(x: 0.50, y: 1.00),
                    CGPoint(x: 0.50, y: 0.68),
                ])
                .fill(tint.opacity(0.50))

                PolygonShape(points: [
                    CGPoint(x: 0.92, y: 0.58),
                    CGPoint(x: 0.50, y: 1.00),
                    CGPoint(x: 0.50, y: 0.68),
                ])
                .fill(tint.opacity(0.86))

                PolygonShape(points: [
                    CGPoint(x: 0.08, y: 0.50),
                    CGPoint(x: 0.50, y: 0.38),
                    CGPoint(x: 0.92, y: 0.50),
                    CGPoint(x: 0.50, y: 0.68),
                ])
                .fill(Color.white.opacity(0.08))

                FacetLines()
                    .stroke(OnboardingPalette.outline, style: StrokeStyle(lineWidth: max(2, size * 0.018), lineCap: .round, lineJoin: .round))
            }
            .shadow(color: tint.opacity(0.30), radius: 18, x: 0, y: 8)
        }
    }
}

private struct NetworkOrbit: View {
    var body: some View {
        ZStack {
            CircuitLine(points: [
                CGPoint(x: 0.18, y: 0.62),
                CGPoint(x: 0.37, y: 0.46),
                CGPoint(x: 0.64, y: 0.50),
                CGPoint(x: 0.83, y: 0.30),
            ])
            .stroke(OnboardingPalette.ethereumCyan.opacity(0.55), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            node(x: -130, y: 56, icon: "server.rack")
            node(x: 128, y: -82, icon: "antenna.radiowaves.left.and.right")
            node(x: 142, y: 72, icon: "point.3.connected.trianglepath.dotted")
        }
    }

    private func node(x: CGFloat, y: CGFloat, icon: String) -> some View {
        ZStack {
            Circle()
                .fill(OnboardingPalette.panel)
                .overlay(Circle().stroke(OnboardingPalette.ethereumCyan, lineWidth: 2))
                .frame(width: 58, height: 58)
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(OnboardingPalette.ethereumCyan)
        }
        .offset(x: x, y: y)
    }
}

private struct ModelCore: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OnboardingPalette.deepPanel)
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(OnboardingPalette.ethereumViolet, lineWidth: 3))
                .frame(width: 118, height: 118)
                .offset(x: 112, y: 66)

            ForEach([-1, 0, 1], id: \.self) { index in
                Capsule()
                    .fill(OnboardingPalette.ethereumViolet)
                    .frame(width: 38, height: 5)
                    .offset(x: 47, y: CGFloat(index * 24 + 66))
            }

            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(OnboardingPalette.primaryText)
                .offset(x: 112, y: 66)
        }
    }
}

private struct KeyOrbit: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(OnboardingPalette.ethereumGold.opacity(0.55), style: StrokeStyle(lineWidth: 3, dash: [8, 12]))
                .frame(width: 268, height: 268)

            ZStack {
                Circle()
                    .stroke(OnboardingPalette.ethereumGold, lineWidth: 8)
                    .frame(width: 58, height: 58)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(OnboardingPalette.ethereumGold)
                    .frame(width: 108, height: 20)
                    .offset(x: 68)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(OnboardingPalette.ethereumGold)
                    .frame(width: 18, height: 34)
                    .offset(x: 116, y: 22)
            }
            .rotationEffect(.degrees(-18))
            .offset(x: 62, y: 96)
        }
    }
}

private struct SyncOrbit: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(OnboardingPalette.success.opacity(0.54), style: StrokeStyle(lineWidth: 3, dash: [10, 10]))
                .frame(width: 278, height: 278)

            ForEach(0..<4, id: \.self) { index in
                ZStack {
                    Circle()
                        .fill(OnboardingPalette.panel)
                        .overlay(Circle().stroke(OnboardingPalette.success, lineWidth: 2))
                        .frame(width: 54, height: 54)
                    Image(systemName: symbol(for: index))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(OnboardingPalette.success)
                }
                .offset(offset(for: index))
            }
        }
    }

    private func symbol(for index: Int) -> String {
        switch index {
        case 0:
            return "server.rack"
        case 1:
            return "checkmark.shield"
        case 2:
            return "link"
        default:
            return "wallet.pass"
        }
    }

    private func offset(for index: Int) -> CGSize {
        switch index {
        case 0:
            return CGSize(width: -132, height: -4)
        case 1:
            return CGSize(width: 0, height: -136)
        case 2:
            return CGSize(width: 132, height: -4)
        default:
            return CGSize(width: 0, height: 136)
        }
    }
}

private struct PolygonShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else {
            return path
        }

        path.move(to: CGPoint(x: rect.minX + first.x * rect.width, y: rect.minY + first.y * rect.height))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height))
        }
        path.closeSubpath()
        return path
    }
}

private struct FacetLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }

        path.move(to: p(0.50, 0.00))
        path.addLine(to: p(0.08, 0.50))
        path.addLine(to: p(0.50, 0.38))
        path.addLine(to: p(0.92, 0.50))
        path.addLine(to: p(0.50, 0.00))
        path.move(to: p(0.08, 0.58))
        path.addLine(to: p(0.50, 1.00))
        path.addLine(to: p(0.92, 0.58))
        path.move(to: p(0.50, 0.38))
        path.addLine(to: p(0.50, 1.00))
        path.move(to: p(0.08, 0.50))
        path.addLine(to: p(0.92, 0.50))
        return path
    }
}

private struct CircuitLine: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else {
            return path
        }
        path.move(to: CGPoint(x: rect.minX + first.x * rect.width, y: rect.minY + first.y * rect.height))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height))
        }
        return path
    }
}

private struct ModelInstallStatusCard: View {
    let installState: OnboardingState.InstallState
    let model: LocalAIModel

    var body: some View {
        switch installState {
        case .idle:
            OnboardingGlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    InfoRow(
                        icon: "arrow.down.circle",
                        title: "Download source",
                        detail: "\(model.artifactRepo) / \(model.artifactFileName)"
                    )
                    InfoRow(
                        icon: "checkmark.seal",
                        title: "Verification",
                        detail: "The app verifies the GGUF SHA256 before marking the model installed."
                    )
                }
                .padding(16)
            }
        case .installing(let progress):
            OnboardingGlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(0.78)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Downloading Gemma 4 E4B")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(OnboardingPalette.primaryText)
                            Text("This is a \(LocalAIModel.recommended.size) model file, so it can take some minutes.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(OnboardingPalette.secondaryText)
                        }
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 18, weight: .black, design: .monospaced))
                            .foregroundStyle(OnboardingPalette.primaryText)
                    }
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(OnboardingPalette.accent)
                }
                .padding(16)
            }
        case .installed:
            OnboardingGlassCard {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(OnboardingPalette.success)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Model installed")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(OnboardingPalette.primaryText)
                        Text("The GGUF is stored in Application Support and ready for the runtime layer.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(OnboardingPalette.secondaryText)
                    }
                    Spacer()
                }
                .padding(16)
            }
        case .failed(let message):
            OnboardingGlassCard {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(OnboardingPalette.warning)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Download failed")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(OnboardingPalette.primaryText)
                        Text(message)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(OnboardingPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(16)
            }
        }
    }
}

private struct HardwareRequirementCard: View {
    let profile: LocalHardwareProfile?
    /// nil means the selected model fits comfortably on this Mac.
    let warning: String?

    var body: some View {
        OnboardingGlassCard {
            HStack(alignment: .top, spacing: 12) {
                statusIcon
                VStack(alignment: .leading, spacing: 5) {
                    Text("Hardware check")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(OnboardingPalette.primaryText)
                    Text(detailText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OnboardingPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(badgeText)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(badgeColor.opacity(0.12)))
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if let profile {
            Image(systemName: warning == nil ? "memorychip.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(warning == nil ? OnboardingPalette.success : OnboardingPalette.warning)
                .frame(width: 24, height: 24)
        } else {
            ProgressView()
                .scaleEffect(0.72)
                .frame(width: 24, height: 24)
        }
    }

    private var detailText: String {
        guard let profile else {
            return "Checking this Mac."
        }
        guard let warning else {
            return "\(profile.displayName). Ready for the local model."
        }
        return "\(profile.displayName). \(warning)"
    }

    private var badgeText: String {
        guard profile != nil else { return "CHECKING" }
        return warning == nil ? "READY" : "TIGHT"
    }

    private var badgeColor: Color {
        guard profile != nil else { return OnboardingPalette.mutedText }
        return warning == nil ? OnboardingPalette.success : OnboardingPalette.warning
    }
}

private struct ModelCard: View {
    let model: LocalAIModel
    let verdict: ModelFitVerdict
    let isSelected: Bool
    let isInstalled: Bool
    let action: () -> Void

    private var verdictTint: Color {
        switch verdict {
        case .fits: return OnboardingPalette.success
        case .tight: return OnboardingPalette.warning
        case .wontFit: return OnboardingPalette.warning
        case .unknown: return OnboardingPalette.mutedText
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(isSelected ? OnboardingPalette.accent : OnboardingPalette.deepPanel)
                        .frame(width: 58, height: 58)
                    Image(systemName: model.systemImage)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : OnboardingPalette.secondaryText)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        Text(model.name)
                            .font(.system(size: 21, weight: .bold))
                            .foregroundStyle(OnboardingPalette.primaryText)
                            .lineLimit(1)
                        Text(model.size)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(OnboardingPalette.mutedText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(OnboardingPalette.deepPanel))
                        Text(model.tag)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(OnboardingPalette.mutedText)
                        Text(verdict.label)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(verdictTint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(verdictTint.opacity(0.14)))
                    }
                    Text(model.detail)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(OnboardingPalette.secondaryText)
                        .lineLimit(2)
                }

                Spacer()

                ZStack {
                    Circle()
                        .stroke(isSelected ? OnboardingPalette.accent : OnboardingPalette.border, lineWidth: 3)
                        .frame(width: 30, height: 30)
                    if isSelected {
                        Circle()
                            .fill(OnboardingPalette.primaryText)
                            .frame(width: 14, height: 14)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? OnboardingPalette.selectedPanel : OnboardingPalette.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(isSelected ? OnboardingPalette.accent : OnboardingPalette.border, lineWidth: isSelected ? 3 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if isInstalled {
                Text("INSTALLED")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(OnboardingPalette.success)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(OnboardingPalette.success.opacity(0.12)))
                    .padding(10)
            }
        }
    }
}

private struct AddressPreviewCard: View {
    let icon: String
    let title: String
    let value: String
    let badge: String

    var body: some View {
        OnboardingGlassCard {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(OnboardingPalette.accent.opacity(0.18))
                        .frame(width: 52, height: 52)
                    Image(systemName: icon)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(OnboardingPalette.accent)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(OnboardingPalette.mutedText)
                    Text(value)
                        .font(.system(size: 17, weight: .bold, design: value.hasPrefix("0x") ? .monospaced : .default))
                        .foregroundStyle(OnboardingPalette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(badge)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(OnboardingPalette.mutedText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(OnboardingPalette.deepPanel))
            }
            .padding(16)
        }
    }
}

private struct InfoRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnboardingPalette.accent)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(OnboardingPalette.primaryText)
                Text(detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OnboardingPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

private struct OnboardingTextField: View {
    let label: String
    let placeholder: String
    var detail: String? = nil
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label.uppercased())
                .font(.system(size: 13, weight: .black, design: .monospaced))
                .foregroundStyle(OnboardingPalette.mutedText)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundStyle(OnboardingPalette.primaryText)
                .padding(.horizontal, 18)
                .frame(height: 62)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(OnboardingPalette.input)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(OnboardingPalette.border, lineWidth: 1.5)
                        )
                )
            if let detail {
                Text(detail)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct OnboardingSegmentedControl: View {
    @Binding var selection: String
    let options: [String]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: systemImage(for: option))
                        Text(option)
                    }
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(selection == option ? .white : OnboardingPalette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(selection == option ? OnboardingPalette.accent : Color.clear)
                            .padding(4)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(OnboardingPalette.input)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(OnboardingPalette.border, lineWidth: 1.5)
                )
        )
    }

    private func systemImage(for option: String) -> String {
        switch option {
        case "Local":
            return "externaldrive.fill"
        case "Sepolia":
            return "testtube.2"
        case "Mainnet":
            return "globe"
        default:
            return "circle.grid.cross"
        }
    }
}

private struct OnboardingGlassCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(OnboardingPalette.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(OnboardingPalette.border, lineWidth: 1)
                    )
            )
    }
}

private struct OnboardingStepIndicator: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 10) {
            ForEach(1...total, id: \.self) { index in
                Circle()
                    .fill(index == current ? OnboardingPalette.accent : OnboardingPalette.border)
                    .frame(width: 12, height: 12)
            }
        }
    }
}

private struct OnboardingBrandButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(title)
                    .font(.system(size: 22, weight: .black))
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .black))
            }
            .foregroundStyle(OnboardingPalette.buttonText)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(
                Capsule()
                    .fill(OnboardingPalette.button)
                    .shadow(color: .black.opacity(0.28), radius: 20, x: 0, y: 10)
            )
        }
        .buttonStyle(.plain)
        .opacity(title == "Installing..." ? 0.65 : 1)
    }
}

private struct OnboardingTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(OnboardingPalette.secondaryText)
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private struct OnboardingIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(OnboardingPalette.secondaryText)
            .background(
                Circle()
                    .fill(OnboardingPalette.input)
                    .overlay(Circle().stroke(OnboardingPalette.border, lineWidth: 1.2))
            )
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private enum OnboardingPalette {
    static let background = Color(red: 0.045, green: 0.055, blue: 0.115)
    static let panel = Color(red: 0.080, green: 0.095, blue: 0.165)
    static let selectedPanel = Color(red: 0.100, green: 0.130, blue: 0.250)
    static let deepPanel = Color(red: 0.050, green: 0.060, blue: 0.120)
    static let input = Color(red: 0.055, green: 0.060, blue: 0.115)
    static let border = Color(red: 0.250, green: 0.285, blue: 0.450)
    static let accent = Color(red: 0.300, green: 0.440, blue: 0.890)
    static let outline = Color(red: 0.100, green: 0.250, blue: 0.680)
    static let ethereumCyan = Color(red: 0.330, green: 0.760, blue: 1.000)
    static let ethereumViolet = Color(red: 0.550, green: 0.430, blue: 1.000)
    static let ethereumBlue = Color(red: 0.220, green: 0.400, blue: 0.980)
    static let ethereumGold = Color(red: 1.000, green: 0.760, blue: 0.190)
    static let primaryText = Color(red: 1.000, green: 0.990, blue: 0.880)
    static let secondaryText = Color(red: 0.760, green: 0.800, blue: 0.930)
    static let mutedText = Color(red: 0.560, green: 0.620, blue: 0.800)
    static let button = Color(red: 1.000, green: 0.990, blue: 0.880)
    static let buttonText = Color(red: 0.045, green: 0.055, blue: 0.115)
    static let success = Color(red: 0.360, green: 0.900, blue: 0.340)
    static let warning = Color(red: 1.000, green: 0.700, blue: 0.230)
}
