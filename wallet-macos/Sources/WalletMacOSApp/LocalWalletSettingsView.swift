import Foundation
import AppKit
import SwiftUI

enum SettingsHealthState: String, Equatable {
    case healthy = "Healthy"
    case warning = "Warning"
    case failed = "Failed"
    case skipped = "Skipped"

    var tint: Color {
        switch self {
        case .healthy:
            return SettingsPalette.green
        case .warning:
            return SettingsPalette.orange
        case .failed:
            return SettingsPalette.red
        case .skipped:
            return SettingsPalette.mutedText
        }
    }

    var systemImage: String {
        switch self {
        case .healthy:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .skipped:
            return "minus.circle.fill"
        }
    }
}

struct SettingsHealthCheck: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let state: SettingsHealthState
    let detail: String
    let latencyMilliseconds: Int?
}

struct SettingsDiagnosticsReport: Equatable {
    let generatedAt: Date
    let checks: [SettingsHealthCheck]
}

struct SettingsHeliosCheckpointResult: Equatable {
    let networkProfile: String
    let checkpointLoaded: Bool
    let checkpointAgeDays: Double?
    let headNumber: UInt64?
    let readsVerified: Bool

    init(status: WalletNodeClient.NetworkStatus) {
        self.networkProfile = status.networkProfile
        self.checkpointLoaded = status.helios.checkpointLoaded
        self.checkpointAgeDays = status.helios.checkpointAgeDays
        self.headNumber = status.helios.head?.number
        self.readsVerified = status.readVerification.verified
    }

    var successMessage: String {
        var parts = ["Helios checkpoint loaded on \(networkProfile)."]
        if let headNumber {
            parts.append("Head #\(headNumber).")
        } else if let checkpointAgeDays {
            parts.append(String(format: "Checkpoint age %.2f days.", checkpointAgeDays))
        }
        parts.append(readsVerified ? "Verified reads are ready." : "Helios is still syncing in the background.")
        return parts.joined(separator: " ")
    }
}

struct LocalWalletSessionSettingsSnapshot: Equatable {
    let isEnabled: Bool
    let configuredPolicy: SessionPolicyConfig
    let record: SessionRecord?
    let capturedAt: Date

    var hasRecord: Bool {
        record != nil
    }

    var isExpired: Bool {
        expiryReason != nil
    }

    var expiryReason: SessionExpiryReason? {
        record.flatMap { SessionLifecycle.expiryReason(record: $0, now: capturedAt) }
    }

    var inactivityExpiresAt: Date? {
        guard let record else {
            return nil
        }
        return record.lastActivityAt.addingTimeInterval(
            TimeInterval(record.policyConfigSnapshot.inactivityTimeoutSeconds)
        )
    }

    var statusTitle: String {
        guard let record else {
            return "Off"
        }
        if isExpired {
            switch expiryReason {
            case .duration:
                return "Duration expired"
            case .inactivity:
                return "Inactive"
            case nil:
                return "Expired"
            }
        }
        if isEnabled && record.installedOnChain {
            return "Active"
        }
        if isEnabled {
            return "Pending install"
        }
        return "Stored"
    }

    var statusDetail: String {
        guard let record else {
            return "No session permission is stored for this chain."
        }
        if isExpired {
            switch expiryReason {
            case .duration:
                return "Duration ended \(Self.dateFormatter.string(from: record.expiresAt))"
            case .inactivity:
                let inactiveAt = inactivityExpiresAt.map(Self.dateFormatter.string(from:)) ?? "earlier"
                return "Inactivity timeout ended \(inactiveAt)"
            case nil:
                return "Expired \(Self.dateFormatter.string(from: record.expiresAt))"
            }
        }
        if isEnabled && record.installedOnChain {
            let inactiveAt = inactivityExpiresAt.map(Self.dateFormatter.string(from:)) ?? "unavailable"
            return "Expires \(Self.dateFormatter.string(from: record.expiresAt)); inactive at \(inactiveAt)"
        }
        if isEnabled {
            return "First in-policy session transaction will install it onchain."
        }
        return "A local record exists while the session toggle is off."
    }

