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

/// Checked app-side EIP-1559 fee policy.
enum GasPricing {
    enum FeeError: Error, Equatable, LocalizedError {
        case invalidWidth(field: String)
        case valueTooLarge(field: String)
        case arithmeticOverflow
        case priorityAboveMaxFee
        case appCapExceeded(field: String, capGwei: String)
        case inconsistentQuote
        case manualCapBelowRequired(field: String, requiredGwei: String, capGwei: String)

        var errorDescription: String? {
            switch self {
            case .invalidWidth(let field):
                return "\(field) must be an exact 32-byte fee value."
            case .valueTooLarge(let field):
                return "\(field) exceeds the supported fee range."
            case .arithmeticOverflow:
                return "Fee calculation overflowed. Fetch a fresh quote and retry."
            case .priorityAboveMaxFee:
                return "The priority fee exceeds the maximum fee."
            case .appCapExceeded(let field, let capGwei):
                return "Current \(field) exceeds the app safety cap of \(capGwei) gwei. Wait for gas to fall and retry."
            case .inconsistentQuote:
                return "The fee quote does not match its base fee and priority fee. Fetch a fresh quote and retry."
            case .manualCapBelowRequired(let field, let requiredGwei, let capGwei):
                return "Current \(field) is \(requiredGwei) gwei, above your \(capGwei) gwei cap. Raise the cap or retry later."
            }
        }

        var isRetryable: Bool {
            switch self {
            case .appCapExceeded, .manualCapBelowRequired, .inconsistentQuote:
                return true
            case .invalidWidth, .valueTooLarge, .arithmeticOverflow, .priorityAboveMaxFee:
                return false
            }
        }
    }

    static let appMaxFeePerGas = Data.fromBigEndian(UInt64(50_000_000_000)).leftPadded(to: 32)
    static let appMaxPriorityFeePerGas = Data.fromBigEndian(UInt64(5_000_000_000)).leftPadded(to: 32)

    /// Resolves a fresh independent quote against automatic or manual product policy.
    /// Both modes remain bounded by the immutable 50/5 gwei app caps.
    static func resolveUserOperationFees(
        quote: ExecutionFeeQuote,
        autoEnabled: Bool,
        autoTier: GasTier,
        manualCap: WalletNodeDaemon.GasPolicy
    ) throws -> (maxPriorityFeePerGas: Data, maxFeePerGas: Data) {
        try requireExactWidth(quote.nextBlockBaseFeePerGas, field: "nextBlockBaseFeePerGas")
        try requireExactWidth(quote.medianPriorityFeePerGas, field: "medianPriorityFeePerGas")
        try requireExactWidth(quote.sixBlockMaxFeePerGas, field: "sixBlockMaxFeePerGas")

        let grownBase = try sixBlockBaseFeeCeiling(
            nextBlockBaseFeePerGas: quote.nextBlockBaseFeePerGas
        )
        let expectedStandardMax = try checkedAddWei(grownBase, quote.medianPriorityFeePerGas)
        guard expectedStandardMax == quote.sixBlockMaxFeePerGas else {
            throw FeeError.inconsistentQuote
        }
        try validateAppCaps(
            maxFeePerGas: expectedStandardMax,
            maxPriorityFeePerGas: quote.medianPriorityFeePerGas
        )

        if autoEnabled {
            let priority = try tieredPriorityFee(
                quote.medianPriorityFeePerGas,
                tier: autoTier
            )
            let maxFee = try checkedAddWei(grownBase, priority)
            try validateAppCaps(maxFeePerGas: maxFee, maxPriorityFeePerGas: priority)
            return (priority, maxFee)
        }

        let configuredMax = try policyQuantity(
            manualCap.maxFeePerGas,
            field: "manual max fee"
        )
        let configuredPriority = try policyQuantity(
            manualCap.maxPriorityFeePerGas,
            field: "manual priority fee"
        )
        let effectiveMax = minWei(configuredMax, appMaxFeePerGas).leftPadded(to: 32)
        let effectivePriority = minWei(configuredPriority, appMaxPriorityFeePerGas).leftPadded(to: 32)

        guard !isWeiLessThan(effectivePriority, quote.medianPriorityFeePerGas) else {
            throw FeeError.manualCapBelowRequired(
                field: "priority fee",
                requiredGwei: gweiText(fromWei: quote.medianPriorityFeePerGas),
                capGwei: gweiText(fromWei: effectivePriority)
            )
        }
        guard !isWeiLessThan(effectiveMax, expectedStandardMax) else {
            throw FeeError.manualCapBelowRequired(
                field: "maximum fee",
                requiredGwei: gweiText(fromWei: expectedStandardMax),
                capGwei: gweiText(fromWei: effectiveMax)
            )
        }
        return (quote.medianPriorityFeePerGas, expectedStandardMax)
    }

