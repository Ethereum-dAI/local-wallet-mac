import Foundation
import Testing
@testable import WalletMacOSApp

@Suite struct PrefundPrecheckTests {
    /// 32-byte big-endian from a decimal wei amount expressed in UInt64.
    private func wei(_ value: UInt64) -> Data {
        Data.fromBigEndian(value).leftPadded(to: 32)
    }

    private func status(
        balance: UInt64,
        deposit: UInt64
    ) throws -> WalletNodeClient.WalletStatus {
        try WalletNodeClient.WalletStatus(json: [
            "accountBalance": "0x" + String(balance, radix: 16),
            "entryPointDeposit": "0x" + String(deposit, radix: 16),
        ])
    }

    @Test func decisionProceedsWithoutReadingStatusWhenNoLimitAcknowledged() async {
        // The gate is scoped to the headroom retry, and must not spend a round
        // trip on an ordinary send.
        var readCount = 0
        let outcome = await PrefundPrecheck.decision(
            acknowledgedCallGasLimit: nil,
            requiredPrefund: wei(1_000),
            callGasLimit: wei(600_000),
            maxFeePerGas: wei(30_000_000_000),
            gasPricingUnavailable: false,
            readWalletStatus: {
                readCount += 1
                return try self.status(balance: 1, deposit: 0)
            }
        )

        #expect(readCount == 0)
        guard case .proceed = outcome else {
            Issue.record("expected .proceed, got \(outcome)")
            return
        }
    }

    @Test func decisionProceedsWhenAffordable() async throws {
        let outcome = await PrefundPrecheck.decision(
            acknowledgedCallGasLimit: 600_000,
            requiredPrefund: wei(1_000),
            callGasLimit: wei(600_000),
            maxFeePerGas: wei(30_000_000_000),
            gasPricingUnavailable: false,
            readWalletStatus: { try self.status(balance: 600, deposit: 400) }
        )

        guard case .proceed = outcome else {
            Issue.record("expected .proceed, got \(outcome)")
            return
        }
    }

    @Test func decisionDeclinesWithTheFullPayload() async throws {
        let outcome = await PrefundPrecheck.decision(
            acknowledgedCallGasLimit: 600_000,
            requiredPrefund: wei(48_000_000_000_000_000),
            callGasLimit: wei(720_000),
            maxFeePerGas: wei(30_000_000_000),
            gasPricingUnavailable: false,
            readWalletStatus: {
                try self.status(balance: 10_000_000_000_000_000, deposit: 3_000_000_000_000_000)
            }
        )

        guard case let .decline(report) = outcome else {
            Issue.record("expected .decline, got \(outcome)")
            return
        }
        #expect(report.requiredPrefundWeiHex == "0x" + wei(48_000_000_000_000_000).hexEncodedString)
        #expect(report.availableWeiHex == "0x" + wei(13_000_000_000_000_000).hexEncodedString)
        #expect(report.deficitWeiHex == "0x" + wei(35_000_000_000_000_000).hexEncodedString)
        #expect(report.maxFeePerGasWeiHex == "0x" + wei(30_000_000_000).hexEncodedString)
        #expect(report.gasPricingUnavailable == false)
        // Reported from the draft's (daemon-floored) limit, not the pressed one.
        #expect(report.effectiveCallGasLimit == 720_000)
    }

    @Test func decisionFailsOpenWhenTheStatusReadThrows() async {
        struct Boom: Error {}
        let outcome = await PrefundPrecheck.decision(
            acknowledgedCallGasLimit: 600_000,
            requiredPrefund: wei(48_000_000_000_000_000),
            callGasLimit: wei(600_000),
            maxFeePerGas: wei(30_000_000_000),
            gasPricingUnavailable: false,
            readWalletStatus: { throw Boom() }
        )

        // Fail open: the send path's own funding check is still the real gate, so
        // a transient read failure must not refuse a send the user can afford.
        guard case .statusUnavailable = outcome else {
            Issue.record("expected .statusUnavailable, got \(outcome)")
            return
        }
    }

    @Test func decisionFallsBackToTheAcknowledgedLimitWhenTheDraftLimitIsTooWide() async throws {
        // Cannot happen while the daemon clamps to policy.max_call_gas_limit, but
        // the narrowing must not silently truncate if it ever does.
        let wide = Data(repeating: 0xff, count: 32)
        let outcome = await PrefundPrecheck.decision(
            acknowledgedCallGasLimit: 600_000,
            requiredPrefund: wei(48_000_000_000_000_000),
            callGasLimit: wide,
            maxFeePerGas: wei(30_000_000_000),
            gasPricingUnavailable: false,
            readWalletStatus: { try self.status(balance: 1, deposit: 0) }
        )

        guard case let .decline(report) = outcome else {
            Issue.record("expected .decline, got \(outcome)")
            return
        }
        #expect(report.effectiveCallGasLimit == 600_000)
    }

