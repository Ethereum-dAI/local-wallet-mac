import Foundation

enum DemoNetworkSettingsError: LocalizedError {
    case invalidRequiredURL(field: String, value: String)
    case invalidOptionalURL(field: String, value: String)

    var errorDescription: String? {
        switch self {
        case .invalidRequiredURL(let field, let value):
            return "\(field) must be a valid URL. Current value: \(value)"
        case .invalidOptionalURL(let field, let value):
            return "\(field) must be blank or a valid URL. Current value: \(value)"
        }
    }
}

struct DemoNetworkSettings: Equatable {
    var isTestnetModeEnabled: Bool
    var mainnetRPCURL: String
    var mainnetArchiveNodeURL: String
    var mainnetConsensusRPCURL: String
    var mainnetMaxFeePerGasGwei: String
    var mainnetMaxPriorityFeePerGasGwei: String
    var sepoliaRPCURL: String
    var sepoliaArchiveNodeURL: String
    var sepoliaConsensusRPCURL: String
    var sepoliaMaxFeePerGasGwei: String
    var sepoliaMaxPriorityFeePerGasGwei: String
    var heliosVerificationEnabled: Bool
    var autoGasModeEnabled: Bool
    var autoGasTier: GasTier

    static let defaults = DemoNetworkSettings(
        isTestnetModeEnabled: true,
        mainnetRPCURL: ChainConfiguration.ethereum.rpcURL.absoluteString,
        mainnetArchiveNodeURL: "",
        mainnetConsensusRPCURL: ChainConfiguration.ethereum.consensusRPCURL.absoluteString,
        mainnetMaxFeePerGasGwei: WalletNodeDaemon.GasPolicy.mainnet.maxFeePerGasGwei,
        mainnetMaxPriorityFeePerGasGwei: WalletNodeDaemon.GasPolicy.mainnet.maxPriorityFeePerGasGwei,
        sepoliaRPCURL: ChainConfiguration.ethereumSepolia.rpcURL.absoluteString,
        sepoliaArchiveNodeURL: "",
        sepoliaConsensusRPCURL: ChainConfiguration.ethereumSepolia.consensusRPCURL.absoluteString,
        sepoliaMaxFeePerGasGwei: WalletNodeDaemon.GasPolicy.sepolia.maxFeePerGasGwei,
        sepoliaMaxPriorityFeePerGasGwei: WalletNodeDaemon.GasPolicy.sepolia.maxPriorityFeePerGasGwei,
        heliosVerificationEnabled: true,
        autoGasModeEnabled: true,
        autoGasTier: .standard
    )

    static let previousDefaultSepoliaRPCURLs = [
        "https://ethereum-sepolia-rpc.publicnode.com",
    ]
    static let previousDefaultSepoliaConsensusRPCURLs = [
        "https://ethereum-sepolia-beacon-api.publicnode.com",
        "https://lodestar-sepolia.chainsafe.io",
    ]

    var activeChain: ChainConfiguration {
        let base = isTestnetModeEnabled ? ChainConfiguration.ethereumSepolia : ChainConfiguration.ethereum
        return base.overridingNetworkURLs(
            rpcURL: Self.url(from: activeRPCURL) ?? base.rpcURL,
            archiveRPCURL: Self.url(from: activeArchiveNodeURL),
            consensusRPCURL: Self.url(from: activeConsensusRPCURL) ?? base.consensusRPCURL
        )
    }

    var activeNetworkName: String {
        isTestnetModeEnabled ? "Ethereum Sepolia" : "Ethereum"
    }

    var activeRPCURL: String {
        isTestnetModeEnabled ? sepoliaRPCURL : mainnetRPCURL
    }

    var activeArchiveNodeURL: String {
        isTestnetModeEnabled ? sepoliaArchiveNodeURL : mainnetArchiveNodeURL
    }

    var activeConsensusRPCURL: String {
        isTestnetModeEnabled ? sepoliaConsensusRPCURL : mainnetConsensusRPCURL
    }

