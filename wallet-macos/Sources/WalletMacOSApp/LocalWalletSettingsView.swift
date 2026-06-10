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

struct LocalWalletSettingsSnapshot: Equatable {
    let capturedAt: Date
    let appVersion: String
    let appBuild: String
    let updateVersion: String
    let updateStatus: String
    let textModelName: String
    let textModelIdentifier: String
    let textModelSize: String
    let textModelDetail: String
    let textModelArtifactRepo: String
    let textModelArtifactFileName: String
    let textModelRuntimeStatus: String
    let textModelInstallStatus: String
    let textModelPath: String
    let contextWindow: String
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
    let unlockRelayerOnLaunch: Bool
    let walletKeyPolicy: String
    let relayerKeyPolicy: String
    let bridgeStatus: String
    let activeBundlerStatus: String
    let lastSubmittedUserOperationHash: String
    let lastBundledTransactionHash: String
    let lastError: String
    let releaseChannel: String
    let walletNodeVersion: String
    let rustFFIBuild: String
    let localLLMBackend: String

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
    @Binding var thinkingEnabled: Bool
    let onExportRankings: () -> Void
    let onExportDatabase: () throws -> String
    let onRevealDatabase: () -> Void
    let onClearChatHistory: () throws -> String
    let onClearRankings: () throws -> String
    let onRevealModelFile: () throws -> String
    let onSaveNetworkSettings: (DemoNetworkSettings) throws -> String
    let onTestNetworkSettings: (DemoNetworkSettings) async throws -> String
    let onRunDiagnostics: (DemoNetworkSettings) async -> SettingsDiagnosticsReport
    let onRefreshRelayer: () -> Void
    let onRotateRelayer: () async throws -> String
    let onExportRelayerKey: () async throws -> String
    let onDeleteRelayerKey: (Bool) async throws -> String
    let onResetWallet: () throws -> String
    let onCopyDebugReport: () async -> String
    let onClearDebugLog: () -> Void
    let onSetUnlockRelayerOnLaunch: (Bool) -> Void
    let onClose: () -> Void

    @State private var selectedTab: SettingsTab = .info
    @State private var hardwareProfile: LocalHardwareProfile?
    @State private var networkDraft: DemoNetworkSettings
    @State private var networkMessage: SettingsMessage?
    @State private var diagnosticsReport: SettingsDiagnosticsReport?
    @State private var diagnosticsMessage: SettingsMessage?
    @State private var dataMessage: SettingsMessage?
    @State private var modelMessage: SettingsMessage?
    @State private var walletMessage: SettingsMessage?
    @State private var securityMessage: SettingsMessage?
    @State private var advancedMessage: SettingsMessage?
    @State private var unlockRelayerOnLaunch: Bool
    @State private var isTestingNetwork = false
    @State private var isRunningDiagnostics = false
    @State private var isRotatingRelayer = false
    @State private var isExportingRelayer = false
    @State private var isDeletingRelayer = false
    @State private var pendingConfirmation: SettingsConfirmation?

