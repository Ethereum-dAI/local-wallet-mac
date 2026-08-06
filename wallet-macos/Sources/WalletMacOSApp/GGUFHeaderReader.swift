import Foundation

enum GGUFHeaderError: Error, Equatable {
    case notGGUF
    case truncated
    case unsupportedValueType(UInt32)
}

struct GGUFHeader: Equatable {
    let architecture: String
    private let integers: [String: Int]

    init(architecture: String, integers: [String: Int]) {
        self.architecture = architecture
        self.integers = integers
    }

    func integer(_ key: String) -> Int? { integers[key] }

    /// nil when the header lacks the attention shape we need; callers surface that
    /// as `.unknown` rather than guessing.
    func memoryProfile(weightBytes: UInt64) -> ModelMemoryProfile? {
        guard let blocks = integer("\(architecture).block_count"),
              let kvHeads = integer("\(architecture).attention.head_count_kv"),
              let keyLength = integer("\(architecture).attention.key_length"),
              let valueLength = integer("\(architecture).attention.value_length")
        else { return nil }
        return ModelMemoryProfile(
            weightBytes: weightBytes,
            blockCount: blocks,
            kvHeadCount: kvHeads,
            keyLength: keyLength,
            valueLength: valueLength,
            trainedContextTokens: integer("\(architecture).context_length") ?? 4096
        )
    }
}

enum GGUFHeaderReader {
    /// Big enough for every GGUF header we have seen. Gemma 4's 262k-token
    /// tokenizer arrays alone take ~15.8 MB, which is the current worst case.
    static let headerProbeBytes = 24 * 1024 * 1024

    static func parse(_ data: Data) throws -> GGUFHeader {
        var cursor = Cursor(data: data)
        guard try cursor.take(4) == Data("GGUF".utf8) else { throw GGUFHeaderError.notGGUF }
        _ = try cursor.u32()                       // version
        _ = try cursor.u64()                       // tensor count
        let kvCount = try cursor.u64()

        var architecture = ""
        var integers: [String: Int] = [:]
        for _ in 0..<kvCount {
            let key = try cursor.string()
            let type = try cursor.u32()
            if type == 8, key == "general.architecture" {
                architecture = try cursor.string()
                continue
            }
            if let value = try cursor.scalarInteger(type: type) {
                integers[key] = value
            }
        }
        return GGUFHeader(architecture: architecture, integers: integers)
    }

    static func fetch(from url: URL, session: URLSession = .shared) async throws -> GGUFHeader {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(headerProbeBytes - 1)", forHTTPHeaderField: "Range")
        let (data, _) = try await session.data(for: request)
        return try parse(data)
    }

    private struct Cursor {
        let data: Data
        var offset: Int = 0

        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= data.count else { throw GGUFHeaderError.truncated }
            defer { offset += count }
            return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
        }

        mutating func u32() throws -> UInt32 {
            try take(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        }

        mutating func u64() throws -> UInt64 {
            try take(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
        }

        mutating func string() throws -> String {
            let length = Int(try u64())
            return String(decoding: try take(length), as: UTF8.self)
        }

        /// Consumes one value. Returns it as an Int when it is a scalar integer,
        /// nil for everything else (strings, floats, bools, arrays) — those are
        /// skipped, not stored.
        mutating func scalarInteger(type: UInt32) throws -> Int? {
            switch type {
            case 0, 1, 7: return Int(try take(1)[0])
            case 2, 3: return Int(try take(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian })
            case 4: return Int(try u32())
            case 5: return Int(Int32(bitPattern: try u32()))
            case 6: _ = try take(4); return nil
            case 8: _ = try string(); return nil
            case 9:
                let elementType = try u32()
                let count = try u64()
                for _ in 0..<count { _ = try scalarInteger(type: elementType) }
                return nil
            case 10: return Int(try u64())
            case 11: return Int(Int64(bitPattern: try u64()))
            case 12: _ = try take(8); return nil
            default: throw GGUFHeaderError.unsupportedValueType(type)
            }
        }
    }
}