    var activePolicy: SessionPolicyConfig {
        record?.policyConfigSnapshot ?? configuredPolicy
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

struct LocalWalletSettingsSnapshot: Equatable {
    let capturedAt: Date
    let appVersion: String
    let appBuild: String
    let textModelName: String
    let textModelIdentifier: String
    let textModelSize: String
    let textModelDetail: String
    let textModelArtifactRepo: String
    let textModelArtifactFileName: String
    let textModelRuntimeStatus: String
    let textModelInstallStatus: String
    let textModelPath: String
    let modelRows: [SettingsModelRow]
    let hardwareSummary: SettingsHardwareSummary?
    /// Context presets worth offering on this Mac; never empty. See
    /// ModelFitEvaluator.selectableContexts.
    let selectableContextTokens: [Int]
    let contextWindow: String
    let contextWindowTokens: Int
    let contextWindowMaxTokens: Int
    let multimodalModelName: String
    let multimodalModelStatus: String
    let networkSettings: DemoNetworkSettings
    let chainName: String
    let chainID: String
    let executionRPCURL: String
    let configuredRPCURL: String
    let archiveNodeURL: String
    let consensusRPCURL: String
    let maxFeePerGasCap: String
    let maxPriorityFeePerGasCap: String
    let entryPointAddress: String
    let kernelFactoryAddress: String
    let kernelImplementationAddress: String
    let validatorAddress: String
    let kernelAccountAddress: String
    let kernelAccountState: String
    let kernelAccountBalance: String
    let relayerAddress: String
    let relayerState: String
    /// The relayer is under the daemon's low-balance threshold, so every send is refused.
    /// A flag rather than a match on `relayerState`, whose wording is display copy.
    let relayerNeedsGas: Bool
    let relayerBalance: String
    let relayerKeyRef: String
    let relayerLifecycle: String
    let relayerPendingFundingAddress: String
    let relayerPendingFundingCount: Int
    let relayerRetiringCount: Int
    let relayerLatestAuditEvent: String
    let relayerMessage: String
    let databasePath: String
    let databaseSize: String
    let conversationCount: Int
    let messageCount: Int
    let rankingCount: Int
    let walletNodeMode: String
    let walletNodeConfigPath: String
    let walletNodeLogPath: String
    let walletKeyPolicy: String
    let relayerKeyPolicy: String
    let session: LocalWalletSessionSettingsSnapshot
    let bridgeStatus: String
    let activeBundlerStatus: String
    let lastSubmittedUserOperationHash: String
    let lastBundledTransactionHash: String
    let lastError: String
    let releaseChannel: String
    let walletNodeVersion: String
    let rustFFIBuild: String
    let localLLMBackend: String
    let swapSlippageBps: UInt64

    static func appVersionText(bundle: Bundle = .main) -> (version: String, build: String) {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return (
            version?.isEmpty == false ? version! : "Development",
            build?.isEmpty == false ? build! : "local"
        )
    }

    static func walletNodeConfigPath() -> String {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return "Not available"
        }
        return base
            .appendingPathComponent("Local Wallet", isDirectory: true)
            .appendingPathComponent("wallet-node", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
            .path
    }

    static func walletNodeLogPath() -> String {
        WalletNodeDaemon.managedLogFileURL()?.path ?? "Not available"
    }
}

struct LocalWalletSettingsView: View {
    let snapshot: LocalWalletSettingsSnapshot
    /// Install progress lives outside the snapshot, observed directly: it changes
    /// ~100 times per download, and re-deriving the whole settings surface (catalog
    /// stats, fit verdicts, a SQLite count) that often is wasted work. See
    /// `ModelInstallStore`.
    @ObservedObject var installs: ModelInstallStore
    @Binding var thinkingEnabled: Bool
    let initialTab: LocalWalletSettingsTab
    let onExportRankings: () -> Void
    let onExportDatabase: () throws -> String
    let onRevealDatabase: () -> Void
    let onClearChatHistory: () throws -> String
    let onClearRankings: () throws -> String
    let onRevealModelFile: () throws -> String
    let onSelectModel: (String) throws -> String
    /// Starts an install; returns nothing to await. The progress and the final
    /// sentence come back through `installs`, which outlives this view.
    let onStartModelInstall: (ModelDownloadRequest) -> Void
    let onRemoveModel: (String) throws -> String
    let onResolveRepo: (String) async throws -> HuggingFaceRepositoryInfo
    let onInspectRemoteFile: (HuggingFaceGGUFFile) async -> RemoteModelFit
    let onStartCuratedModelInstall: (String) -> Void
    let onCancelModelDownload: () -> Void
    let onSaveNetworkSettings: (DemoNetworkSettings) throws -> String
    let onTestNetworkSettings: (DemoNetworkSettings) async throws -> String
    let onRunDiagnostics: (DemoNetworkSettings) async -> SettingsDiagnosticsReport
    let onMonitorHeliosCheckpoint: (DemoNetworkSettings) async throws -> SettingsHeliosCheckpointResult
    let onRefreshRelayer: () -> Void
    let onRotateRelayer: () async throws -> String
    let onExportRelayerKey: () async throws -> String
    let onResetWallet: () async throws -> String
    let onEnableSessionKeys: () async throws -> String
    let onRevokeSessionKeys: () async throws -> String
    let onUpdateSessionPolicy: (SessionPolicyConfig) throws -> String
    let onCopyDebugReport: () async -> String
    let onClearDebugLog: () -> Void
    let onSetSwapSlippageBps: (UInt64) -> Void
    let onSetContextWindowTokens: (Int) -> Void
    let onClose: () -> Void

    @State private var selectedTab: LocalWalletSettingsTab
    @State private var hardwareProfile: LocalHardwareProfile?
    @State private var networkDraft: DemoNetworkSettings
    @State private var appliedNetworkSettings: DemoNetworkSettings
    @State private var networkMessage: SettingsMessage?
    @State private var isMonitoringHeliosCheckpoint = false
    @State private var heliosCheckpointProgressDetail = ""
    @State private var heliosCheckpointMessage: SettingsMessage?
    @State private var heliosCheckpointRunID: UUID?
    @State private var diagnosticsReport: SettingsDiagnosticsReport?
    @State private var diagnosticsMessage: SettingsMessage?
    @State private var dataMessage: SettingsMessage?
    @State private var modelMessage: SettingsMessage?
    /// Which curated model is being fetched, and how far along. One at a time —
    /// `LocalAIModelDownloadManager` refuses a second concurrent download anyway.
    @State private var walletMessage: SettingsMessage?
    @State private var securityMessage: SettingsMessage?
    @State private var sessionMessage: SettingsMessage?
    @State private var advancedMessage: SettingsMessage?
    @State private var sessionPolicyDraft: SessionPolicyDraft
    @State private var slippageBpsDraft: UInt64
    @State private var slippagePercentField: String
    @State private var contextWindowDraft: Int
    @State private var transactionsMessage: SettingsMessage?
    @State private var isTestingNetwork = false
    @State private var isRunningDiagnostics = false
    @State private var isRotatingRelayer = false
    @State private var isExportingRelayer = false
    @State private var isResettingWallet = false
    @State private var isEnablingSessionKeys = false
    @State private var isRevokingSessionKeys = false
    @State private var showingSessionTokenLimits = false
    @State private var pendingConfirmation: SettingsConfirmation?

    init(
        snapshot: LocalWalletSettingsSnapshot,
        installs: ModelInstallStore,
        thinkingEnabled: Binding<Bool>,
        initialTab: LocalWalletSettingsTab = .info,
        onExportRankings: @escaping () -> Void,
        onExportDatabase: @escaping () throws -> String,
        onRevealDatabase: @escaping () -> Void,
        onClearChatHistory: @escaping () throws -> String,
        onClearRankings: @escaping () throws -> String,
        onRevealModelFile: @escaping () throws -> String,
        onSelectModel: @escaping (String) throws -> String,
        onStartModelInstall: @escaping (ModelDownloadRequest) -> Void,
        onRemoveModel: @escaping (String) throws -> String,
        onResolveRepo: @escaping (String) async throws -> HuggingFaceRepositoryInfo,
        onInspectRemoteFile: @escaping (HuggingFaceGGUFFile) async -> RemoteModelFit,
        onStartCuratedModelInstall: @escaping (String) -> Void,
        onCancelModelDownload: @escaping () -> Void,
        onSaveNetworkSettings: @escaping (DemoNetworkSettings) throws -> String,
        onTestNetworkSettings: @escaping (DemoNetworkSettings) async throws -> String,
        onRunDiagnostics: @escaping (DemoNetworkSettings) async -> SettingsDiagnosticsReport,
        onMonitorHeliosCheckpoint: @escaping (DemoNetworkSettings) async throws -> SettingsHeliosCheckpointResult,
        onRefreshRelayer: @escaping () -> Void,
        onRotateRelayer: @escaping () async throws -> String,
        onExportRelayerKey: @escaping () async throws -> String,
        onResetWallet: @escaping () async throws -> String,
        onEnableSessionKeys: @escaping () async throws -> String,
        onRevokeSessionKeys: @escaping () async throws -> String,
        onUpdateSessionPolicy: @escaping (SessionPolicyConfig) throws -> String,
        onCopyDebugReport: @escaping () async -> String,
        onClearDebugLog: @escaping () -> Void,
        onSetSwapSlippageBps: @escaping (UInt64) -> Void,
        onSetContextWindowTokens: @escaping (Int) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self._installs = ObservedObject(wrappedValue: installs)
        self._thinkingEnabled = thinkingEnabled
        self.initialTab = initialTab
        self.onExportRankings = onExportRankings
        self.onExportDatabase = onExportDatabase
        self.onRevealDatabase = onRevealDatabase
        self.onClearChatHistory = onClearChatHistory
        self.onClearRankings = onClearRankings
        self.onRevealModelFile = onRevealModelFile
        self.onSelectModel = onSelectModel
        self.onStartModelInstall = onStartModelInstall
        self.onRemoveModel = onRemoveModel
        self.onResolveRepo = onResolveRepo
        self.onInspectRemoteFile = onInspectRemoteFile
        self.onStartCuratedModelInstall = onStartCuratedModelInstall
        self.onCancelModelDownload = onCancelModelDownload
        self.onSaveNetworkSettings = onSaveNetworkSettings
        self.onTestNetworkSettings = onTestNetworkSettings
        self.onRunDiagnostics = onRunDiagnostics
        self.onMonitorHeliosCheckpoint = onMonitorHeliosCheckpoint
        self.onRefreshRelayer = onRefreshRelayer
        self.onRotateRelayer = onRotateRelayer
        self.onExportRelayerKey = onExportRelayerKey
        self.onResetWallet = onResetWallet
        self.onEnableSessionKeys = onEnableSessionKeys
        self.onRevokeSessionKeys = onRevokeSessionKeys
        self.onUpdateSessionPolicy = onUpdateSessionPolicy
        self.onCopyDebugReport = onCopyDebugReport
        self.onClearDebugLog = onClearDebugLog
        self.onSetSwapSlippageBps = onSetSwapSlippageBps
        self.onSetContextWindowTokens = onSetContextWindowTokens
        self.onClose = onClose
        self._networkDraft = State(initialValue: snapshot.networkSettings)
        self._sessionPolicyDraft = State(initialValue: SessionPolicyDraft(
            policy: snapshot.session.configuredPolicy,
            chainID: Self.chainID(from: snapshot.chainID)
        ))
        self._slippageBpsDraft = State(initialValue: snapshot.swapSlippageBps)
        self._slippagePercentField = State(initialValue: Self.formatSlippagePercent(SwapSlippage.percent(fromBps: snapshot.swapSlippageBps)))
        self._contextWindowDraft = State(initialValue: snapshot.contextWindowTokens)
        self._selectedTab = State(initialValue: initialTab)
        self._appliedNetworkSettings = State(initialValue: snapshot.networkSettings)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(SettingsPalette.border.opacity(0.65))
                .frame(width: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsPalette.background)
        .task {
            guard hardwareProfile == nil else {
                return
            }
            hardwareProfile = await LocalHardwareInspector().inspect()
        }
        .onChange(of: snapshot.session.configuredPolicy) { _, newValue in
            sessionPolicyDraft = SessionPolicyDraft(
                policy: newValue,
                chainID: Self.chainID(from: snapshot.chainID)
            )
        }
        .onChange(of: snapshot.swapSlippageBps) { _, newValue in
            slippageBpsDraft = newValue
            slippagePercentField = Self.formatSlippagePercent(SwapSlippage.percent(fromBps: newValue))
        }
        .onChange(of: snapshot.contextWindowTokens) { _, newValue in
            contextWindowDraft = newValue
        }
        .alert(item: $pendingConfirmation) { confirmation in
            Alert(
                title: Text(confirmation.title),
                message: Text(confirmation.message),
                primaryButton: .destructive(Text(confirmation.confirmTitle)) {
                    runConfirmedAction(confirmation)
                },
                secondaryButton: .cancel()
            )
        }
        .sheet(isPresented: $showingSessionTokenLimits) {
            SessionTokenLimitsSheet(limits: $sessionPolicyDraft.erc20TokenLimits)
        }
    }

    private var sessionDurationSelection: Binding<Int> {
        Binding(
            get: {
                Int(sessionPolicyDraft.ttlSeconds) ?? SessionPolicyConfig.defaultTTLSeconds
            },
            set: { newValue in
                sessionPolicyDraft.ttlSeconds = "\(newValue)"
                if let inactivity = Int(sessionPolicyDraft.inactivityTimeoutSeconds),
                   inactivity > newValue {
                    sessionPolicyDraft.inactivityTimeoutSeconds = "\(newValue)"
                }
            }
        )
    }

    private var sessionIdleSelection: Binding<Int> {
        Binding(
            get: {
                Int(sessionPolicyDraft.inactivityTimeoutSeconds)
                    ?? SessionPolicyConfig.defaultInactivityTimeoutSeconds
            },
            set: { sessionPolicyDraft.inactivityTimeoutSeconds = "\($0)" }
        )
    }

    private var rateLimitCountSelection: Binding<Int> {
        Binding(
            get: {
                Int(sessionPolicyDraft.rateLimitCount) ?? SessionPolicyConfig.default.rateLimitCount
            },
            set: { sessionPolicyDraft.rateLimitCount = "\($0)" }
        )
    }

    private var rateLimitWindowSelection: Binding<Int> {
        Binding(
            get: {
                Int(sessionPolicyDraft.rateLimitIntervalSec)
                    ?? SessionPolicyConfig.default.rateLimitIntervalSec
            },
            set: { sessionPolicyDraft.rateLimitIntervalSec = "\($0)" }
        )
    }

    // Friendly preset choices for the session-key timing/budget pickers. The
    // policy itself stays second-based; these only drive the menus. Any saved
    // value that isn't a standard preset is preserved as its own option, so
    // opening an existing policy never silently rewrites it.
    private var sessionDurationOptions: [Int] {
        Self.menuOptions(SessionPolicyConfig.allowedTTLSeconds, current: Int(sessionPolicyDraft.ttlSeconds))
    }

    private var idleLockOptions: [Int] {
        Self.menuOptions(
            [600, 1_800, 3_600, 7_200, 14_400],
            current: Int(sessionPolicyDraft.inactivityTimeoutSeconds),
            cappedAt: Int(sessionPolicyDraft.ttlSeconds)
        )
    }

    private var rateLimitCountOptions: [Int] {
        Self.menuOptions([5, 10, 20, 50, 100], current: Int(sessionPolicyDraft.rateLimitCount))
    }

    private var rateLimitWindowOptions: [Int] {
        Self.menuOptions([3_600, 21_600, 43_200, 86_400], current: Int(sessionPolicyDraft.rateLimitIntervalSec))
    }

    private static func menuOptions(_ presets: [Int], current: Int?, cappedAt cap: Int? = nil) -> [Int] {
        var options = presets
        if let cap {
            options = options.filter { $0 <= cap }
        }
        if let current, !options.contains(current) {
            options.append(current)
        }
        return options.sorted()
    }

    private static func chainID(from value: String) -> UInt64 {
        UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 11_155_111
    }

    private static func friendlyDurationLabel(seconds: Int) -> String {
        if seconds % 86_400 == 0 {
            let days = seconds / 86_400
            return "\(days) \(days == 1 ? "day" : "days")"
        }
        if seconds % 3_600 == 0 {
            let hours = seconds / 3_600
            return "\(hours) \(hours == 1 ? "hour" : "hours")"
        }
        if seconds % 60 == 0 {
            let minutes = seconds / 60
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        }
        return "\(seconds) seconds"
    }

    private static func ethLabel(wei: String) -> String {
        let trimmed = wei.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let weiValue = Decimal(string: trimmed) else {
            return trimmed.isEmpty ? "Not set" : "\(trimmed) wei"
        }
        let ethValue = weiValue / Decimal(1_000_000_000) / Decimal(1_000_000_000)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        return "\(formatter.string(from: ethValue as NSDecimalNumber) ?? "\(ethValue)") ETH"
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(SettingsPalette.primaryText)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(SettingsPalette.control))
                }
                .buttonStyle(.plain)
                .disabled(isSessionTransactionInProgress)
                .opacity(isSessionTransactionInProgress ? 0.45 : 1)
                .help("Back to chat")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(SettingsPalette.primaryText)
                    Text(snapshot.chainName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SettingsPalette.secondaryText)
                }
            }
            .padding(.top, 24)
            .padding(.horizontal, 18)

            VStack(spacing: 7) {
                ForEach(LocalWalletSettingsTab.allCases) { tab in
                    settingsTabButton(tab)
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text("Version \(snapshot.appVersion)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SettingsPalette.secondaryText)
                Text("Build \(snapshot.appBuild)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SettingsPalette.mutedText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 22)
        }
        .frame(width: 245)
        .background(SettingsPalette.sidebar)
    }

    private func settingsTabButton(_ tab: LocalWalletSettingsTab) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 14, weight: .black))
                    .frame(width: 18)
                Text(tab.title)
                    .font(.system(size: 14, weight: .bold))
                Spacer()
            }
            .foregroundStyle(selectedTab == tab ? SettingsPalette.primaryText : SettingsPalette.secondaryText)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectedTab == tab ? SettingsPalette.selected : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(isSessionTransactionInProgress)
        .opacity(isSessionTransactionInProgress && selectedTab != tab ? 0.45 : 1)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedTab.title)
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundStyle(SettingsPalette.primaryText)
                    Text(selectedTab.subtitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsPalette.secondaryText)
                }
                Spacer()
            }
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 18)

            ScrollView {
                Group {
                    switch selectedTab {
                    case .info:
                        infoTab
                    case .models:
                        modelsTab
                    case .network:
                        networkTab
                    case .transactions:
                        transactionsTab
                    case .diagnostics:
                        diagnosticsTab
                    case .data:
                        dataTab
                    case .wallet:
                        walletTab
                    case .sessionKeys:
                        sessionKeysTab
                    case .security:
                        securityTab
                    case .about:
                        aboutTab
                    case .advanced:
                        advancedTab
                    }
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
            }
            if selectedTab == .sessionKeys {
                sessionKeysFooter
            }
        }
    }

    private var infoTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "System") {
                SettingsInfoGrid {
                    SettingsInfoItem(
                        title: "Hardware",
                        value: hardwareProfile?.displayName ?? "Inspecting...",
                        systemImage: "desktopcomputer",
                        tint: SettingsPalette.cyan
                    )
                    SettingsInfoItem(
                        title: "Model memory",
                        value: hardwareMemoryStatus,
                        systemImage: "memorychip.fill",
                        tint: SettingsPalette.green
                    )
                    SettingsInfoItem(
                        title: "macOS",
                        value: ProcessInfo.processInfo.operatingSystemVersionString,
                        systemImage: "apple.logo",
                        tint: SettingsPalette.secondaryText
                    )
                    SettingsInfoItem(
                        title: "App",
                        value: "\(snapshot.appVersion) (\(snapshot.appBuild))",
                        systemImage: "app.badge.fill",
                        tint: SettingsPalette.blue
                    )
                }
            }

            SettingsSection(title: "Models") {
                SettingsInfoGrid {
                    SettingsInfoItem(
                        title: "Text model",
                        value: snapshot.textModelName,
                        detail: snapshot.textModelRuntimeStatus,
                        systemImage: "text.bubble.fill",
                        tint: SettingsPalette.green
                    )
                    SettingsInfoItem(
                        title: "Text artifact",
                        value: snapshot.textModelSize,
                        detail: snapshot.textModelInstallStatus,
                        systemImage: "externaldrive.fill",
                        tint: SettingsPalette.cyan
                    )
                    SettingsInfoItem(
                        title: "Multimodal model",
                        value: snapshot.multimodalModelName,
                        detail: snapshot.multimodalModelStatus,
                        systemImage: "photo.on.rectangle.angled",
                        tint: SettingsPalette.orange
                    )
                    SettingsInfoItem(
                        title: "Context window",
                        value: snapshot.contextWindow,
                        systemImage: "rectangle.expand.vertical",
                        tint: SettingsPalette.blue
                    )
                }
            }

            SettingsSection(title: "Wallet") {
                SettingsKeyValueRows(rows: [
                    SettingsKeyValue(title: "Chain", value: "\(snapshot.chainName) · \(snapshot.chainID)"),
                    SettingsKeyValue(title: "Smart account", value: snapshot.kernelAccountAddress),
                    SettingsKeyValue(title: "Account state", value: "\(snapshot.kernelAccountState) · \(snapshot.kernelAccountBalance)"),
                    SettingsKeyValue(title: "Relayer", value: snapshot.relayerAddress),
                    SettingsKeyValue(title: "Relayer state", value: "\(snapshot.relayerState) · \(snapshot.relayerBalance)"),
                ])
            }

            SettingsSection(title: "Storage") {
                SettingsKeyValueRows(rows: [
                    SettingsKeyValue(title: "Database", value: snapshot.databasePath),
                    SettingsKeyValue(title: "Database size", value: snapshot.databaseSize),
                    SettingsKeyValue(title: "wallet-node config", value: snapshot.walletNodeConfigPath),
                ])
            }
        }
    }

    private var modelsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let hardware = snapshot.hardwareSummary {
                SettingsSection(title: "This Mac") {
                    SettingsKeyValueRows(rows: [
                        SettingsKeyValue(title: "Memory", value: hardware.memoryText),
                        SettingsKeyValue(title: "Model budget", value: hardware.budgetText),
                        SettingsKeyValue(title: "Free disk", value: hardware.diskText),
                    ])
                }
            }

            SettingsSection(title: "Text Model") {
                ForEach(snapshot.modelRows) { row in
                    HStack(spacing: 12) {
                        modelStateIcon(row)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.displayName)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(SettingsPalette.primaryText)
                            Text(modelRowDetail(row))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(SettingsPalette.secondaryText)
                        }
                        Spacer()
                        if row.isDefault {
                            SettingsBadge(text: "Default", tint: SettingsPalette.blue)
                        }
                        SettingsBadge(text: row.verdict.label, tint: settingsVerdictTint(row.verdict))
                        if let install = installs.install, install.modelID == row.id {
                            installProgressLabel(install.phase)
                            if case .downloading = install.phase {
                                Button("Cancel") { onCancelModelDownload() }
                                    .buttonStyle(SettingsSecondaryButtonStyle())
                            }
                        } else {
                            // Precedence lives on the row (`primaryControl`), not in
                            // this chain, so it can be asserted without a view.
                            switch row.primaryControl {
                            case .download:
                                Button("Download") { install(row.id) }
                                    .buttonStyle(SettingsSecondaryButtonStyle())
                                    .disabled(installs.install != nil)
                            case .inUse:
                                SettingsBadge(text: "In use", tint: SettingsPalette.blue)
                            case .use:
                                Button("Use") { runModelAction { try onSelectModel(row.id) } }
                                    .buttonStyle(SettingsPrimaryButtonStyle())
                            case .none:
                                EmptyView()
                            }
                        }
                        if row.isRemovable {
                            Button("Remove") { runModelAction { try onRemoveModel(row.id) } }
                                .buttonStyle(SettingsSecondaryButtonStyle())
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(SettingsPalette.rowBackground))
                    // The whole row selects an installed model, so the state dot is a
                    // real target rather than decoration that looks clickable.
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard row.isInstalled, !row.isActive else { return }
                        runModelAction { try onSelectModel(row.id) }
                    }
                }
                // The outcome outranks `modelMessage`, and every local action clears
                // it, so the banner always shows the newest of the two. The other
                // order swallowed the install result whenever a stale "Revealed…"
                // or "Switched to…" was still on screen — including checksum and
                // disk failures, which then had nowhere at all to appear.
                if let outcome = installOutcomeMessage {
                    SettingsMessageBanner(message: outcome, onDismiss: { installs.clearOutcome() })
                } else if let banner = modelMessage {
                    SettingsMessageBanner(message: banner)
                }
            }

            SettingsSection(title: "Context Window") {
                Picker("", selection: Binding(
                    get: { contextWindowDraft },
                    set: { newValue in
                        contextWindowDraft = newValue
                        onSetContextWindowTokens(newValue)
                        showModelMessage(SettingsMessage(
                            kind: .success,
                            text: "Context window set to \(newValue) tokens. Applies to the next message."
                        ))
                    }
                )) {
                    ForEach(snapshot.selectableContextTokens, id: \.self) { tokens in
                        Text("\(tokens) tokens").tag(tokens)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
                Text("Active: \(snapshot.contextWindow). Larger windows use more memory. The verdicts above are computed at this size. Sizes this Mac cannot hold are not listed.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsPalette.secondaryText)
                Divider().overlay(SettingsPalette.border).padding(.vertical, 4)
                HStack(spacing: 12) {
                    Toggle("Show thinking", isOn: $thinkingEnabled)
                        .toggleStyle(.switch)
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Button {
                        do {
                            showModelMessage(SettingsMessage(kind: .success, text: try onRevealModelFile()))
                        } catch {
                            showModelMessage(SettingsMessage(kind: .error, text: error.localizedDescription))
                        }
                    } label: {
                        Label("Reveal model file", systemImage: "folder")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                }
            }

            SettingsSection(title: "Add From Hugging Face") {
                AddHuggingFaceModelForm(
                    install: huggingFaceInstall,
                    blockedByInstallOf: blockingInstallName,
                    onResolveRepo: onResolveRepo,
                    onInspectRemoteFile: onInspectRemoteFile,
                    onStartModelInstall: onStartModelInstall,
                    onCancelModelDownload: onCancelModelDownload
                )
            }

            SettingsSection(title: "Multimodal Runtime") {
                SettingsKeyValueRows(rows: [
                    SettingsKeyValue(title: "Selected", value: snapshot.multimodalModelName),
                    SettingsKeyValue(title: "Status", value: snapshot.multimodalModelStatus),
                ])
            }
        }
    }

    /// The last install's result, as a banner. Comes from the install store, so a
    /// download that finished while the user was on another tab still reports
    /// itself.
    private var installOutcomeMessage: SettingsMessage? {
        guard let outcome = installs.outcome else { return nil }
        return SettingsMessage(kind: outcome.isFailure ? .error : .success, text: outcome.text)
    }

    /// The install this form is responsible for drawing: one that no model row has
    /// claimed. A curated download is rendered by its own row, and a Hugging Face
    /// model gets a row only once `InstalledModelStore` has a record — which is
    /// exactly when it stops being this form's business.
    private var huggingFaceInstall: ModelInstallProgress? {
        guard let install = installs.install else { return nil }
        return install.isClaimedByRow(ids: snapshot.modelRows.map(\.id)) ? nil : install
    }

    /// Set when something *else* holds the one install slot, so a disabled
    /// "Download & add" says why instead of just looking broken.
    private var blockingInstallName: String? {
        guard huggingFaceInstall == nil else { return nil }
        return installs.install?.displayName
    }

    /// Runs a model action (select/remove) and surfaces the specific outcome
    /// `AppModel` reports — never a generic "Done." — or the thrown error's
    /// `localizedDescription` on failure.
    private func runModelAction(_ action: () throws -> String) {
        do {
            showModelMessage(SettingsMessage(kind: .success, text: try action()))
        } catch {
            showModelMessage(SettingsMessage(kind: .error, text: error.localizedDescription))
        }
    }

    /// Every locally produced model message goes through here, so it replaces the
    /// previous install outcome rather than being ranked against it. Without the
    /// clear, whichever of the two the banner preferred could hide the other
    /// indefinitely.
    private func showModelMessage(_ message: SettingsMessage) {
        installs.clearOutcome()
        modelMessage = message
    }

    /// The leading glyph states what the row *is*, and is never a control that
    /// silently does nothing. An empty radio next to a model you have not
    /// downloaded reads as "click to select" and cannot be — so a model that is not
    /// on disk gets a download glyph instead, and only rows that can actually be
    /// selected get the radio.
    @ViewBuilder
    private func modelStateIcon(_ row: SettingsModelRow) -> some View {
        if row.isActive {
            Image(systemName: "largecircle.fill.circle").foregroundStyle(SettingsPalette.blue)
        } else if row.isInstalled {
            Image(systemName: "circle").foregroundStyle(SettingsPalette.secondaryText)
        } else {
            Image(systemName: "arrow.down.circle").foregroundStyle(SettingsPalette.mutedText)
        }
    }

    /// Says out loud whether the file is on disk. Without it, "5.03 GB · 6.48 GB in
    /// memory" reads identically for a model you have and one you do not.
    private func modelRowDetail(_ row: SettingsModelRow) -> String {
        let base = "\(row.detail) · \(row.estimatedText) in memory"
        return row.isInstalled ? base : "\(base) · not downloaded"
    }

    /// Multi-gigabyte download followed by a real load test, so the row says which
    /// of the two it is doing rather than showing one bar that stalls at 100%.
    @ViewBuilder
    private func installProgressLabel(_ phase: ModelInstallPhase) -> some View {
        switch phase {
        case .downloading(let progress):
            ProgressView(value: progress.fractionCompleted).frame(width: 120)
            Text(progress.statusText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(SettingsPalette.secondaryText)
        case .testing:
            ProgressView().controlSize(.small)
            Text("Testing")
                .font(.system(size: 11))
                .foregroundStyle(SettingsPalette.secondaryText)
        }
    }

    /// Hands the install to the chat model and returns immediately. Nothing about
    /// it is stored here: this view is torn down whenever the user leaves the tab,
    /// and a multi-gigabyte download must not be reduced to invisible-and-uncancellable
    /// by that.
    private func install(_ id: String) {
        modelMessage = nil
        installs.clearOutcome()
        onStartCuratedModelInstall(id)
    }

    private var networkTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Active Network") {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsKeyValueRows(rows: [
                        SettingsKeyValue(title: "Network", value: "Sepolia"),
                    ])

                    SettingsEditableField(
                        title: "Execution RPC",
                        placeholder: DemoNetworkSettings.defaults.sepoliaRPCURL,
                        text: $networkDraft.sepoliaRPCURL
                    )
                    SettingsEditableField(
                        title: "Archive node",
                        placeholder: "Optional",
                        detail: "Optional Helios endpoint for historical state reads. Helios is the light-client layer wallet-node uses to verify Ethereum reads without trusting a plain RPC response blindly.",
                        text: $networkDraft.sepoliaArchiveNodeURL
                    )
                    SettingsEditableField(
                        title: "Consensus RPC",
                        placeholder: ChainConfiguration.ethereumSepolia.consensusRPCURL?.absoluteString ?? "",
                        detail: "Optional for Helios verification. Leave blank to use execution RPC reads.",
                        text: $networkDraft.sepoliaConsensusRPCURL
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $networkDraft.heliosVerificationEnabled) {
                            Text("Verify reads with Helios")
                                .font(.system(size: 13, weight: .bold))
                        }
                        Text(
                            networkDraft.isHeliosVerificationActive
                                ? "Read calls use Helios with the configured consensus RPC."
                                : "Read calls use the execution RPC directly."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $networkDraft.autoGasModeEnabled) {
                            Text("Automatic gas pricing")
                                .font(.system(size: 13, weight: .bold))
                        }
                        Text("When on, the wallet follows live Sepolia gas at the selected tier and the caps below are ignored.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if networkDraft.autoGasModeEnabled {
                            Picker("Speed tier", selection: $networkDraft.autoGasTier) {
                                ForEach(GasTier.allCases, id: \.self) { tier in
                                    Text(tier.label).tag(tier)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 280)
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        SettingsEditableField(
                            title: "Max fee cap (gwei)",
                            placeholder: DemoNetworkSettings.defaults.sepoliaMaxFeePerGasGwei,
                            detail: "Upper bound wallet-node accepts for chain gas price. Sepolia default is 50 gwei.",
                            text: $networkDraft.sepoliaMaxFeePerGasGwei
                        )
                        SettingsEditableField(
                            title: "Priority fee cap (gwei)",
                            placeholder: DemoNetworkSettings.defaults.sepoliaMaxPriorityFeePerGasGwei,
                            detail: "Tip cap for submitted raw transactions. Must be less than or equal to max fee cap.",
                            text: $networkDraft.sepoliaMaxPriorityFeePerGasGwei
                        )
                    }
                    .disabled(networkDraft.autoGasModeEnabled)
                    .opacity(networkDraft.autoGasModeEnabled ? 0.45 : 1)

                    if let networkMessage {
                        SettingsMessageBanner(message: networkMessage)
                    }
                    if isMonitoringHeliosCheckpoint {
                        SettingsTransactionProgressBanner(
                            title: "Resyncing Helios checkpoint",
                            detail: heliosCheckpointProgressDetail
                        )
                    } else if let heliosCheckpointMessage {
                        SettingsMessageBanner(message: heliosCheckpointMessage)
                    }

                    HStack(spacing: 10) {
                        Button {
                            testNetworkDraft()
                        } label: {
                            Label(isTestingNetwork ? "Testing..." : "Test RPC", systemImage: "checkmark.seal")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .disabled(isTestingNetwork)

                        Button {
                            saveNetworkDraft()
                        } label: {
                            Label("Save network", systemImage: "square.and.arrow.down")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .buttonStyle(SettingsPrimaryButtonStyle())

                        Button {
                            networkDraft = networkDraft.resettingActiveNetworkToDefaults()
                            networkMessage = SettingsMessage(
                                kind: .info,
                                text: "Restored default \(networkDraft.activeNetworkName) endpoints. Save to apply them."
                            )
                        } label: {
                            Label("Reset defaults", systemImage: "arrow.counterclockwise")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())

                        Spacer()
                    }
                    .padding(.top, 2)
                }
            }

            SettingsSection(title: "Current Runtime") {
                SettingsKeyValueRows(rows: [
                    SettingsKeyValue(title: "Runtime network", value: snapshot.chainName),
                    SettingsKeyValue(title: "Chain ID", value: snapshot.chainID),
                    SettingsKeyValue(title: "Execution RPC", value: snapshot.executionRPCURL),
                    SettingsKeyValue(title: "Helios archive node", value: snapshot.archiveNodeURL),
                    SettingsKeyValue(title: "Consensus RPC", value: snapshot.consensusRPCURL),
                    SettingsKeyValue(
                        title: "Read verification",
                        value: snapshot.networkSettings.isHeliosVerificationActive ? "Helios" : "Execution RPC"
                    ),
                    SettingsKeyValue(title: "Max fee cap", value: snapshot.maxFeePerGasCap),
                    SettingsKeyValue(title: "Priority fee cap", value: snapshot.maxPriorityFeePerGasCap),
                    SettingsKeyValue(title: "EntryPoint", value: snapshot.entryPointAddress),
                ])
            }

            SettingsSection(title: "Kernel Contracts") {
                SettingsKeyValueRows(rows: [
                    SettingsKeyValue(title: "Factory", value: snapshot.kernelFactoryAddress),
                    SettingsKeyValue(title: "Implementation", value: snapshot.kernelImplementationAddress),
                    SettingsKeyValue(title: "Validator", value: snapshot.validatorAddress),
                ])
            }
        }
    }

    private func saveNetworkDraft() {
        do {
            let validated = try networkDraft.validated()
            let shouldMonitorHelios = NetworkSettingsChangePolicy.requiresHeliosCheckpointResync(
                from: appliedNetworkSettings,
                to: validated
            )
            let message = try onSaveNetworkSettings(validated)
            networkDraft = validated
            appliedNetworkSettings = validated
            networkMessage = SettingsMessage(kind: .success, text: message)
            if shouldMonitorHelios {
                startHeliosCheckpointMonitor(for: validated)
            } else if !isMonitoringHeliosCheckpoint {
                heliosCheckpointMessage = nil
            }
        } catch {
            networkMessage = SettingsMessage(kind: .error, text: error.localizedDescription)
        }
    }

    private func startHeliosCheckpointMonitor(for settings: DemoNetworkSettings) {
        let runID = UUID()
        heliosCheckpointRunID = runID
        isMonitoringHeliosCheckpoint = true
        heliosCheckpointProgressDetail = "wallet-node is restarting with \(settings.activeNetworkName) consensus RPC and fetching a fresh finalized checkpoint."
        heliosCheckpointMessage = nil

        Task {
            do {
                let result = try await onMonitorHeliosCheckpoint(settings)
                await MainActor.run {
                    guard heliosCheckpointRunID == runID else {
                        return
                    }
                    isMonitoringHeliosCheckpoint = false
                    heliosCheckpointProgressDetail = ""
                    heliosCheckpointMessage = SettingsMessage(kind: .success, text: result.successMessage)
                }
            } catch {
                await MainActor.run {
                    guard heliosCheckpointRunID == runID else {
                        return
                    }
                    isMonitoringHeliosCheckpoint = false
                    heliosCheckpointProgressDetail = ""
                    heliosCheckpointMessage = SettingsMessage(
                        kind: .error,
                        text: "Helios checkpoint resync did not finish: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func testNetworkDraft() {
        guard !isTestingNetwork else {
            return
        }
        isTestingNetwork = true
        networkMessage = SettingsMessage(kind: .info, text: "Checking \(networkDraft.activeNetworkName) RPC...")
        Task {
            do {
                let message = try await onTestNetworkSettings(networkDraft)
                await MainActor.run {
                    networkMessage = SettingsMessage(kind: .success, text: message)
                    isTestingNetwork = false
                }
            } catch {
                await MainActor.run {
                    networkMessage = SettingsMessage(kind: .error, text: error.localizedDescription)
                    isTestingNetwork = false
                }
            }
        }
    }

    private var diagnosticsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Health Checks") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Button {
                            runDiagnostics()
                        } label: {
                            Label(isRunningDiagnostics ? "Running..." : "Run diagnostics", systemImage: "stethoscope")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .buttonStyle(SettingsPrimaryButtonStyle())
                        .disabled(isRunningDiagnostics)

                        if let diagnosticsReport {
                            Text("Last checked \(Self.dateFormatter.string(from: diagnosticsReport.generatedAt))")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(SettingsPalette.secondaryText)
                        }
                        Spacer()
                    }

                    if let diagnosticsMessage {
                        SettingsMessageBanner(message: diagnosticsMessage)
                    }

                    if let diagnosticsReport {
                        VStack(spacing: 0) {
                            ForEach(diagnosticsReport.checks) { check in
                                SettingsHealthRow(check: check)
                                if check.id != diagnosticsReport.checks.last?.id {
                                    Divider().overlay(SettingsPalette.border.opacity(0.55))
                                }
                            }
                        }
                    } else {
                        SettingsMessageBanner(
                            message: SettingsMessage(
                                kind: .info,
                                text: "Run diagnostics to check execution RPC, Helios archive endpoint, consensus RPC, wallet-node status, chain ID, latest block, latency, and current relayer state."
                            )
                        )
                    }
                }
            }

            SettingsSection(title: "Runtime Snapshot") {
                SettingsKeyValueRows(rows: [
                    SettingsKeyValue(title: "Execution RPC", value: snapshot.executionRPCURL),
                    SettingsKeyValue(title: "Helios archive node", value: snapshot.archiveNodeURL),
                    SettingsKeyValue(title: "Consensus RPC", value: snapshot.consensusRPCURL),
                    SettingsKeyValue(
                        title: "Read verification",
                        value: snapshot.networkSettings.isHeliosVerificationActive ? "Helios" : "Execution RPC"
                    ),
                    SettingsKeyValue(title: "wallet-node", value: snapshot.walletNodeMode),
                    SettingsKeyValue(title: "Relayer message", value: snapshot.relayerMessage),
                    SettingsKeyValue(title: "Bridge status", value: snapshot.bridgeStatus),
                    SettingsKeyValue(title: "Last error", value: snapshot.lastError),
                ])
            }
        }
    }

    private func runDiagnostics() {
        guard !isRunningDiagnostics else {
            return
        }
        isRunningDiagnostics = true
        diagnosticsMessage = SettingsMessage(kind: .info, text: "Running network and wallet-node checks...")
        Task {
            let report = await onRunDiagnostics(networkDraft)
            await MainActor.run {
                diagnosticsReport = report
                diagnosticsMessage = SettingsMessage(kind: .success, text: "Diagnostics completed.")
                isRunningDiagnostics = false
            }
        }
    }

    private var dataTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Exports") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsInfoGrid {
                        SettingsInfoItem(
                            title: "Conversations",
                            value: "\(snapshot.conversationCount)",
                            detail: "\(snapshot.messageCount) messages",
                            systemImage: "bubble.left.and.bubble.right.fill",
                            tint: SettingsPalette.blue
                        )
                        SettingsInfoItem(
                            title: "Rankings",
                            value: "\(snapshot.rankingCount)",
                            detail: "Tool feedback records",
                            systemImage: "hand.thumbsup.fill",
                            tint: SettingsPalette.green
                        )
                        SettingsInfoItem(
                            title: "Database",
                            value: snapshot.databaseSize,
                            detail: snapshot.databasePath,
                            systemImage: "cylinder.split.1x2.fill",
                            tint: SettingsPalette.cyan
                        )
                    }
                    HStack(spacing: 12) {
                        Button {
                            do {
                                dataMessage = SettingsMessage(kind: .success, text: try onExportDatabase())
                            } catch {
                                dataMessage = SettingsMessage(kind: .error, text: error.localizedDescription)
                            }
                        } label: {
                            Label("Export chat DB", systemImage: "square.and.arrow.down")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .buttonStyle(SettingsPrimaryButtonStyle())

                        Button(action: onExportRankings) {
                            Label("Export rankings", systemImage: "tray.and.arrow.down")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())

                        Button(action: onRevealDatabase) {
                            Label("Reveal DB", systemImage: "folder")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        Spacer()
                    }
                    if let dataMessage {
                        SettingsMessageBanner(message: dataMessage)
                    }
                }
            }

            SettingsSection(title: "Database") {
                SettingsKeyValueRows(rows: [
                    SettingsKeyValue(title: "Path", value: snapshot.databasePath),
                    SettingsKeyValue(title: "Size", value: snapshot.databaseSize),
                    SettingsKeyValue(title: "Conversations", value: "\(snapshot.conversationCount)"),
                    SettingsKeyValue(title: "Messages", value: "\(snapshot.messageCount)"),
                    SettingsKeyValue(title: "Rankings", value: "\(snapshot.rankingCount)"),
                ])
            }

            SettingsSection(title: "Danger Zone") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("These actions only affect local app data on this Mac. They do not submit onchain transactions.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SettingsPalette.secondaryText)
                    HStack(spacing: 12) {
                        Button {
                            pendingConfirmation = .clearRankings
                        } label: {
                            Label("Clear rankings", systemImage: "trash")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .buttonStyle(SettingsDestructiveButtonStyle())

                        Button {
                            pendingConfirmation = .clearChatHistory
                        } label: {
                            Label("Clear chat history", systemImage: "trash.fill")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .buttonStyle(SettingsDestructiveButtonStyle())
                        Spacer()
                    }
                }
            }
        }
    }

    private var walletTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Wallet Overview") {
                SettingsInfoGrid {
                    SettingsInfoItem(
                        title: "Smart account",
                        value: snapshot.kernelAccountState,
                        detail: "\(snapshot.kernelAccountBalance) on \(snapshot.chainName)",
                        systemImage: "lock.shield.fill",
                        tint: SettingsPalette.blue
                    )
                    SettingsInfoItem(
                        title: "Gas relayer",
                        value: snapshot.relayerState,
                        detail: "\(snapshot.relayerBalance) available",
                        systemImage: "fuelpump.fill",
                        tint: snapshot.relayerNeedsGas ? SettingsPalette.orange : SettingsPalette.green
                    )
                }
            }

            SettingsSection(title: "Smart Account") {
                SettingsInfoGrid {
                    SettingsInfoItem(
                        title: "Address",
                        value: snapshot.kernelAccountAddress,
                        detail: snapshot.kernelAccountState,
                        systemImage: "lock.shield.fill",
                        tint: SettingsPalette.blue
                    )
                    SettingsInfoItem(
                        title: "Balance",
                        value: snapshot.kernelAccountBalance,
                        detail: snapshot.chainName,
                        systemImage: "creditcard.fill",
                        tint: SettingsPalette.green
                    )
                }
                Divider().overlay(SettingsPalette.border).padding(.vertical, 4)
                SettingsKeyValueRows(rows: [
                    SettingsKeyValue(title: "Address", value: snapshot.kernelAccountAddress),
                    SettingsKeyValue(title: "State", value: snapshot.kernelAccountState),
                    SettingsKeyValue(title: "Balance", value: snapshot.kernelAccountBalance),
                    SettingsKeyValue(title: "Chain", value: "\(snapshot.chainName) · \(snapshot.chainID)"),
                    SettingsKeyValue(title: "EntryPoint", value: snapshot.entryPointAddress),
                ])
            }
            SettingsSection(title: "Local Relayer") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsInfoGrid {
                        SettingsInfoItem(
                            title: "Address",
                            value: snapshot.relayerAddress,
                            detail: snapshot.relayerState,
                            systemImage: "key.fill",
                            tint: SettingsPalette.cyan
                        )
                        SettingsInfoItem(
                            title: "Balance",
                            value: snapshot.relayerBalance,
                            detail: snapshot.relayerLifecycle,
                            systemImage: "fuelpump.fill",
                            tint: snapshot.relayerNeedsGas ? SettingsPalette.orange : SettingsPalette.green
                        )
                        SettingsInfoItem(
                            title: "Pending funding",
                            value: "\(snapshot.relayerPendingFundingCount)",
                            detail: snapshot.relayerPendingFundingAddress,
                            systemImage: "clock.badge.exclamationmark.fill",
                            tint: snapshot.relayerPendingFundingCount > 0 ? SettingsPalette.orange : SettingsPalette.secondaryText
                        )
                    }
                    SettingsKeyValueRows(rows: [
                        SettingsKeyValue(title: "Key ref", value: snapshot.relayerKeyRef),
                        SettingsKeyValue(title: "Lifecycle", value: snapshot.relayerLifecycle),
                        SettingsKeyValue(title: "Retiring keys", value: "\(snapshot.relayerRetiringCount)"),
                        SettingsKeyValue(title: "Latest audit event", value: snapshot.relayerLatestAuditEvent),
                        SettingsKeyValue(title: "Mode", value: snapshot.walletNodeMode),
                        SettingsKeyValue(title: "Message", value: snapshot.relayerMessage),
                    ])
                    HStack(spacing: 12) {
                        Button(action: onRefreshRelayer) {
                            Label("Refresh relayer", systemImage: "arrow.clockwise")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())

                        Button {
                            copyToPasteboard(snapshot.relayerAddress)
                            walletMessage = SettingsMessage(kind: .success, text: "Relayer top-up address copied.")
                        } label: {
                            Label("Copy top-up address", systemImage: "doc.on.doc")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())

                        Button {
                            rotateRelayer()
                        } label: {
                            Label(isRotatingRelayer ? "Rotating..." : "Rotate key", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .disabled(isRotatingRelayer)
                        Spacer()
                    }
                    if let walletMessage {
                        SettingsMessageBanner(message: walletMessage)
                    }
                }
            }
        }
    }

    private var sessionKeysTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Session Key") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(SettingsPalette.cyan)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(SettingsPalette.cyan.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Session keys let the assistant sign only the wallet actions you allow.")
                                .font(.system(size: 14, weight: .heavy))
                                .foregroundStyle(SettingsPalette.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Your passkey still owns the wallet. Actions outside these caps, tokens, or time windows fall back to passkey approval.")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(SettingsPalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }

                    SettingsInfoGrid {
                        SettingsInfoItem(
                            title: "Status",
                            value: snapshot.session.statusTitle,
                            detail: snapshot.session.statusDetail,
                            systemImage: sessionStatusImage,
                            tint: sessionStatusTint
                        )
                        SettingsInfoItem(
                            title: "ETH cap",
                            value: Self.ethLabel(wei: snapshot.session.activePolicy.perTxValueLimitWei),
                            detail: snapshot.session.activePolicy.allowlist.nativeTransfers ? "Native transfers enabled" : "Native transfers off",
                            systemImage: "circle.hexagongrid.fill",
                            tint: SettingsPalette.cyan
                        )
                        SettingsInfoItem(
                            title: "ERC-20",
                            value: sessionERC20Summary,
                            detail: "Approvals only for Uniswap SwapRouter02",
                            systemImage: "seal.fill",
                            tint: SettingsPalette.blue
                        )
                        SettingsInfoItem(
                            title: "Time box",
                            value: Self.friendlyDurationLabel(seconds: snapshot.session.activePolicy.ttlSeconds),
                            detail: "Locks after \(Self.friendlyDurationLabel(seconds: snapshot.session.activePolicy.inactivityTimeoutSeconds)) idle",
                            systemImage: "timer",
                            tint: SettingsPalette.green
                        )
                    }

                    Toggle(isOn: Binding(
                        get: { snapshot.session.isEnabled },
                        set: { value in
                            if value {
                                enableSessionKeys()
                            } else {
                                pendingConfirmation = .revokeSessionKeys
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(snapshot.session.isEnabled ? "Session key enabled" : "Enable session key")
                                .font(.system(size: 13, weight: .heavy))
                            Text("Enabling creates an onchain permission. You approve once with your passkey, then the assistant can act inside the saved policy.")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(SettingsPalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .foregroundStyle(SettingsPalette.primaryText)
                    .disabled(isEnablingSessionKeys || isRevokingSessionKeys)

                    if isSessionTransactionInProgress {
                        SettingsTransactionProgressBanner(
                            title: sessionTransactionTitle,
                            detail: sessionTransactionDetail
                        )
                    }

                    SettingsKeyValueRows(rows: sessionKeyRows)
                        .opacity(isSessionTransactionInProgress ? 0.55 : 1)
                }
            }

            SettingsSection(title: "ETH") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("ETH transfers", isOn: $sessionPolicyDraft.nativeTransfers)
                        .toggleStyle(.switch)
                        .font(.system(size: 13, weight: .bold))
                    SettingsEditableField(
                        title: "Max ETH per action",
                        placeholder: "0.1",
                        detail: "Applies to native ETH transfers and ETH input sent directly to Uniswap SwapRouter02.",
                        text: $sessionPolicyDraft.nativeValueLimitETH
                    )
                }
                .disabled(isSessionTransactionInProgress)
                .opacity(isSessionTransactionInProgress ? 0.55 : 1)
            }

            SettingsSection(title: "ERC-20") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 16) {
                        Toggle("ERC-20 transfers", isOn: $sessionPolicyDraft.erc20Transfers)
                            .toggleStyle(.switch)
                            .font(.system(size: 13, weight: .bold))

                        VStack(alignment: .leading, spacing: 7) {
                            Text("Approvals and swaps")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(SettingsPalette.mutedText)
                                .textCase(.uppercase)
                                .tracking(0.5)
                            Text("Fixed to Uniswap SwapRouter02. If a swap needs a token approval, the session key can only approve that router and only up to the token cap below.")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(SettingsPalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 10) {
                        Text("Token caps apply by symbol across supported chains.")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SettingsPalette.secondaryText)
                        Spacer()
                        Button {
                            setAllTokenLimitsEnabled(true)
                        } label: {
                            Label("All on", systemImage: "checkmark.circle")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        Button {
                            setAllTokenLimitsEnabled(false)
                        } label: {
                            Label("All off", systemImage: "minus.circle")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        Button {
                            resetTokenCapsToDefaults()
                        } label: {
                            Label("Reset caps", systemImage: "arrow.counterclockwise")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                    }

                    SessionTokenLimitTable(limits: $sessionPolicyDraft.erc20TokenLimits, rowLimit: 5)

                    if sessionPolicyDraft.erc20TokenLimits.count > 5 {
                        Button {
                            showingSessionTokenLimits = true
                        } label: {
                            HStack(spacing: 10) {
                                Label(
                                    "Show more tokens",
                                    systemImage: "list.bullet.rectangle"
                                )
                                .font(.system(size: 12, weight: .bold))
                                Spacer(minLength: 0)
                                Text("\(sessionPolicyDraft.erc20TokenLimits.count - 5) more")
                                    .font(.system(size: 11, weight: .heavy))
                                    .foregroundStyle(SettingsPalette.secondaryText)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                    }

                    SettingsMessageBanner(
                        message: SettingsMessage(
                            kind: .info,
                            text: "Token caps are enforced on ERC-20 transfers, swap inputs, and SwapRouter02 approvals. Existing onchain allowances are not revoked or reduced."
                        )
                    )
                }
                .disabled(isSessionTransactionInProgress)
                .opacity(isSessionTransactionInProgress ? 0.55 : 1)
            }

            SettingsSection(title: "Timing And Budget") {
                VStack(alignment: .leading, spacing: 16) {
                    SessionRuleRow(
                        title: "Session expires after",
                        detail: "When it ends, the assistant stops signing until you start a new session with your passkey."
                    ) {
                        SettingsInlineMenu(
                            selection: sessionDurationSelection,
                            options: sessionDurationOptions,
                            label: { Self.friendlyDurationLabel(seconds: $0) }
                        )
                    }

                    Divider().overlay(SettingsPalette.border.opacity(0.45))

                    SessionRuleRow(
                        title: "Lock if idle for",
                        detail: "Locks the session early after a quiet stretch. Approve with your passkey to resume."
                    ) {
                        SettingsInlineMenu(
                            selection: sessionIdleSelection,
                            options: idleLockOptions,
                            label: { Self.friendlyDurationLabel(seconds: $0) }
                        )
                    }

                    Divider().overlay(SettingsPalette.border.opacity(0.45))

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center, spacing: 8) {
                            Text("Allow up to")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(SettingsPalette.primaryText)
                            SettingsInlineMenu(
                                selection: rateLimitCountSelection,
                                options: rateLimitCountOptions,
                                label: { "\($0)" }
                            )
                            Text("actions every")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(SettingsPalette.primaryText)
                            SettingsInlineMenu(
                                selection: rateLimitWindowSelection,
                                options: rateLimitWindowOptions,
                                label: { Self.friendlyDurationLabel(seconds: $0) }
                            )
                            Spacer(minLength: 0)
                        }
                        Text("After this many actions, signing pauses until the window resets.")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SettingsPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().overlay(SettingsPalette.border.opacity(0.45))

                    SessionRuleRow(
                        title: "Gas budget for the session",
                        detail: "The most gas the assistant can spend before the session ends."
                    ) {
                        HStack(spacing: 8) {
                            TextField("0.05", text: $sessionPolicyDraft.gasBudgetETH)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(SettingsPalette.primaryText)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 78)
                                .padding(.horizontal, 12)
                                .frame(height: 38)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(SettingsPalette.row)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(SettingsPalette.border.opacity(0.72), lineWidth: 1)
                                        )
                                )
                            Text("ETH")
                                .font(.system(size: 12, weight: .heavy))
                                .foregroundStyle(SettingsPalette.mutedText)
                        }
                    }
                }
                .disabled(isSessionTransactionInProgress)
                .opacity(isSessionTransactionInProgress ? 0.55 : 1)
            }

        }
    }

    private var sessionKeysFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let sessionMessage {
                SettingsMessageBanner(message: sessionMessage)
            }
            HStack(spacing: 12) {
                Button {
                    saveSessionPolicyDraft()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                        .font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .disabled(isSessionTransactionInProgress)

                Button {
                    sessionPolicyDraft = SessionPolicyDraft(
                        policy: .default,
                        chainID: Self.chainID(from: snapshot.chainID)
                    )
                    saveSessionPolicyDraft()
                } label: {
                    Label("Use defaults", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .disabled(isSessionTransactionInProgress)

                if snapshot.session.hasRecord {
                    Button {
                        pendingConfirmation = .revokeSessionKeys
                    } label: {
                        Label(isRevokingSessionKeys ? "Ending..." : "End session key", systemImage: "xmark.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(SettingsDestructiveButtonStyle())
                    .disabled(isRevokingSessionKeys)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 12)
        .background(
            SettingsPalette.background
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(SettingsPalette.border.opacity(0.75))
                        .frame(height: 1)
                }
        )
    }

    private var securityTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Authentication") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsKeyValueRows(rows: [
                        SettingsKeyValue(title: "Wallet key", value: snapshot.walletKeyPolicy),
                        SettingsKeyValue(title: "Relayer key", value: snapshot.relayerKeyPolicy),
                    ])
                    if let securityMessage {
                        SettingsMessageBanner(message: securityMessage)
                    }
                }
            }

            SettingsSection(title: "Key Material") {
                SettingsKeyValueRows(rows: [
                    SettingsKeyValue(title: "Smart account", value: snapshot.kernelAccountAddress),
                    SettingsKeyValue(title: "Relayer address", value: snapshot.relayerAddress),
                    SettingsKeyValue(title: "Relayer key ref", value: snapshot.relayerKeyRef),
                    SettingsKeyValue(title: "Relayer lifecycle", value: snapshot.relayerLifecycle),
                ])
                Divider().overlay(SettingsPalette.border).padding(.vertical, 4)
                HStack(spacing: 12) {
                    Button {
                        exportRelayerKey()
                    } label: {
                        Label(isExportingRelayer ? "Exporting..." : "Export relayer key", systemImage: "key.viewfinder")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .disabled(isExportingRelayer)

                    Button {
                        copyToPasteboard(snapshot.relayerAddress)
                        securityMessage = SettingsMessage(kind: .success, text: "Relayer address copied.")
                    } label: {
                        Label("Copy relayer address", systemImage: "doc.on.doc")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    Spacer()
                }
            }

            SettingsSection(title: "Danger Zone") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Relayer key operations affect wallet-node submission. Resetting the wallet deletes the Secure Enclave wallet key, relayer keys, and local wallet metadata.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SettingsPalette.secondaryText)
                    HStack(spacing: 12) {
                        Button {
                            pendingConfirmation = .resetWallet
                        } label: {
                            Label(isResettingWallet ? "Resetting..." : "Reset wallet", systemImage: "xmark.octagon.fill")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .buttonStyle(SettingsDestructiveButtonStyle())
                        .disabled(isResettingWallet)
                        Spacer()
                    }
                }
            }
        }
    }

    private var transactionsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Swaps") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Slippage tolerance")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(SettingsPalette.primaryText)
                    Text("Maximum price movement allowed before a swap reverts. Applies to every new swap quote.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SettingsPalette.secondaryText)
                    HStack(spacing: 8) {
                        ForEach(SwapSlippage.presetPercents, id: \.self) { preset in
                            Button {
                                persistSlippage(SwapSlippage.bps(fromPercent: preset))
                            } label: {
                                Text(Self.formatSlippagePercent(preset))
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                        }
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        TextField("Custom %", text: $slippagePercentField)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .onSubmit { commitCustomSlippage() }
                        Button("Apply") { commitCustomSlippage() }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                        Spacer()
                    }
                    SettingsKeyValueRows(rows: [
                        SettingsKeyValue(
                            title: "Current",
                            value: "\(Self.formatSlippagePercent(SwapSlippage.percent(fromBps: slippageBpsDraft))) (\(slippageBpsDraft) bps)"
                        ),
                    ])
                    if let transactionsMessage {
                        SettingsMessageBanner(message: transactionsMessage)
                    }
                }
            }
        }
    }

    private func commitCustomSlippage() {
        let normalized = slippagePercentField
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard let percent = Double(normalized), percent > 0 else {
            transactionsMessage = SettingsMessage(kind: .error, text: "Enter a percentage between 0.1 and 50.")
            return
        }
        let bps = percent > 50 ? SwapSlippage.maxBps : SwapSlippage.bps(fromPercent: percent)
        persistSlippage(bps)
    }

    private func persistSlippage(_ bps: UInt64) {
        let clamped = SwapSlippage.clampBps(bps)
        slippageBpsDraft = clamped
        slippagePercentField = Self.formatSlippagePercent(SwapSlippage.percent(fromBps: clamped))
        onSetSwapSlippageBps(clamped)
        transactionsMessage = SettingsMessage(
            kind: .success,
            text: "Swap slippage set to \(Self.formatSlippagePercent(SwapSlippage.percent(fromBps: clamped)))."
        )
    }

    private static func formatSlippagePercent(_ percent: Double) -> String {
        let formatted = String(format: "%g", percent)
        return "\(formatted)%"
    }

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Daemon") {
                SettingsKeyValueRows(rows: [
                    SettingsKeyValue(title: "Mode", value: snapshot.walletNodeMode),
                    SettingsKeyValue(title: "Config", value: snapshot.walletNodeConfigPath),
                    SettingsKeyValue(title: "Log file", value: snapshot.walletNodeLogPath),
                    SettingsKeyValue(title: "Version", value: snapshot.walletNodeVersion),
                    SettingsKeyValue(title: "Relayer message", value: snapshot.relayerMessage),
                    SettingsKeyValue(title: "Active bundler", value: snapshot.activeBundlerStatus),
                    SettingsKeyValue(title: "Bridge", value: snapshot.bridgeStatus),
                ])
            }

            SettingsSection(title: "Transaction State") {
                SettingsKeyValueRows(rows: [
                    SettingsKeyValue(title: "Last userOp", value: snapshot.lastSubmittedUserOperationHash),
                    SettingsKeyValue(title: "Last bundle tx", value: snapshot.lastBundledTransactionHash),
                    SettingsKeyValue(title: "Last error", value: snapshot.lastError),
                ])
                Divider().overlay(SettingsPalette.border).padding(.vertical, 4)
                HStack(spacing: 12) {
                    Button {
                        advancedMessage = SettingsMessage(kind: .info, text: "Collecting debug report...")
                        Task {
                            let report = await onCopyDebugReport()
                            await MainActor.run {
                                copyToPasteboard(report)
                                advancedMessage = SettingsMessage(kind: .success, text: "Debug report copied.")
                            }
                        }
                    } label: {
                        Label("Copy debug report", systemImage: "doc.on.clipboard")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())

                    Button {
                        onClearDebugLog()
                        advancedMessage = SettingsMessage(kind: .success, text: "Debug log cleared.")
                    } label: {
                        Label("Clear debug log", systemImage: "eraser")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    if let advancedMessage {
                        SettingsMessageBanner(message: advancedMessage)
                    }
                    Spacer()
                }
            }
        }
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Application") {
                SettingsInfoGrid {
                    SettingsInfoItem(
                        title: "Version",
                        value: snapshot.appVersion,
                        detail: "Build \(snapshot.appBuild)",
                        systemImage: "app.badge.fill",
                        tint: SettingsPalette.blue
                    )
                    SettingsInfoItem(
                        title: "Release channel",
                        value: snapshot.releaseChannel,
                        detail: "Local development settings",
                        systemImage: "dot.radiowaves.left.and.right",
                        tint: SettingsPalette.cyan
                    )
                }
            }

            SettingsSection(title: "Runtime Components") {
                SettingsKeyValueRows(rows: [
                    SettingsKeyValue(title: "wallet-node", value: snapshot.walletNodeVersion),
                    SettingsKeyValue(title: "wallet-node mode", value: snapshot.walletNodeMode),
                    SettingsKeyValue(title: "Rust FFI", value: snapshot.rustFFIBuild),
                    SettingsKeyValue(title: "Local LLM", value: snapshot.localLLMBackend),
                    SettingsKeyValue(title: "Text model", value: snapshot.textModelName),
                    SettingsKeyValue(title: "Multimodal model", value: snapshot.multimodalModelName),
                ])
            }

            SettingsSection(title: "Build") {
                SettingsKeyValueRows(rows: [
                    SettingsKeyValue(title: "Captured", value: Self.dateFormatter.string(from: snapshot.capturedAt)),
                    SettingsKeyValue(title: "App version", value: snapshot.appVersion),
                    SettingsKeyValue(title: "App build", value: snapshot.appBuild),
                ])
            }
        }
    }

    private var sessionStatusTint: Color {
        if snapshot.session.isExpired {
            return SettingsPalette.orange
        }
        return snapshot.session.isEnabled ? SettingsPalette.green : SettingsPalette.secondaryText
    }

    private var sessionStatusImage: String {
        if snapshot.session.isExpired {
            return "clock.badge.exclamationmark.fill"
        }
        return snapshot.session.isEnabled ? "shield.fill" : "shield.slash"
    }

    private var sessionStatusShortDetail: String {
        if snapshot.session.isEnabled {
            return "\(Self.ethLabel(wei: snapshot.session.activePolicy.perTxValueLimitWei)) per action"
        }
        return "Passkey approval required for assistant actions"
    }

    private var sessionAllowedActionsText: String {
        var actions: [String] = []
        if snapshot.session.activePolicy.allowlist.nativeTransfers {
            actions.append("ETH transfers")
        }
        if snapshot.session.activePolicy.allowlist.erc20Transfers {
            actions.append("ERC-20 transfers")
        }
        if snapshot.session.activePolicy.allowlist.swapRouter {
            actions.append("swaps")
        }
        return actions.isEmpty ? "None enabled" : actions.joined(separator: ", ")
    }

    private var sessionERC20Summary: String {
        let policy = snapshot.session.activePolicy
        let count = policy.effectiveERC20TokenLimits(on: Self.chainID(from: snapshot.chainID))
            .filter(\.isEnabled)
            .count
        guard count > 0 else {
            return "No tokens enabled"
        }
        let transferText = policy.allowlist.erc20Transfers ? "transfer" : "no transfer"
        return "\(count) tokens · \(transferText)"
    }

    private var isSessionTransactionInProgress: Bool {
        isEnablingSessionKeys || isRevokingSessionKeys
    }

    private var sessionTransactionTitle: String {
        isRevokingSessionKeys ? "Disabling session key..." : "Enabling session key..."
    }

    private var sessionTransactionDetail: String {
        if isRevokingSessionKeys {
            return "A passkey-authorized revoke transaction is being executed. Keep this Session Keys screen open until the session key is fully disabled."
        }
        return "A passkey-authorized enable transaction is being executed. Keep this Session Keys screen open until the assistant permission is installed."
    }

    private var sessionKeyRows: [SettingsKeyValue] {
        var rows = [
            SettingsKeyValue(title: "Assistant access", value: snapshot.session.isEnabled ? "On" : "Off"),
            SettingsKeyValue(title: "Policy source", value: snapshot.session.hasRecord ? "Active session snapshot" : "Saved wallet defaults"),
            SettingsKeyValue(title: "Allowed actions", value: sessionAllowedActionsText),
            SettingsKeyValue(title: "ERC-20 tokens", value: sessionERC20Summary),
            SettingsKeyValue(title: "Approvals", value: "Uniswap SwapRouter02 only"),
        ]
        guard let record = snapshot.session.record else {
            return rows
        }
        rows.append(contentsOf: [
            SettingsKeyValue(title: "Onchain permission", value: "0x\(record.permissionId.hexEncodedString)"),
            SettingsKeyValue(title: "Installed onchain", value: record.installedOnChain ? "Yes" : "No"),
            SettingsKeyValue(title: "Enabled at", value: Self.dateFormatter.string(from: record.enabledAt)),
            SettingsKeyValue(title: "Last activity", value: Self.dateFormatter.string(from: record.lastActivityAt)),
            SettingsKeyValue(title: "Expires", value: Self.dateFormatter.string(from: record.expiresAt)),
            SettingsKeyValue(
                title: "Inactive at",
                value: snapshot.session.inactivityExpiresAt.map(Self.dateFormatter.string(from:)) ?? "Unavailable"
            ),
            SettingsKeyValue(title: "Validation nonce", value: "\(record.validationNonce)"),
            SettingsKeyValue(title: "Session key ref", value: record.sessionKeyRef),
        ])
        return rows
    }

    private func setAllTokenLimitsEnabled(_ isEnabled: Bool) {
        for index in sessionPolicyDraft.erc20TokenLimits.indices {
            sessionPolicyDraft.erc20TokenLimits[index].isEnabled = isEnabled
        }
    }

    private func resetTokenCapsToDefaults() {
        for index in sessionPolicyDraft.erc20TokenLimits.indices {
            let token = sessionPolicyDraft.erc20TokenLimits[index].token
            sessionPolicyDraft.erc20TokenLimits[index].maxAmount = SessionPolicyConfig.defaultERC20LimitDecimal(for: token)
        }
    }

    private func enableSessionKeys() {
        guard !isEnablingSessionKeys else {
            return
        }
        isEnablingSessionKeys = true
        sessionMessage = SettingsMessage(
            kind: .info,
            text: "Confirm with your passkey, then wait here while the enable transaction is submitted."
        )
        Task {
            do {
                let message = try await onEnableSessionKeys()
                await MainActor.run {
                    sessionMessage = SettingsMessage(kind: .success, text: message)
                    isEnablingSessionKeys = false
                }
            } catch {
                await MainActor.run {
                    sessionMessage = SettingsMessage(kind: .error, text: error.localizedDescription)
                    isEnablingSessionKeys = false
                }
            }
        }
    }

    private func revokeSessionKeys() {
        guard !isRevokingSessionKeys else {
            return
        }
        isRevokingSessionKeys = true
        sessionMessage = SettingsMessage(
            kind: .info,
            text: "Confirm with your passkey, then wait here while the revoke transaction is confirmed."
        )
        Task {
            do {
                let message = try await onRevokeSessionKeys()
                await MainActor.run {
                    sessionMessage = SettingsMessage(kind: .success, text: message)
                    isRevokingSessionKeys = false
                }
            } catch {
                await MainActor.run {
                    sessionMessage = SettingsMessage(kind: .error, text: error.localizedDescription)
                    isRevokingSessionKeys = false
                }
            }
        }
    }

    private func saveSessionPolicyDraft() {
        do {
            let policy = try sessionPolicyDraft.policy()
            let message = try onUpdateSessionPolicy(policy)
            sessionPolicyDraft = SessionPolicyDraft(
                policy: policy,
                chainID: Self.chainID(from: snapshot.chainID)
            )
            sessionMessage = SettingsMessage(kind: .success, text: message)
        } catch {
            sessionMessage = SettingsMessage(kind: .error, text: error.localizedDescription)
        }
    }

    private func rotateRelayer() {
        guard !isRotatingRelayer else {
            return
        }
        isRotatingRelayer = true
        walletMessage = SettingsMessage(kind: .info, text: "Requesting local authorization to rotate the relayer key...")
        Task {
            do {
                let message = try await onRotateRelayer()
                await MainActor.run {
                    walletMessage = SettingsMessage(kind: .success, text: message)
                    isRotatingRelayer = false
                }
            } catch {
                await MainActor.run {
                    walletMessage = SettingsMessage(kind: .error, text: error.localizedDescription)
                    isRotatingRelayer = false
                }
            }
        }
    }

    private func exportRelayerKey() {
        guard !isExportingRelayer else {
            return
        }
        isExportingRelayer = true
        securityMessage = SettingsMessage(kind: .info, text: "Requesting local authorization to export the relayer key...")
        Task {
            do {
                let privateKey = try await onExportRelayerKey()
                await MainActor.run {
                    ConcealedPasteboard.copy(privateKey)
                    securityMessage = SettingsMessage(
                        kind: .success,
                        text: "Relayer private key copied to the clipboard as concealed content. It clears automatically in \(Int(ConcealedPasteboard.defaultClearDelay)) seconds."
                    )
                    isExportingRelayer = false
                }
            } catch {
                await MainActor.run {
                    securityMessage = SettingsMessage(kind: .error, text: error.localizedDescription)
                    isExportingRelayer = false
                }
            }
        }
    }

    private func resetWallet() {
        guard !isResettingWallet else { return }
        isResettingWallet = true
        securityMessage = SettingsMessage(
            kind: .info,
            text: "Requesting local authorization to reset the wallet..."
        )
        Task {
            do {
                let message = try await onResetWallet()
                await MainActor.run {
                    securityMessage = SettingsMessage(kind: .success, text: message)
                    isResettingWallet = false
                }
            } catch {
                await MainActor.run {
                    securityMessage = SettingsMessage(kind: .error, text: error.localizedDescription)
                    isResettingWallet = false
                }
            }
        }
    }

    private func runConfirmedAction(_ confirmation: SettingsConfirmation) {
        do {
            switch confirmation {
            case .clearRankings:
                dataMessage = SettingsMessage(kind: .success, text: try onClearRankings())
            case .clearChatHistory:
                dataMessage = SettingsMessage(kind: .success, text: try onClearChatHistory())
            case .revokeSessionKeys:
                revokeSessionKeys()
            case .resetWallet:
                resetWallet()
            }
        } catch {
            let message = SettingsMessage(kind: .error, text: error.localizedDescription)
            switch confirmation {
            case .clearRankings, .clearChatHistory:
                dataMessage = message
            case .revokeSessionKeys:
                sessionMessage = message
            case .resetWallet:
                securityMessage = message
            }
        }
    }

    // For non-secret values only (addresses, reports); secrets go through
    // ConcealedPasteboard so they are hidden from clipboard managers and
    // cleared automatically.
    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private var hardwareMemoryStatus: String {
        guard let hardwareProfile else {
            return "Inspecting..."
        }
        guard let summary = snapshot.hardwareSummary else {
            return hardwareProfile.memoryText
        }
        return "\(summary.memoryText) · \(summary.budgetText) for models"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private enum SettingsConfirmation: Identifiable, Equatable {
    case clearRankings
    case clearChatHistory
    case revokeSessionKeys
    case resetWallet

    var id: String {
        switch self {
        case .clearRankings:
            return "clear-rankings"
        case .clearChatHistory:
            return "clear-chat-history"
        case .revokeSessionKeys:
            return "revoke-session-keys"
        case .resetWallet:
            return "reset-wallet"
        }
    }

    var title: String {
        switch self {
        case .clearRankings:
            return "Clear rankings?"
        case .clearChatHistory:
            return "Clear chat history?"
        case .revokeSessionKeys:
            return "Disable session keys?"
        case .resetWallet:
            return "Reset wallet?"
        }
    }

    var message: String {
        switch self {
        case .clearRankings:
            return "This removes all local tool-feedback records used for ranking and evaluation."
        case .clearChatHistory:
            return "This removes local conversations and messages, then creates a new empty chat."
        case .revokeSessionKeys:
            return "This starts a passkey-authorized onchain revoke transaction. Stay on the Session Keys settings screen until the transaction finishes and the local session key state is cleared."
        case .resetWallet:
            return "This deletes the Secure Enclave wallet key reference, local relayer keys, local session keys, and wallet metadata. If session keys are enabled, disable them first. An onchain session permission stays valid until it expires. A new account will be created."
        }
    }

    var confirmTitle: String {
        switch self {
        case .clearRankings:
            return "Clear Rankings"
        case .clearChatHistory:
            return "Clear History"
        case .revokeSessionKeys:
            return "Disable"
        case .resetWallet:
            return "Reset Wallet"
        }
    }
}

private struct SessionPolicyDraft: Equatable {
    var nativeValueLimitETH: String
    var rateLimitCount: String
    var rateLimitIntervalSec: String
    var ttlSeconds: String
    var inactivityTimeoutSeconds: String
    var gasBudgetETH: String
    var nativeTransfers: Bool
    var erc20Transfers: Bool
    var erc20TokenLimits: [SessionPolicyTokenLimitDraft]

    init(policy: SessionPolicyConfig, chainID: UInt64) {
        _ = chainID
        nativeValueLimitETH = SessionPolicyConfig.tokenDecimalString(
            fromBaseUnits: policy.perTxValueLimitWei,
            decimals: 18
        )
        rateLimitCount = "\(policy.rateLimitCount)"
        rateLimitIntervalSec = "\(policy.rateLimitIntervalSec)"
        ttlSeconds = "\(policy.ttlSeconds)"
        inactivityTimeoutSeconds = "\(policy.inactivityTimeoutSeconds)"
        gasBudgetETH = SessionPolicyConfig.tokenDecimalString(
            fromBaseUnits: policy.gasBudgetWei,
            decimals: 18
        )
        nativeTransfers = policy.allowlist.nativeTransfers
        erc20Transfers = policy.allowlist.erc20Transfers
        erc20TokenLimits = WalletTokenRegistry.erc20PolicyCatalog().compactMap { token in
            guard token.contractAddress != nil,
                  let limit = policy.erc20TokenLimit(for: token)
            else {
                return nil
            }
            return SessionPolicyTokenLimitDraft(
                token: token,
                isEnabled: limit.isEnabled,
                maxAmount: SessionPolicyConfig.tokenDecimalString(
                    fromBaseUnits: limit.maxAmount,
                    decimals: token.decimals
                )
            )
        }
    }

    func policy() throws -> SessionPolicyConfig {
        guard let count = Int(rateLimitCount.trimmingCharacters(in: .whitespacesAndNewlines)),
              let interval = Int(rateLimitIntervalSec.trimmingCharacters(in: .whitespacesAndNewlines)),
              let ttl = Int(ttlSeconds.trimmingCharacters(in: .whitespacesAndNewlines)),
              let inactivityTimeout = Int(inactivityTimeoutSeconds.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw AppError.invalidAmount
        }
        let tokenLimits = try erc20TokenLimits.map { draft in
            return SessionERC20TokenLimit(
                symbol: draft.token.symbol,
                isEnabled: draft.isEnabled,
                maxAmount: try SessionPolicyConfig.tokenBaseUnits(
                    fromDecimalString: draft.maxAmount,
                    decimals: draft.token.decimals
                )
            )
        }
        return try SessionPolicyConfig(
            perTxValueLimitWei: try SessionPolicyConfig.tokenBaseUnits(
                fromDecimalString: nativeValueLimitETH,
                decimals: 18
            ),
            rateLimitCount: count,
            rateLimitIntervalSec: interval,
            ttlSeconds: ttl,
            inactivityTimeoutSeconds: inactivityTimeout,
            gasBudgetWei: try SessionPolicyConfig.tokenBaseUnits(
                fromDecimalString: gasBudgetETH,
                decimals: 18
            ),
            allowlist: SessionPolicyAllowlist(
                nativeTransfers: nativeTransfers,
                erc20TokenScope: .knownList,
                erc20Transfers: erc20Transfers,
                erc20Approvals: .knownSwapRouters,
                swapRouter: true
            ),
            erc20TokenLimits: tokenLimits
        ).validated()
    }
}

private struct SessionPolicyTokenLimitDraft: Identifiable, Equatable {
    let token: WalletToken
    var isEnabled: Bool
    var maxAmount: String

    var id: String {
        token.id
    }
}

enum LocalWalletSettingsTab: String, CaseIterable, Identifiable {
    case info
    case models
    case network
    case transactions
    case diagnostics
    case data
    case wallet
    case sessionKeys
    case security
    case about
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info:
            return "Info"
        case .models:
            return "Models"
        case .network:
            return "Network"
        case .transactions:
            return "Transactions"
        case .diagnostics:
            return "Diagnostics"
        case .data:
            return "Data"
        case .wallet:
            return "Wallet"
        case .sessionKeys:
            return "Session Keys"
        case .security:
            return "Security"
        case .about:
            return "About"
        case .advanced:
            return "Advanced"
        }
    }

    var subtitle: String {
        switch self {
        case .info:
            return "App, hardware, model, wallet, and storage state"
        case .models:
            return "Local model runtime and generation preferences"
        case .network:
            return "Chain, RPC, and contract configuration"
        case .transactions:
            return "Swap slippage and transaction preferences"
        case .diagnostics:
            return "Network, wallet-node, and relayer health checks"
        case .data:
            return "Local database and feedback exports"
        case .wallet:
            return "Smart account and relayer status"
        case .sessionKeys:
            return "Assistant signing limits and token caps"
        case .security:
            return "Local keys, biometric unlock, and reset controls"
        case .about:
            return "Versions, update channel, and runtime components"
        case .advanced:
            return "Daemon, config, and build diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .info:
            return "info.circle.fill"
        case .models:
            return "sparkles"
        case .network:
            return "network"
        case .transactions:
            return "arrow.left.arrow.right"
        case .diagnostics:
            return "stethoscope"
        case .data:
            return "tray.and.arrow.down.fill"
        case .wallet:
            return "lock.shield.fill"
        case .sessionKeys:
            return "key.fill"
        case .security:
            return "touchid"
        case .about:
            return "app.badge.fill"
        case .advanced:
            return "terminal.fill"
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(SettingsPalette.mutedText)
                .tracking(0.8)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(SettingsPalette.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(SettingsPalette.border.opacity(0.75), lineWidth: 1)
                    )
            )
        }
    }
}

