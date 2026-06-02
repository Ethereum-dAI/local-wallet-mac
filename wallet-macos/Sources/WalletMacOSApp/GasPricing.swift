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

    /// Compact gwei text from a big-endian wei value, e.g. "24", "1.5", "1.23",
    /// "0.001". Precision scales with magnitude: 2 decimals at/above 1 gwei, 3
    /// below so small tips (mainnet's 0.001 gwei priority floor) stay visible.
    /// A non-zero value too small for that precision renders as "<0.001", never "0".
    static func gweiText(fromWei data: Data) -> String {
        let trimmed = Data(data.drop { $0 == 0 })
        guard trimmed.count <= 8 else { return "high" }
        var wei: UInt64 = 0
        for byte in trimmed { wei = (wei << 8) | UInt64(byte) }
        if wei == 0 { return "0" }

        var whole = wei / 1_000_000_000
        let frac = wei % 1_000_000_000
        // 2 decimals (1/100 gwei) at/above 1 gwei, 3 (1/1000 gwei) below.
        let decimals = whole >= 1 ? 2 : 3
        let scale: UInt64 = decimals == 2 ? 10_000_000 : 1_000_000
        let limit: UInt64 = decimals == 2 ? 100 : 1_000
        var units = (frac + scale / 2) / scale // rounded fractional units
        if units >= limit { whole += 1; units = 0 }

        if units == 0 {
            // Below display precision: a real but tiny tip must not read as "0".
            return whole == 0 ? "<0.001" : String(whole)
        }
        var fraction = String(units)
        while fraction.count < decimals { fraction = "0" + fraction }
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return "\(whole).\(fraction)"
    }
}
