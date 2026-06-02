import Foundation

/// Speed tier targeted when automatic gas pricing is enabled.
enum GasTier: String, CaseIterable, Hashable {
    case slow
    case standard
    case fast

    var label: String {
        switch self {
        case .slow: return "Slow"
        case .standard: return "Standard"
        case .fast: return "Fast"
        }
    }
}

/// Pure gas-fee math shared by the daemon launch path and userop construction.
enum GasPricing {
    /// Resolve the (priority, maxFee) a userop should carry.
    ///
    /// - Auto: the selected live tier, uncapped (the wallet follows the network).
    /// - Manual: the live `standard` tier, clamped to the configured caps so it is
    ///   never above them (and priority never above the resolved max fee).
    /// - `autoTier` is consulted only when `autoEnabled` is true.
    static func resolveUserOperationFees(
        gasPrice: WalletNodeClient.UserOperationGasPrice,
        autoEnabled: Bool,
        autoTier: GasTier,
        manualCap: WalletNodeDaemon.GasPolicy
    ) -> (maxPriorityFeePerGas: Data, maxFeePerGas: Data) {
        if autoEnabled {
            let tier: WalletNodeClient.UserOperationGasPriceTier
            switch autoTier {
            case .slow: tier = gasPrice.slow
            case .standard: tier = gasPrice.standard
            case .fast: tier = gasPrice.fast
            }
            return (tier.maxPriorityFeePerGas, tier.maxFeePerGas)
        }

        let standard = gasPrice.standard
        // GasPolicy hex fields are always well-formed (built via custom()/defaults),
        // so quantityString cannot fail in practice; fall back to the live value if it ever does.
        let capMax = (try? Data.quantityString(manualCap.maxFeePerGas).leftPadded(to: 32)) ?? standard.maxFeePerGas
        let capPriority = (try? Data.quantityString(manualCap.maxPriorityFeePerGas).leftPadded(to: 32)) ?? standard.maxPriorityFeePerGas

        let maxFee = minWei(standard.maxFeePerGas, capMax)
        var priority = minWei(standard.maxPriorityFeePerGas, capPriority)
        priority = minWei(priority, maxFee) // invariant: priority <= maxFee
        return (priority, maxFee)
    }

    /// Numeric minimum of two big-endian wei values. Inputs are padded to a common
    /// width (≥32 bytes) so no significant byte is ever dropped, even if a value
    /// somehow exceeds 32 bytes.
    static func minWei(_ a: Data, _ b: Data) -> Data {
        let width = max(32, a.count, b.count)
        let pa = a.leftPadded(to: width)
        let pb = b.leftPadded(to: width)
        for (x, y) in zip(pa, pb) where x != y {
            return x < y ? pa : pb
        }
        return pa
    }

    /// Compact gwei text from a big-endian wei value, e.g. "24", "1.5", "1.23".
    static func gweiText(fromWei data: Data) -> String {
        let trimmed = Data(data.drop { $0 == 0 })
        guard trimmed.count <= 8 else { return "high" }
        var wei: UInt64 = 0
        for byte in trimmed { wei = (wei << 8) | UInt64(byte) }

        var whole = wei / 1_000_000_000
        let frac = wei % 1_000_000_000
        var hundredths = (frac + 5_000_000) / 10_000_000 // round to 1/100 gwei
        if hundredths >= 100 { whole += 1; hundredths = 0 }
        if hundredths == 0 { return String(whole) }
        if hundredths % 10 == 0 { return "\(whole).\(hundredths / 10)" }
        return "\(whole).\(String(format: "%02d", hundredths))"
    }
}