private struct SettingsInfoGrid<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 230), spacing: 12, alignment: .top),
            ],
            alignment: .leading,
            spacing: 12
        ) {
            content
        }
    }
}

private struct SettingsInfoItem: View {
    let title: String
    let value: String
    var detail: String? = nil
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(SettingsPalette.mutedText)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text(value)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(SettingsPalette.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SettingsPalette.secondaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(minHeight: 86, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsPalette.row)
        )
    }
}

private struct SettingsKeyValue: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let value: String
}

private struct SettingsKeyValueRows: View {
    let rows: [SettingsKeyValue]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text(row.title)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(SettingsPalette.mutedText)
                        .frame(width: 150, alignment: .leading)
                    Text(row.value.isEmpty ? "Not set" : row.value)
                        .font(.system(size: 13, weight: .semibold, design: row.value.hasPrefix("0x") ? .monospaced : .default))
                        .foregroundStyle(SettingsPalette.primaryText)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
                if row.id != rows.last?.id {
                    Divider().overlay(SettingsPalette.border.opacity(0.55))
                }
            }
        }
    }
}

private struct SettingsEditableField: View {
    let title: String
    let placeholder: String
    var detail: String? = nil
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(SettingsPalette.mutedText)
                .textCase(.uppercase)
                .tracking(0.5)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(SettingsPalette.primaryText)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SettingsPalette.row)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(SettingsPalette.border.opacity(0.72), lineWidth: 1)
                        )
                )
            if let detail {
                Text(detail)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsPalette.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A compact, palette-styled dropdown for picking one of a fixed set of integer
/// values (durations in seconds, or counts). Used by the session-key timing and
/// budget rules so every value is a bounded choice instead of free-form text.
private struct SettingsInlineMenu: View {
    @Binding var selection: Int
    let options: [Int]
    let label: (Int) -> String

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(label(option), systemImage: "checkmark")
                    } else {
                        Text(label(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(label(selection))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SettingsPalette.primaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(SettingsPalette.mutedText)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(SettingsPalette.row)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(SettingsPalette.border.opacity(0.72), lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// A single plain-language policy rule: a sentence-style title with a trailing
/// control on the first line, and a one-line consequence beneath it.
private struct SessionRuleRow<Control: View>: View {
    let title: String
    let detail: String
    let control: Control

    init(title: String, detail: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SettingsPalette.primaryText)
                Spacer(minLength: 12)
                control
            }
            Text(detail)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SessionTokenLimitTable: View {
    @Binding var limits: [SessionPolicyTokenLimitDraft]
    var rowLimit: Int?

    var body: some View {
        let indices = displayedIndices
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("On")
                    .frame(width: 42, alignment: .center)
                Text("Token")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Cap")
                    .frame(width: 170, alignment: .leading)
            }
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(SettingsPalette.mutedText)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(SettingsPalette.control.opacity(0.72))

            ForEach(indices, id: \.self) { index in
                SessionTokenLimitTableRow(limit: $limits[index])
                if index != indices.last {
                    Divider().overlay(SettingsPalette.border.opacity(0.45))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(SettingsPalette.border.opacity(0.72), lineWidth: 1)
        )
    }

    private var displayedIndices: [Int] {
        let indices = Array(limits.indices)
        guard let rowLimit else {
            return indices
        }
        return Array(indices.prefix(rowLimit))
    }
}

private struct SessionTokenLimitsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var limits: [SessionPolicyTokenLimitDraft]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ERC-20 Token Caps")
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(SettingsPalette.primaryText)
                    Text("Caps apply by token symbol across all supported chains.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsPalette.secondaryText)
                }
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .heavy))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(SettingsIconButtonStyle())
            }

            ScrollView {
                SessionTokenLimitTable(limits: $limits)
            }
            .frame(minHeight: 360, maxHeight: 560)

            HStack {
                Text("\(limits.count) known token symbols")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsPalette.secondaryText)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 760)
        .background(SettingsPalette.background)
    }
}

