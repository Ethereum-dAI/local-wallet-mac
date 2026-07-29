import Foundation
import Testing
@testable import WalletMacOSApp

/// Coalescing floor for the event-driven balance reads. `AppModel` itself has no test seam for the
/// read, but this boundary is where the "don't hit the chain twice for one user action" guarantee
/// lives, so it's worth pinning.
@Suite struct BackgroundBalanceReadGateTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let minInterval: TimeInterval = 5

    @Test func firstReadIsAlwaysAllowed() {
        #expect(BackgroundBalanceReadGate.allowed(now: base, lastReadAt: nil, minInterval: minInterval))
    }

    @Test func readWellAfterTheFloorIsAllowed() {
        #expect(
            BackgroundBalanceReadGate.allowed(
                now: base.addingTimeInterval(60),
                lastReadAt: base,
                minInterval: minInterval
            )
        )
    }

    @Test func readExactlyAtTheFloorIsAllowed() {
        #expect(
            BackgroundBalanceReadGate.allowed(
                now: base.addingTimeInterval(minInterval),
                lastReadAt: base,
                minInterval: minInterval
            )
        )
    }

    @Test func readInsideTheFloorIsCoalesced() {
        // The cmd-tab-away-and-straight-back case, and two triggers firing together.
        #expect(
            !BackgroundBalanceReadGate.allowed(
                now: base.addingTimeInterval(minInterval - 0.5),
                lastReadAt: base,
                minInterval: minInterval
            )
        )
    }

    @Test func simultaneousTriggersCoalesce() {
        #expect(
            !BackgroundBalanceReadGate.allowed(now: base, lastReadAt: base, minInterval: minInterval)
        )
    }

    @Test func clockMovingBackwardsDoesNotOpenTheGate() {
        // A backwards system-clock adjustment makes the interval negative; that must read as
        // "too soon", not "allowed", or an NTP correction could unblock an unbounded read.
        #expect(
            !BackgroundBalanceReadGate.allowed(
                now: base.addingTimeInterval(-30),
                lastReadAt: base,
                minInterval: minInterval
            )
        )
    }
}
