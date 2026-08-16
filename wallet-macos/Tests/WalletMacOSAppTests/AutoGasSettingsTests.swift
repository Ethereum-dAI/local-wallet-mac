import Foundation
import Testing
@testable import WalletMacOSApp

private func freshStore() -> DemoSettingsStore {
    let suite = UserDefaults(suiteName: "auto-gas-tests-\(UUID().uuidString)")!
    return DemoSettingsStore(defaults: suite)
}

@Test func autoGasDefaultsAreOnAndStandard() {
    let store = freshStore()
    let settings = store.networkSettings
    #expect(settings.autoGasModeEnabled == true)
    #expect(settings.autoGasTier == .standard)
    #expect(settings.heliosVerificationEnabled == true)
}

@Test func defaultSepoliaRPCUsesPublicnodeAndConsensusStartsEmpty() {
    let store = freshStore()

    #expect(store.networkSettings.sepoliaRPCURL == "https://ethereum-sepolia-rpc.publicnode.com")
    #expect(store.networkSettings.sepoliaConsensusRPCURL == "")
    #expect(store.networkSettings.isHeliosVerificationActive == false)
}

/// dRPC put Sepolia behind a paid plan and now fails the daemon's chain-id
/// check, so an install still holding that default cannot start wallet-node at
/// all. The migration is what unbricks it without the user editing Settings.
@Test func previousSepoliaExecutionDefaultMigratesToPublicnode() {
    let suite = UserDefaults(suiteName: "auto-gas-tests-\(UUID().uuidString)")!
    suite.set("https://sepolia.drpc.org", forKey: "com.localwallet.demo.sepolia-rpc-url")
    let store = DemoSettingsStore(defaults: suite)

    #expect(store.networkSettings.sepoliaRPCURL == "https://ethereum-sepolia-rpc.publicnode.com")
}

@Test func previousSepoliaConsensusDefaultsMigrateToEmpty() {
    for previousDefault in DemoNetworkSettings.previousDefaultSepoliaConsensusRPCURLs {
        let suite = UserDefaults(suiteName: "auto-gas-tests-\(UUID().uuidString)")!
        suite.set(
            previousDefault,
            forKey: "com.localwallet.demo.sepolia-consensus-rpc-url"
        )
        let store = DemoSettingsStore(defaults: suite)

        #expect(store.networkSettings.sepoliaConsensusRPCURL == "")
    }
}

@Test func customSepoliaRPCsArePreserved() {
    let suite = UserDefaults(suiteName: "auto-gas-tests-\(UUID().uuidString)")!
    suite.set("https://example.com/execution", forKey: "com.localwallet.demo.sepolia-rpc-url")
    suite.set(
        "https://example.com/beacon",
        forKey: "com.localwallet.demo.sepolia-consensus-rpc-url"
    )
    let store = DemoSettingsStore(defaults: suite)

    #expect(store.networkSettings.sepoliaRPCURL == "https://example.com/execution")
    #expect(store.networkSettings.sepoliaConsensusRPCURL == "https://example.com/beacon")
    #expect(store.networkSettings.isHeliosVerificationActive)
}

@Test func persistedAutoGasOffOverridesDefault() {
    let suite = UserDefaults(suiteName: "auto-gas-tests-\(UUID().uuidString)")!
    suite.set(false, forKey: "com.localwallet.demo.auto-gas-mode-enabled")
    let store = DemoSettingsStore(defaults: suite)

    #expect(store.networkSettings.autoGasModeEnabled == false)
}

@Test func autoGasSettingsRoundTrip() {
    let store = freshStore()
    var settings = store.networkSettings
    settings.autoGasModeEnabled = true
    settings.autoGasTier = .fast
    settings.heliosVerificationEnabled = false
    store.setNetworkSettings(settings)

    let reloaded = store.networkSettings
    #expect(reloaded.autoGasModeEnabled == true)
    #expect(reloaded.autoGasTier == .fast)
    #expect(reloaded.heliosVerificationEnabled == false)
}

@Test func unknownPersistedTierFallsBackToStandard() {
    let suite = UserDefaults(suiteName: "auto-gas-tests-\(UUID().uuidString)")!
    suite.set("turbo", forKey: "com.localwallet.demo.auto-gas-tier")
    let store = DemoSettingsStore(defaults: suite)
    #expect(store.networkSettings.autoGasTier == .standard)
}

@Test func togglingAutoPreservesManualCapValues() {
    let store = freshStore()
    var settings = store.networkSettings
    settings.sepoliaMaxFeePerGasGwei = "73"
    settings.sepoliaMaxPriorityFeePerGasGwei = "7"
    settings.autoGasModeEnabled = true
    store.setNetworkSettings(settings)

    let reloaded = store.networkSettings
    #expect(reloaded.sepoliaMaxFeePerGasGwei == "73")
    #expect(reloaded.sepoliaMaxPriorityFeePerGasGwei == "7")
}

