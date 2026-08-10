import Foundation
import LocalAuthentication
import Testing
@testable import WalletMacOSApp

/// The reuse window only ever meant something if the context carrying it outlives
/// the call. These pin that, and pin which paths are allowed to use it at all.
struct BiometricAuthenticationContextsTests {
    @Test func aDomainGetsTheSameContextBackSoTheReuseWindowApplies() {
        let pool = BiometricAuthenticationContexts.shared
        let first = pool.context(for: .relayerLaunch, reason: "Unlock the local relayer key")
        let second = pool.context(for: .relayerLaunch, reason: "Unlock the local relayer key")
        #expect(first === second)
        #expect(first.touchIDAuthenticationAllowableReuseDuration
            == BiometricAuthenticationContexts.maximumReuseDuration)
        pool.invalidateAll()
    }

    /// One unlock must not authorise the other: the relayer secret and the RAILGUN
    /// entropy are different key material with different access controls.
    @Test func domainsDoNotShareAnAuthorisation() {
        let pool = BiometricAuthenticationContexts.shared
        let relayer = pool.context(for: .relayerLaunch, reason: "a")
        let railgun = pool.context(for: .railgun, reason: "b")
        #expect(relayer !== railgun)
        pool.invalidateAll()
    }

    /// Deleting or resetting key material must drop the window, or the next read
    /// of whatever replaces it would be waved through.
    @Test func invalidatingADomainForcesAFreshContext() {
        let pool = BiometricAuthenticationContexts.shared
        let before = pool.context(for: .relayerLaunch, reason: "a")
        pool.invalidate(.relayerLaunch)
        let after = pool.context(for: .relayerLaunch, reason: "a")
        #expect(before !== after)
        pool.invalidateAll()
    }

    /// The security boundary, asserted rather than assumed: there is no signing
    /// domain, so a transaction can never reuse an unlock granted to the daemon.
    @Test func thereIsNoReusableDomainForSigning() {
        #expect(BiometricAuthenticationContexts.Domain.allCases.map(\.rawValue).sorted()
            == ["railgun", "relayerLaunch"])
    }

    /// The OS clamps at five minutes; asking for more just hides the clamp.
    @Test func reuseIsCappedAtTheOSMaximum() {
        #expect(BiometricAuthenticationContexts.maximumReuseDuration
            == LATouchIDAuthenticationMaximumAllowableReuseDuration)
        #expect(BundlerSecretPromptReusePolicy.authenticationReuseDuration
            == BiometricAuthenticationContexts.maximumReuseDuration)
    }

    /// A respawn during one session used to fall outside the 10-second window and
    /// re-prompt. It has to comfortably outlast a daemon restart now.
    @Test func theLaunchCacheOutlastsADaemonRestart() {
        #expect(BundlerSecretPromptReusePolicy.cacheTTL >= 10 * 60)
        let now = Date()
        let expiry = BundlerSecretPromptReusePolicy.expiry(now: now)
        #expect(BundlerSecretPromptReusePolicy.shouldUseCached(
            now: now.addingTimeInterval(5 * 60),
            expiresAt: expiry
        ))
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
