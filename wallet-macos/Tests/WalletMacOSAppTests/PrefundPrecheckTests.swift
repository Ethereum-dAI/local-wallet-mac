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

    @Test func decisionChecksEveryOperationEvenWithoutHeadroomRetry() async {
        var readCount = 0
        let outcome = await PrefundPrecheck.decision(
            requiredPrefund: wei(1_000),
            callValue: UserOperationCallValue.zero,
            callGasLimit: wei(600_000),
            maxFeePerGas: wei(30_000_000_000),
            feeQuoteAtPolicyCeiling: false,
            readWalletStatus: {
                readCount += 1
                return try self.status(balance: 1, deposit: 0)
            }
        )

        #expect(readCount == 1)
        guard case .decline = outcome else {
            Issue.record("expected .decline, got \(outcome)")
            return
        }
    }

    @Test func decisionProceedsWhenAffordable() async throws {
        let outcome = await PrefundPrecheck.decision(
            requiredPrefund: wei(1_000),
            callValue: UserOperationCallValue.zero,
            callGasLimit: wei(600_000),
            maxFeePerGas: wei(30_000_000_000),
            feeQuoteAtPolicyCeiling: false,
            readWalletStatus: { try self.status(balance: 600, deposit: 400) }
        )

        guard case .proceed = outcome else {
            Issue.record("expected .proceed, got \(outcome)")
            return
        }
    }

    @Test func nativeValueIsNotMistakenForGasCoveredByTheEntryPointDeposit() async throws {
        // wallet-node requires the account itself to hold the call value. The
        // EntryPoint deposit can cover gas, but it cannot be sent to the
        // recipient. The old balance + deposit check incorrectly allowed this.
        let outcome = await PrefundPrecheck.decision(
            requiredPrefund: wei(1_000),
            callValue: wei(1_001),
            callGasLimit: wei(600_000),
            maxFeePerGas: wei(30_000_000_000),
            feeQuoteAtPolicyCeiling: false,
            readWalletStatus: { try self.status(balance: 1_000, deposit: 1_000) }
        )

        guard case let .accountBalanceDecline(report) = outcome else {
            Issue.record("expected .accountBalanceDecline, got \(outcome)")
            return
        }
        #expect(report.callValueWeiHex == "0x" + wei(1_001).hexEncodedString)
        #expect(report.gasBalanceRequiredWeiHex == "0x" + wei(0).hexEncodedString)
        #expect(report.minimumAccountBalanceWeiHex == "0x" + wei(1_001).hexEncodedString)
        #expect(report.accountBalanceWeiHex == "0x" + wei(1_000).hexEncodedString)
        #expect(report.deficitWeiHex == "0x" + wei(1).hexEncodedString)
    }

    @Test func nativeValueAndUncoveredGasAreBothRequiredFromTheAccount() async throws {
        let outcome = await PrefundPrecheck.decision(
            requiredPrefund: wei(1_000),
            callValue: wei(500),
            callGasLimit: wei(600_000),
            maxFeePerGas: wei(30_000_000_000),
            feeQuoteAtPolicyCeiling: false,
            readWalletStatus: { try self.status(balance: 600, deposit: 400) }
        )

        guard case let .accountBalanceDecline(report) = outcome else {
            Issue.record("expected .accountBalanceDecline, got \(outcome)")
            return
        }
        #expect(report.gasBalanceRequiredWeiHex == "0x" + wei(600).hexEncodedString)
        #expect(report.minimumAccountBalanceWeiHex == "0x" + wei(1_100).hexEncodedString)
        #expect(report.deficitWeiHex == "0x" + wei(500).hexEncodedString)
    }

    @Test func depositAbovePrefundLeavesOnlyNativeValueToCover() async throws {
        let outcome = await PrefundPrecheck.decision(
            requiredPrefund: wei(1_000),
            callValue: wei(500),
            callGasLimit: wei(600_000),
            maxFeePerGas: wei(30_000_000_000),
            feeQuoteAtPolicyCeiling: false,
            readWalletStatus: { try self.status(balance: 500, deposit: 2_000) }
        )

        guard case .proceed = outcome else {
            Issue.record("expected .proceed, got \(outcome)")
            return
        }
    }

    @Test func nativeValuePlusGasOverflowFailsClosed() async throws {
        let outcome = await PrefundPrecheck.decision(
            requiredPrefund: wei(2),
            callValue: Data(repeating: 0xff, count: 32),
            callGasLimit: wei(600_000),
            maxFeePerGas: wei(30_000_000_000),
            feeQuoteAtPolicyCeiling: false,
            readWalletStatus: { try self.status(balance: UInt64.max, deposit: 1) }
        )

        guard case .statusUnavailable = outcome else {
            Issue.record("expected .statusUnavailable, got \(outcome)")
            return
        }
    }

    @Test func decisionDeclinesWithTheFullPayload() async throws {
        let outcome = await PrefundPrecheck.decision(
            requiredPrefund: wei(48_000_000_000_000_000),
            callValue: UserOperationCallValue.zero,
            callGasLimit: wei(720_000),
            maxFeePerGas: wei(30_000_000_000),
            feeQuoteAtPolicyCeiling: false,
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
        #expect(report.feeQuoteAtPolicyCeiling == false)
        // Reported from the draft's (daemon-floored) limit, not the pressed one.
        #expect(report.effectiveCallGasLimit == 720_000)
    }

    @Test func decisionReturnsUnavailableForCallerToFailClosed() async {
        struct Boom: Error {}
        let outcome = await PrefundPrecheck.decision(
            requiredPrefund: wei(48_000_000_000_000_000),
            callValue: UserOperationCallValue.zero,
            callGasLimit: wei(600_000),
            maxFeePerGas: wei(30_000_000_000),
            feeQuoteAtPolicyCeiling: false,
            readWalletStatus: { throw Boom() }
        )

        // AppModel treats this outcome as terminal before owner/session key use.
        guard case .statusUnavailable = outcome else {
            Issue.record("expected .statusUnavailable, got \(outcome)")
            return
        }
    }

    @Test func decisionDoesNotTruncateAnImpossibleWideDraftLimit() async throws {
        // Cannot happen after local policy authorization, but the report must
        // remain loud rather than silently taking the low 64 bits.
        let wide = Data(repeating: 0xff, count: 32)
        let outcome = await PrefundPrecheck.decision(
            requiredPrefund: wei(48_000_000_000_000_000),
            callValue: UserOperationCallValue.zero,
            callGasLimit: wide,
            maxFeePerGas: wei(30_000_000_000),
            feeQuoteAtPolicyCeiling: false,
            readWalletStatus: { try self.status(balance: 1, deposit: 0) }
        )

        guard case let .decline(report) = outcome else {
            Issue.record("expected .decline, got \(outcome)")
            return
        }
        #expect(report.effectiveCallGasLimit == UInt64.max)
    }

    @Test func decisionCarriesTheGasPricingUnavailableFlag() async throws {
        // The floor is arithmetically right but economically meaningless, so the
        // card needs to know not to ask for a top-up.
        let outcome = await PrefundPrecheck.decision(
            requiredPrefund: wei(2_400_000_000_000_000_000),
            callValue: UserOperationCallValue.zero,
            callGasLimit: wei(600_000),
            maxFeePerGas: wei(1_500_000_000_000),
            feeQuoteAtPolicyCeiling: true,
            readWalletStatus: { try self.status(balance: 10_000_000_000_000_000, deposit: 0) }
        )

        guard case let .decline(report) = outcome else {
            Issue.record("expected .decline, got \(outcome)")
            return
        }
        #expect(report.feeQuoteAtPolicyCeiling)
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
        // Arithmetic boundary only. Production passes the nonzero liability
        // recomputed by the local Rust authorization policy, never daemon data.
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

    @Test func nativeTransferCallValueUsesTheReviewedETHAmount() throws {
        let value = try UserOperationCallValue.wei(
            for: .nativeTransfer(
                recipient: "0x0000000000000000000000000000000000000001",
                amountETH: "0.125"
            )
        )
        let expected = try EtherAmountParser.wei(fromETHString: "0.125")
        #expect(value == expected)
    }

    @Test func nativeInputSwapCallValueUsesTheQuotedAmountIn() throws {
        let amountIn = wei(123)
        let quote = SwapQuote(
            chainID: 11_155_111,
            factory: "0x0000000000000000000000000000000000000001",
            router: "0x0000000000000000000000000000000000000002",
            quoter: "0x0000000000000000000000000000000000000003",
            tokenIn: "ETH",
            tokenOut: "USDC",
            amountIn: amountIn,
            quoteAmountOut: wei(100),
            amountOutMinimum: wei(99),
            slippageBps: 50,
            path: Data(),
            hops: [],
            gasEstimate: "100000",
            allowance: nil,
            requiresApproval: false
        )

        let native = try UserOperationCallValue.wei(
            for: .exactInputSwap(
                SwapExecutionRequest(
                    quote: quote,
                    recipient: "0x0000000000000000000000000000000000000004",
                    tokenInIsNative: true,
                    tokenOutIsNative: false
                )
            )
        )
        let token = try UserOperationCallValue.wei(
            for: .exactInputSwap(
                SwapExecutionRequest(
                    quote: quote,
                    recipient: "0x0000000000000000000000000000000000000004",
                    tokenInIsNative: false,
                    tokenOutIsNative: true
                )
            )
        )

        #expect(native == amountIn)
        #expect(token == wei(0))
    }

    @Test func batchCallValueSumsEveryKernelExecution() throws {
        let total = try UserOperationCallValue.wei(for: [
            KernelExecutionRequest(
                target: "0x0000000000000000000000000000000000000001",
                value: wei(40),
                callData: Data()
            ),
            KernelExecutionRequest(
                target: "0x0000000000000000000000000000000000000002",
                value: Data([60]),
                callData: Data()
            ),
        ])
        #expect(total == wei(100))
    }

    @Test func batchCallValueOverflowIsRejected() {
        #expect(throws: AppError.self) {
            _ = try UserOperationCallValue.wei(for: [
                KernelExecutionRequest(
                    target: "0x0000000000000000000000000000000000000001",
                    value: Data(repeating: 0xff, count: 32),
                    callData: Data()
                ),
                KernelExecutionRequest(
                    target: "0x0000000000000000000000000000000000000002",
                    value: Data([1]),
                    callData: Data()
                ),
            ])
        }
    }
}