    init(
        snapshot: LocalWalletSettingsSnapshot,
        thinkingEnabled: Binding<Bool>,
        onExportRankings: @escaping () -> Void,
        onExportDatabase: @escaping () throws -> String,
        onRevealDatabase: @escaping () -> Void,
        onClearChatHistory: @escaping () throws -> String,
        onClearRankings: @escaping () throws -> String,
        onRevealModelFile: @escaping () throws -> String,
        onSaveNetworkSettings: @escaping (DemoNetworkSettings) throws -> String,
        onTestNetworkSettings: @escaping (DemoNetworkSettings) async throws -> String,
        onRunDiagnostics: @escaping (DemoNetworkSettings) async -> SettingsDiagnosticsReport,
        onRefreshRelayer: @escaping () -> Void,
        onRotateRelayer: @escaping () async throws -> String,
        onExportRelayerKey: @escaping () async throws -> String,
        onDeleteRelayerKey: @escaping (Bool) async throws -> String,
        onResetWallet: @escaping () throws -> String,
        onCopyDebugReport: @escaping () async -> String,
        onClearDebugLog: @escaping () -> Void,
        onSetUnlockRelayerOnLaunch: @escaping (Bool) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self._thinkingEnabled = thinkingEnabled
        self.onExportRankings = onExportRankings
        self.onExportDatabase = onExportDatabase
        self.onRevealDatabase = onRevealDatabase
        self.onClearChatHistory = onClearChatHistory
        self.onClearRankings = onClearRankings
        self.onRevealModelFile = onRevealModelFile
        self.onSaveNetworkSettings = onSaveNetworkSettings
        self.onTestNetworkSettings = onTestNetworkSettings
        self.onRunDiagnostics = onRunDiagnostics
        self.onRefreshRelayer = onRefreshRelayer
        self.onRotateRelayer = onRotateRelayer
        self.onExportRelayerKey = onExportRelayerKey
        self.onDeleteRelayerKey = onDeleteRelayerKey
        self.onResetWallet = onResetWallet
        self.onCopyDebugReport = onCopyDebugReport
        self.onClearDebugLog = onClearDebugLog
        self.onSetUnlockRelayerOnLaunch = onSetUnlockRelayerOnLaunch
        self.onClose = onClose
        self._networkDraft = State(initialValue: snapshot.networkSettings)
        self._unlockRelayerOnLaunch = State(initialValue: snapshot.unlockRelayerOnLaunch)
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
        .onChange(of: snapshot.unlockRelayerOnLaunch) { _, newValue in
            unlockRelayerOnLaunch = newValue
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
                ForEach(SettingsTab.allCases) { tab in
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

    private func settingsTabButton(_ tab: SettingsTab) -> some View {
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
                SettingsStatusPill(
                    title: snapshot.updateVersion,
                    detail: snapshot.updateStatus,
                    systemImage: "arrow.down.circle.fill",
                    tint: SettingsPalette.green
                )
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
                    case .diagnostics:
                        diagnosticsTab
                    case .data:
                        dataTab
                    case .wallet:
                        walletTab
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
                        tint: hardwareProfile?.hasMinimumModelMemory == false ? SettingsPalette.orange : SettingsPalette.green
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
            SettingsSection(title: "Text Runtime") {
                SettingsKeyValueRows(rows: [
                    SettingsKeyValue(title: "Selected", value: snapshot.textModelName),
                    SettingsKeyValue(title: "Identifier", value: snapshot.textModelIdentifier),
                    SettingsKeyValue(title: "Detail", value: snapshot.textModelDetail),
                    SettingsKeyValue(title: "Repository", value: snapshot.textModelArtifactRepo),
                    SettingsKeyValue(title: "Artifact", value: snapshot.textModelArtifactFileName),
                    SettingsKeyValue(title: "Install status", value: snapshot.textModelInstallStatus),
                    SettingsKeyValue(title: "Path", value: snapshot.textModelPath),
                    SettingsKeyValue(title: "Runtime", value: snapshot.textModelRuntimeStatus),
                    SettingsKeyValue(title: "Context", value: snapshot.contextWindow),
                ])
                Divider().overlay(SettingsPalette.border).padding(.vertical, 4)
                HStack(spacing: 12) {
                    Toggle("Show thinking", isOn: $thinkingEnabled)
                        .toggleStyle(.switch)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(SettingsPalette.primaryText)
                    Spacer()
                    Button {
                        do {
                            modelMessage = SettingsMessage(kind: .success, text: try onRevealModelFile())
                        } catch {
                            modelMessage = SettingsMessage(kind: .error, text: error.localizedDescription)
                        }
                    } label: {
                        Label("Reveal model file", systemImage: "folder")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                }
                if let modelMessage {
                    SettingsMessageBanner(message: modelMessage)
                }
            }

            SettingsSection(title: "Multimodal Runtime") {
                SettingsKeyValueRows(rows: [
                    SettingsKeyValue(title: "Selected", value: snapshot.multimodalModelName),
                    SettingsKeyValue(title: "Status", value: snapshot.multimodalModelStatus),
                ])
            }

            SettingsSection(title: "Available Text Models") {
                SettingsInfoGrid {
                    ForEach(LocalAIModel.available) { model in
                        SettingsInfoItem(
                            title: model.name,
                            value: model.size,
                            detail: model.detail,
                            systemImage: model.systemImage,
                            tint: model.id == snapshot.textModelIdentifier ? SettingsPalette.green : SettingsPalette.blue
                        )
                    }
                }
            }
        }
    }

    private var networkTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Active Network") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Network", selection: $networkDraft.isTestnetModeEnabled) {
                        Text("Sepolia").tag(true)
                        Text("Mainnet").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)

                    SettingsEditableField(
                        title: "Execution RPC",
                        placeholder: networkDraft.isTestnetModeEnabled
                            ? DemoNetworkSettings.defaults.sepoliaRPCURL
                            : DemoNetworkSettings.defaults.mainnetRPCURL,
                        text: activeExecutionRPCBinding
                    )
                    SettingsEditableField(
                        title: "Archive node",
                        placeholder: "Optional",
                        detail: "Optional Helios endpoint for historical state reads. Helios is the light-client layer wallet-node uses to verify Ethereum reads without trusting a plain RPC response blindly.",
                        text: activeArchiveRPCBinding
                    )
                    SettingsEditableField(
                        title: "Consensus RPC",
                        placeholder: networkDraft.isTestnetModeEnabled
                            ? DemoNetworkSettings.defaults.sepoliaConsensusRPCURL
                            : DemoNetworkSettings.defaults.mainnetConsensusRPCURL,
                        detail: "Required for Helios verification. Leave blank to restore the default for the selected network.",
                        text: activeConsensusRPCBinding
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $networkDraft.autoGasModeEnabled) {
                            Text("Automatic gas pricing")
                                .font(.system(size: 13, weight: .bold))
                        }
                        Text("Applies to all networks. When on, the wallet follows live network gas at the selected tier and the caps below are ignored.")
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
                            placeholder: networkDraft.isTestnetModeEnabled
                                ? DemoNetworkSettings.defaults.sepoliaMaxFeePerGasGwei
                                : DemoNetworkSettings.defaults.mainnetMaxFeePerGasGwei,
                            detail: "Upper bound wallet-node accepts for chain gas price. Sepolia default is 50 gwei.",
                            text: activeMaxFeeCapBinding
                        )
                        SettingsEditableField(
                            title: "Priority fee cap (gwei)",
                            placeholder: networkDraft.isTestnetModeEnabled
                                ? DemoNetworkSettings.defaults.sepoliaMaxPriorityFeePerGasGwei
                                : DemoNetworkSettings.defaults.mainnetMaxPriorityFeePerGasGwei,
                            detail: "Tip cap for submitted raw transactions. Must be less than or equal to max fee cap.",
                            text: activePriorityFeeCapBinding
                        )
                    }
                    .disabled(networkDraft.autoGasModeEnabled)
                    .opacity(networkDraft.autoGasModeEnabled ? 0.45 : 1)

