import Darwin
import Foundation

/// Typed client for the `railgun-helper` sidecar's Unix-socket JSON-RPC API (shield /
/// unshield / balance). Mirrors the daemon transport: one request per connection,
/// `Connection: close`, body read to EOF, bearer-authenticated — byte-for-byte what the
/// Rust `railgun_helper::rpc` server/client and `wallet-node` use.
///
/// The sidecar is the wallet's single privacy entry point: an unshield exits through
/// RAILGUN's privacy paymaster as an ERC-4337 UserOperation submitted by a PUBLIC bundler —
/// there is no local broadcaster, so the app only ever talks to this one socket.
struct RailgunHelperClient: Sendable {
    let socketPath: String
    let bearerToken: String
    /// Overall connect+read budget for a plain (fast) call — reads like `balance` and
    /// `unshieldStatus` that touch no external network beyond the app's own RPC.
    var timeout: TimeInterval = 30

    /// `unshield` and `maxUnshieldable` both perform a full RAILGUN UTXO sync PLUS a bundler
    /// gas probe before returning — proving itself is asynchronous (see
    /// `awaitUnshieldSubmitted`), so this covers sync + one gas-price round trip only, not
    /// proving. The sidecar's RPC server handles one connection to completion (no
    /// keep-alive), so the socket is held open for the whole call.
    ///
    /// Chosen as 2x the plain-call timeout: comfortable headroom over a sync + single RPC
    /// round trip without creeping toward the 300s PROVING deadline `awaitUnshieldSubmitted`
    /// waits on separately — conflating the two would make a slow sync look like a timed-out
    /// proof, or mask a genuinely wedged sync inside the proving budget.
    private static let syncCallTimeout: TimeInterval = 60

    enum ClientError: LocalizedError {
        case connectFailed(String)
        case ioFailed(String)
        case httpError(String)
        case decodeFailed(String)
        /// A synchronous RPC rejection. `code` is the sidecar's stable domain code from
        /// `error.data.code` — `badRequest`, `insufficientShieldedBalance`,
        /// `bundlerUnavailable`, `unknownJobId`, or `error` for anything unnamed — and is
        /// `nil` only for rejections this client raised locally, which never crossed the wire.
        /// Switch on the code; never substring-match `message`, which the sidecar
        /// deliberately stripped of its prefix so that becomes impossible.
        case rpcError(code: String?, message: String)
        /// A failed exit, carrying the sidecar's stable code so the view layer can pick copy.
        case exitFailed(code: String?, message: String)