    var activeGasPolicy: WalletNodeDaemon.GasPolicy {
        let fallback = isTestnetModeEnabled ? WalletNodeDaemon.GasPolicy.sepolia : WalletNodeDaemon.GasPolicy.mainnet
        return (try? WalletNodeDaemon.GasPolicy.custom(
            maxFeePerGasGwei: activeMaxFeePerGasGwei,
            maxPriorityFeePerGasGwei: activeMaxPriorityFeePerGasGwei
        )) ?? fallback
    }

    /// Caps written to the daemon `config.toml` at launch. Manual mode uses the
    /// user's per-chain caps; auto mode uses a generous ceiling (live fee wins).
    var resolvedDaemonGasPolicy: WalletNodeDaemon.GasPolicy {
        autoGasModeEnabled ? WalletNodeDaemon.GasPolicy.autoCeiling : activeGasPolicy
    }

    var activeMaxFeePerGasGwei: String {
        isTestnetModeEnabled ? sepoliaMaxFeePerGasGwei : mainnetMaxFeePerGasGwei
    }

    var activeMaxPriorityFeePerGasGwei: String {
        isTestnetModeEnabled ? sepoliaMaxPriorityFeePerGasGwei : mainnetMaxPriorityFeePerGasGwei
    }

    func validated() throws -> DemoNetworkSettings {
        var settings = self
        settings.mainnetRPCURL = try Self.normalizedRequiredURL(mainnetRPCURL, field: "Mainnet execution RPC")
        settings.mainnetArchiveNodeURL = try Self.normalizedOptionalURL(mainnetArchiveNodeURL, field: "Mainnet archive RPC")
        settings.mainnetConsensusRPCURL = try Self.normalizedDefaultedURL(
            mainnetConsensusRPCURL,
            defaultValue: Self.defaults.mainnetConsensusRPCURL,
            field: "Mainnet consensus RPC"
        )
        let mainnetGasPolicy = try WalletNodeDaemon.GasPolicy.custom(
            maxFeePerGasGwei: mainnetMaxFeePerGasGwei,
            maxPriorityFeePerGasGwei: mainnetMaxPriorityFeePerGasGwei,
            maxField: "Mainnet max fee cap",
            priorityField: "Mainnet priority fee cap"
        )
        settings.mainnetMaxFeePerGasGwei = mainnetGasPolicy.maxFeePerGasGwei
        settings.mainnetMaxPriorityFeePerGasGwei = mainnetGasPolicy.maxPriorityFeePerGasGwei
        settings.sepoliaRPCURL = try Self.normalizedRequiredURL(sepoliaRPCURL, field: "Sepolia execution RPC")
        settings.sepoliaArchiveNodeURL = try Self.normalizedOptionalURL(sepoliaArchiveNodeURL, field: "Sepolia archive RPC")
        settings.sepoliaConsensusRPCURL = try Self.normalizedDefaultedURL(
            sepoliaConsensusRPCURL,
            defaultValue: Self.defaults.sepoliaConsensusRPCURL,
            field: "Sepolia consensus RPC"
        )
        let sepoliaGasPolicy = try WalletNodeDaemon.GasPolicy.custom(
            maxFeePerGasGwei: sepoliaMaxFeePerGasGwei,
            maxPriorityFeePerGasGwei: sepoliaMaxPriorityFeePerGasGwei,
            maxField: "Sepolia max fee cap",
            priorityField: "Sepolia priority fee cap"
        )
        settings.sepoliaMaxFeePerGasGwei = sepoliaGasPolicy.maxFeePerGasGwei
        settings.sepoliaMaxPriorityFeePerGasGwei = sepoliaGasPolicy.maxPriorityFeePerGasGwei
        return settings
    }

