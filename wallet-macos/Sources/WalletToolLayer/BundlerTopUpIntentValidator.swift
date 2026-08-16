/// Strict validation for the amount-only `top_up_bundler` contract.
///
/// The destination is deliberately absent from this boundary. Callers must
/// resolve it from trusted local relayer state instead of model-supplied args.
public enum BundlerTopUpIntentValidator {
    /// Any 59-digit whole-ETH value remains within UInt256 after conversion to
    /// wei. Some 60-digit values fit, but accepting the whole class would not.
    public static let maximumIntegerDigits = 59
    public static let maximumFractionalDigits = 18

    /// Returns the original amount only when the argument object exactly
    /// matches the product-owned amount-only contract.
    public static func validatedAmount(
        from arguments: [String: String]
    ) -> String? {
        guard arguments.count == 1,
              let amount = arguments["amount"],
              isValidAmount(amount) else {
            return nil
        }
        return amount
    }

    /// Convenience overload for boundaries that already have a `ToolIntent`.
    public static func validatedAmount(from intent: ToolIntent) -> String? {
        guard intent.tool == .topUpBundler else {
            return nil
        }
        return validatedAmount(from: intent.args)
    }

    private static func isValidAmount(_ amount: String) -> Bool {
        let parts = amount.split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 1 || parts.count == 2 else {
            return false
        }

        let integer = parts[0]
        guard !integer.isEmpty,
              integer.utf8.count <= maximumIntegerDigits,
              integer.utf8.allSatisfy(isASCIIDigit) else {
            return false
        }

        if parts.count == 2 {
            let fraction = parts[1]
            guard !fraction.isEmpty,
                  fraction.utf8.count <= maximumFractionalDigits,
                  fraction.utf8.allSatisfy(isASCIIDigit) else {
                return false
            }
        }

        return amount.utf8.contains { byte in
            byte >= 0x31 && byte <= 0x39
        }
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }
}
