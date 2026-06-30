import Foundation

enum EtherAmountParser {
    static func wei(fromETHString value: String) throws -> Data {
        try units(fromDecimalString: value, decimals: 18)
    }

    /// Convert an ETH decimal string (e.g. "0.01") to a wei decimal string (e.g. "10000000000000000").
    /// The result is suitable for passing to sidecar RPCs that expect `BigInt(amountWei)`.
    static func weiDecimalString(fromETHString value: String) throws -> String {
        let weiData = try wei(fromETHString: value)
        return decimalString(fromBigEndianData: weiData)
    }

    /// Convert big-endian `Data` (e.g. from `units(fromDecimalString:decimals:)`) to a decimal string.
    static func decimalString(fromBigEndianData data: Data) -> String {
        // Strip leading zero bytes.
        let trimmed = data.drop { $0 == 0 }
        guard !trimmed.isEmpty else { return "0" }

        // Convert big-endian bytes to a decimal string using repeated division-by-10.
        var bytes = [UInt]( trimmed.map { UInt($0) } )
        var digits = [Character]()

        while !bytes.isEmpty {
            // Divide bytes array (big-endian number) by 10, collect remainder digit.
            var remainder: UInt = 0
            var newBytes = [UInt]()
            newBytes.reserveCapacity(bytes.count)
            for byte in bytes {
                let acc = remainder * 256 + byte
                let q = acc / 10
                remainder = acc % 10
                if !newBytes.isEmpty || q != 0 {
                    newBytes.append(q)
                }
            }
            digits.append(Character(String(remainder)))
            bytes = newBytes
        }

        return String(digits.reversed())
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