    /// Legacy compatibility for daemon-backed gas display. Daemon tiers are not
    /// an authorization source. Any malformed, over-cap, or inconsistent value
    /// resolves to zero rather than being truncated or saturated.
    static func resolveUserOperationFees(
        gasPrice: WalletNodeClient.UserOperationGasPrice,
        autoEnabled: Bool,
        autoTier: GasTier,
        manualCap: WalletNodeDaemon.GasPolicy
    ) -> (maxPriorityFeePerGas: Data, maxFeePerGas: Data) {
        let zero = Data(repeating: 0, count: 32)
        let standard = gasPrice.standard
        guard standard.maxFeePerGas.count <= 32,
              standard.maxPriorityFeePerGas.count <= 32
        else {
            return (zero, zero)
        }
        let base = baseFeeWei(
            standardMaxFee: standard.maxFeePerGas,
            standardPriority: standard.maxPriorityFeePerGas
        )
        do {
            let grown = try sixBlockBaseFeeCeiling(nextBlockBaseFeePerGas: base)
            let maxFee = try checkedAddWei(grown, standard.maxPriorityFeePerGas.leftPadded(to: 32))
            let quote = ExecutionFeeQuote(
                chainID: 0,
                blockNumber: 0,
                issuedAt: .distantPast,
                nextBlockBaseFeePerGas: base,
                medianPriorityFeePerGas: standard.maxPriorityFeePerGas.leftPadded(to: 32),
                sixBlockMaxFeePerGas: maxFee
            )
            return try resolveUserOperationFees(
                quote: quote,
                autoEnabled: autoEnabled,
                autoTier: autoTier,
                manualCap: manualCap
            )
        } catch {
            return (zero, zero)
        }
    }

    /// Applies six consecutive maximum EIP-1559 base-fee increases. Every step
    /// rounds upward, so integer division cannot understate the authorization.
    static func sixBlockBaseFeeCeiling(nextBlockBaseFeePerGas: Data) throws -> Data {
        var value = try exactUInt64(nextBlockBaseFeePerGas, field: "nextBlockBaseFeePerGas")
        for _ in 0..<6 {
            let quotient = value / 8
            let remainder = value % 8
            let increase = quotient + (remainder == 0 ? 0 : 1)
            let result = value.addingReportingOverflow(increase)
            guard !result.overflow else { throw FeeError.arithmeticOverflow }
            value = result.partialValue
        }
        return Data.fromBigEndian(value).leftPadded(to: 32)
    }

    static func checkedAddWei(_ lhs: Data, _ rhs: Data) throws -> Data {
        let left = try exactUInt64(lhs, field: "fee")
        let right = try exactUInt64(rhs, field: "fee")
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else { throw FeeError.arithmeticOverflow }
        return Data.fromBigEndian(result.partialValue).leftPadded(to: 32)
    }

    static func checkedSubtractWei(_ lhs: Data, _ rhs: Data) throws -> Data {
        let left = try exactUInt64(lhs, field: "fee")
        let right = try exactUInt64(rhs, field: "fee")
        guard left >= right else { throw FeeError.priorityAboveMaxFee }
        return Data.fromBigEndian(left - right).leftPadded(to: 32)
    }

