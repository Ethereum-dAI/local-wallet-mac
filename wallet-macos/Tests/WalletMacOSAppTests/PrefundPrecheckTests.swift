import Foundation
import Testing
@testable import WalletMacOSApp

@Suite struct PrefundPrecheckTests {
    /// 32-byte big-endian from a decimal wei amount expressed in UInt64.
    private func wei(_ value: UInt64) -> Data {
        Data.fromBigEndian(value).leftPadded(to: 32)
    }

    @Test func skippedEntirelyWhenNoLimitWasAcknowledged() {
        // The gate is scoped to the headroom retry. An ordinary send must be
        // unaffected even when it is nominally short.
        #expect(PrefundPrecheck.evaluate(
            acknowledgedCallGasLimit: nil,
            requiredPrefund: wei(1_000),
            accountBalance: wei(1),
            entryPointDeposit: wei(0)
        ) == nil)
    }

    @Test func reportsDeficitWhenBalancePlusDepositFallsShort() throws {
        let shortfall = try #require(PrefundPrecheck.evaluate(
            acknowledgedCallGasLimit: 600_000,
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
            acknowledgedCallGasLimit: 600_000,
            requiredPrefund: wei(1_000),
            accountBalance: wei(600),
            entryPointDeposit: wei(400)
        ) == nil)
    }

    @Test func depositAloneCanCoverTheFloor() {
        #expect(PrefundPrecheck.evaluate(
            acknowledgedCallGasLimit: 600_000,
            requiredPrefund: wei(1_000),
            accountBalance: wei(0),
            entryPointDeposit: wei(1_000)
        ) == nil)
    }

    @Test func zeroRequiredPrefundNeverDeclines() {
        // Fail open: a daemon that omitted requiredPrefund decodes as zero.
        #expect(PrefundPrecheck.evaluate(
            acknowledgedCallGasLimit: 600_000,
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
            acknowledgedCallGasLimit: 600_000,
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
            acknowledgedCallGasLimit: 600_000,
            requiredPrefund: Data(repeating: 0xff, count: 32),
            accountBalance: half,
            entryPointDeposit: half
        ) == nil)
    }

    @Test func acceptsUnpaddedInputs() throws {
        // Callers pass daemon-decoded quantities; tolerate short Data.
        let shortfall = try #require(PrefundPrecheck.evaluate(
            acknowledgedCallGasLimit: 600_000,
            requiredPrefund: Data([0x10]),
            accountBalance: Data([0x03]),
            entryPointDeposit: Data()
        ))
        #expect(shortfall.deficit == wei(13))
    }
}