private struct SessionTokenLimitTableRow: View {
    @Binding var limit: SessionPolicyTokenLimitDraft

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $limit.isEnabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 42)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(limit.token.symbol)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(SettingsPalette.primaryText)
                    Text(limit.token.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SettingsPalette.secondaryText)
                        .lineLimit(1)
                }
                Text(chainCoverageText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsPalette.mutedText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TextField(SessionPolicyConfig.defaultERC20LimitDecimal(for: limit.token), text: $limit.maxAmount)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(SettingsPalette.primaryText)
                .padding(.horizontal, 10)
                .frame(width: 170, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SettingsPalette.panel)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(SettingsPalette.border.opacity(0.72), lineWidth: 1)
                        )
                )
                .disabled(!limit.isEnabled)
                .opacity(limit.isEnabled ? 1 : 0.5)
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(SettingsPalette.row)
    }

    private var chainCoverageText: String {
        "\(limit.token.decimals) decimals · Sepolia"
    }
}

private struct SettingsMessage: Equatable {
    enum Kind {
        case info
        case success
        case error
    }

    let kind: Kind
    let text: String

    var tint: Color {
        switch kind {
        case .info:
            return SettingsPalette.cyan
        case .success:
            return SettingsPalette.green
        case .error:
            return SettingsPalette.red
        }
    }

