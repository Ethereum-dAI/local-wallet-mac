import Foundation
import Testing
@testable import WalletMacOSApp

/// `gas_price.rs` clamps to `(max_fee_cap, priority_cap)` on all three tiers when
/// the chain price is above the cap. The app cannot tell that apart from a live
/// quote by magnitude, but it can by *shape*.
@Suite struct GasPriceFallbackTests {
    private func tier(maxFee: UInt64, priority: UInt64) -> WalletNodeClient.UserOperationGasPriceTier {
        WalletNodeClient.UserOperationGasPriceTier(
            maxFeePerGas: Data.fromBigEndian(maxFee).leftPadded(to: 32),
            maxPriorityFeePerGas: Data.fromBigEndian(priority).leftPadded(to: 32)
        )
    }

    @Test func detectsTheUniformCeilingQuote() {
        // What the daemon returns when the price is above the cap:
        // (max_fee_cap, priority_cap) repeated across slow/standard/fast.
        let capped = tier(maxFee: 1_500_000_000_000, priority: 100_000_000_000)
        let quote = WalletNodeClient.UserOperationGasPrice(
            slow: capped,
            standard: capped,
            fast: capped
        )

        #expect(GasPricing.isPolicyCeilingQuote(quote))
    }

    @Test func aLiveQuoteIsNotMistakenForACeilingQuote() {
        // derive_fee_tiers spreads slow/standard/fast around the chain value, so a
        // real quote never arrives with all three identical.
        let quote = WalletNodeClient.UserOperationGasPrice(
            slow: tier(maxFee: 18_000_000_000, priority: 900_000_000),
            standard: tier(maxFee: 20_000_000_000, priority: 1_000_000_000),
            fast: tier(maxFee: 24_000_000_000, priority: 1_200_000_000)
        )

        #expect(GasPricing.isPolicyCeilingQuote(quote) == false)
    }

    @Test func aSingleDifferingFieldIsEnoughToLookLive() {
        let base = tier(maxFee: 20_000_000_000, priority: 1_000_000_000)
        let quote = WalletNodeClient.UserOperationGasPrice(
            slow: base,
            standard: base,
            fast: tier(maxFee: 20_000_000_000, priority: 1_000_000_001)
        )

        #expect(GasPricing.isPolicyCeilingQuote(quote) == false)
    }

    @Test func anAllZeroQuoteIsNotTreatedAsACeilingQuote() {
        // Zeroed tiers are degenerate but they are not a ceiling clamp, and
        // labelling them as one would mislabel a different bug.
        let zero = tier(maxFee: 0, priority: 0)
        let quote = WalletNodeClient.UserOperationGasPrice(slow: zero, standard: zero, fast: zero)

        #expect(GasPricing.isPolicyCeilingQuote(quote) == false)
    }
}