    @Test func decisionCarriesTheGasPricingUnavailableFlag() async throws {
        // The floor is arithmetically right but economically meaningless, so the
        // card needs to know not to ask for a top-up.
        let outcome = await PrefundPrecheck.decision(
            acknowledgedCallGasLimit: 600_000,
            requiredPrefund: wei(2_400_000_000_000_000_000),
            callGasLimit: wei(600_000),
            maxFeePerGas: wei(1_500_000_000_000),
            gasPricingUnavailable: true,
            readWalletStatus: { try self.status(balance: 10_000_000_000_000_000, deposit: 0) }
        )

        guard case let .decline(report) = outcome else {
            Issue.record("expected .decline, got \(outcome)")
            return
        }
        #expect(report.gasPricingUnavailable)
        #expect(report.maxFeePerGasWeiHex == "0x" + wei(1_500_000_000_000).hexEncodedString)
    }

    @Test func reportsDeficitWhenBalancePlusDepositFallsShort() throws {
        let shortfall = try #require(PrefundPrecheck.evaluate(
            requiredPrefund: wei(48_000_000_000_000_000),   // 0.048 ETH
            accountBalance: wei(10_000_000_000_000_000),    // 0.010 ETH
            entryPointDeposit: wei(3_000_000_000_000_000)   // 0.003 ETH
        ))

        #expect(shortfall.available == wei(13_000_000_000_000_000))
        #expect(shortfall.deficit == wei(35_000_000_000_000_000))
        #expect(shortfall.requiredPrefund == wei(48_000_000_000_000_000))
        #expect(shortfall.deficit.count == 32)
    }

    @Test func exactlyCoveredIsAllowed() {
        // The boundary is >=. Declining here would block a send that succeeds.
        #expect(PrefundPrecheck.evaluate(
            requiredPrefund: wei(1_000),
            accountBalance: wei(600),
            entryPointDeposit: wei(400)
        ) == nil)
    }

    @Test func depositAloneCanCoverTheFloor() {
        #expect(PrefundPrecheck.evaluate(
            requiredPrefund: wei(1_000),
            accountBalance: wei(0),
            entryPointDeposit: wei(1_000)
        ) == nil)
    }

    @Test func zeroRequiredPrefundNeverDeclines() {
        // Fail open: a daemon that omitted requiredPrefund decodes as zero.
        #expect(PrefundPrecheck.evaluate(
            requiredPrefund: Data(repeating: 0, count: 32),
            accountBalance: Data(repeating: 0, count: 32),
            entryPointDeposit: Data(repeating: 0, count: 32)
        ) == nil)
    }

    @Test func handlesBalancesAboveUInt64Max() throws {
        // A 20 ETH balance exceeds UInt64.max wei. Narrowing anywhere in the
        // arithmetic would wrap and invent a shortfall.
        let twentyEth = Data([0x01, 0x15, 0x8e, 0x46, 0x09, 0x13, 0xd0, 0x00, 0x00])
            .leftPadded(to: 32)
        #expect(PrefundPrecheck.evaluate(
            requiredPrefund: wei(48_000_000_000_000_000),
            accountBalance: twentyEth,
            entryPointDeposit: Data(repeating: 0, count: 32)
        ) == nil)
    }

    @Test func additionCarriesAcrossTheFullWidth() throws {
        // accountBalance + entryPointDeposit must not overflow 32 bytes silently:
        // both at 2^255 sum to 2^256, which covers any 32-byte prefund.
        var half = Data(repeating: 0, count: 32)
        half[0] = 0x80
        #expect(PrefundPrecheck.evaluate(
            requiredPrefund: Data(repeating: 0xff, count: 32),
            accountBalance: half,
            entryPointDeposit: half
        ) == nil)
    }

    @Test func acceptsUnpaddedInputs() throws {
        // Callers pass daemon-decoded quantities; tolerate short Data.
        let shortfall = try #require(PrefundPrecheck.evaluate(
            requiredPrefund: Data([0x10]),
            accountBalance: Data([0x03]),
            entryPointDeposit: Data()
        ))
        #expect(shortfall.deficit == wei(13))
    }
}