    static func validateAppCaps(maxFeePerGas: Data, maxPriorityFeePerGas: Data) throws {
        _ = try exactUInt64(maxFeePerGas, field: "maxFeePerGas")
        _ = try exactUInt64(maxPriorityFeePerGas, field: "maxPriorityFeePerGas")
        guard !isWeiLessThan(maxFeePerGas, maxPriorityFeePerGas) else {
            throw FeeError.priorityAboveMaxFee
        }
        guard !isWeiLessThan(appMaxFeePerGas, maxFeePerGas) else {
            throw FeeError.appCapExceeded(field: "maximum fee", capGwei: "50")
        }
        guard !isWeiLessThan(appMaxPriorityFeePerGas, maxPriorityFeePerGas) else {
            throw FeeError.appCapExceeded(field: "priority fee", capGwei: "5")
        }
    }

    static func exactUInt64(_ data: Data, field: String) throws -> UInt64 {
        let significant = data.drop(while: { $0 == 0 })
        guard significant.count <= 8 else {
            throw FeeError.valueTooLarge(field: field)
        }
        var value: UInt64 = 0
        for byte in significant {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    static func isWeiLessThan(_ lhs: Data, _ rhs: Data) -> Bool {
        let width = max(lhs.count, rhs.count)
        let left = lhs.leftPadded(to: width)
        let right = rhs.leftPadded(to: width)
        for (a, b) in zip(left, right) where a != b {
            return a < b
        }
        return false
    }

    /// True when every daemon display tier has the same nonzero shape.
    static func isPolicyCeilingQuote(_ gasPrice: WalletNodeClient.UserOperationGasPrice) -> Bool {
        let standard = gasPrice.standard
        guard standard.maxFeePerGas.contains(where: { $0 != 0 }) else {
            return false
        }
        return gasPrice.slow == standard && gasPrice.fast == standard
    }

    static func minWei(_ a: Data, _ b: Data) -> Data {
        let width = max(32, a.count, b.count)
        let pa = a.leftPadded(to: width)
        let pb = b.leftPadded(to: width)
        return isWeiLessThan(pa, pb) ? pa : pb
    }

    /// Compact gwei text from a big-endian wei value.
    static func gweiText(fromWei data: Data) -> String {
        let trimmed = Data(data.drop { $0 == 0 })
        guard trimmed.count <= 8 else { return "high" }
        var wei: UInt64 = 0
        for byte in trimmed { wei = (wei << 8) | UInt64(byte) }
        if wei == 0 { return "0" }

        var whole = wei / 1_000_000_000
        let frac = wei % 1_000_000_000
        let decimals = whole >= 1 ? 2 : 3
        let scale: UInt64 = decimals == 2 ? 10_000_000 : 1_000_000
        let limit: UInt64 = decimals == 2 ? 100 : 1_000
        var units = (frac + scale / 2) / scale
        if units >= limit { whole += 1; units = 0 }

        if units == 0 {
            return whole == 0 ? "<0.001" : String(whole)
        }
        var fraction = String(units)
        while fraction.count < decimals { fraction = "0" + fraction }
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return "\(whole).\(fraction)"
    }

    /// Exact subtraction for the legacy display path. Invalid or oversized
    /// values fail closed to zero; significant bytes are never dropped.
    static func baseFeeWei(standardMaxFee: Data, standardPriority: Data) -> Data {
        (try? checkedSubtractWei(standardMaxFee, standardPriority))
            ?? Data(repeating: 0, count: 32)
    }

    private static func tieredPriorityFee(_ standard: Data, tier: GasTier) throws -> Data {
        let value = try exactUInt64(standard, field: "medianPriorityFeePerGas")
        let numerator: UInt64
        switch tier {
        case .slow: numerator = 85
        case .standard: numerator = 100
        case .fast: numerator = 125
        }
        let product = value.multipliedReportingOverflow(by: numerator)
        guard !product.overflow else { throw FeeError.arithmeticOverflow }
        return Data.fromBigEndian(product.partialValue / 100).leftPadded(to: 32)
    }

    private static func policyQuantity(_ value: String, field: String) throws -> Data {
        let parsed: Data
        do {
            parsed = try Data.quantityString(value)
        } catch {
            throw FeeError.valueTooLarge(field: field)
        }
        guard parsed.count <= 32 else { throw FeeError.valueTooLarge(field: field) }
        _ = try exactUInt64(parsed, field: field)
        return parsed.leftPadded(to: 32)
    }

    private static func requireExactWidth(_ data: Data, field: String) throws {
        guard data.count == 32 else { throw FeeError.invalidWidth(field: field) }
    }
}
