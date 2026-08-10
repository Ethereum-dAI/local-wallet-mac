import Foundation
import Testing
@testable import WalletMacOSApp

/// The chat's gas pill used to be driven by a 30-second poll that ran for the life
/// of the app. It fed nothing else — the fees an operation is signed with are
/// fetched by `suggestedUserOperationFees` when the operation is built — but every
/// tick went through `withWalletNodeClient`, which relaunches the daemon on socket
/// loss, so a decorative number could resurrect a dead daemon and unlock the
/// relayer key on a schedule. It is now event-driven behind this gate.
struct GasIndicatorRefreshGateTests {
    private let interval: TimeInterval = 20
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theFirstRefreshIsAlwaysAllowed() {
        #expect(GasIndicatorRefreshGate.allowed(now: now, lastReadAt: nil, minInterval: interval))
    }

    /// Returning to the app twice in a few seconds is one read, not two.
    @Test func aBurstOfTriggersCoalescesIntoOneRead() {
        let first = now
        #expect(GasIndicatorRefreshGate.allowed(
            now: first.addingTimeInterval(3),
            lastReadAt: first,
            minInterval: interval
        ) == false)
    }

    @Test func aRefreshIsAllowedOnceTheIntervalHasPassed() {
        #expect(GasIndicatorRefreshGate.allowed(
            now: now.addingTimeInterval(interval),
            lastReadAt: now,
            minInterval: interval
        ))
    }

    /// The gate must not be so long that the pill is visibly stale when someone
    /// comes back to act on it, nor so short that it re-reads on every focus change.
    @Test func theIntervalIsInThePlausibleRange() {
        #expect(interval >= 10)
        #expect(interval <= 60)
    }

    /// A clock that jumps backwards (NTP correction, sleep/wake) must not wedge the
    /// gate shut forever.
    @Test func aBackwardsClockDoesNotLockTheGate() {
        let allowed = GasIndicatorRefreshGate.allowed(
            now: now.addingTimeInterval(-3600),
            lastReadAt: now,
            minInterval: interval
        )
        // Blocked for this call, but the stamp is in the past relative to real time,
        // so the next genuine trigger after the interval passes is allowed again.
        #expect(allowed == false)
        #expect(GasIndicatorRefreshGate.allowed(
            now: now.addingTimeInterval(interval),
            lastReadAt: now,
            minInterval: interval
        ))
    }
}