    var systemImage: String {
        switch kind {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}

private struct SettingsTransactionProgressBanner: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .progressViewStyle(.circular)
                .tint(SettingsPalette.blue)
                .frame(width: 24, height: 24)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(SettingsPalette.primaryText)
                Text(detail)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsPalette.blue.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(SettingsPalette.blue.opacity(0.55), lineWidth: 1)
                )
        )
    }
}

/// A small pill label — a fit verdict, "Default", a health state — matching the
/// capsule style already used inline by `SettingsHealthRow`.
private struct SettingsBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

private struct SettingsMessageBanner: View {
    let message: SettingsMessage
    /// Non-nil for a message that outlives the view showing it — the install
    /// outcome, which is session state and would otherwise re-appear on every
    /// return to this tab with no way to acknowledge it. View-local messages die
    /// with the view and need no button.
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.systemImage)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(message.tint)
                .padding(.top, 1)
            Text(message.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsPalette.primaryText)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .black))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(SettingsIconButtonStyle())
                .help("Dismiss")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(message.tint.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(message.tint.opacity(0.35), lineWidth: 1)
                )
        )
    }
}

private struct SettingsHealthRow: View {
    let check: SettingsHealthCheck

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: check.state.systemImage)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(check.state.tint)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(check.title)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(SettingsPalette.primaryText)
                    Text(check.state.rawValue)
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(check.state.tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(check.state.tint.opacity(0.14)))
                    if let latency = check.latencyMilliseconds {
                        Text("\(latency) ms")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(SettingsPalette.secondaryText)
                    }
                }
                Text(check.detail)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}

