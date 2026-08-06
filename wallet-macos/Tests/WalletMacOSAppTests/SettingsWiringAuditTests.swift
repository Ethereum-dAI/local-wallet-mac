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

    /// Suspicion B, resolved. Selection used to drive install only, which was safe
    /// while the catalog held exactly one model. It no longer does: the catalog is
    /// user-extensible, so selection drives the runtime through
    /// `InstalledModelStore` + `EmbeddedLlamaInferenceService.setActiveModel`.
    /// What must stay true is that the shipped default is unchanged.
    @Test func defaultModelIsStillGemmaQ4() {
        #expect(LocalAIModel.recommended.id == "google/gemma-4-E4B-it")
        #expect(LocalAIModel.recommended.artifactFileName == "gemma-4-E4B-it-Q4_0.gguf")
        #expect(LocalAIModel.available.first?.id == LocalAIModel.recommended.id)
    }
}
