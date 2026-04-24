import Foundation

enum EtherAmountParser {
    static func wei(fromETHString value: String) throws -> Data {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidAmount
        }

        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else {
            throw AppError.invalidAmount
        }

        let wholePart = String(parts[0])
        let fractionalPart = parts.count == 2 ? String(parts[1]) : ""

        guard wholePart.allSatisfy(\.isNumber), fractionalPart.allSatisfy(\.isNumber) else {
            throw AppError.invalidAmount
        }
        guard fractionalPart.count <= 18 else {
            throw AppError.invalidAmount
        }

        let normalizedWhole = wholePart.isEmpty ? "0" : wholePart
        let paddedFraction = fractionalPart + String(repeating: "0", count: 18 - fractionalPart.count)
        let decimalString = normalizedWhole + paddedFraction
        let normalizedDecimal = decimalString.drop { $0 == "0" }

        guard !normalizedDecimal.isEmpty else {
            return Data(repeating: 0, count: 32)
        }

        return try hexData(fromDecimalString: String(normalizedDecimal)).leftPadded(to: 32)
    }

    private static func hexData(fromDecimalString value: String) throws -> Data {
        var digits = value.compactMap(\.wholeNumberValue)
        var bytes = [UInt8]()

        while !digits.isEmpty {
            var quotient = [Int]()
            quotient.reserveCapacity(digits.count)
            var remainder = 0

            for digit in digits {
                let accumulator = remainder * 10 + digit
                let q = accumulator / 256
                remainder = accumulator % 256
                if !quotient.isEmpty || q != 0 {
                    quotient.append(q)
                }
            }

            bytes.append(UInt8(remainder))
            digits = quotient
        }

        guard !bytes.isEmpty else {
            throw AppError.invalidAmount
        }

        return Data(bytes.reversed())
    }
}
