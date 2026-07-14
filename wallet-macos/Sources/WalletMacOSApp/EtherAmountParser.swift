import Foundation

enum EtherAmountParser {
    static func wei(fromETHString value: String) throws -> Data {
        try units(fromDecimalString: value, decimals: 18)
    }

    /// Wei as a base-10 string (e.g. "0.01" ETH → "10000000000000000"), for JSON-RPC
    /// callers (the railgun-helper sidecar) that expect a decimal amount. Same validation
    /// as `wei(fromETHString:)`.
    static func weiDecimalString(fromETHString value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError.invalidAmount }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw AppError.invalidAmount }
        let wholePart = String(parts[0])
        let fractionalPart = parts.count == 2 ? String(parts[1]) : ""
        guard wholePart.allSatisfy(\.isNumber), fractionalPart.allSatisfy(\.isNumber) else {
            throw AppError.invalidAmount
        }
        if fractionalPart.count > 18 {
            guard fractionalPart.dropFirst(18).allSatisfy({ $0 == "0" }) else {
                throw AppError.invalidAmount
            }
        }
        let clipped = String(fractionalPart.prefix(18))
        let normalizedWhole = wholePart.isEmpty ? "0" : wholePart
        let padded = clipped + String(repeating: "0", count: 18 - clipped.count)
        let combined = String((normalizedWhole + padded).drop { $0 == "0" })
        return combined.isEmpty ? "0" : combined
    }

    static func units(fromDecimalString value: String, decimals: Int) throws -> Data {
        guard decimals >= 0 else {
            throw AppError.invalidAmount
        }

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

        if fractionalPart.count > decimals {
            let extraFraction = fractionalPart.dropFirst(decimals)
            guard extraFraction.allSatisfy({ $0 == "0" }) else {
                throw AppError.invalidAmount
            }
        }

        let clippedFraction = String(fractionalPart.prefix(decimals))
        guard clippedFraction.count <= decimals else {
            throw AppError.invalidAmount
        }

        let normalizedWhole = wholePart.isEmpty ? "0" : wholePart
        let paddedFraction = clippedFraction + String(repeating: "0", count: decimals - clippedFraction.count)
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