private struct SettingsPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(SettingsPalette.primaryText)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? SettingsPalette.blue.opacity(0.72) : SettingsPalette.blue)
            )
    }
}

private struct SettingsSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(SettingsPalette.primaryText)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? SettingsPalette.control.opacity(0.74) : SettingsPalette.control)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(SettingsPalette.border.opacity(0.78), lineWidth: 1)
                    )
            )
    }
}

private struct SettingsIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(SettingsPalette.primaryText)
            .background(
                Circle()
                    .fill(configuration.isPressed ? SettingsPalette.control.opacity(0.74) : SettingsPalette.control)
                    .overlay(Circle().stroke(SettingsPalette.border.opacity(0.78), lineWidth: 1))
            )
    }
}

private struct SettingsDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(SettingsPalette.primaryText)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? SettingsPalette.red.opacity(0.62) : SettingsPalette.red.opacity(0.42))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(SettingsPalette.red.opacity(0.70), lineWidth: 1)
                    )
            )
    }
}

private enum SettingsPalette {
    static let background = Color(red: 0.045, green: 0.055, blue: 0.100)
    static let sidebar = Color(red: 0.035, green: 0.042, blue: 0.082)
    static let panel = Color(red: 0.066, green: 0.076, blue: 0.125)
    static let row = Color(red: 0.082, green: 0.094, blue: 0.150)
    static let rowBackground = row
    static let selected = Color(red: 0.116, green: 0.135, blue: 0.215)
    static let control = Color(red: 0.105, green: 0.121, blue: 0.190)
    static let border = Color(red: 0.175, green: 0.205, blue: 0.315)
    static let primaryText = Color(red: 1.000, green: 0.990, blue: 0.900)
    static let secondaryText = Color(red: 0.730, green: 0.790, blue: 0.900)
    static let mutedText = Color(red: 0.500, green: 0.560, blue: 0.700)
    static let blue = Color(red: 0.265, green: 0.470, blue: 0.930)
    static let green = Color(red: 0.250, green: 0.760, blue: 0.430)
    static let cyan = Color(red: 0.250, green: 0.740, blue: 0.820)
    static let orange = Color(red: 0.930, green: 0.560, blue: 0.230)
    static let red = Color(red: 0.950, green: 0.280, blue: 0.260)
}

