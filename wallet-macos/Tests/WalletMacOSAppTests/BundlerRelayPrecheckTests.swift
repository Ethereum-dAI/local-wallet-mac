import Foundation
import Testing
@testable import WalletMacOSApp

@Suite struct BundlerRelayPrecheckTests {
    @Test func exactDaemonMaximumCostPassesAndOneWeiShortFails() throws {
        let gas = gasPlan(call: 100_000, verification: 200_000, preVerification: 50_000, fee: 2)
        // (100k + 200k + 50k + the daemon's 150k overhead) * 2 = 1,000,000 wei.
        let exact = relayer(balance: "0xf4240", threshold: "0x0")
        #expect(try decision(gas: gas, requiredPrefund: 700_000, status: exact) == .proceed)

        let short = relayer(balance: "0xf423f", threshold: "0x0")
        let result = try decision(gas: gas, requiredPrefund: 700_000, status: short)
        guard case let .externalFundingRequired(report) = result else {
            Issue.record("Expected exact one-wei shortfall")
            return
        }
        #expect(report.requiredMaxCostWeiHex == "0xf4240")
        #expect(report.deficitWeiHex == "0x1")
    }

    @Test func fixedFloorCanDominateAndDoesNotGuaranteeEveryOperation() throws {
        let minimumBalanceWeiHex = "0x11c37937e08000" // 0.005 ETH
        let cheap = gasPlan(call: 1, verification: 1, preVerification: 1, fee: 1)
        let belowFloor = relayer(balance: "0x1", threshold: minimumBalanceWeiHex)
        #expect(try decision(gas: cheap, requiredPrefund: 3, status: belowFloor).canRelay == false)

        let expensive = gasPlan(
            call: 4_000_000,
            verification: 4_000_000,
            preVerification: 1_000_000,
            fee: 1_000_000_000
        )
        let atFloor = relayer(balance: minimumBalanceWeiHex, threshold: minimumBalanceWeiHex)
        #expect(
            try decision(
                gas: expensive,
                requiredPrefund: 9_000_000_000_000_000,
                status: atFloor
            ).canRelay == false
        )
    }

    @Test func malformedStatusChainAddressAndArithmeticFailClosed() {
        let gas = gasPlan(call: 100, verification: 100, preVerification: 100, fee: 1)
        #expect(throws: BundlerRelayPrecheck.Error.self) {
            try decision(gas: gas, requiredPrefund: 300, status: relayer(balance: "unavailable"))
        }
        #expect(throws: BundlerRelayPrecheck.Error.self) {
            try decision(gas: gas, requiredPrefund: 300, status: relayer(chainID: 1))
        }
        #expect(throws: BundlerRelayPrecheck.Error.self) {
            try decision(
                gas: gas,
                requiredPrefund: 300,
                status: relayer(eoa: "0x2222222222222222222222222222222222222222")
            )
        }
        let overflow = gasPlan(call: UInt64.max, verification: 1, preVerification: 0, fee: 1)
        #expect(throws: BundlerRelayPrecheck.Error.self) {
            try decision(gas: overflow, requiredPrefund: 0, status: relayer())
        }
        let multiplyOverflow = gasPlan(
            call: 1,
            verification: 0,
            preVerification: 0,
            fee: UInt64.max
        )
        #expect(throws: BundlerRelayPrecheck.Error.arithmeticOverflow) {
            try decision(
                gas: multiplyOverflow,
                requiredPrefund: UInt64.max,
                status: relayer()
            )
        }
        #expect(throws: BundlerRelayPrecheck.Error.inconsistentRequiredPrefund) {
            try decision(gas: gas, requiredPrefund: 299, status: relayer())
        }
    }

    @Test func balanceComparisonDoesNotNarrowA256BitBalanceToUInt64() throws {
        let gas = gasPlan(call: 100, verification: 100, preVerification: 100, fee: 1)
        let largeBalance = relayer(
            balance: "0x10000000000000000",
            threshold: "0x0"
        )
        #expect(try decision(gas: gas, requiredPrefund: 300, status: largeBalance) == .proceed)
    }

    @Test func onlyAnActiveReadyOrOrdinarilyLockedRelayerCanReachAuthentication() throws {
        let gas = gasPlan(call: 100, verification: 100, preVerification: 100, fee: 1)

        #expect(
            try decision(
                gas: gas,
                requiredPrefund: 300,
                status: relayer(
                    ready: false,
                    keyLoaded: false,
                    reason: "bundler_eoa_locked"
                )
            ) == .proceed
        )

        for status in [
            relayer(
                ready: false,
                keyLoaded: true,
                reason: "bundler_eoa_compromise_suspected"
            ),
            relayer(
                ready: false,
                keyLoaded: false,
                reason: "bundler_eoa_locked",
                compromiseSubmissionBlocked: true
            ),
            relayer(ready: false, keyLoaded: true, reason: "verified_reads_not_ready"),
            relayer(ready: true, keyLoaded: true, reason: nil, lifecycle: "retiring"),
            relayer(ready: false, keyLoaded: false, reason: nil),
            relayer(ready: true, keyLoaded: false, reason: "bundler_eoa_locked"),
        ] {
            #expect(throws: BundlerRelayPrecheck.Error.statusUnavailable) {
                try decision(gas: gas, requiredPrefund: 300, status: status)
            }
        }
    }
}

private let testBundlerEOA = "0x7A3f000000000000000000000000000000009C21"

private func gasPlan(
    call: UInt64,
    verification: UInt64,
    preVerification: UInt64,
    fee: UInt64
) -> UserOperationGasPlan {
    func half(_ value: UInt64) -> Data {
        Data.fromBigEndian(value).leftPadded(to: 16)
    }
    return UserOperationGasPlan(
        accountGasLimits: half(verification) + half(call),
        preVerificationGas: Data.fromBigEndian(preVerification).leftPadded(to: 32),
        gasFees: half(0) + half(fee),
        paymasterAndData: Data()
    )
}

private func relayer(
    balance: String = "0xffffffffffffffff",
    threshold: String = "0x0",
    chainID: Int = 11_155_111,
    eoa: String = testBundlerEOA,
    needsTopup: Bool = false,
    ready: Bool = true,
    keyLoaded: Bool = true,
    reason: String? = nil,
    lifecycle: String = "active",
    compromiseSubmissionBlocked: Bool = false
) -> WalletNodeClient.RelayerStatus {
    WalletNodeClient.RelayerStatus(
        ready: ready,
        keyLoaded: keyLoaded,
        reason: reason,
        ownerScope: "default",
        chainId: chainID,
        networkProfile: "sepolia",
        eoa: eoa,
        keyRef: "bundler-eoa:default:\(chainID):1",
        balance: balance,
        thresholdLow: threshold,
        needsTopup: needsTopup,
        lifecycle: lifecycle,
        compromiseSubmissionBlocked: compromiseSubmissionBlocked,
        pendingFundingAddress: nil,
        pendingFundingCount: 0,
        retiringCount: 0,
        keyHistory: [],
        latestAuditEvent: nil,
        replacement: nil
    )
}

private func decision(
    gas: UserOperationGasPlan,
    requiredPrefund: UInt64,
    status: WalletNodeClient.RelayerStatus
) throws -> BundlerRelayPrecheck.Decision {
    try BundlerRelayPrecheck.evaluate(
        gasPlan: gas,
        requiredPrefund: Data.fromBigEndian(requiredPrefund).leftPadded(to: 32),
        status: status,
        expectedChainID: 11_155_111,
        expectedEOA: testBundlerEOA
    )
}