    func resettingActiveNetworkToDefaults() -> DemoNetworkSettings {
        // Resets only the active network's endpoints and caps. autoGasModeEnabled /
        // autoGasTier are global preferences and are intentionally preserved here.
        var settings = self
        if isTestnetModeEnabled {
            settings.sepoliaRPCURL = Self.defaults.sepoliaRPCURL
            settings.sepoliaArchiveNodeURL = Self.defaults.sepoliaArchiveNodeURL
            settings.sepoliaConsensusRPCURL = Self.defaults.sepoliaConsensusRPCURL
            settings.sepoliaMaxFeePerGasGwei = Self.defaults.sepoliaMaxFeePerGasGwei
            settings.sepoliaMaxPriorityFeePerGasGwei = Self.defaults.sepoliaMaxPriorityFeePerGasGwei
        } else {
            settings.mainnetRPCURL = Self.defaults.mainnetRPCURL
            settings.mainnetArchiveNodeURL = Self.defaults.mainnetArchiveNodeURL
            settings.mainnetConsensusRPCURL = Self.defaults.mainnetConsensusRPCURL
            settings.mainnetMaxFeePerGasGwei = Self.defaults.mainnetMaxFeePerGasGwei
            settings.mainnetMaxPriorityFeePerGasGwei = Self.defaults.mainnetMaxPriorityFeePerGasGwei
        }
        return settings
    }

    private static func normalizedRequiredURL(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw DemoNetworkSettingsError.invalidRequiredURL(field: field, value: value)
        }
        return url.absoluteString
    }

    private static func normalizedOptionalURL(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw DemoNetworkSettingsError.invalidOptionalURL(field: field, value: value)
        }
        return url.absoluteString
    }

    private static func normalizedDefaultedURL(_ value: String, defaultValue: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return defaultValue
        }
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw DemoNetworkSettingsError.invalidRequiredURL(field: field, value: value)
        }
        return url.absoluteString
    }

    static func defaultingSepoliaRPCURL(_ value: String?) -> String {
        defaultingURL(
            value,
            defaultValue: defaults.sepoliaRPCURL,
            previousDefaultValues: previousDefaultSepoliaRPCURLs
        )
    }

    static func defaultingSepoliaConsensusRPCURL(_ value: String?) -> String {
        defaultingURL(
            value,
            defaultValue: defaults.sepoliaConsensusRPCURL,
            previousDefaultValues: previousDefaultSepoliaConsensusRPCURLs
        )
    }

    private static func defaultingURL(
        _ value: String?,
        defaultValue: String,
        previousDefaultValues: [String]
    ) -> String {
        guard let value else {
            return defaultValue
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return defaultValue
        }
        if previousDefaultValues.contains(trimmed) {
            return defaultValue
        }
        return trimmed
    }

    private static func url(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }
        return URL(string: trimmed)
    }
}

