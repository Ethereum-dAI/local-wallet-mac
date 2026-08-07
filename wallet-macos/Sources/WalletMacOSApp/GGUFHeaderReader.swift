import Foundation

enum GGUFHeaderError: Error, Equatable, LocalizedError {
    case notGGUF
    case truncated
    case unsupportedValueType(UInt32)
    case rangeNotSupported(status: Int)

    var errorDescription: String? {
        switch self {
        case .notGGUF:
            return "That file is not a GGUF model."
        case .truncated:
            return "That file's GGUF header is incomplete or malformed."
        case .unsupportedValueType(let type):
            return "That file's GGUF header uses an unsupported value type (\(type))."
        case .rangeNotSupported(let status):
            return "The host would not serve a partial read of that file (HTTP \(status)), so its size cannot be checked before downloading."
        }
    }
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

    /// Reads only the leading `headerProbeBytes` of a *remote* GGUF, so a model's
    /// memory profile can be shown before committing to a multi-gigabyte download.
    ///
    /// Deliberately not `URLSession.data(for:)`: that buffers the whole response
    /// body, so a host that ignored the `Range` header and answered `200 OK` would
    /// pull an entire model into RAM — the exact failure this feature exists to
    /// warn about. `BoundedRangeProbe` refuses anything but `206 Partial Content`
    /// before a byte of body is kept, and cancels the transfer the moment the
    /// probe is full.
    static func fetch(
        from url: URL,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> GGUFHeader {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(headerProbeBytes - 1)", forHTTPHeaderField: "Range")
        let data = try await BoundedRangeProbe(limit: headerProbeBytes)
            .fetch(request, configuration: configuration)
        return try parse(data)
    }

    /// A one-shot data task that never buffers more than `limit` bytes.
    ///
    /// `@unchecked Sendable` with an `NSLock` rather than an actor: `URLSession`
    /// calls its delegate from its own queues (and, for the `async` disposition
    /// method, from an unspecified task), so the mutable state has to be guarded
    /// wherever it is touched from. Every mutation goes through `lock`, and
    /// `settle` clears the continuation under it so exactly one of
    /// "probe full" / "transfer finished" / "response rejected" resumes it.
    private final class BoundedRangeProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let limit: Int
        private let lock = NSLock()
        private var buffer = Data()
        private var continuation: CheckedContinuation<Data, Error>?

        init(limit: Int) {
            self.limit = limit
            super.init()
        }

        func fetch(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> Data {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            // The session holds the delegate strongly until it is invalidated;
            // without this the probe (and its buffer) would outlive the call.
            defer { session.finishTasksAndInvalidate() }
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                session.dataTask(with: request).resume()
            }
        }

        private func settle(_ result: Result<Data, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse
        ) async -> URLSession.ResponseDisposition {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 206 else {
                settle(.failure(GGUFHeaderError.rangeNotSupported(status: status)))
                return .cancel
            }
            return .allow
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            buffer.append(data)
            let full = buffer.count >= limit ? Data(buffer.prefix(limit)) : nil
            lock.unlock()
            guard let full else { return }
            // Cancelling drives `didCompleteWithError`, which finds the
            // continuation already cleared and does nothing.
            dataTask.cancel()
            settle(.success(full))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                settle(.failure(error))
                return
            }
            lock.lock()
            let collected = buffer
            lock.unlock()
            // A server may legitimately have fewer bytes than the probe asked
            // for; `parse` reports a genuinely short header as `.truncated`.
            settle(.success(collected))
        }
    }

    private struct Cursor {
        let data: Data
        var offset: Int = 0

        mutating func take(_ count: Int) throws -> Data {
            // `offset + count` is not safe to compute directly: `count` is
            // attacker-controlled (it flows from a length field in untrusted,
            // network-fetched bytes) and can be large enough that the addition
            // itself overflows `Int` and traps before the bounds check runs.
            // Compare against the remaining budget instead, which never overflows
            // because `offset <= data.count` is an invariant this function
            // maintains.
            guard count >= 0 else { throw GGUFHeaderError.truncated }
            let remaining = data.count - offset
            guard count <= remaining else { throw GGUFHeaderError.truncated }
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
            // `Int(UInt64)` traps for any value above `Int.max`, and this length
            // is attacker-controlled — a crafted or corrupted header must not be
            // able to abort the process. `Int(exactly:)` turns an out-of-range
            // length into `nil`, which we reject as `.truncated` (no buffer we
            // read is ever big enough to hold such a string anyway).
            guard let length = Int(exactly: try u64()) else { throw GGUFHeaderError.truncated }
            return String(decoding: try take(length), as: UTF8.self)
        }

        /// Consumes one value. Returns it as an Int when it is a scalar integer,
        /// nil for everything else (strings, floats, bools, arrays) — those are
        /// skipped, not stored.
        mutating func scalarInteger(type: UInt32) throws -> Int? {
            switch type {
            case 0, 7: return Int(try take(1)[0])
            case 1: return Int(Int8(bitPattern: try take(1)[0]))
            case 2: return Int(try take(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian })
            case 3:
                let bits = try take(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
                return Int(Int16(bitPattern: bits))
            case 4: return Int(try u32())
            case 5: return Int(Int32(bitPattern: try u32()))
            case 6: _ = try take(4); return nil
            case 8: _ = try string(); return nil
            case 9:
                let elementType = try u32()
                let count = try u64()
                // Same attacker-controlled-length concern as `string()`: a
                // declared element count that vastly exceeds what's left in the
                // buffer must throw immediately rather than spin the loop (each
                // element needs at least one byte, so this is a sound lower
                // bound, not just a heuristic).
                guard count <= UInt64(data.count - offset) else { throw GGUFHeaderError.truncated }
                for _ in 0..<count { _ = try scalarInteger(type: elementType) }
                return nil
            case 10:
                let value = try u64()
                // Same attacker-controlled-value concern as everywhere else in
                // this switch: `Int(UInt64)` traps above `Int.max`. Unlike case
                // 11 (a genuinely *signed* i64, where reinterpreting the bits via
                // `Int64(bitPattern:)` is the correct decode), this is an
                // unsigned u64 — a value above `Int.max` is never a plausible
                // block count, context length, or any other field this parser
                // consumes, and reinterpreting its bits as a negative `Int`
                // would let that garbage number reach `ModelMemoryProfile` /
                // `ModelFitEvaluator`, which convert it straight back to
                // `UInt64` and would trap on a negative value. So: consume the
                // 8 bytes (cursor stays in sync) but don't store an implausible
                // value — `nil` here means "skipped", exactly like the
                // float/string/array arms below.
                return Int(exactly: value)
            case 11: return Int(Int64(bitPattern: try u64()))
            case 12: _ = try take(8); return nil
            default: throw GGUFHeaderError.unsupportedValueType(type)
            }
        }
    }
}
