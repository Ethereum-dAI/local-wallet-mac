import Foundation
import Testing
@testable import WalletMacOSApp

struct ModelSwapPlannerTests {
    private let modelA = URL(fileURLWithPath: "/tmp/model-a.gguf")
    private let modelB = URL(fileURLWithPath: "/tmp/model-b.gguf")

    @Test func unchangedModelAndContextNeedsNoSwap() {
        let loaded = ModelLoadState(modelURL: modelA, contextTokens: 8192)
        let target = ModelSwapTarget(modelURL: modelA, contextTokens: 8192)
        #expect(ModelSwapPlanner.needsSwap(loaded: loaded, target: target) == false)
    }

    @Test func changedContextSameModelNeedsSwap() {
        let loaded = ModelLoadState(modelURL: modelA, contextTokens: 8192)
        let target = ModelSwapTarget(modelURL: modelA, contextTokens: 4096)
        #expect(ModelSwapPlanner.needsSwap(loaded: loaded, target: target) == true)
    }

    @Test func changedModelSameContextNeedsSwap() {
        let loaded = ModelLoadState(modelURL: modelA, contextTokens: 8192)
        let target = ModelSwapTarget(modelURL: modelB, contextTokens: 8192)
        #expect(ModelSwapPlanner.needsSwap(loaded: loaded, target: target) == true)
    }

    @Test func firstCallWithNothingLoadedNeedsSwap() {
        let loaded = ModelLoadState(modelURL: nil, contextTokens: nil)
        let target = ModelSwapTarget(modelURL: modelA, contextTokens: 8192)
        #expect(ModelSwapPlanner.needsSwap(loaded: loaded, target: target) == true)
    }

    @Test func commitSucceedsWhenTheDesireDidNotChangeDuringTheLoad() {
        let target = ModelSwapTarget(modelURL: modelA, contextTokens: 8192)
        let desire = DesiredModel(modelURL: modelA, contextTokens: 8192)
        let committed = ModelSwapPlanner.commit(justLoaded: target, desiredAtLoadStart: desire, desiredNow: desire)
        #expect(committed == ModelLoadState(modelURL: modelA, contextTokens: 8192))
    }

    /// Finding 1's regression: `setActiveModel(url: B, ...)` lands while model A is
    /// still loading. The A-load must not be committed as current, and the next
    /// swap decision must still target B rather than being fooled into thinking A
    /// is already current.
    @Test func aDesireThatChangesDuringALoadIsNotCommittedAndTheNextDecisionStillTargetsTheNewDesire() {
        let justLoaded = ModelSwapTarget(modelURL: modelA, contextTokens: 8192)
        let desiredAtLoadStart = DesiredModel(modelURL: modelA, contextTokens: 8192)
        let desiredNow = DesiredModel(modelURL: modelB, contextTokens: 8192)

        let committed = ModelSwapPlanner.commit(
            justLoaded: justLoaded,
            desiredAtLoadStart: desiredAtLoadStart,
            desiredNow: desiredNow
        )
        #expect(committed == nil)

        // The service's tracked "loaded" state is therefore left exactly as it was
        // before this load (still nothing, in this scenario) — so the very next
        // decision correctly targets B, not the just-finished-but-abandoned A.
        let stillNothingLoaded = ModelLoadState(modelURL: nil, contextTokens: nil)
        let nextTarget = ModelSwapTarget(modelURL: modelB, contextTokens: 8192)
        #expect(ModelSwapPlanner.needsSwap(loaded: stillNothingLoaded, target: nextTarget) == true)
    }
}
