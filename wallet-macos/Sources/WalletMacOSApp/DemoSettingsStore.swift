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
    var sepoliaRPCURL: String
    var sepoliaArchiveNodeURL: String
    var sepoliaConsensusRPCURL: String

    static let defaults = DemoNetworkSettings(
        isTestnetModeEnabled: true,
        mainnetRPCURL: ChainConfiguration.ethereum.rpcURL.absoluteString,
        mainnetArchiveNodeURL: "",
        mainnetConsensusRPCURL: ChainConfiguration.ethereum.consensusRPCURL.absoluteString,
        sepoliaRPCURL: ChainConfiguration.ethereumSepolia.rpcURL.absoluteString,
        sepoliaArchiveNodeURL: "",
        sepoliaConsensusRPCURL: ChainConfiguration.ethereumSepolia.consensusRPCURL.absoluteString
    )

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

    func validated() throws -> DemoNetworkSettings {
        var settings = self
        settings.mainnetRPCURL = try Self.normalizedRequiredURL(mainnetRPCURL, field: "Mainnet execution RPC")
        settings.mainnetArchiveNodeURL = try Self.normalizedOptionalURL(mainnetArchiveNodeURL, field: "Mainnet archive RPC")
        settings.mainnetConsensusRPCURL = try Self.normalizedRequiredURL(mainnetConsensusRPCURL, field: "Mainnet consensus RPC")
        settings.sepoliaRPCURL = try Self.normalizedRequiredURL(sepoliaRPCURL, field: "Sepolia execution RPC")
        settings.sepoliaArchiveNodeURL = try Self.normalizedOptionalURL(sepoliaArchiveNodeURL, field: "Sepolia archive RPC")
        settings.sepoliaConsensusRPCURL = try Self.normalizedRequiredURL(sepoliaConsensusRPCURL, field: "Sepolia consensus RPC")
        return settings
    }

    func resettingActiveNetworkToDefaults() -> DemoNetworkSettings {
        var settings = self
        if isTestnetModeEnabled {
            settings.sepoliaRPCURL = Self.defaults.sepoliaRPCURL
            settings.sepoliaArchiveNodeURL = Self.defaults.sepoliaArchiveNodeURL
            settings.sepoliaConsensusRPCURL = Self.defaults.sepoliaConsensusRPCURL
        } else {
            settings.mainnetRPCURL = Self.defaults.mainnetRPCURL
            settings.mainnetArchiveNodeURL = Self.defaults.mainnetArchiveNodeURL
            settings.mainnetConsensusRPCURL = Self.defaults.mainnetConsensusRPCURL
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
        static let sepoliaRPCURL = "com.localwallet.demo.sepolia-rpc-url"
        static let sepoliaArchiveNodeURL = "com.localwallet.demo.sepolia-archive-node-url"
        static let sepoliaConsensusRPCURL = "com.localwallet.demo.sepolia-consensus-rpc-url"
        static let unlockRelayerOnLaunch = "com.localwallet.demo.unlock-relayer-on-launch"
        static let legacyOnboardingRPCURL = "com.localwallet.demo.onboarding.rpc-url"
        static let legacyOnboardingArchiveNodeURL = "com.localwallet.demo.onboarding.archive-node-url"
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

    var networkSettings: DemoNetworkSettings {
        DemoNetworkSettings(
            isTestnetModeEnabled: isTestnetModeEnabled,
            mainnetRPCURL: defaults.string(forKey: Keys.mainnetRPCURL) ?? DemoNetworkSettings.defaults.mainnetRPCURL,
            mainnetArchiveNodeURL: defaults.string(forKey: Keys.mainnetArchiveNodeURL) ?? DemoNetworkSettings.defaults.mainnetArchiveNodeURL,
            mainnetConsensusRPCURL: defaults.string(forKey: Keys.mainnetConsensusRPCURL) ?? DemoNetworkSettings.defaults.mainnetConsensusRPCURL,
            sepoliaRPCURL: defaults.string(forKey: Keys.sepoliaRPCURL)
                ?? defaults.string(forKey: Keys.legacyOnboardingRPCURL)
                ?? DemoNetworkSettings.defaults.sepoliaRPCURL,
            sepoliaArchiveNodeURL: defaults.string(forKey: Keys.sepoliaArchiveNodeURL)
                ?? defaults.string(forKey: Keys.legacyOnboardingArchiveNodeURL)
                ?? DemoNetworkSettings.defaults.sepoliaArchiveNodeURL,
            sepoliaConsensusRPCURL: defaults.string(forKey: Keys.sepoliaConsensusRPCURL) ?? DemoNetworkSettings.defaults.sepoliaConsensusRPCURL
        )
    }

    func setNetworkSettings(_ settings: DemoNetworkSettings) {
        defaults.set(settings.isTestnetModeEnabled, forKey: Keys.testnetModeEnabled)
        defaults.set(settings.mainnetRPCURL, forKey: Keys.mainnetRPCURL)
        defaults.set(settings.mainnetArchiveNodeURL, forKey: Keys.mainnetArchiveNodeURL)
        defaults.set(settings.mainnetConsensusRPCURL, forKey: Keys.mainnetConsensusRPCURL)
        defaults.set(settings.sepoliaRPCURL, forKey: Keys.sepoliaRPCURL)
        defaults.set(settings.sepoliaArchiveNodeURL, forKey: Keys.sepoliaArchiveNodeURL)
        defaults.set(settings.sepoliaConsensusRPCURL, forKey: Keys.sepoliaConsensusRPCURL)
    }
}
