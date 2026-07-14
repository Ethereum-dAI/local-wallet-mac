import Darwin
import Foundation

/// Typed client for the `railgun-helper` sidecar's Unix-socket JSON-RPC API (shield /
/// unshield / balance). Mirrors the daemon transport: one request per connection,
/// `Connection: close`, body read to EOF, bearer-authenticated — byte-for-byte what the
/// Rust `railgun_helper::rpc` server/client and `wallet-node` use.
///
/// The sidecar is the wallet's single privacy entry point: it owns the local broadcaster
/// and proxies the unshield, so the app only talks to this one socket.
struct RailgunHelperClient: Sendable {
    let socketPath: String
    let bearerToken: String
    /// Overall connect+read budget for a single call (unshield proving is async — the
    /// helper returns a jobId immediately — so calls themselves stay short).
    var timeout: TimeInterval = 30

    enum ClientError: LocalizedError {
        case connectFailed(String)
        case ioFailed(String)
        case httpError(String)
        case decodeFailed(String)
        case rpcError(String)

        var errorDescription: String? {
            switch self {
            case .connectFailed(let m): return "railgun-helper connect failed: \(m)"
            case .ioFailed(let m): return "railgun-helper I/O failed: \(m)"
            case .httpError(let m): return "railgun-helper HTTP error: \(m)"
            case .decodeFailed(let m): return "railgun-helper decode failed: \(m)"
            case .rpcError(let m): return "railgun-helper error: \(m)"
            }
        }
    }

    // MARK: Typed API

    /// One shield deposit tx (native ETH → shielded pool). The OWNER submits these.
    struct ShieldTx: Decodable, Equatable {
        let to: String
        let data: String
        let value: String
    }

    struct BalanceSplit: Decodable, Equatable {
        let valid: String
        let pending: String
        let total: String
    }

    struct UnshieldStatus: Decodable {
        let status: String // "pending" | "done" | "error"
        let result: JSONValue?
        let error: String?
    }

    func balance() async throws -> BalanceSplit {
        try decode(try await call(method: "balance", params: .null))
    }

    func prepareShield(amountWei: String) async throws -> [ShieldTx] {
        try decode(try await call(method: "prepareShield", params: .object(["amountWei": .string(amountWei)])))
    }

    /// Kicks off the async unshield (proving + local-broadcaster relay). Returns a jobId.
    func unshield(amountWei: String, to: String) async throws -> String {
        let v = try await call(method: "unshield", params: .object(["amountWei": .string(amountWei), "to": .string(to)]))
        guard case let .object(o) = v, case let .string(id)? = o["jobId"] else {
            throw ClientError.decodeFailed("unshield: missing jobId")
        }
        return id
    }

    func unshieldStatus(jobId: String) async throws -> UnshieldStatus {
        try decode(try await call(method: "unshieldStatus", params: .object(["jobId": .string(jobId)])))
    }

    /// Poll `unshieldStatus` until `done`/`error` or the deadline. Proving downloads
    /// circuit artifacts on first use (tens of seconds), so allow a generous deadline.
    func awaitUnshield(jobId: String, deadline: Date, poll: TimeInterval = 2) async throws -> JSONValue {
        while Date() < deadline {
            let st = try await unshieldStatus(jobId: jobId)
            switch st.status {
            case "done": return st.result ?? .null
            case "error": throw ClientError.rpcError(st.error ?? "unshield failed")
            default: break
            }
            try await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
        throw ClientError.ioFailed("unshield job \(jobId) did not finish before deadline")
    }

    // MARK: Transport

    private func decode<T: Decodable>(_ value: JSONValue) throws -> T {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClientError.decodeFailed("\(T.self): \(error)")
        }
    }

    private func call(method: String, params: JSONValue) async throws -> JSONValue {
        let body = try JSONEncoder().encode(
            JSONValue.object([
                "jsonrpc": .string("2.0"),
                "id": .number(1),
                "method": .string(method),
                "params": params,
            ])
        )
        let socketPath = self.socketPath
        let token = self.bearerToken
        let timeout = self.timeout
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let raw = try Self.sendBlocking(socketPath: socketPath, token: token, body: body, timeout: timeout)
                    cont.resume(returning: try Self.parseBody(raw))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func sendBlocking(socketPath: String, token: String, body: Data, timeout: TimeInterval) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.connectFailed("socket(): errno \(errno)") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw ClientError.connectFailed("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in pathBytes.enumerated() { buf[i] = b }
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ClientError.connectFailed("connect(\(socketPath)): errno \(errno)") }

        // Set a receive timeout so a wedged sidecar can't block forever.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let header = "POST / HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var request = Data(header.utf8)
        request.append(body)
        try request.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
                if n <= 0 { throw ClientError.ioFailed("write: errno \(errno)") }
                off += n
            }
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { throw ClientError.ioFailed("read: errno \(errno)") }
            if n == 0 { break }
            response.append(chunk, count: n)
        }
        return response
    }

    private static func parseBody(_ raw: Data) throws -> JSONValue {
        guard let text = String(data: raw, encoding: .utf8),
              let sep = text.range(of: "\r\n\r\n") else {
            throw ClientError.httpError("malformed HTTP response")
        }
        let head = String(text[..<sep.lowerBound])
        let bodyStr = String(text[sep.upperBound...])
        guard head.split(separator: "\r\n").first?.contains(" 200") == true else {
            throw ClientError.httpError(String(head.split(separator: "\r\n").first ?? ""))
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(bodyStr.utf8))
        if case let .object(o) = value {
            if case let .object(err)? = o["error"], case let .string(msg)? = err["message"] {
                throw ClientError.rpcError(msg)
            }
            return o["result"] ?? .null
        }
        return value
    }
}

/// Minimal JSON value for shaping requests / reading dynamic RPC results.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var stringValue: String? { if case let .string(s) = self { return s } else { return nil } }
    subscript(_ key: String) -> JSONValue? { if case let .object(o) = self { return o[key] } else { return nil } }
}
