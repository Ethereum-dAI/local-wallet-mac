import Foundation
import Testing
@testable import WalletMacOSApp

private final class StubProbeRuntime: ModelProbeRuntime {
    var loadFailsAbove: Int
    var toolCallSucceeds: Bool
    private(set) var attemptedContexts: [Int] = []

    init(loadFailsAbove: Int = .max, toolCallSucceeds: Bool = true) {
        self.loadFailsAbove = loadFailsAbove
        self.toolCallSucceeds = toolCallSucceeds
    }

    func load(at url: URL, contextTokens: Int) throws {
        attemptedContexts.append(contextTokens)
        if contextTokens > loadFailsAbove {
            throw LocalAIModelSelfTestError.outOfMemory
        }
    }

    func probeToolCall() async throws -> Bool { toolCallSucceeds }
    func unload() {}
}

struct ModelSelfTestTests {
    private let url = URL(fileURLWithPath: "/tmp/model.gguf")

    @Test func readyWhenItLoadsAndCallsATool() async {
        let runtime = StubProbeRuntime()
        let result = await ModelSelfTest(runtime: runtime)
            .run(modelURL: url, requestedContextTokens: 8192, trainedContextTokens: 131_072)
        #expect(result == .ready(contextTokens: 8192))
        #expect(runtime.attemptedContexts == [8192])
    }

    @Test func stepsDownTheLadderUntilItLoads() async {
        let runtime = StubProbeRuntime(loadFailsAbove: 4096)
        let result = await ModelSelfTest(runtime: runtime)
            .run(modelURL: url, requestedContextTokens: 32768, trainedContextTokens: 131_072)
        #expect(result == .steppedDown(from: 32768, to: 4096))
        #expect(runtime.attemptedContexts == [32768, 16384, 8192, 4096])
    }

    @Test func reportsMissingToolSupportSeparatelyFromAFailedLoad() async {
        let runtime = StubProbeRuntime(toolCallSucceeds: false)
        let result = await ModelSelfTest(runtime: runtime)
            .run(modelURL: url, requestedContextTokens: 8192, trainedContextTokens: 32768)
        #expect(result == .noToolSupport)
    }

    @Test func failsWhenEvenTheSmallestPresetWillNotLoad() async {
        let runtime = StubProbeRuntime(loadFailsAbove: 0)
        let result = await ModelSelfTest(runtime: runtime)
            .run(modelURL: url, requestedContextTokens: 8192, trainedContextTokens: 32768)
        if case .failed = result {} else {
            Issue.record("expected .failed, got \(result)")
        }
    }
}
