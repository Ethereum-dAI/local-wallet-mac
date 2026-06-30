import Darwin
import Foundation
import SpawnHelper

/// Spawns and supervises the `privacy-helper` sidecar (a single prebuilt binary that
/// reads fd-3 (ready), fd-4 (alive), fd-5 (secret JSON) and serves JSON-RPC over a
/// Unix socket). The spawn handshake mirrors `WalletNodeDaemon.launchBlocking`
/// (`WalletNodeDaemon.swift:158-226`); the JSON-RPC transport mirrors the unix-socket
/// POST path in `WalletNodeClient.swift` (`UnixSocketJSONRPCTransport`, lines ~771-898).
///
/// The app owns both the sidecar socket path and the auth token: the token is the
/// daemon's per-launch bearer token (the sidecar reuses it for app↔sidecar auth —
/// see `privacy-helper/src/index.ts`).
final class PrivacyHelperSidecar: @unchecked Sendable {
    private let pid: pid_t
    private var aliveWriteFD: Int32
    private let socketPath: String
    private let token: String

    private init(pid: pid_t, aliveWriteFD: Int32, socketPath: String, token: String) {
        self.pid = pid
        self.aliveWriteFD = aliveWriteFD
        self.socketPath = socketPath
        self.token = token
    }

    deinit {
        // Closing the alive pipe's write end signals the child to exit (fd-4 EOF).
        if aliveWriteFD >= 0 {
            close(aliveWriteFD)
            aliveWriteFD = -1
        }
        unlink(socketPath)
    }

    /// Resolves the privacy-helper binary:
    /// 1. `LOCAL_WALLET_PRIVACY_HELPER_BIN` env override
    /// 2. bundled `bin/privacy-helper` resource
    /// 3. DEV fallback: `<repo-root>/privacy-helper/dist/privacy-helper`, where
    ///    `<repo-root>` is 4 `deletingLastPathComponent()` up from this file
    ///    (`<repo>/wallet-macos/Sources/WalletMacOSApp/PrivacyHelperSidecar.swift`).
    static func resolveBinaryPath() -> String? {
        if let path = ProcessInfo.processInfo.environment["LOCAL_WALLET_PRIVACY_HELPER_BIN"],
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let path = Bundle.main.url(forResource: "privacy-helper", withExtension: nil, subdirectory: "bin")?.path,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // #filePath = <repo>/wallet-macos/Sources/WalletMacOSApp/PrivacyHelperSidecar.swift
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // .../WalletMacOSApp
            .deletingLastPathComponent()  // .../Sources
            .deletingLastPathComponent()  // .../wallet-macos
            .deletingLastPathComponent()  // <repo>
            .appendingPathComponent("privacy-helper/dist/privacy-helper")
            .path
        return FileManager.default.isExecutableFile(atPath: dev) ? dev : nil
    }

    static func launch(
        entropyHex: String,
        daemonSocketPath: String,
        daemonToken: String
    ) async throws -> PrivacyHelperSidecar {
        try await Task.detached(priority: .userInitiated) {
            try launchBlocking(
                entropyHex: entropyHex,
                daemonSocketPath: daemonSocketPath,
                daemonToken: daemonToken
            )
        }.value
    }

