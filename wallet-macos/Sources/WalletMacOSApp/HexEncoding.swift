import Foundation

extension Data {
    init(hexString: String) throws {
        let normalized = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard normalized.count.isMultiple(of: 2) else {
            throw AppError.invalidHexString
        }

        var bytes = Data(capacity: normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let nextIndex = normalized.index(index, offsetBy: 2)
            let byteString = normalized[index..<nextIndex]
            guard let value = UInt8(byteString, radix: 16) else {
                throw AppError.invalidHexString
            }
            bytes.append(value)
            index = nextIndex
        }

        self = bytes
    }

    var hexEncodedString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    func leftPadded(to length: Int) -> Data {
        if count >= length {
            return self
        }
        return Data(repeating: 0, count: length - count) + self
    }

    static func fromBigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var bigEndian = value.bigEndian
        return Data(bytes: &bigEndian, count: MemoryLayout<T>.size)
    }

    static func quantityString(_ value: String) throws -> Data {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidHexString
        }

        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            let body = String(trimmed.dropFirst(2))
            let paddedBody = body.count.isMultiple(of: 2) ? body : "0" + body
            return try Data(hexString: "0x" + paddedBody)
        }

        guard trimmed.allSatisfy(\.isNumber) else {
            throw AppError.invalidHexString
        }

        let normalizedDecimal = trimmed.drop { $0 == "0" }
        guard !normalizedDecimal.isEmpty else {
            return Data([0])
        }

        var digits = normalizedDecimal.compactMap(\.wholeNumberValue)
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

        return Data(bytes.reversed())
    }
}
