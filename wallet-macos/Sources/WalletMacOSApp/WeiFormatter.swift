import Foundation

enum WeiFormatter {
    static func ethDisplayString(fromHexWei value: String) -> String {
        guard let decimal = decimalWeiString(fromHexWei: value) else {
            return "\(value) wei"
        }
        guard decimal != "0" else {
            return "0 ETH"
        }
        let splitIndex = max(decimal.count - 18, 0)
        let whole = splitIndex == 0 ? "0" : String(decimal.prefix(splitIndex))
        let fractionRaw = splitIndex == 0 ? String(decimal).leftPadding(to: 18, with: "0") : String(decimal.suffix(18))
        let fraction = String(fractionRaw.prefix(6)).trimmingTrailingZeros()

        if fraction.isEmpty {
            return "\(whole) ETH"
        }

        return "\(whole).\(fraction) ETH"
    }

    /// Formats a maximum fee without ever displaying less than the authorized
    /// amount. Ordinary balance formatting truncates after six decimals; that
    /// is unsafe for a signing prompt because a non-zero liability could appear
    /// as zero. This rounds upward to the nearest micro-ETH instead.
    static func ethUpperBoundDisplayString(fromHexWei value: String) -> String {
        guard let decimal = decimalWeiString(fromHexWei: value) else {
            return "\(value) wei"
        }
        guard decimal != "0" else {
            return "0 ETH"
        }

        let discardedDigitCount = 12 // 18 ETH decimals - 6 displayed decimals
        let quotient: String
        let remainder: Substring
        if decimal.count > discardedDigitCount {
            let splitIndex = decimal.index(decimal.endIndex, offsetBy: -discardedDigitCount)
            quotient = String(decimal[..<splitIndex])
            remainder = decimal[splitIndex...]
        } else {
            quotient = "0"
            remainder = decimal[decimal.startIndex...]
        }

        let roundedMicroETH = remainder.allSatisfy({ $0 == "0" })
            ? quotient
            : incrementDecimalString(quotient)
        let splitIndex = max(roundedMicroETH.count - 6, 0)
        let whole = splitIndex == 0 ? "0" : String(roundedMicroETH.prefix(splitIndex))
        let fractionRaw = splitIndex == 0
            ? roundedMicroETH.leftPadding(to: 6, with: "0")
            : String(roundedMicroETH.suffix(6))
        let fraction = fractionRaw.trimmingTrailingZeros()

        return fraction.isEmpty ? "\(whole) ETH" : "\(whole).\(fraction) ETH"
    }

    private static func decimalWeiString(fromHexWei value: String) -> String? {
        let normalized = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
        let trimmed = normalized.drop { $0 == "0" }
        guard !trimmed.isEmpty else {
            return "0"
        }

        var digits = [Int](repeating: 0, count: 1)
        for scalar in trimmed.lowercased() {
            guard let hexValue = scalar.hexDigitValue else {
                return nil
            }
            multiplyDecimalDigitsBy16(&digits)
            addHexValue(hexValue, to: &digits)
        }
        return digits.reversed().map(String.init).joined()
    }

    private static func incrementDecimalString(_ value: String) -> String {
        var digits = value.reversed().compactMap(\.wholeNumberValue)
        var carry = 1
        var index = 0
        while carry > 0 {
            if index == digits.count {
                digits.append(0)
            }
            let sum = digits[index] + carry
            digits[index] = sum % 10
            carry = sum / 10
            index += 1
        }
        return digits.reversed().map(String.init).joined()
    }

    private static func multiplyDecimalDigitsBy16(_ digits: inout [Int]) {
        var carry = 0
        for index in 0..<digits.count {
            let value = digits[index] * 16 + carry
            digits[index] = value % 10
            carry = value / 10
        }

        while carry > 0 {
            digits.append(carry % 10)
            carry /= 10
        }
    }

    private static func addHexValue(_ value: Int, to digits: inout [Int]) {
        var carry = value
        var index = 0
        while carry > 0 {
            if index == digits.count {
                digits.append(0)
            }

            let total = digits[index] + carry
            digits[index] = total % 10
            carry = total / 10
            index += 1
        }
    }
}

// Formats a balance straight from a JSON-RPC hex *quantity*.
//
// `eth_getBalance` returns a minimally-encoded quantity, so an odd nibble count is normal
// (0.1 ETH is `0x16345785d8a0000`). `Data(hexString:)` parses fixed-width byte strings and
// rejects odd-length input, so quantities must go through `Data.quantityString`. Throwing
// here is deliberate: a balance that cannot be parsed has to surface as unavailable, never
// as a `0` that looks like the funds are gone.
enum TokenBalanceDisplay {
    static func displayString(balanceHex: String, decimals: Int, symbol: String) throws -> String {
        let rawUnits = try Data.quantityString(balanceHex)
        return TokenAmountFormatter.displayString(
            rawUnits: rawUnits,
            decimals: decimals,
            symbol: symbol
        )
    }
}

enum TokenAmountFormatter {
    static func displayString(rawUnits: Data, decimals: Int, symbol: String) -> String {
        let trimmed = rawUnits.drop { $0 == 0 }
        guard !trimmed.isEmpty else {
            return "0 \(symbol)"
        }

        var digits = [Int](repeating: 0, count: 1)
        for byte in trimmed {
            multiplyDecimalDigitsBy256(&digits)
            addByte(Int(byte), to: &digits)
        }

        let decimal = digits.reversed().map(String.init).joined()
        let splitIndex = max(decimal.count - decimals, 0)
        let whole = splitIndex == 0 ? "0" : String(decimal.prefix(splitIndex))
        let fractionRaw = decimals == 0
            ? ""
            : (splitIndex == 0
               ? String(decimal).leftPadding(to: decimals, with: "0")
               : String(decimal.suffix(decimals)))
        let fraction = String(fractionRaw.prefix(6)).trimmingTrailingZeros()

        if fraction.isEmpty {
            return "\(whole) \(symbol)"
        }
        return "\(whole).\(fraction) \(symbol)"
    }

    private static func multiplyDecimalDigitsBy256(_ digits: inout [Int]) {
        var carry = 0
        for index in 0..<digits.count {
            let value = digits[index] * 256 + carry
            digits[index] = value % 10
            carry = value / 10
        }

        while carry > 0 {
            digits.append(carry % 10)
            carry /= 10
        }
    }

    private static func addByte(_ value: Int, to digits: inout [Int]) {
        var carry = value
        var index = 0
        while carry > 0 {
            if index == digits.count {
                digits.append(0)
            }

            let total = digits[index] + carry
            digits[index] = total % 10
            carry = total / 10
            index += 1
        }
    }
}

private extension String {
    func leftPadding(to length: Int, with character: Character) -> String {
        if count >= length {
            return self
        }
        return String(repeating: String(character), count: length - count) + self
    }

    func trimmingTrailingZeros() -> String {
        var value = self
        while value.last == "0" {
            value.removeLast()
        }
        return value
    }
}
