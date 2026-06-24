import Foundation
import Testing
@testable import WalletMacOSApp

struct SwapSlippageSettingsTests {
    private func freshStore() -> DemoSettingsStore {
        let suite = UserDefaults(suiteName: "swap-slippage-tests-\(UUID().uuidString)")!
        return DemoSettingsStore(defaults: suite)
    }

    @Test func defaultsToOnePercent() {
        #expect(freshStore().swapSlippageBps == 100)
    }

    @Test func roundTrips() {
        let store = freshStore()
        store.setSwapSlippageBps(300)
        let reloaded = DemoSettingsStore(defaults: store.defaults)
        #expect(reloaded.swapSlippageBps == 300)
    }

    @Test func clampsAboveDaemonMaxOnWrite() {
        let store = freshStore()
        store.setSwapSlippageBps(9999)
        #expect(store.swapSlippageBps == 5000)
    }
}
