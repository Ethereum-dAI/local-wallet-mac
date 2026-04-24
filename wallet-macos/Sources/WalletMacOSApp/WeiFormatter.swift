import Foundation

enum WeiFormatter {
    static func ethDisplayString(fromHexWei value: String) -> String {
        let normalized = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
        let trimmed = normalized.drop { $0 == "0" }

        guard !trimmed.isEmpty else {
            return "0 ETH"
        }

        var digits = [Int](repeating: 0, count: 1)
        for scalar in trimmed.lowercased() {
            guard let hexValue = scalar.hexDigitValue else {
                return "\(value) wei"
            }

            multiplyDecimalDigitsBy16(&digits)
            addHexValue(hexValue, to: &digits)
        }

        let decimal = digits.reversed().map(String.init).joined()
        let splitIndex = max(decimal.count - 18, 0)
        let whole = splitIndex == 0 ? "0" : String(decimal.prefix(splitIndex))
        let fractionRaw = splitIndex == 0 ? String(decimal).leftPadding(to: 18, with: "0") : String(decimal.suffix(18))
        let fraction = String(fractionRaw.prefix(6)).trimmingTrailingZeros()

        if fraction.isEmpty {
            return "\(whole) ETH"
        }

        return "\(whole).\(fraction) ETH"
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
