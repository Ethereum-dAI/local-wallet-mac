import Testing
@testable import WalletMacOSApp

struct SwapSlippageTests {
    @Test func percentToBpsRoundNumbers() {
        #expect(SwapSlippage.bps(fromPercent: 1.0) == 100)
        #expect(SwapSlippage.bps(fromPercent: 0.1) == 10)
        #expect(SwapSlippage.bps(fromPercent: 0.5) == 50)
        #expect(SwapSlippage.bps(fromPercent: 3.0) == 300)
    }

    @Test func bpsToPercent() {
        #expect(SwapSlippage.percent(fromBps: 100) == 1.0)
        #expect(SwapSlippage.percent(fromBps: 10) == 0.1)
    }

    @Test func clampsToDaemonMax() {
        #expect(SwapSlippage.maxBps == 5000)
        #expect(SwapSlippage.bps(fromPercent: 50.0) == 5000)
        #expect(SwapSlippage.bps(fromPercent: 100.0) == 5000) // clamp
        #expect(SwapSlippage.clampBps(9999) == 5000)
        #expect(SwapSlippage.percent(fromBps: 9999) == 50.0)
    }

    @Test func rejectsNonPositiveAndNonFinite() {
        #expect(SwapSlippage.bps(fromPercent: 0.0) == 0)
        #expect(SwapSlippage.bps(fromPercent: -1.0) == 0)
        #expect(SwapSlippage.bps(fromPercent: .nan) == 0)
        #expect(SwapSlippage.bps(fromPercent: .infinity) == 0)
    }

    @Test func defaultsMatchDaemon() {
        #expect(SwapSlippage.defaultBps == 100)
        #expect(SwapSlippage.presetPercents == [0.1, 0.5, 1.0, 3.0])
    }
}
