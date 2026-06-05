import Foundation
import Testing
@testable import WalletMacOSApp

@Test func onboardingReadinessTimingUsesOneAndTwoMinuteThresholds() {
    let timing = OnboardingChainReadinessTiming.default

    #expect(timing.takingLongerDelay == 60)
    #expect(timing.timeout == 120)
    #expect(timing.isTakingLonger(elapsed: 59.9) == false)
    #expect(timing.isTakingLonger(elapsed: 60) == true)
    #expect(timing.hasTimedOut(elapsed: 119.9) == false)
    #expect(timing.hasTimedOut(elapsed: 120) == true)
}

@Test func onboardingRelayerUnlockCacheCoversSyncTimeoutHandoff() {
    #expect(BundlerSecretPromptReusePolicy.onboardingHandoffCacheTTL >= OnboardingChainReadinessTiming.default.timeout)
}

@Test func networkStatusDecodesHeliosReadyHealthShape() throws {
    let status = try WalletNodeClient.NetworkStatus(json: [
        "status": "verified_reads_ready",
        "chainId": 11_155_111,
        "networkProfile": "sepolia",
        "helios": [
            "ready": true,
            "checkpointLoaded": true,
            "checkpointAgeDays": NSNull(),
            "head": [
                "number": 7_654_321,
                "hash": "0xabc",
            ],
        ],
        "bundler": [
            "ready": false,
            "eoa": NSNull(),
            "needsTopup": false,
            "reason": "bundler_eoa_missing",
        ],
    ])

    #expect(status.status == "verified_reads_ready")
    #expect(status.reason == nil)
    #expect(status.chainId == 11_155_111)
    #expect(status.networkProfile == "sepolia")
    #expect(status.helios.ready)
    #expect(status.helios.checkpointLoaded)
    #expect(status.helios.head?.number == 7_654_321)
    #expect(status.helios.head?.hash == "0xabc")
    #expect(status.bundler?.ready == false)
    #expect(status.bundler?.reason == "bundler_eoa_missing")
}

@Test func networkStatusDecodesSyncingHealthShape() throws {
    let status = try WalletNodeClient.NetworkStatus(json: [
        "status": "syncing_consensus",
        "chainId": 1,
        "networkProfile": "mainnet",
        "helios": [
            "ready": false,
            "checkpointLoaded": false,
            "checkpointAgeDays": NSNull(),
            "head": NSNull(),
        ],
        "bundler": [
            "ready": false,
            "eoa": NSNull(),
            "needsTopup": false,
            "reason": "verified_reads_not_ready",
        ],
    ])

    #expect(status.status == "syncing_consensus")
    #expect(status.chainId == 1)
    #expect(status.networkProfile == "mainnet")
    #expect(status.helios.ready == false)
    #expect(status.helios.checkpointLoaded == false)
    #expect(status.helios.head == nil)
    #expect(status.bundler?.reason == "verified_reads_not_ready")
}