@Test func resolvedDaemonGasPolicyUsesManualCapsWhenAutoOff() {
    var settings = DemoNetworkSettings.defaults
    settings.autoGasModeEnabled = false
    settings.sepoliaMaxFeePerGasGwei = "50"
    settings.sepoliaMaxPriorityFeePerGasGwei = "5"
    #expect(settings.resolvedDaemonGasPolicy.maxFeePerGas == settings.activeGasPolicy.maxFeePerGas)
}

@Test func resolvedDaemonGasPolicyUsesImmutableCeilingWhenAutoOn() {
    var settings = DemoNetworkSettings.defaults
    settings.autoGasModeEnabled = true
    #expect(settings.resolvedDaemonGasPolicy.maxFeePerGas == WalletNodeDaemon.GasPolicy.autoCeiling.maxFeePerGas)
}

@Test func autoGasTierChangeDoesNotRequireWalletNodeRestart() {
    var old = DemoNetworkSettings.defaults
    old.autoGasModeEnabled = true
    old.autoGasTier = .standard
    var new = old
    new.autoGasTier = .fast

    #expect(NetworkSettingsChangePolicy.requiresWalletNodeRestart(from: old, to: new) == false)
}

@Test func gasPolicyModeChangeDoesNotRestartWhenDaemonCapsAreIdentical() {
    var old = DemoNetworkSettings.defaults
    old.autoGasModeEnabled = false
    var new = old
    new.autoGasModeEnabled = true

    #expect(NetworkSettingsChangePolicy.requiresWalletNodeRestart(from: old, to: new) == false)
}

@Test func gasPolicyModeChangeRestartsWhenDaemonCapsActuallyChange() {
    var old = DemoNetworkSettings.defaults
    old.autoGasModeEnabled = false
    old.sepoliaMaxFeePerGasGwei = "40"
    old.sepoliaMaxPriorityFeePerGasGwei = "4"
    var new = old
    new.autoGasModeEnabled = true

    #expect(NetworkSettingsChangePolicy.requiresWalletNodeRestart(from: old, to: new))
}

@Test func heliosVerificationChangeRequiresWalletNodeRestart() {
    var old = DemoNetworkSettings.defaults
    old.heliosVerificationEnabled = true
    var new = old
    new.heliosVerificationEnabled = false

    #expect(NetworkSettingsChangePolicy.requiresWalletNodeRestart(from: old, to: new))
}

@Test func addingConsensusRPCRequiresHeliosCheckpointResync() {
    var old = DemoNetworkSettings.defaults
    old.sepoliaConsensusRPCURL = ""
    var new = old
    new.sepoliaConsensusRPCURL = "https://example.com/beacon"

    #expect(NetworkSettingsChangePolicy.requiresHeliosCheckpointResync(from: old, to: new))
}

@Test func changingConsensusRPCRequiresHeliosCheckpointResync() {
    var old = DemoNetworkSettings.defaults
    old.sepoliaConsensusRPCURL = "https://example.com/beacon-a"
    var new = old
    new.sepoliaConsensusRPCURL = "https://example.com/beacon-b"

    #expect(NetworkSettingsChangePolicy.requiresHeliosCheckpointResync(from: old, to: new))
}

@Test func clearingConsensusRPCDoesNotRequireHeliosCheckpointResync() {
    var old = DemoNetworkSettings.defaults
    old.sepoliaConsensusRPCURL = "https://example.com/beacon"
    var new = old
    new.sepoliaConsensusRPCURL = ""

    #expect(NetworkSettingsChangePolicy.requiresHeliosCheckpointResync(from: old, to: new) == false)
}

@Test func changingExecutionRPCOnlyDoesNotRequireHeliosCheckpointResync() {
    var old = DemoNetworkSettings.defaults
    old.sepoliaConsensusRPCURL = "https://example.com/beacon"
    var new = old
    new.sepoliaRPCURL = "https://example.com/execution"

    #expect(NetworkSettingsChangePolicy.requiresHeliosCheckpointResync(from: old, to: new) == false)
}

@Test func autoCeilingMatchesImmutableAppCap() {
    let ceiling = WalletNodeDaemon.GasPolicy.autoCeiling
    // Priority must not exceed max, and daemon defense in depth matches the app boundary.
    #expect(GasPricing.minWei(
        (try? Data.quantityString(ceiling.maxPriorityFeePerGas)) ?? Data(),
        (try? Data.quantityString(ceiling.maxFeePerGas)) ?? Data()
    ) == ((try? Data.quantityString(ceiling.maxPriorityFeePerGas).leftPadded(to: 32)) ?? Data()))
    #expect(ceiling.maxFeePerGasGwei == "50")
    #expect(ceiling.maxPriorityFeePerGasGwei == "5")
}

@Test func appNetworkIsAlwaysSepolia() {
    let settings = DemoNetworkSettings.defaults

    #expect(settings.activeChain.id == 11_155_111)
    #expect(settings.activeNetworkName == "Ethereum Sepolia")
    #expect(WalletTokenRegistry.tokens(on: 1).isEmpty)
    #expect(SessionSwapRouterRegistry.routers(on: 1).isEmpty)
}