/// Maps a fit verdict to its badge colour. A free function rather than a method so
/// the model list and the Hugging Face form colour the same verdict identically.
private func settingsVerdictTint(_ verdict: ModelFitVerdict) -> Color {
    switch verdict {
    case .fits: return SettingsPalette.green
    case .tight: return SettingsPalette.orange
    case .wontFit: return SettingsPalette.red
    case .unknown: return SettingsPalette.mutedText
    }
}

/// Repo → file → verdict → download. Resolution is explicit (a button, not on every
/// keystroke) so a half-typed repo name never fires a request; the fit verdict then
/// follows the selected file automatically, since it is what decides whether the
/// download is worth starting.
private struct AddHuggingFaceModelForm: View {
    /// This form's own install, already filtered by the caller to one that no model
    /// row is drawing. The repo/file list is still local state and is lost on
    /// navigation — but the download is not, which is the part measured in
    /// gigabytes, so its progress and its Cancel button render outside every
    /// `files`-dependent branch below.
    let install: ModelInstallProgress?
    /// The name of an install the *rest* of Settings owns. It holds the single
    /// install slot, so this form can start nothing — and has to say which.
    let blockedByInstallOf: String?
    let onResolveRepo: (String) async throws -> HuggingFaceRepositoryInfo
    let onInspectRemoteFile: (HuggingFaceGGUFFile) async -> RemoteModelFit
    let onStartModelInstall: (ModelDownloadRequest) -> Void
    let onCancelModelDownload: () -> Void

