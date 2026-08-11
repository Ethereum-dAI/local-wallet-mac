import Foundation
import Testing
@testable import WalletMacOSApp

struct HardwareBudgetTests {
    private let gb: UInt64 = 1_073_741_824

    @Test func usableIsMetalBudgetWhenItIsTheTighterBound() {
        // 36 GB Mac: Metal reports 28.1 GB, RAM − 8 GB = 28 GB.
        let budget = HardwareBudget(
            totalMemoryBytes: 36 * gb,
            metalBudgetBytes: 30_182_211_584,
            freeDiskBytes: 200 * gb
        )
        #expect(budget.usableBytes == 28 * gb)
    }

    @Test func usableIsRamMinusReserveWhenMetalIsGenerous() {
        // 16 GB: reserve is 40% (6.4 GiB), leaving 9.6 GiB — tighter than Metal's 14 GiB.
        let budget = HardwareBudget(
            totalMemoryBytes: 16 * gb,
            metalBudgetBytes: 14 * gb,
            freeDiskBytes: 100 * gb
        )
        #expect(budget.usableBytes == 10_307_921_544)
    }

    /// The reserve scales so small machines keep a workable budget instead of zero.
    /// An 8 GB Air: Metal offers ~6 GiB, reserve is 3.2 GiB, so 4.8 GiB is usable.
    @Test func eightGigMacKeepsANonZeroBudget() {
        let budget = HardwareBudget(
            totalMemoryBytes: 8 * gb,
            metalBudgetBytes: 6 * gb,
            freeDiskBytes: 100 * gb
        )
        #expect(budget.usableBytes == 5_153_960_792)
    }

    @Test func reserveIsCappedAtEightGigabytesOnLargeMachines() {
        #expect(HardwareBudget.systemReserveBytes(totalMemoryBytes: 128 * gb) == 8 * gb)
        #expect(HardwareBudget.systemReserveBytes(totalMemoryBytes: 8 * gb) < 8 * gb)
    }

    @Test func comfortableIsEightyPercentOfUsable() {
        let budget = HardwareBudget(
            totalMemoryBytes: 36 * gb,
            metalBudgetBytes: 30_182_211_584,
            freeDiskBytes: 200 * gb
        )
        #expect(budget.comfortableBytes == (28 * gb) / 100 * 80)
    }

    @Test func liveInspectionReportsPlausibleNumbers() async {
        let budget = await LocalHardwareInspector().budget()
        #expect(budget.totalMemoryBytes > 0)
        #expect(budget.metalBudgetBytes > 0)
        #expect(budget.metalBudgetBytes <= budget.totalMemoryBytes)
        #expect(budget.freeDiskBytes > 0)
    }
}