struct DemoSettingsStore {
    private enum Keys {
        static let testnetModeEnabled = "com.localwallet.demo.testnet-mode-enabled"
        static let mainnetRPCURL = "com.localwallet.demo.mainnet-rpc-url"
        static let mainnetArchiveNodeURL = "com.localwallet.demo.mainnet-archive-node-url"
        static let mainnetConsensusRPCURL = "com.localwallet.demo.mainnet-consensus-rpc-url"
        static let mainnetMaxFeePerGasGwei = "com.localwallet.demo.mainnet-max-fee-per-gas-gwei"
        static let mainnetMaxPriorityFeePerGasGwei = "com.localwallet.demo.mainnet-max-priority-fee-per-gas-gwei"
        static let sepoliaRPCURL = "com.localwallet.demo.sepolia-rpc-url"
        static let sepoliaArchiveNodeURL = "com.localwallet.demo.sepolia-archive-node-url"
        static let sepoliaConsensusRPCURL = "com.localwallet.demo.sepolia-consensus-rpc-url"
        static let sepoliaMaxFeePerGasGwei = "com.localwallet.demo.sepolia-max-fee-per-gas-gwei"
        static let sepoliaMaxPriorityFeePerGasGwei = "com.localwallet.demo.sepolia-max-priority-fee-per-gas-gwei"
        static let heliosVerificationEnabled = "com.localwallet.demo.helios-verification-enabled"
        static let autoGasModeEnabled = "com.localwallet.demo.auto-gas-mode-enabled"
        static let autoGasTier = "com.localwallet.demo.auto-gas-tier"
        static let unlockRelayerOnLaunch = "com.localwallet.demo.unlock-relayer-on-launch"
        static let swapSlippageBps = "com.localwallet.demo.swap-slippage-bps"
        static let sessionKeysEnabled = "com.localwallet.demo.session-keys-enabled"
        static let sessionPolicy = "com.localwallet.demo.session-policy"
        static let legacyOnboardingRPCURL = "com.localwallet.demo.onboarding.rpc-url"
        static let legacyOnboardingArchiveNodeURL = "com.localwallet.demo.onboarding.archive-node-url"
        static let legacyOnboardingConsensusRPCURL = "com.localwallet.demo.onboarding.consensus-rpc-url"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isTestnetModeEnabled: Bool {
        if defaults.object(forKey: Keys.testnetModeEnabled) == nil {
            return true
        }
        return defaults.bool(forKey: Keys.testnetModeEnabled)
    }

