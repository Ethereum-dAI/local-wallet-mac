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
    var sepoliaRPCURL: String
    var sepoliaArchiveNodeURL: String
    var sepoliaConsensusRPCURL: String
    var sepoliaMaxFeePerGasGwei: String
    var sepoliaMaxPriorityFeePerGasGwei: String
    var heliosVerificationEnabled: Bool
    var autoGasModeEnabled: Bool
    var autoGasTier: GasTier

    static let defaults = DemoNetworkSettings(
        sepoliaRPCURL: ChainConfiguration.ethereumSepolia.rpcURL.absoluteString,
        sepoliaArchiveNodeURL: "",
        sepoliaConsensusRPCURL: "",
        sepoliaMaxFeePerGasGwei: WalletNodeDaemon.GasPolicy.sepolia.maxFeePerGasGwei,
        sepoliaMaxPriorityFeePerGasGwei: WalletNodeDaemon.GasPolicy.sepolia.maxPriorityFeePerGasGwei,
        heliosVerificationEnabled: true,
        autoGasModeEnabled: true,
        autoGasTier: .standard
    )

    /// Anyone still pointing at a superseded default is moved to the current
    /// one on the next launch; a URL the user typed themselves is left alone.
    /// dRPC is here because it began answering `eth_chainId` with HTTP 400
    /// ("chain is not available on free plan"), which stops the daemon booting
    /// at all — an install left on it is bricked until this migration runs.
    static let previousDefaultSepoliaRPCURLs = [
        "https://sepolia.drpc.org",
    ]
    static let previousDefaultSepoliaConsensusRPCURLs = [
        "http://unstable.sepolia.beacon-api.nimbus.team",
        "https://ethereum-sepolia-beacon-api.publicnode.com",
        "https://lodestar-sepolia.chainsafe.io",
    ]

    var activeChain: ChainConfiguration {
        let base = ChainConfiguration.ethereumSepolia
        return base.overridingNetworkURLs(
            rpcURL: Self.url(from: activeRPCURL) ?? base.rpcURL,
            archiveRPCURL: Self.url(from: activeArchiveNodeURL),
            consensusRPCURL: Self.url(from: activeConsensusRPCURL)
        )
    }

    var isActiveConsensusRPCConfigured: Bool {
        activeConsensusRPCURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var isHeliosVerificationActive: Bool {
        heliosVerificationEnabled && isActiveConsensusRPCConfigured
    }

    var activeNetworkName: String {
        "Ethereum Sepolia"
    }

    var activeRPCURL: String {
        sepoliaRPCURL
    }

    var activeArchiveNodeURL: String {
        sepoliaArchiveNodeURL
    }

    var activeConsensusRPCURL: String {
        sepoliaConsensusRPCURL
    }

    var activeGasPolicy: WalletNodeDaemon.GasPolicy {
        return (try? WalletNodeDaemon.GasPolicy.custom(
            maxFeePerGasGwei: activeMaxFeePerGasGwei,
            maxPriorityFeePerGasGwei: activeMaxPriorityFeePerGasGwei
        )) ?? .sepolia
    }

    /// Caps written to the daemon `config.toml` at launch. Manual mode uses the
    /// user's per-chain caps; auto mode uses a generous ceiling (live fee wins).
    var resolvedDaemonGasPolicy: WalletNodeDaemon.GasPolicy {
        autoGasModeEnabled ? WalletNodeDaemon.GasPolicy.autoCeiling : activeGasPolicy
    }

    var activeMaxFeePerGasGwei: String {
        sepoliaMaxFeePerGasGwei
    }

    var activeMaxPriorityFeePerGasGwei: String {
        sepoliaMaxPriorityFeePerGasGwei
    }

    func validated() throws -> DemoNetworkSettings {
        var settings = self
        settings.sepoliaRPCURL = try Self.normalizedRequiredURL(sepoliaRPCURL, field: "Sepolia execution RPC")
        settings.sepoliaArchiveNodeURL = try Self.normalizedOptionalURL(sepoliaArchiveNodeURL, field: "Sepolia archive RPC")
        settings.sepoliaConsensusRPCURL = try Self.normalizedOptionalURL(sepoliaConsensusRPCURL, field: "Sepolia consensus RPC")
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
        // Auto-gas preferences are global and intentionally preserved here.
        var settings = self
        settings.sepoliaRPCURL = Self.defaults.sepoliaRPCURL
        settings.sepoliaArchiveNodeURL = Self.defaults.sepoliaArchiveNodeURL
        settings.sepoliaConsensusRPCURL = Self.defaults.sepoliaConsensusRPCURL
        settings.sepoliaMaxFeePerGasGwei = Self.defaults.sepoliaMaxFeePerGasGwei
        settings.sepoliaMaxPriorityFeePerGasGwei = Self.defaults.sepoliaMaxPriorityFeePerGasGwei
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
        static let sepoliaRPCURL = "com.localwallet.demo.sepolia-rpc-url"
        static let sepoliaArchiveNodeURL = "com.localwallet.demo.sepolia-archive-node-url"
        static let sepoliaConsensusRPCURL = "com.localwallet.demo.sepolia-consensus-rpc-url"
        static let sepoliaMaxFeePerGasGwei = "com.localwallet.demo.sepolia-max-fee-per-gas-gwei"
        static let sepoliaMaxPriorityFeePerGasGwei = "com.localwallet.demo.sepolia-max-priority-fee-per-gas-gwei"
        static let heliosVerificationEnabled = "com.localwallet.demo.helios-verification-enabled"
        static let autoGasModeEnabled = "com.localwallet.demo.auto-gas-mode-enabled"
        static let autoGasTier = "com.localwallet.demo.auto-gas-tier"
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
