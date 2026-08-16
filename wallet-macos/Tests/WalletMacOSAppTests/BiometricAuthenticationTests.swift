import Foundation
import LocalAuthentication
import Testing
@testable import WalletMacOSApp

/// The reuse window only ever meant something if the context carrying it outlives
/// the call. These pin that, and pin which paths are allowed to use it at all.
///
/// Each test builds its own pool rather than touching
/// `BiometricAuthenticationContexts.shared`. Tests in a suite run concurrently,
/// and a sibling's `invalidateAll()` would invalidate a context this one is
/// still asserting on — an invalidated `LAContext` reports a reuse duration of
/// 0, so the shared pool made these tests fail on timing alone.
struct BiometricAuthenticationContextsTests {
    @Test func aDomainGetsTheSameContextBackSoTheReuseWindowApplies() {
        let pool = BiometricAuthenticationContexts()
        let first = pool.context(for: .relayerLaunch, reason: "Unlock the local relayer key")
        let second = pool.context(for: .relayerLaunch, reason: "Unlock the local relayer key")
        #expect(first === second)
        #expect(first.touchIDAuthenticationAllowableReuseDuration
            == BiometricAuthenticationContexts.maximumReuseDuration)
    }

    /// Deleting or resetting key material must drop the window, or the next read
    /// of whatever replaces it would be waved through.
    @Test func invalidatingADomainForcesAFreshContext() {
        let pool = BiometricAuthenticationContexts()
        let before = pool.context(for: .relayerLaunch, reason: "a")
        pool.invalidate(.relayerLaunch)
        let after = pool.context(for: .relayerLaunch, reason: "a")
        #expect(before !== after)
    }

    /// The security boundary, asserted rather than assumed: launching the daemon
    /// is the only unlock that may be reused. Nothing that authorises moving funds
    /// — signing a transaction, enabling a session key — gets a window, so an
    /// unlock granted to the daemon can never cover one.
    @Test func onlyTheDaemonLaunchUnlockIsReusable() {
        #expect(BiometricAuthenticationContexts.Domain.allCases.map(\.rawValue)
            == ["relayerLaunch"])
    }

    /// The OS clamps at five minutes; asking for more just hides the clamp.
    @Test func reuseIsCappedAtTheOSMaximum() {
        #expect(BiometricAuthenticationContexts.maximumReuseDuration
            == LATouchIDAuthenticationMaximumAllowableReuseDuration)
    }
}

struct BiometricPromptLogTests {
    @Test func countsPerReasonMakeARepeatedUnlockObvious() {
        let log = BiometricPromptLog()
        log.record(reason: "Unlock the local relayer key", reusable: true)
        log.record(reason: "Unlock the local relayer key", reusable: true)
        log.record(reason: "Sign the transaction", reusable: false)

        let lines = log.reportLines(formatter: ISO8601DateFormatter())
        #expect(lines.first == "requests=2 reason=Unlock the local relayer key")
        #expect(lines.contains { $0.contains("reusable=false") && $0.contains("Sign the transaction") })
    }

    @Test func anIdleSessionSaysSoRatherThanShowingNothing() {
        #expect(BiometricPromptLog().reportLines(formatter: ISO8601DateFormatter())
            == ["no biometric authorisations requested this session"])
    }

    /// A long session must not grow the report without bound.
    @Test func theLogIsBounded() {
        let log = BiometricPromptLog()
        for i in 0..<200 { log.record(reason: "r\(i)", reusable: false) }
        #expect(log.snapshot().count == 64)
        #expect(log.snapshot().last?.reason == "r199")
    }
}
