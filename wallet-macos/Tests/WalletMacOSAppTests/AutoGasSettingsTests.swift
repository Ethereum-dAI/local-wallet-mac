import Foundation
import Testing
@testable import WalletMacOSApp

private func freshStore() -> DemoSettingsStore {
    let suite = UserDefaults(suiteName: "auto-gas-tests-\(UUID().uuidString)")!
    return DemoSettingsStore(defaults: suite)
}

@Test func autoGasDefaultsAreOffAndStandard() {
    let store = freshStore()
    let settings = store.networkSettings
    #expect(settings.autoGasModeEnabled == false)
    #expect(settings.autoGasTier == .standard)
}

@Test func autoGasSettingsRoundTrip() {
    let store = freshStore()
    var settings = store.networkSettings
    settings.autoGasModeEnabled = true
    settings.autoGasTier = .fast
    store.setNetworkSettings(settings)

    let reloaded = store.networkSettings
    #expect(reloaded.autoGasModeEnabled == true)
    #expect(reloaded.autoGasTier == .fast)
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

@Test func autoCeilingIsValidAndGenerous() {
    let ceiling = WalletNodeDaemon.GasPolicy.autoCeiling
    // priority <= max, and far above the mainnet default (10 gwei).
    #expect(GasPricing.minWei(
        (try? Data.quantityString(ceiling.maxPriorityFeePerGas)) ?? Data(),
        (try? Data.quantityString(ceiling.maxFeePerGas)) ?? Data()
    ) == ((try? Data.quantityString(ceiling.maxPriorityFeePerGas).leftPadded(to: 32)) ?? Data()))
    #expect(Int(ceiling.maxFeePerGasGwei) ?? 0 >= 1000)
}

@Test func parseBaseFeeReadsBaseFeePerGas() throws {
    let result: Any = ["baseFeePerGas": "0x3b9aca00", "number": "0x10"] // 1 gwei
    let data = try WalletNodeClient.parseBaseFee(result)
    #expect(GasPricing.gweiText(fromWei: data) == "1")
}

@Test func parseBaseFeeThrowsWhenMissing() {
    let result: Any = ["number": "0x10"]
    #expect(throws: (any Error).self) {
        _ = try WalletNodeClient.parseBaseFee(result)
    }
}
