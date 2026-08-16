import Foundation
import Testing
@testable import WalletMacOSApp

private func gwei(_ data: Data) -> String { GasPricing.gweiText(fromWei: data) }

private func feeQuote(nextBaseFeeWei: UInt64, priorityWei: UInt64) throws -> ExecutionFeeQuote {
    let nextBase = Data.fromBigEndian(nextBaseFeeWei).leftPadded(to: 32)
    let priority = Data.fromBigEndian(priorityWei).leftPadded(to: 32)
    let grown = try GasPricing.sixBlockBaseFeeCeiling(nextBlockBaseFeePerGas: nextBase)
    let maxFee = try GasPricing.checkedAddWei(grown, priority)
    return ExecutionFeeQuote(
        chainID: 11_155_111,
        blockNumber: 100,
        issuedAt: Date(timeIntervalSince1970: 1_000),
        nextBlockBaseFeePerGas: nextBase,
        medianPriorityFeePerGas: priority,
        sixBlockMaxFeePerGas: maxFee
    )
}

@Test func autoModeUsesTierTipAndExactSixBlockBaseFeeGrowth() throws {
    let quote = try feeQuote(nextBaseFeeWei: 18_000_000_000, priorityWei: 2_000_000_000)
    let cap = try WalletNodeDaemon.GasPolicy.custom(maxFeePerGasGwei: "5", maxPriorityFeePerGasGwei: "1")

    let fast = try GasPricing.resolveUserOperationFees(
        quote: quote, autoEnabled: true, autoTier: .fast, manualCap: cap
    )
    #expect(gwei(fast.maxFeePerGas) == "38.99")
    #expect(gwei(fast.maxPriorityFeePerGas) == "2.5")

    let slow = try GasPricing.resolveUserOperationFees(
        quote: quote, autoEnabled: true, autoTier: .slow, manualCap: cap
    )
    #expect(gwei(slow.maxFeePerGas) == "38.19")
    #expect(gwei(slow.maxPriorityFeePerGas) == "1.7")

    let standard = try GasPricing.resolveUserOperationFees(
        quote: quote, autoEnabled: true, autoTier: .standard, manualCap: cap
    )
    #expect(gwei(standard.maxFeePerGas) == "38.49")
    #expect(gwei(standard.maxPriorityFeePerGas) == "2")
}

@Test func manualModeUsesLiveFeesWhenTheyFitConfiguredAndImmutableCaps() throws {
    let quote = try feeQuote(nextBaseFeeWei: 18_000_000_000, priorityWei: 2_000_000_000)
    let cap = try WalletNodeDaemon.GasPolicy.custom(maxFeePerGasGwei: "100", maxPriorityFeePerGasGwei: "10")

    let r = try GasPricing.resolveUserOperationFees(
        quote: quote, autoEnabled: false, autoTier: .standard, manualCap: cap
    )
    #expect(gwei(r.maxFeePerGas) == "38.49")
    #expect(gwei(r.maxPriorityFeePerGas) == "2")
}

@Test func manualModeFailsClosedWhenCurrentViableFeeExceedsManualCap() throws {
    let quote = try feeQuote(nextBaseFeeWei: 18_000_000_000, priorityWei: 2_000_000_000)
    let cap = try WalletNodeDaemon.GasPolicy.custom(maxFeePerGasGwei: "30", maxPriorityFeePerGasGwei: "3")

    #expect(throws: GasPricing.FeeError.self) {
        _ = try GasPricing.resolveUserOperationFees(
            quote: quote, autoEnabled: false, autoTier: .standard, manualCap: cap
        )
    }
}

@Test func manualModeFailsClosedWhenPriorityExceedsManualCap() throws {
    let quote = try feeQuote(nextBaseFeeWei: 1_000_000_000, priorityWei: 2_000_000_000)
    let cap = try WalletNodeDaemon.GasPolicy.custom(maxFeePerGasGwei: "50", maxPriorityFeePerGasGwei: "1")

    #expect(throws: GasPricing.FeeError.self) {
        _ = try GasPricing.resolveUserOperationFees(
            quote: quote, autoEnabled: false, autoTier: .standard, manualCap: cap
        )
    }
}

@Test func immutableAppCapsAllowExactValuesAndRejectCapPlusOne() throws {
    let nextBase = Data.fromBigEndian(UInt64(22_500_000_000)).leftPadded(to: 32)
    let grown = try GasPricing.sixBlockBaseFeeCeiling(nextBlockBaseFeePerGas: nextBase)
    let maxCap = GasPricing.appMaxFeePerGas
    let exactPriority = try GasPricing.checkedSubtractWei(maxCap, grown)
    let exactQuote = ExecutionFeeQuote(
        chainID: 11_155_111,
        blockNumber: 100,
        issuedAt: Date(),
        nextBlockBaseFeePerGas: nextBase,
        medianPriorityFeePerGas: exactPriority,
        sixBlockMaxFeePerGas: maxCap
    )
    let cap = WalletNodeDaemon.GasPolicy.sepolia

    _ = try GasPricing.resolveUserOperationFees(
        quote: exactQuote, autoEnabled: true, autoTier: .standard, manualCap: cap
    )

    let oneWei = Data.fromBigEndian(UInt64(1)).leftPadded(to: 32)
    let overPriority = try GasPricing.checkedAddWei(exactPriority, oneWei)
    let overQuote = ExecutionFeeQuote(
        chainID: exactQuote.chainID,
        blockNumber: exactQuote.blockNumber,
        issuedAt: exactQuote.issuedAt,
        nextBlockBaseFeePerGas: nextBase,
        medianPriorityFeePerGas: overPriority,
        sixBlockMaxFeePerGas: try GasPricing.checkedAddWei(maxCap, oneWei)
    )
    #expect(throws: GasPricing.FeeError.self) {
        _ = try GasPricing.resolveUserOperationFees(
            quote: overQuote, autoEnabled: true, autoTier: .standard, manualCap: cap
        )
    }
}

