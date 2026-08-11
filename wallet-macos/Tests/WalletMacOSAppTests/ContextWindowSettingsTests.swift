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

    /// Changing the preset used to persist only, so the live runtime kept the
    /// window it was constructed with: the next message still ran at the old size
    /// and "Active: N tokens" still reported it. The picker's copy promises the
    /// next message, so the service has to hear about it.
    @Test func resizingTheContextWindowReachesTheLiveService() {
        let suite = UserDefaults(suiteName: "context-resize-\(UUID().uuidString)")!
        let store = OnboardingSettingsStore(defaults: suite)
        store.contextWindowTokens = 4096
        let service = EmbeddedLlamaInferenceService(settingsStore: store)
        #expect(service.contextSize == 4096)

        service.setContextTokens(16_384)

        #expect(service.contextSize == 16_384)
    }

    /// A resize must not look like a model switch: `prepareRuntime` falls back to
    /// `installedModelPath` when no model was explicitly selected, and inventing a
    /// URL here would pin it to whatever happened to be installed at the time.
    @Test func resizingDoesNotInventAModelSelection() {
        let suite = UserDefaults(suiteName: "context-resize-\(UUID().uuidString)")!
        let service = EmbeddedLlamaInferenceService(settingsStore: OnboardingSettingsStore(defaults: suite))

        service.setContextTokens(16_384)

        #expect(service.activeModelURL == nil)
    }

    /// The mechanism that makes the new size take effect: a context-only change
    /// still counts as needing a swap, so the next `prepareRuntime` reloads.
    @Test func aContextOnlyChangeStillForcesAReload() {
        let url = URL(fileURLWithPath: "/tmp/model.gguf")
        let needsSwap = ModelSwapPlanner.needsSwap(
            loaded: ModelLoadState(modelURL: url, contextTokens: 4096),
            target: ModelSwapTarget(modelURL: url, contextTokens: 16_384)
        )
        #expect(needsSwap)
    }
}
