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
    /// `maxFeePerGas` is given EIP-1559 headroom — `baseFeeHeadroomMultiplier × baseFee
    /// + tip` — so a base-fee rise between building and inclusion can't strand the tx
    /// (the failure we saw: a 0.97 gwei maxFee left unmineable once the base fee rose to
    /// 1.1 gwei). This raises only the *ceiling*; the effective fee paid is still
    /// `baseFee + tip`, so it costs no more. baseFee is derived from the standard tier.
    ///
    /// - Auto: the selected tier's tip, with headroom on maxFee (uncapped — the daemon's
    ///   generous launch ceiling is the only bound).
    /// - Manual: the standard tier's tip clamped to the priority cap, with headroom on
    ///   maxFee but never above the configured max-fee cap (priority never above maxFee).
    /// - `autoTier` is consulted only when `autoEnabled` is true.
    static func resolveUserOperationFees(
        gasPrice: WalletNodeClient.UserOperationGasPrice,
        autoEnabled: Bool,
        autoTier: GasTier,
        manualCap: WalletNodeDaemon.GasPolicy
    ) -> (maxPriorityFeePerGas: Data, maxFeePerGas: Data) {
        let standard = gasPrice.standard
        let baseFee = weiUInt64(baseFeeWei(
            standardMaxFee: standard.maxFeePerGas,
            standardPriority: standard.maxPriorityFeePerGas
        ))

        if autoEnabled {
            let tier: WalletNodeClient.UserOperationGasPriceTier
            switch autoTier {
            case .slow: tier = gasPrice.slow
            case .standard: tier = gasPrice.standard
            case .fast: tier = gasPrice.fast
            }
            let priority = tier.maxPriorityFeePerGas
            return (priority, headroomMaxFee(baseFee: baseFee, priority: priority))
        }

        // GasPolicy hex fields are always well-formed (built via custom()/defaults),
        // so quantityString cannot fail in practice; fall back to the live value if it ever does.
        let capMax = (try? Data.quantityString(manualCap.maxFeePerGas).leftPadded(to: 32)) ?? standard.maxFeePerGas
        let capPriority = (try? Data.quantityString(manualCap.maxPriorityFeePerGas).leftPadded(to: 32)) ?? standard.maxPriorityFeePerGas

        let priority = minWei(standard.maxPriorityFeePerGas, capPriority)
        let maxFee = minWei(headroomMaxFee(baseFee: baseFee, priority: priority), capMax)
        return (minWei(priority, maxFee), maxFee) // priority never above maxFee
    }

    /// Multiplier applied to the base fee when computing maxFeePerGas headroom. 2× base
    /// fee survives ~6 blocks of maximum (12.5%/block) base-fee growth before stranding.
    private static let baseFeeHeadroomMultiplier: UInt64 = 2

    /// maxFeePerGas = `multiplier × baseFee + priorityTip`, in UInt64 with saturation
    /// (realistic gas values fit in 64 bits). Returned as 32-byte big-endian wei.
    private static func headroomMaxFee(baseFee: UInt64, priority: Data) -> Data {
        let scaled = baseFee.multipliedReportingOverflow(by: baseFeeHeadroomMultiplier)
        let scaledBase = scaled.overflow ? UInt64.max : scaled.partialValue
        let sum = scaledBase.addingReportingOverflow(weiUInt64(priority))
        let value = sum.overflow ? UInt64.max : sum.partialValue
        return Data.fromBigEndian(value).leftPadded(to: 32)
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

    /// Network base fee, derived from the standard tier as
    /// `eth_gasPrice − eth_maxPriorityFeePerGas`. geth defines
    /// `gasPrice = baseFee + priorityTip`, so this is exact and needs no extra
    /// RPC — it stays correct even when the light client can't serve blocks.
    /// Clamped to zero if the tip somehow exceeds the gas price.
    static func baseFeeWei(standardMaxFee: Data, standardPriority: Data) -> Data {
        let maxFee = weiUInt64(standardMaxFee)
        let priority = weiUInt64(standardPriority)
        let base = maxFee >= priority ? maxFee - priority : 0
        return Data.fromBigEndian(base).leftPadded(to: 32)
    }

    /// Low-64-bit value of a big-endian wei blob (realistic gas values fit in UInt64).
    private static func weiUInt64(_ data: Data) -> UInt64 {
        var value: UInt64 = 0
        for byte in Data(data.drop { $0 == 0 }).suffix(8) {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }
}