                    if let networkMessage {
                        SettingsMessageBanner(message: networkMessage)
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

    private var activeExecutionRPCBinding: Binding<String> {
        Binding(
            get: {
                networkDraft.isTestnetModeEnabled ? networkDraft.sepoliaRPCURL : networkDraft.mainnetRPCURL
            },
            set: { value in
                if networkDraft.isTestnetModeEnabled {
                    networkDraft.sepoliaRPCURL = value
                } else {
                    networkDraft.mainnetRPCURL = value
                }
            }
        )
    }

    private var activeArchiveRPCBinding: Binding<String> {
        Binding(
            get: {
                networkDraft.isTestnetModeEnabled ? networkDraft.sepoliaArchiveNodeURL : networkDraft.mainnetArchiveNodeURL
            },
            set: { value in
                if networkDraft.isTestnetModeEnabled {
                    networkDraft.sepoliaArchiveNodeURL = value
                } else {
                    networkDraft.mainnetArchiveNodeURL = value
                }
            }
        )
    }

    private var activeConsensusRPCBinding: Binding<String> {
        Binding(
            get: {
                networkDraft.isTestnetModeEnabled ? networkDraft.sepoliaConsensusRPCURL : networkDraft.mainnetConsensusRPCURL
            },
            set: { value in
                if networkDraft.isTestnetModeEnabled {
                    networkDraft.sepoliaConsensusRPCURL = value
                } else {
                    networkDraft.mainnetConsensusRPCURL = value
                }
            }
        )
    }

    private var activeMaxFeeCapBinding: Binding<String> {
        Binding(
            get: {
                networkDraft.isTestnetModeEnabled
                    ? networkDraft.sepoliaMaxFeePerGasGwei
                    : networkDraft.mainnetMaxFeePerGasGwei
            },
            set: { value in
                if networkDraft.isTestnetModeEnabled {
                    networkDraft.sepoliaMaxFeePerGasGwei = value
                } else {
                    networkDraft.mainnetMaxFeePerGasGwei = value
                }
            }
        )
    }

    private var activePriorityFeeCapBinding: Binding<String> {
        Binding(
            get: {
                networkDraft.isTestnetModeEnabled
                    ? networkDraft.sepoliaMaxPriorityFeePerGasGwei
                    : networkDraft.mainnetMaxPriorityFeePerGasGwei
            },
            set: { value in
                if networkDraft.isTestnetModeEnabled {
                    networkDraft.sepoliaMaxPriorityFeePerGasGwei = value
                } else {
                    networkDraft.mainnetMaxPriorityFeePerGasGwei = value
                }
            }
        )
    }

    private func saveNetworkDraft() {
        do {
            let message = try onSaveNetworkSettings(networkDraft)
            networkDraft = try networkDraft.validated()
            networkMessage = SettingsMessage(kind: .success, text: message)
        } catch {
            networkMessage = SettingsMessage(kind: .error, text: error.localizedDescription)
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
                            tint: snapshot.relayerState == "Needs top-up" ? SettingsPalette.orange : SettingsPalette.green
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

    private var securityTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Authentication") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Unlock local relayer on app launch", isOn: Binding(
                        get: { unlockRelayerOnLaunch },
                        set: { value in
                            unlockRelayerOnLaunch = value
                            onSetUnlockRelayerOnLaunch(value)
                            securityMessage = SettingsMessage(
                                kind: .success,
                                text: value
                                    ? "The app will unlock wallet-node on launch so relayer balance is available immediately."
                                    : "The app will defer relayer unlock until refresh or transaction submission."
                            )
                        }
                    ))
                    .toggleStyle(.switch)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SettingsPalette.primaryText)
                    SettingsKeyValueRows(rows: [
                        SettingsKeyValue(title: "Wallet key", value: snapshot.walletKeyPolicy),
                        SettingsKeyValue(title: "Relayer key", value: snapshot.relayerKeyPolicy),
                        SettingsKeyValue(title: "Startup mode", value: unlockRelayerOnLaunch ? "Unlock relayer during launch" : "Defer relayer unlock"),
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
                            pendingConfirmation = .deleteRelayerKey(unsafe: false)
                        } label: {
                            Label("Safe delete relayer", systemImage: "trash")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .buttonStyle(SettingsDestructiveButtonStyle())
                        .disabled(isDeletingRelayer)

                        Button {
                            pendingConfirmation = .deleteRelayerKey(unsafe: true)
                        } label: {
                            Label("Unsafe reset relayer", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .buttonStyle(SettingsDestructiveButtonStyle())
                        .disabled(isDeletingRelayer)

                        Button {
                            pendingConfirmation = .resetWallet
                        } label: {
                            Label("Reset wallet", systemImage: "xmark.octagon.fill")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .buttonStyle(SettingsDestructiveButtonStyle())
                        Spacer()
                    }
                }
            }
        }
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
                        title: "Update",
                        value: snapshot.updateVersion,
                        detail: snapshot.updateStatus,
                        systemImage: "arrow.down.circle.fill",
                        tint: SettingsPalette.green
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
                    SettingsKeyValue(title: "Available update", value: "\(snapshot.updateVersion) · \(snapshot.updateStatus)"),
                ])
            }
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
                    copyToPasteboard(privateKey)
                    securityMessage = SettingsMessage(kind: .success, text: "Relayer private key copied to the clipboard.")
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

    private func deleteRelayerKey(unsafe: Bool) {
        guard !isDeletingRelayer else {
            return
        }
        isDeletingRelayer = true
        securityMessage = SettingsMessage(kind: .info, text: "Requesting local authorization to delete the relayer key...")
        Task {
            do {
                let message = try await onDeleteRelayerKey(unsafe)
                await MainActor.run {
                    securityMessage = SettingsMessage(kind: .success, text: message)
                    isDeletingRelayer = false
                }
            } catch {
                await MainActor.run {
                    securityMessage = SettingsMessage(kind: .error, text: error.localizedDescription)
                    isDeletingRelayer = false
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
            case .deleteRelayerKey(let unsafe):
                deleteRelayerKey(unsafe: unsafe)
            case .resetWallet:
                securityMessage = SettingsMessage(kind: .success, text: try onResetWallet())
            }
        } catch {
            let message = SettingsMessage(kind: .error, text: error.localizedDescription)
            switch confirmation {
            case .clearRankings, .clearChatHistory:
                dataMessage = message
            case .deleteRelayerKey, .resetWallet:
                securityMessage = message
            }
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private var hardwareMemoryStatus: String {
        guard let hardwareProfile else {
            return "Inspecting..."
        }
        return hardwareProfile.hasMinimumModelMemory
            ? "\(hardwareProfile.memoryText) available"
            : "\(hardwareProfile.memoryText), below local model target"
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
    case deleteRelayerKey(unsafe: Bool)
    case resetWallet

    var id: String {
        switch self {
        case .clearRankings:
            return "clear-rankings"
        case .clearChatHistory:
            return "clear-chat-history"
        case .deleteRelayerKey(let unsafe):
            return unsafe ? "unsafe-reset-relayer" : "delete-relayer"
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
        case .deleteRelayerKey(let unsafe):
            return unsafe ? "Unsafe reset relayer key?" : "Safe delete relayer key?"
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
        case .deleteRelayerKey(let unsafe):
            return unsafe
                ? "This deletes relayer key material even if wallet-node has pending relay state."
                : "This asks wallet-node to delete the relayer key only when it is safe."
        case .resetWallet:
            return "This deletes the Secure Enclave wallet key reference, local relayer keys, and wallet metadata. A new account will be created."
        }
    }

    var confirmTitle: String {
        switch self {
        case .clearRankings:
            return "Clear Rankings"
        case .clearChatHistory:
            return "Clear History"
        case .deleteRelayerKey(let unsafe):
            return unsafe ? "Unsafe Reset" : "Safe Delete"
        case .resetWallet:
            return "Reset Wallet"
        }
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case info
    case models
    case network
    case diagnostics
    case data
    case wallet
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
        case .diagnostics:
            return "Diagnostics"
        case .data:
            return "Data"
        case .wallet:
            return "Wallet"
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
        case .diagnostics:
            return "Network, wallet-node, and relayer health checks"
        case .data:
            return "Local database and feedback exports"
        case .wallet:
            return "Smart account and relayer status"
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
        case .diagnostics:
            return "stethoscope"
        case .data:
            return "tray.and.arrow.down.fill"
        case .wallet:
            return "lock.shield.fill"
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

private struct SettingsMessageBanner: View {
    let message: SettingsMessage

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

private struct SettingsStatusPill: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(SettingsPalette.primaryText)
                Text(detail)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(SettingsPalette.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(
            Capsule()
                .fill(SettingsPalette.control)
                .overlay(Capsule().stroke(SettingsPalette.border, lineWidth: 1))
        )
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
