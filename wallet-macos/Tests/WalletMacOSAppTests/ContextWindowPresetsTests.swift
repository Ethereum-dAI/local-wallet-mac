import Testing
@testable import WalletMacOSApp

struct ContextWindowPresetsTests {
    @Test func optionsFilterByModelMax() {
        #expect(ContextWindowPresets.options(maxTokens: 32768) == [2048, 4096, 8192, 16384, 32768])
        #expect(ContextWindowPresets.options(maxTokens: 8192) == [2048, 4096, 8192])
    }

    @Test func optionsAppendNonLadderMax() {
        #expect(ContextWindowPresets.options(maxTokens: 10000) == [2048, 4096, 8192, 10000])
    }

    @Test func optionsNeverEmpty() {
        #expect(ContextWindowPresets.options(maxTokens: 1000) == [2048])
    }

    @Test func clampSnapsToAllowedOption() {
        #expect(ContextWindowPresets.clamp(4096, maxTokens: 32768) == 4096)
        #expect(ContextWindowPresets.clamp(99999, maxTokens: 32768) == 32768) // over max
        #expect(ContextWindowPresets.clamp(3000, maxTokens: 32768) == 2048)   // between rungs
        #expect(ContextWindowPresets.clamp(0, maxTokens: 32768) == 2048)
    }
}