@Test func immutablePriorityCapAllowsExactValueAndRejectsCapPlusOne() throws {
    let cap = WalletNodeDaemon.GasPolicy.sepolia
    let exact = try feeQuote(nextBaseFeeWei: 0, priorityWei: 5_000_000_000)
    _ = try GasPricing.resolveUserOperationFees(
        quote: exact, autoEnabled: true, autoTier: .standard, manualCap: cap
    )

    let over = try feeQuote(nextBaseFeeWei: 0, priorityWei: 5_000_000_001)
    #expect(throws: GasPricing.FeeError.self) {
        _ = try GasPricing.resolveUserOperationFees(
            quote: over, autoEnabled: true, autoTier: .standard, manualCap: cap
        )
    }
}

@Test func oversizedWeiIsRejectedInsteadOfTakingItsLowSixtyFourBits() throws {
    let oversized = Data([0x01]) + Data(repeating: 0, count: 32)
    #expect(throws: GasPricing.FeeError.self) {
        _ = try GasPricing.sixBlockBaseFeeCeiling(nextBlockBaseFeePerGas: oversized)
    }
}

@Test func legacyDaemonDisplayPathFailsClosedOnOversizedFee() throws {
    let oversized = Data([0x01]) + Data(repeating: 0, count: 32)
    let tier = WalletNodeClient.UserOperationGasPriceTier(
        maxFeePerGas: oversized,
        maxPriorityFeePerGas: Data.fromBigEndian(UInt64(1)).leftPadded(to: 32)
    )
    let daemonQuote = WalletNodeClient.UserOperationGasPrice(
        slow: tier,
        standard: tier,
        fast: tier
    )
    let resolved = GasPricing.resolveUserOperationFees(
        gasPrice: daemonQuote,
        autoEnabled: true,
        autoTier: .standard,
        manualCap: .sepolia
    )

    #expect(resolved.maxFeePerGas == Data(repeating: 0, count: 32))
    #expect(resolved.maxPriorityFeePerGas == Data(repeating: 0, count: 32))
}

@Test func minWeiPicksSmaller() {
    let a = Data.fromBigEndian(UInt64(100)).leftPadded(to: 32)
    let b = Data.fromBigEndian(UInt64(250)).leftPadded(to: 32)
    #expect(GasPricing.minWei(a, b) == a)
    #expect(GasPricing.minWei(b, a) == a)
}

@Test func gweiTextFormatsCompactly() {
    #expect(GasPricing.gweiText(fromWei: Data.fromBigEndian(UInt64(24_000_000_000)).leftPadded(to: 32)) == "24")
    #expect(GasPricing.gweiText(fromWei: Data.fromBigEndian(UInt64(1_500_000_000)).leftPadded(to: 32)) == "1.5")
    #expect(GasPricing.gweiText(fromWei: Data.fromBigEndian(UInt64(500_000_000)).leftPadded(to: 32)) == "0.5")
    #expect(GasPricing.gweiText(fromWei: Data.fromBigEndian(UInt64(1_234_000_000)).leftPadded(to: 32)) == "1.23")
    #expect(GasPricing.gweiText(fromWei: Data([0])) == "0")
}

@Test func gweiTextReturnsSentinelForOversizedValues() {
    // 9 significant bytes — exceeds 64-bit range, not a realistic gas value.
    #expect(GasPricing.gweiText(fromWei: Data([0x01, 0, 0, 0, 0, 0, 0, 0, 0])) == "high")
}

@Test func baseFeeWeiDerivesExactlyFromStandardTier() {
    // baseFee = gasPrice − priorityTip (geth: gasPrice = baseFee + tip), exact.
    let maxFee = Data.fromBigEndian(UInt64(2_093_623_001)).leftPadded(to: 32)
    let priority = Data.fromBigEndian(UInt64(1_000_000)).leftPadded(to: 32)
    let base = GasPricing.baseFeeWei(standardMaxFee: maxFee, standardPriority: priority)
    #expect(GasPricing.gweiText(fromWei: base) == "2.09") // 2.092623001 gwei → 2 dp
}

@Test func baseFeeWeiClampsToZeroWhenPriorityExceedsMaxFee() {
    let maxFee = Data.fromBigEndian(UInt64(1_000_000)).leftPadded(to: 32)
    let priority = Data.fromBigEndian(UInt64(2_000_000)).leftPadded(to: 32)
    let base = GasPricing.baseFeeWei(standardMaxFee: maxFee, standardPriority: priority)
    #expect(GasPricing.gweiText(fromWei: base) == "0")
}

@Test func gweiTextKeepsSmallSubCentiGweiValues() {
    // Very small priority fees such as 0.001 gwei (1_000_000 wei) remain visible.
    // It must NOT round to "0".
    #expect(GasPricing.gweiText(fromWei: Data.fromBigEndian(UInt64(1_000_000)).leftPadded(to: 32)) == "0.001")
    // Sub-gwei values keep up to 3 decimals.
    #expect(GasPricing.gweiText(fromWei: Data.fromBigEndian(UInt64(425_000_000)).leftPadded(to: 32)) == "0.425")
    // A non-zero tip below display precision shows a floor sentinel, not "0".
    #expect(GasPricing.gweiText(fromWei: Data.fromBigEndian(UInt64(100_000)).leftPadded(to: 32)) == "<0.001")
    // Exactly zero is still "0".
    #expect(GasPricing.gweiText(fromWei: Data.fromBigEndian(UInt64(0)).leftPadded(to: 32)) == "0")
}
