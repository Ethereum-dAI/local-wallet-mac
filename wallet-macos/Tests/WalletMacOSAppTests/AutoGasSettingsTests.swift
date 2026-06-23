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

@Test func defaultSepoliaRPCsUseDrpcAndNimbus() {
    let store = freshStore()

    #expect(store.networkSettings.sepoliaRPCURL == "https://sepolia.drpc.org")
    #expect(store.networkSettings.sepoliaConsensusRPCURL == "http://unstable.sepolia.beacon-api.nimbus.team")
}

@Test func previousSepoliaExecutionDefaultMigratesToDrpc() {
    let suite = UserDefaults(suiteName: "auto-gas-tests-\(UUID().uuidString)")!
    suite.set(
        DemoNetworkSettings.previousDefaultSepoliaRPCURLs[0],
        forKey: "com.localwallet.demo.sepolia-rpc-url"
    )
    let store = DemoSettingsStore(defaults: suite)

    #expect(store.networkSettings.sepoliaRPCURL == "https://sepolia.drpc.org")
}

@Test func previousSepoliaConsensusDefaultsMigrateToNimbus() {
    for previousDefault in DemoNetworkSettings.previousDefaultSepoliaConsensusRPCURLs {
        let suite = UserDefaults(suiteName: "auto-gas-tests-\(UUID().uuidString)")!
        suite.set(
            previousDefault,
            forKey: "com.localwallet.demo.sepolia-consensus-rpc-url"
        )
        let store = DemoSettingsStore(defaults: suite)

        #expect(store.networkSettings.sepoliaConsensusRPCURL == "http://unstable.sepolia.beacon-api.nimbus.team")
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
    settings.isTestnetModeEnabled = true
    settings.autoGasModeEnabled = false
    settings.sepoliaMaxFeePerGasGwei = "50"
    settings.sepoliaMaxPriorityFeePerGasGwei = "5"
    #expect(settings.resolvedDaemonGasPolicy.maxFeePerGas == settings.activeGasPolicy.maxFeePerGas)
}

@Test func resolvedDaemonGasPolicyUsesGenerousCeilingWhenAutoOn() {
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

@Test func gasPolicyModeChangeRequiresWalletNodeRestart() {
    var old = DemoNetworkSettings.defaults
    old.autoGasModeEnabled = false
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

@Test func inactiveNetworkGasChangeDoesNotRequireWalletNodeRestart() {
    var old = DemoNetworkSettings.defaults
    old.isTestnetModeEnabled = true
    var new = old
    new.mainnetMaxFeePerGasGwei = "123"

    #expect(NetworkSettingsChangePolicy.requiresWalletNodeRestart(from: old, to: new) == false)
}

@Test func autoCeilingIsValidAndGenerous() {
    let ceiling = WalletNodeDaemon.GasPolicy.autoCeiling
    // priority <= max, and far above the mainnet default (10 gwei).
    #expect(GasPricing.minWei(
        (try? Data.quantityString(ceiling.maxPriorityFeePerGas)) ?? Data(),
        (try? Data.quantityString(ceiling.maxFeePerGas)) ?? Data()
    ) == ((try? Data.quantityString(ceiling.maxPriorityFeePerGas).leftPadded(to: 32)) ?? Data()))
    #expect(Int(ceiling.maxFeePerGasGwei) ?? 0 >= 1000)
}
