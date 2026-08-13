import Foundation

/// Recognizes the product-owned bundler top-up prompt without allowing an
/// untrusted destination to enter the intent.
public enum BundlerTopUpIntentParser {
    private static let expression = try! NSRegularExpression(
        pattern: #"(?i)^\s*(?:top\s*up|fund|refill)\s+(?:the\s+)?bundler\s+(?:with\s+)?([0-9]+(?:\.[0-9]+)?)\s*(?:eth)?\s*$"#
    )

    public static func parse(_ input: String) -> ToolIntent? {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let match = expression.firstMatch(in: input, range: range),
              match.range == range,
              let amountRange = Range(match.range(at: 1), in: input) else {
            return nil
        }

        let arguments = ["amount": String(input[amountRange])]
        guard BundlerTopUpIntentValidator.validatedAmount(from: arguments) != nil else {
            return nil
        }

        return ToolIntent(
            tool: .topUpBundler,
            args: arguments,
            source: .model
        )
    }
}
