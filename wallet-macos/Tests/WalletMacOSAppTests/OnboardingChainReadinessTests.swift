import Foundation
import Testing
@testable import WalletMacOSApp

@Test func onboardingReadinessTimingUsesOneAndThirtyMinuteThresholds() {
    let timing = OnboardingChainReadinessTiming.default

    #expect(timing.takingLongerDelay == 60)
    #expect(timing.timeout == 30 * 60)
    #expect(timing.isTakingLonger(elapsed: 59.9) == false)
    #expect(timing.isTakingLonger(elapsed: 60) == true)
    #expect(timing.hasTimedOut(elapsed: 1_799.9) == false)
    #expect(timing.hasTimedOut(elapsed: 1_800) == true)
}

@Test func onboardingReadinessLaunchesReadOnlyWithoutReadingProtectedRelayerKeys() throws {
    let source = try appSource(named: "OnboardingChainReadiness.swift")

    #expect(source.contains("bundlerSecrets: []"))
    #expect(source.contains("BundlerKeyStore.shared") == false)
    #expect(source.contains("unlockAllForOnboardingDaemonLaunch") == false)
}

@Test func walletNodeDaemonAcceptsAnEmptyReadOnlySecretPayload() throws {
    let source = try appSource(named: "WalletNodeDaemon.swift")
    let data = try WalletNodeDaemon.secretPayloadData([])
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let keys = try #require(object["keys"] as? [Any])

    #expect(keys.isEmpty)
    #expect(source.contains("guard !bundlerSecrets.isEmpty") == false)
}

@Test func onboardingReadinessCopyDescribesReadOnlyStartupWithoutAuthenticationWarning() throws {
    let source = try appSource(named: "OnboardingView.swift")

    #expect(source.contains("Starting wallet-node in read-only mode."))
    #expect(source.contains("Unlocking the bundler key and starting the local daemon.") == false)
    #expect(source.contains("macOS may ask for biometric authentication to unlock the local bundler key.") == false)
}

@Test func onboardingShowsMainnetAsComingSoonButCannotSelectIt() {
    #expect(OnboardingNetworkOption.sepolia.isEnabled)
    #expect(OnboardingNetworkOption.sepolia.badge == nil)
    #expect(OnboardingNetworkOption.mainnet.isEnabled == false)
    #expect(OnboardingNetworkOption.mainnet.badge == "Coming soon")
}

@Test func onboardingRPCFieldsExposeRequirementAndHelpMetadata() {
    #expect(OnboardingRPCField.execution.isRequired)
    #expect(OnboardingRPCField.consensus.isRequired == false)
    #expect(OnboardingRPCField.archive.isRequired == false)
    #expect(OnboardingRPCField.execution.helpText.contains("transaction preparation"))
    #expect(OnboardingRPCField.consensus.helpText.contains("Helios verified reads"))
    #expect(OnboardingRPCField.archive.helpText.contains("historical reads"))
}

@Test func networkStatusDecodesHeliosReadyHealthShape() throws {
    let status = try WalletNodeClient.NetworkStatus(json: [
        "status": "verified_reads_ready",
        "chainId": 11_155_111,
        "networkProfile": "sepolia",
        "readVerification": [
            "mode": "helios",
            "verified": true,
        ],
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
    #expect(status.readVerification.mode == "helios")
    #expect(status.readVerification.verified)
    #expect(status.helios.ready)
    #expect(status.helios.checkpointLoaded)
    #expect(status.helios.head?.number == 7_654_321)
    #expect(status.helios.head?.hash == "0xabc")
    #expect(status.bundler?.ready == false)
    #expect(status.bundler?.reason == "bundler_eoa_missing")
}

@Test func networkStatusDecodesP256PrecompileAvailable() throws {
    let status = try WalletNodeClient.NetworkStatus(json: [
        "status": "bundler_ready",
        "chainId": 11_155_111,
        "networkProfile": "sepolia",
        "helios": [
            "ready": true,
            "checkpointLoaded": true,
        ],
        "p256Precompile": [
            "status": "available",
            "usePrecompiled": true,
        ],
    ])

    #expect(status.p256Precompile?.status == "available")
    #expect(status.p256Precompile?.usePrecompiled == true)
    #expect(status.p256Precompile?.reason == nil)
}

@Test func networkStatusDecodesP256PrecompileUnavailableWithReason() throws {
    let status = try WalletNodeClient.NetworkStatus(json: [
        "status": "bundler_ready",
        "chainId": 11_155_111,
        "networkProfile": "sepolia",
        "helios": [
            "ready": true,
            "checkpointLoaded": true,
        ],
        "p256Precompile": [
            "status": "unavailable",
            "usePrecompiled": false,
            "reason": "precompile_absent",
        ],
    ])

    #expect(status.p256Precompile?.status == "unavailable")
    #expect(status.p256Precompile?.usePrecompiled == false)
    #expect(status.p256Precompile?.reason == "precompile_absent")
}

@Test func networkStatusTreatsMissingP256PrecompileAsNil() throws {
    let status = try WalletNodeClient.NetworkStatus(json: [
        "status": "bundler_ready",
        "chainId": 11_155_111,
        "networkProfile": "sepolia",
        "helios": [
            "ready": true,
            "checkpointLoaded": true,
        ],
    ])

    #expect(status.p256Precompile == nil)
}

@Test func networkStatusDecodesSyncingHealthShape() throws {
    let status = try WalletNodeClient.NetworkStatus(json: [
        "status": "syncing_consensus",
        "chainId": 11_155_111,
        "networkProfile": "sepolia",
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
    #expect(status.chainId == 11_155_111)
    #expect(status.networkProfile == "sepolia")
    #expect(status.readVerification.mode == "helios")
    #expect(status.readVerification.verified)
    #expect(status.helios.ready == false)
    #expect(status.helios.checkpointLoaded == false)
    #expect(status.helios.head == nil)
    #expect(status.bundler?.reason == "verified_reads_not_ready")
}

@Test func onboardingDebugSummaryIncludesHeliosHeadAndBundlerReason() throws {
    let status = try WalletNodeClient.NetworkStatus(json: [
        "status": "degraded",
        "reason": "helios_lagging",
        "chainId": 11_155_111,
        "networkProfile": "sepolia",
        "readVerification": [
            "mode": "execution_rpc",
            "verified": false,
        ],
        "helios": [
            "ready": true,
            "checkpointLoaded": true,
            "checkpointAgeDays": 0.125,
            "head": [
                "number": 7_654_321,
                "hash": "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
            ],
        ],
        "bundler": [
            "ready": false,
            "eoa": "0x1111111111111111111111111111111111111111",
            "needsTopup": true,
            "reason": "bundler_eoa_needs_topup",
        ],
    ])

    let summary = status.onboardingDebugSummary

    #expect(summary.contains("status=degraded"))
    #expect(summary.contains("readVerification=execution_rpc"))
    #expect(summary.contains("readsVerified=false"))
    #expect(summary.contains("helios.ready=true"))
    #expect(summary.contains("head=#7654321"))
    #expect(summary.contains("bundler.reason=bundler_eoa_needs_topup"))
    #expect(summary.contains("reason=helios_lagging"))
}

private func appSource(named fileName: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fileURL = packageRoot
        .appendingPathComponent("Sources/WalletMacOSApp", isDirectory: true)
        .appendingPathComponent(fileName)
    return try String(contentsOf: fileURL, encoding: .utf8)
}
