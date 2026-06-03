import Foundation
import Testing
@testable import WalletMacOSApp

private func tier(maxFeeGwei: UInt64, priorityGwei: UInt64) -> WalletNodeClient.UserOperationGasPriceTier {
    WalletNodeClient.UserOperationGasPriceTier(
        maxFeePerGas: Data.fromBigEndian(maxFeeGwei * 1_000_000_000).leftPadded(to: 32),
        maxPriorityFeePerGas: Data.fromBigEndian(priorityGwei * 1_000_000_000).leftPadded(to: 32)
    )
}

private func price(slow: (UInt64, UInt64), standard: (UInt64, UInt64), fast: (UInt64, UInt64))
    -> WalletNodeClient.UserOperationGasPrice {
    WalletNodeClient.UserOperationGasPrice(
        slow: tier(maxFeeGwei: slow.0, priorityGwei: slow.1),
        standard: tier(maxFeeGwei: standard.0, priorityGwei: standard.1),
        fast: tier(maxFeeGwei: fast.0, priorityGwei: fast.1)
    )
}

private func gwei(_ data: Data) -> String { GasPricing.gweiText(fromWei: data) }

@Test func autoModeUsesTierTipWithBaseFeeHeadroom() throws {
    // baseFee = standard.maxFee - standard.priority = 20 - 2 = 18; headroom maxFee = 2*18 + tip.
    let p = price(slow: (10, 1), standard: (20, 2), fast: (40, 4))
    let cap = try WalletNodeDaemon.GasPolicy.custom(maxFeePerGasGwei: "5", maxPriorityFeePerGasGwei: "1")

    let fast = GasPricing.resolveUserOperationFees(gasPrice: p, autoEnabled: true, autoTier: .fast, manualCap: cap)
    #expect(gwei(fast.maxFeePerGas) == "40")          // 2*18 + 4
    #expect(gwei(fast.maxPriorityFeePerGas) == "4")   // tip verbatim

    let slow = GasPricing.resolveUserOperationFees(gasPrice: p, autoEnabled: true, autoTier: .slow, manualCap: cap)
    #expect(gwei(slow.maxFeePerGas) == "37")          // 2*18 + 1
    #expect(gwei(slow.maxPriorityFeePerGas) == "1")

    let standard = GasPricing.resolveUserOperationFees(gasPrice: p, autoEnabled: true, autoTier: .standard, manualCap: cap)
    #expect(gwei(standard.maxFeePerGas) == "38")      // 2*18 + 2
    #expect(gwei(standard.maxPriorityFeePerGas) == "2")
}

@Test func manualModeAddsMaxFeeHeadroomUnderCap() throws {
    // baseFee 18; headroom maxFee = 2*18 + 2 = 38 (below the 100 cap); tip = standard tip.
    let p = price(slow: (10, 1), standard: (20, 2), fast: (40, 4))
    let cap = try WalletNodeDaemon.GasPolicy.custom(maxFeePerGasGwei: "100", maxPriorityFeePerGasGwei: "10")

    let r = GasPricing.resolveUserOperationFees(gasPrice: p, autoEnabled: false, autoTier: .standard, manualCap: cap)
    #expect(gwei(r.maxFeePerGas) == "38")
    #expect(gwei(r.maxPriorityFeePerGas) == "2")
}

@Test func maxFeeGetsHeadroomSoRisingBaseFeeDoesNotStrand() throws {
    // Reproduces the stranded-tx bug: spot gas ~10 gwei (baseFee 9 + 1 tip). Without
    // headroom maxFee would be ~10 and a base-fee rise past it strands the tx; with
    // headroom maxFee = 2*9 + 1 = 19, leaving room for the base fee to roughly double.
    let p = price(slow: (8, 1), standard: (10, 1), fast: (12, 1))
    let cap = try WalletNodeDaemon.GasPolicy.custom(maxFeePerGasGwei: "50", maxPriorityFeePerGasGwei: "5")

    let r = GasPricing.resolveUserOperationFees(gasPrice: p, autoEnabled: true, autoTier: .standard, manualCap: cap)
    #expect(gwei(r.maxFeePerGas) == "19")
    #expect(gwei(r.maxPriorityFeePerGas) == "1")
}

@Test func manualModeClampsStandardToCaps() throws {
    let p = price(slow: (10, 1), standard: (50, 8), fast: (80, 12))
    let cap = try WalletNodeDaemon.GasPolicy.custom(maxFeePerGasGwei: "30", maxPriorityFeePerGasGwei: "3")

    let r = GasPricing.resolveUserOperationFees(gasPrice: p, autoEnabled: false, autoTier: .standard, manualCap: cap)
    #expect(gwei(r.maxFeePerGas) == "30")        // clamped to max cap
    #expect(gwei(r.maxPriorityFeePerGas) == "3") // clamped to priority cap
}

@Test func manualClampKeepsPriorityNotAboveMaxFee() {
    // standard priority below max cap but above the (low) max-fee cap
    let p = price(slow: (1, 1), standard: (50, 9), fast: (80, 12))
    // Use memberwise init directly: priority cap (20) intentionally exceeds max-fee cap (5)
    // to test that GasPricing clamps priority down to the resolved max fee.
    let cap = WalletNodeDaemon.GasPolicy(
        maxFeePerGas: "0x" + String(5 * 1_000_000_000, radix: 16),
        maxPriorityFeePerGas: "0x" + String(20 * 1_000_000_000, radix: 16),
        maxFeePerGasGwei: "5",
        maxPriorityFeePerGasGwei: "20"
    )

    let r = GasPricing.resolveUserOperationFees(gasPrice: p, autoEnabled: false, autoTier: .standard, manualCap: cap)
    #expect(gwei(r.maxFeePerGas) == "5")
    // priority must not exceed the resolved max fee (5), even though priority cap is 20
    #expect(gwei(r.maxPriorityFeePerGas) == "5")
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
    // Mainnet's low-congestion priority floor is 0.001 gwei (1_000_000 wei).
    // It must NOT round to "0".
    #expect(GasPricing.gweiText(fromWei: Data.fromBigEndian(UInt64(1_000_000)).leftPadded(to: 32)) == "0.001")
    // Sub-gwei values keep up to 3 decimals.
    #expect(GasPricing.gweiText(fromWei: Data.fromBigEndian(UInt64(425_000_000)).leftPadded(to: 32)) == "0.425")
    // A non-zero tip below display precision shows a floor sentinel, not "0".
    #expect(GasPricing.gweiText(fromWei: Data.fromBigEndian(UInt64(100_000)).leftPadded(to: 32)) == "<0.001")
    // Exactly zero is still "0".
    #expect(GasPricing.gweiText(fromWei: Data.fromBigEndian(UInt64(0)).leftPadded(to: 32)) == "0")
}