        var errorDescription: String? {
            switch self {
            case .connectFailed(let m): return "railgun-helper connect failed: \(m)"
            case .ioFailed(let m): return "railgun-helper I/O failed: \(m)"
            case .httpError(let m): return "railgun-helper HTTP error: \(m)"
            case .decodeFailed(let m): return "railgun-helper decode failed: \(m)"
            case .rpcError(_, let m): return "railgun-helper error: \(m)"
            case .exitFailed(_, let m): return m
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
        /// "pending" | "submitted" | "done" | "error". `submitted` means the bundler accepted
        /// the UserOperation (a real op hash exists) and inclusion is pending; the card should
        /// show submitted-not-yet-included. `submitted` and `done` share the SAME `result`
        /// schema (an exit outcome), differing only in `included` — never model them as two
        /// shapes.
        let status: String
        /// Stable failure code when `status == "error"`: feeDidNotConverge,
        /// bundlerRejected, paymasterNotConfigured, deliveryReverted, error.
        let code: String?
        /// Always "ETH" for the paymaster exit — the tail call unwraps WETH before forwarding.
        let deliveredAsset: String?
        let result: JSONValue?
        let error: String?
    }

    /// Headroom-aware limits for an exit. Two numbers because there is no gross-up: the
    /// requested amount IS what leaves the pool, so `maxValueWei` is the input bound to
    /// validate `unshield(amountWei:)` against, and `receivableAtMaxWei` is what the
    /// recipient would actually receive at that amount — the two are NOT interchangeable.
    struct MaxUnshieldable: Decodable, Equatable {
        let maxValueWei: String
        let receivableAtMaxWei: String
        let reserveWei: String
    }

    func balance() async throws -> BalanceSplit {
        try decode(try await call(method: "balance", params: .null))
    }

    /// The largest `amountWei` the sidecar will currently accept for `unshield`, plus what the
    /// recipient would net at that amount. Also performs a live RAILGUN sync + bundler gas
    /// probe, so it gets the same extended timeout as `unshield`.
    func maxUnshieldable() async throws -> MaxUnshieldable {
        try decode(try await call(method: "maxUnshieldable", params: .null, timeout: Self.syncCallTimeout))
    }

    func prepareShield(amountWei: String) async throws -> [ShieldTx] {
        try decode(try await call(method: "prepareShield", params: .object(["amountWei": .string(amountWei)])))
    }

    /// Kicks off the async unshield (paymaster-sponsored proving + bundler submission).
    /// Returns a jobId immediately; poll `unshieldStatus` (or use `awaitUnshieldSubmitted` /
    /// `awaitUnshieldIncluded`) to observe progress.
    func unshield(amountWei: String, to: String) async throws -> String {
        let v = try await call(
            method: "unshield",
            params: .object(["amountWei": .string(amountWei), "to": .string(to)]),
            timeout: Self.syncCallTimeout
        )
        guard case let .object(o) = v, case let .string(id)? = o["jobId"] else {
            throw ClientError.decodeFailed("unshield: missing jobId")
        }
        return id
    }

    func unshieldStatus(jobId: String) async throws -> UnshieldStatus {
        try decode(try await call(method: "unshieldStatus", params: .object(["jobId": .string(jobId)])))
    }

    /// Poll until the sidecar has a UserOperation hash (`submitted`) or fails.
    ///
    /// The deadline bounds PROVING, not inclusion.
    ///
    /// MEASURED on an anvil Sepolia fork, circuit `railgun/01x03` — the shape the paymaster path
    /// actually proves (unshield note + fee note + change): 8.45s cold, 5.01s warm per proof.
    ///
    /// 300s, not 120s, because Task 7 measured the SDK's fee loop consuming **2, 3, 4 and 5 of
    /// its 5 rounds** on an IDLE fork with flat gas: convergence needs `new_fee <= fee_value`
    /// AND within 1%, and the ~0.006% estimate jitter is far inside the 1% band but makes the
    /// `<=` half roughly a coin flip per round. So ~6% of attempts exhaust the cap, and the
    /// authorised unconditional retry means a worst case of TEN proofs (~54s) on top of UTXO
    /// sync and artifact download — the fixture measured ~80s per exit end to end.
    ///
    /// Do NOT tighten this: nullifier count was never varied, so a wallet spending several
    /// small notes proves a larger circuit than any of these measurements.
    func awaitUnshieldSubmitted(
        jobId: String,
        deadline: Date = Date().addingTimeInterval(300),
        poll: TimeInterval = 3
    ) async throws -> JSONValue {
        while Date() < deadline {
            let st = try await unshieldStatus(jobId: jobId)
            switch st.status {
            case "submitted", "done": return st.result ?? .null
            case "error": throw ClientError.exitFailed(code: st.code, message: st.error ?? "unshield failed")
            default: break // "pending" — still proving.
            }
            try await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
        throw ClientError.ioFailed("unshield job \(jobId) was not submitted before the deadline")
    }

    /// Poll a submitted job until it is included. Inclusion is the bundler's schedule, not
    /// ours, so a timeout here leaves the card as submitted rather than reporting a failure —
    /// reporting a reverted exit to a user whose funds actually arrived would be the worst
    /// outcome in this whole feature, so a `nil` return here must NEVER be read as failure.
    func awaitUnshieldIncluded(
        jobId: String,
        deadline: Date = Date().addingTimeInterval(900),
        poll: TimeInterval = 6
    ) async throws -> JSONValue? {
        while Date() < deadline {
            let st = try await unshieldStatus(jobId: jobId)
            switch st.status {
            case "done": return st.result ?? .null
            case "error": throw ClientError.exitFailed(code: st.code, message: st.error ?? "unshield failed")
            default: break
            }
            try await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
        return nil // Still pending — not an error.
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

    /// - Parameter timeout: overrides `self.timeout` for this one call (used by `unshield` /
    ///   `maxUnshieldable`, which sync + probe gas before returning).
    private func call(method: String, params: JSONValue, timeout overrideTimeout: TimeInterval? = nil) async throws -> JSONValue {
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
        let timeout = overrideTimeout ?? self.timeout
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
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ClientError.ioFailed("write: errno \(errno)")
                }
                if n == 0 { throw ClientError.ioFailed("write returned 0") }
                off += n
            }
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw ClientError.ioFailed("read: errno \(errno)")
            }
            if n == 0 { break }
            response.append(chunk, count: n)
        }
        return response
    }

    /// Internal (not private) so the wire-contract tests can drive it directly: `data.code`
    /// extraction is the load-bearing behaviour here, not the socket plumbing around it.
    static func parseBody(_ raw: Data) throws -> JSONValue {
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
                // The stable domain code rides in `error.data.code` (JSON-RPC's own `code` is a
                // transport-level integer) — see `local-wallet-railgun/src/rpc.rs`. Keep it:
                // dropping it collapses every distinct rejection into one untypeable blob, and
                // the message is deliberately prefix-free so it cannot be matched instead.
                throw ClientError.rpcError(code: err["data"]?["code"]?.stringValue, message: msg)
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
    var boolValue: Bool? { if case let .bool(b) = self { return b } else { return nil } }
    subscript(_ key: String) -> JSONValue? { if case let .object(o) = self { return o[key] } else { return nil } }
}