    // Mirrors WalletNodeDaemon.launchBlocking (WalletNodeDaemon.swift:158-226): three
    // pipe() pairs, setCloseOnExec on all six ends, spawnHelper, close child ends in
    // parent, write the fd-5 payload, wait for "ready" on fd-3, keep alivePipe[1] open.
    private static func launchBlocking(
        entropyHex: String,
        daemonSocketPath: String,
        daemonToken: String
    ) throws -> PrivacyHelperSidecar {
        guard let execPath = resolveBinaryPath() else {
            throw AppError.localDaemonLaunchFailed("privacy-helper binary not found")
        }

        // The app owns the sidecar socket path; the sidecar listens there and the app
        // connects to that known path. The auth token is the daemon's per-launch token.
        let socketPath = NSTemporaryDirectory() + "ph-\(UUID().uuidString).sock"
        let payload = try JSONSerialization.data(withJSONObject: [
            "entropyHex": entropyHex,
            "sidecarSocketPath": socketPath,
            "daemon": [
                "socketPath": daemonSocketPath,
                "token": daemonToken,
            ],
        ])

        var readyPipe: [Int32] = [-1, -1]
        var alivePipe: [Int32] = [-1, -1]
        var secretPipe: [Int32] = [-1, -1]
        guard pipe(&readyPipe) == 0 else {
            throw AppError.localDaemonLaunchFailed("failed to create privacy-helper ready pipe: errno \(errno)")
        }
        guard pipe(&alivePipe) == 0 else {
            closeIfOpen(&readyPipe[0])
            closeIfOpen(&readyPipe[1])
            throw AppError.localDaemonLaunchFailed("failed to create privacy-helper alive pipe: errno \(errno)")
        }
        guard pipe(&secretPipe) == 0 else {
            closeIfOpen(&readyPipe[0])
            closeIfOpen(&readyPipe[1])
            closeIfOpen(&alivePipe[0])
            closeIfOpen(&alivePipe[1])
            throw AppError.localDaemonLaunchFailed("failed to create privacy-helper secret pipe: errno \(errno)")
        }

        do {
            try setCloseOnExec(readyPipe[0])
            try setCloseOnExec(readyPipe[1])
            try setCloseOnExec(alivePipe[0])
            try setCloseOnExec(alivePipe[1])
            try setCloseOnExec(secretPipe[0])
            try setCloseOnExec(secretPipe[1])

            let pid = try spawnHelper(
                execPath: execPath,
                readyWrite: readyPipe[1],
                aliveRead: alivePipe[0],
                secretRead: secretPipe[0]
            )
            closeIfOpen(&readyPipe[1])
            closeIfOpen(&alivePipe[0])
            closeIfOpen(&secretPipe[0])
            try writeAll(payload, to: secretPipe[1])
            closeIfOpen(&secretPipe[1])

            let readyData = try readLineWithTimeout(fd: readyPipe[0], timeout: 8)
            closeIfOpen(&readyPipe[0])
            let readyLine = String(data: readyData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard readyLine == "ready" else {
                closeIfOpen(&alivePipe[1])
                throw AppError.localDaemonLaunchFailed("privacy-helper ready event was invalid: \(readyLine ?? "<non-utf8>")")
            }
            return PrivacyHelperSidecar(
                pid: pid,
                aliveWriteFD: alivePipe[1],
                socketPath: socketPath,
                token: daemonToken
            )
        } catch {
            closeIfOpen(&readyPipe[0])
            closeIfOpen(&readyPipe[1])
            closeIfOpen(&alivePipe[0])
            closeIfOpen(&alivePipe[1])
            closeIfOpen(&secretPipe[0])
            closeIfOpen(&secretPipe[1])
            throw error
        }
    }

    /// POSTs `{jsonrpc,id,method,params}` over the Unix socket at `socketPath` with an
    /// `Authorization: Bearer <token>` header. Mirrors WalletNodeClient's unix-socket
    /// transport (WalletNodeClient.swift `UnixSocketJSONRPCTransport`, lines ~771-898).
    ///
    /// `params` is passed through verbatim: the sidecar handler reads `reqObj.params`
    /// directly (privacy-helper/src/rpc.ts), and `prepareShield`'s handler destructures
    /// `{ amountWei }` from it — so `params` must be the object, NOT an array wrapping it.
    private func rpc(_ method: String, _ params: Any = [String: Any]()) async throws -> Any {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ])
        let socketPath = self.socketPath
        let token = self.token
        let data = try await Task.detached(priority: .userInitiated) {
            try PrivacyHelperSidecar.callBlocking(socketPath: socketPath, bearerToken: token, body: body)
        }.value

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.localDaemonLaunchFailed("privacy-helper returned an invalid response")
        }
        if let error = object["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? 0
            let message = error["message"] as? String ?? "RPC error"
            throw AppError.localDaemonLaunchFailed("privacy-helper RPC \(method) \(code): \(message)")
        }
        guard let result = object["result"] else {
            throw AppError.localDaemonLaunchFailed("privacy-helper RPC \(method) returned no result")
        }
        return result
    }

    func balanceHexWei() async throws -> String {
        guard let value = try await rpc("balance") as? String else {
            throw AppError.localDaemonLaunchFailed("privacy-helper balance returned a non-string result")
        }
        return value
    }

    func prepareShield(amountWei: String) async throws -> (to: String, data: String, value: String) {
        let result = try await rpc("prepareShield", ["amountWei": amountWei])
        guard let object = result as? [String: Any],
              let to = object["to"] as? String,
              let data = object["data"] as? String,
              let value = object["value"] as? String
        else {
            throw AppError.localDaemonLaunchFailed("privacy-helper prepareShield returned an invalid result")
        }
        return (to, data, value)
    }

    // MARK: - fd helpers (duplicated locally from WalletNodeDaemon's private statics;
    // deliberately NOT refactored into a shared file to avoid touching the critical
    // daemon-spawn path — see WalletNodeDaemon.swift:478-529, 436-476, 501-522).

    private static func setCloseOnExec(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0 else {
            throw AppError.localDaemonLaunchFailed("fcntl(F_GETFD) failed: errno \(errno)")
        }
        guard fcntl(fd, F_SETFD, flags | FD_CLOEXEC) >= 0 else {
            throw AppError.localDaemonLaunchFailed("fcntl(F_SETFD) failed: errno \(errno)")
        }
    }

    private static func closeIfOpen(_ fd: inout Int32) {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard var base = buffer.baseAddress else {
                return
            }
            var remaining = data.count
            while remaining > 0 {
                let written = Darwin.write(fd, base, remaining)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw AppError.localDaemonLaunchFailed("privacy-helper secret pipe write failed: errno \(errno)")
                }
                if written == 0 {
                    throw AppError.localDaemonLaunchFailed("privacy-helper secret pipe write made no progress")
                }
                base = base.advanced(by: written)
                remaining -= written
            }
        }
    }

    private static func readLineWithTimeout(fd: Int32, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()

        while Date() < deadline {
            var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remainingMilliseconds = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
            let pollResult = poll(&pollFd, 1, remainingMilliseconds)
            if pollResult == 0 {
                throw AppError.localDaemonLaunchFailed("timed out waiting for privacy-helper ready event")
            }
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                throw AppError.localDaemonLaunchFailed("privacy-helper ready pipe poll failed: errno \(errno)")
            }

            while true {
                var byte: UInt8 = 0
                let readCount = withUnsafeMutableBytes(of: &byte) { buffer in
                    Darwin.read(fd, buffer.baseAddress, 1)
                }
                if readCount < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw AppError.localDaemonLaunchFailed("privacy-helper ready pipe read failed: errno \(errno)")
                }
                if readCount == 0 {
                    throw AppError.localDaemonLaunchFailed("privacy-helper ready pipe closed before ready event")
                }
                if byte == UInt8(ascii: "\n") {
                    return data
                }
                data.append(byte)
            }
        }

        throw AppError.localDaemonLaunchFailed("timed out waiting for privacy-helper ready event")
    }

    // Unix-socket JSON-RPC POST transport, mirrored from WalletNodeClient.swift's
    // private UnixSocketJSONRPCTransport (lines ~778-897).

    private static func callBlocking(socketPath: String, bearerToken: String, body: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw AppError.localDaemonLaunchFailed("failed to create privacy-helper socket: errno \(errno)")
        }
        defer {
            close(fd)
        }

        try connect(fd: fd, socketPath: socketPath)

        var request = Data()
        request.appendString("POST / HTTP/1.1\r\n")
        request.appendString("Host: localhost\r\n")
        request.appendString("Content-Type: application/json\r\n")
        request.appendString("Authorization: Bearer \(bearerToken)\r\n")
        request.appendString("Content-Length: \(body.count)\r\n")
        request.appendString("Connection: close\r\n\r\n")
        request.append(body)
        try writeAllSocket(fd: fd, data: request)

        let response = try readAllSocket(fd: fd)
        return try parseHTTPBody(response)
    }

    private static func connect(fd: Int32, socketPath: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        let encoded = Array(socketPath.utf8)
        guard encoded.count < maxLength else {
            throw AppError.localDaemonLaunchFailed("privacy-helper socket path is too long")
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            if let baseAddress = buffer.baseAddress {
                baseAddress.initializeMemory(as: UInt8.self, repeating: 0, count: buffer.count)
            }
            buffer.copyBytes(from: encoded)
        }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + encoded.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, length)
            }
        }
        guard result == 0 else {
            throw AppError.localDaemonLaunchFailed("failed to connect to privacy-helper socket: errno \(errno)")
        }
    }

    private static func writeAllSocket(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw AppError.localDaemonLaunchFailed("failed to write privacy-helper request: errno \(errno)")
                }
                if written == 0 {
                    throw AppError.localDaemonLaunchFailed("privacy-helper socket closed while writing")
                }
                offset += written
            }
        }
    }

    private static func readAllSocket(fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw AppError.localDaemonLaunchFailed("failed to read privacy-helper response: errno \(errno)")
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func parseHTTPBody(_ response: Data) throws -> Data {
        guard !response.isEmpty else {
            throw AppError.localDaemonLaunchFailed("privacy-helper closed the connection without a response")
        }
        guard let separator = "\r\n\r\n".data(using: .utf8),
              let range = response.range(of: separator)
        else {
            throw AppError.localDaemonLaunchFailed("privacy-helper returned an invalid response")
        }
        let head = response[..<range.lowerBound]
        guard let headText = String(data: head, encoding: .utf8),
              let statusLine = headText.components(separatedBy: "\r\n").first
        else {
            throw AppError.localDaemonLaunchFailed("privacy-helper returned an invalid response")
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw AppError.localDaemonLaunchFailed("privacy-helper returned an invalid response")
        }
        let body = response[range.upperBound...]
        if !(200..<300).contains(status), body.isEmpty {
            throw AppError.localDaemonLaunchFailed("privacy-helper returned HTTP \(status) without a response body")
        }
        return body
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
