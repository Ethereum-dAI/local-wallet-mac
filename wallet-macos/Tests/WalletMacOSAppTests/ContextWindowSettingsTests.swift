import Foundation
import Testing
@testable import WalletMacOSApp

struct ContextWindowSettingsTests {
    private func freshStore() -> OnboardingSettingsStore {
        let suite = UserDefaults(suiteName: "context-window-tests-\(UUID().uuidString)")!
        return OnboardingSettingsStore(defaults: suite)
    }

    @Test func defaultsTo4096() {
        #expect(freshStore().contextWindowTokens == 4096)
    }

    @Test func roundTrips() {
        let store = freshStore()
        store.contextWindowTokens = 8192
        let reloaded = OnboardingSettingsStore(defaults: store.defaults)
        #expect(reloaded.contextWindowTokens == 8192)
    }

    @Test func recommendedModelHasContextMax() {
        #expect(LocalAIModel.recommended.maxContextTokens >= 4096)
    }

    @Test func inferenceServiceUsesStoredContextWindow() {
        let suite = UserDefaults(suiteName: "context-window-tests-\(UUID().uuidString)")!
        let store = OnboardingSettingsStore(defaults: suite)
        store.contextWindowTokens = 8192
        let service = EmbeddedLlamaInferenceService(settingsStore: store)
        #expect(service.contextSize == 8192)
    }

    @Test func activeModelURLTracksTheLastSetModel() {
        let suite = UserDefaults(suiteName: "active-model-\(UUID().uuidString)")!
        let service = EmbeddedLlamaInferenceService(settingsStore: OnboardingSettingsStore(defaults: suite))
        #expect(service.activeModelURL == nil)
        service.setActiveModel(url: URL(fileURLWithPath: "/tmp/other.gguf"), contextTokens: 8192)
        #expect(service.activeModelURL?.path == "/tmp/other.gguf")
        #expect(service.contextSize == 8192)
    }
}