    @State private var repoID: String = ""
    /// The repo the listed `files` actually came from, in its validated,
    /// normalised form.
    ///
    /// `download()` must key the install off this and never off `repoID`, which
    /// is live, editable, and unvalidated. Editing the field after "Find models"
    /// (or clearing it) previously downloaded the right bytes but stored them
    /// under the new text: wrong `repoID` on the row, a destination named after a
    /// repo the file did not come from, and a `modelID` that no longer matches
    /// the real repo — so re-adding it later installed a second multi-gigabyte
    /// copy instead of recognising the existing one.
    @State private var resolvedRepoID: String = ""
    @State private var files: [HuggingFaceGGUFFile] = []
    @State private var selectedPath: String = ""
    @State private var message: SettingsMessage?
    @State private var isResolving = false
    @State private var fit: RemoteModelFit?
    @State private var isInspecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SettingsEditableField(
                    title: "Repository",
                    placeholder: "unsloth/gemma-4-E2B-it-GGUF",
                    text: $repoID
                )
                Button(isResolving ? "Checking…" : "Find models") { resolve() }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .disabled(repoID.isEmpty || isResolving)
            }

            if !files.isEmpty {
                Picker("File", selection: $selectedPath) {
                    ForEach(files.filter { !$0.isAuxiliary }) { file in
                        Text("\(file.path) · \(ByteCountFormatter.string(fromByteCount: Int64(file.sizeBytes), countStyle: .file))")
                            .tag(file.path)
                    }
                }
                .pickerStyle(.menu)

                fitLine

                HStack {
                    Spacer()
                    Button("Download & add") { download() }
                        .buttonStyle(SettingsPrimaryButtonStyle())
                        .disabled(selectedPath.isEmpty || install != nil || blockedByInstallOf != nil)
                }
            }

            // Outside the `files` branch on purpose. `files` is view state: leaving
            // this tab and coming back rebuilds the form empty, and a 6 GB download
            // in flight then had nowhere to draw its progress and nowhere to offer
            // Cancel — while every other Download in Settings stayed disabled
            // behind it. Quitting the app was the only way out.
            if let install {
                installLine(install)
            } else if let blockedByInstallOf {
                Text("Waiting on \(blockedByInstallOf): one download at a time.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let message {
                SettingsMessageBanner(message: message)
            }

            Text("Public GGUF repositories only. Unverified models can get tool calls wrong. Review every transaction.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        // On the container, not the Picker: the Picker only exists once `files`
        // is non-empty, and an `onChange` that appears at the same moment its
        // value is set does not fire for that first assignment.
        .onChange(of: selectedPath) { _, _ in inspect() }
        // Editing the repository after resolving it makes the listed files stale.
        // `download()` is keyed off `resolvedRepoID` so it could not install the
        // wrong thing either way, but showing another repo's file list under a
        // changed name invites exactly that misreading.
        .onChange(of: repoID) { _, newValue in
            guard newValue != resolvedRepoID, !files.isEmpty else { return }
            files = []
            selectedPath = ""
            resolvedRepoID = ""
            fit = nil
        }
    }

    /// Progress for this form's own install, naming the model — after a trip to
    /// another tab the file picker that started it is gone, so the bar has to say
    /// what it belongs to.
    @ViewBuilder
    private func installLine(_ install: ModelInstallProgress) -> some View {
        HStack {
            switch install.phase {
            case .downloading(let progress):
                ProgressView(value: progress.fractionCompleted).frame(width: 180)
                Text("\(install.displayName): \(progress.statusText)")
                    .font(.system(size: 11, design: .monospaced))
            case .testing:
                ProgressView().controlSize(.small)
                Text("Loading \(install.displayName) for real and checking it can make a tool call. This can take a minute.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if case .downloading = install.phase {
                Button("Cancel") { onCancelModelDownload() }
                    .buttonStyle(SettingsSecondaryButtonStyle())
            }
            Spacer()
        }
    }

    /// The pre-download verdict. Advisory: it never disables "Download & add".
    @ViewBuilder
    private var fitLine: some View {
        if isInspecting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading this file's header to size it against this Mac…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else if let fit {
            HStack(alignment: .top, spacing: 8) {
                SettingsBadge(text: fit.verdict.label, tint: settingsVerdictTint(fit.verdict))
                Text(fit.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Reads the selected file's GGUF header over a ranged request. `inspectionID`
    /// discards a slow reply for a file the user has already navigated away from.
    @State private var inspectionID = 0

    private func inspect() {
        guard let file = files.first(where: { $0.path == selectedPath }) else {
            fit = nil
            return
        }
        inspectionID += 1
        let id = inspectionID
        fit = nil
        isInspecting = true
        Task { @MainActor in
            let result = await onInspectRemoteFile(file)
            guard id == inspectionID else { return }
            isInspecting = false
            fit = result
        }
    }

    private func resolve() {
        isResolving = true
        message = nil
        fit = nil
        Task { @MainActor in
            defer { isResolving = false }
            do {
                let normalised = try HuggingFaceRepository.validate(repoID: repoID)
                let info = try await onResolveRepo(normalised)
                resolvedRepoID = normalised
                files = info.files
                let firstPath = info.files.first { !$0.isAuxiliary }?.path ?? ""
                // Re-resolving the same repo leaves `selectedPath` unchanged, so
                // `onChange` would not fire; inspect explicitly in that case.
                if firstPath == selectedPath { inspect() } else { selectedPath = firstPath }
                let context = info.trainedContextTokens.map { " · trained to \($0)" } ?? ""
                message = SettingsMessage(
                    kind: info.hasChatTemplate ? .success : .error,
                    text: info.hasChatTemplate
                        ? "\(info.files.count) GGUF file(s)\(context)."
                        : "This repo has no chat template, so it cannot make tool calls."
                )
            } catch {
                files = []
                resolvedRepoID = ""
                selectedPath = ""
                fit = nil
                message = SettingsMessage(kind: .error, text: error.localizedDescription)
            }
        }
    }

    private func download() {
        guard let file = files.first(where: { $0.path == selectedPath }),
              !resolvedRepoID.isEmpty
        else { return }
        message = nil
        onStartModelInstall(ModelDownloadRequest(repoID: resolvedRepoID, file: file))
    }
}