    func setTestnetModeEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: Keys.testnetModeEnabled)
    }

    var unlockRelayerOnLaunch: Bool {
        if defaults.object(forKey: Keys.unlockRelayerOnLaunch) == nil {
            return true
        }
        return defaults.bool(forKey: Keys.unlockRelayerOnLaunch)
    }

    func setUnlockRelayerOnLaunch(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: Keys.unlockRelayerOnLaunch)
    }

    var swapSlippageBps: UInt64 {
        if defaults.object(forKey: Keys.swapSlippageBps) == nil {
            return SwapSlippage.defaultBps
        }
        let stored = defaults.integer(forKey: Keys.swapSlippageBps)
        return SwapSlippage.clampBps(UInt64(max(0, stored)))
    }

    func setSwapSlippageBps(_ bps: UInt64) {
        defaults.set(Int(SwapSlippage.clampBps(bps)), forKey: Keys.swapSlippageBps)
    }

    var sessionKeysEnabled: Bool {
        defaults.bool(forKey: Keys.sessionKeysEnabled)
    }

    func setSessionKeysEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: Keys.sessionKeysEnabled)
    }

    var sessionPolicy: SessionPolicyConfig {
        guard let data = defaults.data(forKey: Keys.sessionPolicy) else {
            return .default
        }
        guard let decoded = try? JSONDecoder().decode(SessionPolicyConfig.self, from: data),
              let validated = try? decoded.validated()
        else {
            return .default
        }
        return validated
    }

    func setSessionPolicy(_ policy: SessionPolicyConfig) {
        guard let data = try? JSONEncoder().encode(policy) else {
            return
        }
        defaults.set(data, forKey: Keys.sessionPolicy)
    }

    var networkSettings: DemoNetworkSettings {
        DemoNetworkSettings(
            isTestnetModeEnabled: isTestnetModeEnabled,
            mainnetRPCURL: defaults.string(forKey: Keys.mainnetRPCURL) ?? DemoNetworkSettings.defaults.mainnetRPCURL,
            mainnetArchiveNodeURL: defaults.string(forKey: Keys.mainnetArchiveNodeURL) ?? DemoNetworkSettings.defaults.mainnetArchiveNodeURL,
            mainnetConsensusRPCURL: defaults.string(forKey: Keys.mainnetConsensusRPCURL) ?? DemoNetworkSettings.defaults.mainnetConsensusRPCURL,
            mainnetMaxFeePerGasGwei: defaults.string(forKey: Keys.mainnetMaxFeePerGasGwei)
                ?? DemoNetworkSettings.defaults.mainnetMaxFeePerGasGwei,
            mainnetMaxPriorityFeePerGasGwei: defaults.string(forKey: Keys.mainnetMaxPriorityFeePerGasGwei)
                ?? DemoNetworkSettings.defaults.mainnetMaxPriorityFeePerGasGwei,
            sepoliaRPCURL: DemoNetworkSettings.defaultingSepoliaRPCURL(
                defaults.string(forKey: Keys.sepoliaRPCURL)
                    ?? defaults.string(forKey: Keys.legacyOnboardingRPCURL)
            ),
            sepoliaArchiveNodeURL: defaults.string(forKey: Keys.sepoliaArchiveNodeURL)
                ?? defaults.string(forKey: Keys.legacyOnboardingArchiveNodeURL)
                ?? DemoNetworkSettings.defaults.sepoliaArchiveNodeURL,
            sepoliaConsensusRPCURL: DemoNetworkSettings.defaultingSepoliaConsensusRPCURL(
                defaults.string(forKey: Keys.sepoliaConsensusRPCURL)
                    ?? defaults.string(forKey: Keys.legacyOnboardingConsensusRPCURL)
            ),
            sepoliaMaxFeePerGasGwei: defaults.string(forKey: Keys.sepoliaMaxFeePerGasGwei)
                ?? DemoNetworkSettings.defaults.sepoliaMaxFeePerGasGwei,
            sepoliaMaxPriorityFeePerGasGwei: defaults.string(forKey: Keys.sepoliaMaxPriorityFeePerGasGwei)
                ?? DemoNetworkSettings.defaults.sepoliaMaxPriorityFeePerGasGwei,
            heliosVerificationEnabled: defaults.object(forKey: Keys.heliosVerificationEnabled) as? Bool
                ?? DemoNetworkSettings.defaults.heliosVerificationEnabled,
            autoGasModeEnabled: defaults.object(forKey: Keys.autoGasModeEnabled) as? Bool
                ?? DemoNetworkSettings.defaults.autoGasModeEnabled,
            autoGasTier: defaults.string(forKey: Keys.autoGasTier)
                .flatMap(GasTier.init(rawValue:)) ?? .standard
        )
    }

    func setNetworkSettings(_ settings: DemoNetworkSettings) {
        defaults.set(settings.isTestnetModeEnabled, forKey: Keys.testnetModeEnabled)
        defaults.set(settings.mainnetRPCURL, forKey: Keys.mainnetRPCURL)
        defaults.set(settings.mainnetArchiveNodeURL, forKey: Keys.mainnetArchiveNodeURL)
        defaults.set(settings.mainnetConsensusRPCURL, forKey: Keys.mainnetConsensusRPCURL)
        defaults.set(settings.mainnetMaxFeePerGasGwei, forKey: Keys.mainnetMaxFeePerGasGwei)
        defaults.set(settings.mainnetMaxPriorityFeePerGasGwei, forKey: Keys.mainnetMaxPriorityFeePerGasGwei)
        defaults.set(settings.sepoliaRPCURL, forKey: Keys.sepoliaRPCURL)
        defaults.set(settings.sepoliaArchiveNodeURL, forKey: Keys.sepoliaArchiveNodeURL)
        defaults.set(settings.sepoliaConsensusRPCURL, forKey: Keys.sepoliaConsensusRPCURL)
        defaults.set(settings.sepoliaMaxFeePerGasGwei, forKey: Keys.sepoliaMaxFeePerGasGwei)
        defaults.set(settings.sepoliaMaxPriorityFeePerGasGwei, forKey: Keys.sepoliaMaxPriorityFeePerGasGwei)
        defaults.set(settings.heliosVerificationEnabled, forKey: Keys.heliosVerificationEnabled)
        defaults.set(settings.autoGasModeEnabled, forKey: Keys.autoGasModeEnabled)
        defaults.set(settings.autoGasTier.rawValue, forKey: Keys.autoGasTier)
    }
}
