import Foundation
import Testing
@testable import WalletMacOSApp

/// Wiring tests for the Task 10 settings-correctness audit.
///
/// These prove the *actual* runtime behavior of two suspicions raised during the
/// audit, so the matrix doc is backed by executable evidence rather than a read of
/// the source alone.
struct SettingsWiringAuditTests {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "settings-audit-\(UUID().uuidString)")!
    }

    /// Suspicion A — the legacy onboarding RPC key
    /// (`com.localwallet.demo.onboarding.rpc-url`) is read as a fallback inside
    /// `DemoSettingsStore.networkSettings`. It feeds the **Sepolia** execution RPC
    /// (via `defaultingSepoliaRPCURL`) and only when the primary
    /// `com.localwallet.demo.sepolia-rpc-url` key is unset. Because testnet mode
    /// defaults to ON, that value also surfaces as the *active* execution RPC.
    @Test func legacyOnboardingRPCFallsBackIntoSepoliaNetworkSettings() {
        let defaults = suite()
        defaults.set("https://example.test/rpc", forKey: "com.localwallet.demo.onboarding.rpc-url")
        let store = DemoSettingsStore(defaults: defaults)
        let settings = store.networkSettings

        // The fallback feeds the Sepolia execution RPC...
        #expect(settings.sepoliaRPCURL == "https://example.test/rpc")
        // ...and, since testnet mode defaults to ON, it is the active RPC.
        #expect(settings.isTestnetModeEnabled == true)
        #expect(settings.activeRPCURL == "https://example.test/rpc")
        // It must NOT leak into the mainnet RPC, which keeps its own default.
        #expect(settings.mainnetRPCURL == DemoNetworkSettings.defaults.mainnetRPCURL)
    }

    /// The fallback is only consulted when the primary Sepolia key is absent. Once
    /// the user has saved a Sepolia RPC explicitly, the legacy onboarding value is
    /// ignored (the `?? legacyOnboardingRPCURL` branch is never reached).
    @Test func explicitSepoliaRPCOverridesLegacyOnboardingFallback() {
        let defaults = suite()
        defaults.set("https://example.test/rpc", forKey: "com.localwallet.demo.onboarding.rpc-url")
        defaults.set("https://primary.test/rpc", forKey: "com.localwallet.demo.sepolia-rpc-url")
        let settings = DemoSettingsStore(defaults: defaults).networkSettings

        #expect(settings.sepoliaRPCURL == "https://primary.test/rpc")
        #expect(settings.activeRPCURL == "https://primary.test/rpc")
    }

    /// Suspicion B — model selection drives install, not runtime. The runtime model
    /// path comes from `installedModelPath`, while `selectedModelID` only steers the
    /// download/install pipeline. With a single-model catalog this is by design.
    /// Asserting the catalog invariant guards that "single model" assumption: if a
    /// second model is ever added, this test fails and forces a re-evaluation of the
    /// selection-vs-runtime split documented in the matrix.
    @Test func modelCatalogIsSingleModelSoSelectionDrivesInstallNotRuntime() {
        #expect(LocalAIModel.available.count == 1)
        #expect(LocalAIModel.available.first?.id == LocalAIModel.recommended.id)
    }
}
