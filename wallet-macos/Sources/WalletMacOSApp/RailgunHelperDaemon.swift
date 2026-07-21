import Darwin
import Foundation
import Security
import SpawnHelper

/// Spawns and owns the `railgun-helper` sidecar (the wallet's privacy entry point), which
/// in turn spawns the `railgun-broadcaster`. Mirrors `WalletNodeDaemon`'s spawn contract:
/// fd-3 ready / fd-4 alive / fd-5 secret, secrets delivered on fd-5 (never argv/env).
///
/// Differences from the daemon: the helper doesn't emit a ready token on fd-3 (the app
/// chooses the socket + token), so readiness is detected by polling the socket; and the
/// helper reads its config from env (set around the spawn) + fd-5.
///
/// The app points the helper at its OWN active-chain RPC, so the pool state the helper
/// reads and the chain the app's daemon submits the shield on are the same.
final class RailgunHelperDaemon: @unchecked Sendable {
    let socketPath: String
    let token: String
    private let pid: pid_t
    private let aliveWriteFD: Int32

    var client: RailgunHelperClient {
        RailgunHelperClient(socketPath: socketPath, bearerToken: token)
    }

    private init(socketPath: String, token: String, pid: pid_t, aliveWriteFD: Int32) {
        self.socketPath = socketPath
        self.token = token
        self.pid = pid
        self.aliveWriteFD = aliveWriteFD
    }

    deinit {
        // Closing the alive pipe + SIGTERM stops the helper; its broadcaster child follows
        // via its own getppid backstop.
        if aliveWriteFD >= 0 { close(aliveWriteFD) }
        if pid > 0 { kill(pid, SIGTERM) }
    }

    enum DaemonError: LocalizedError {
        case binaryNotFound(String)
        case launchFailed(String)
        case notReady(String)
        var errorDescription: String? {
            switch self {
            case .binaryNotFound(let m): return "railgun sidecar binary not found: \(m)"
            case .launchFailed(let m): return "railgun sidecar launch failed: \(m)"
            case .notReady(let m): return "railgun sidecar not ready: \(m)"
            }
        }
    }

    static func launch(
        rpcURL: String,
        secrets: RailgunSecrets,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> RailgunHelperDaemon {
        let helperBin = try resolveBinary(
            name: "railgun-helper",
            envKeys: ["RAILGUN_HELPER_BIN", "LOCAL_WALLET_PRIVACY_BIN"],
            environment: environment
        )
        let broadcasterBin = try resolveBinary(
            name: "railgun-broadcaster",
            envKeys: ["RAILGUN_BROADCASTER_BIN"],
            environment: environment
        )

        let unique = UUID().uuidString.prefix(8)
        let dir = NSTemporaryDirectory()
        let helperSocket = "\(dir)lw-rg-\(unique)-h.sock"
        let bcSocket = "\(dir)lw-rg-\(unique)-b.sock"
        let helperToken = randomToken()
        let bcToken = randomToken()

        var readyPipe: [Int32] = [-1, -1]
        var alivePipe: [Int32] = [-1, -1]
        var secretPipe: [Int32] = [-1, -1]
        guard pipe(&readyPipe) == 0, pipe(&alivePipe) == 0, pipe(&secretPipe) == 0 else {
            throw DaemonError.launchFailed("pipe() errno \(errno)")
        }
        for fd in [readyPipe[0], readyPipe[1], alivePipe[0], alivePipe[1], secretPipe[0], secretPipe[1]] {
            setCloseOnExec(fd)
        }

        // The helper reads config from env; set the RAILGUN_* vars around the spawn (the C
        // spawn helper inherits `environ`), then restore.
        let childEnv: [String: String] = [
            "RAILGUN_RPC_URL": rpcURL,
            "RAILGUN_SOCKET": helperSocket,
            "RAILGUN_TOKEN": helperToken,
            "RAILGUN_BROADCASTER_BIN": broadcasterBin,
            "RAILGUN_BROADCASTER_SOCKET": bcSocket,
            "RAILGUN_BROADCASTER_TOKEN": bcToken,
            // Tell the helper its secret arrives on fd 5 (we deliver it there below). Without
            // this flag the helper won't read fd 5 (see read_fd5 / FD5_ENV_FLAG).
            "RAILGUN_FD5": "1",
            "RUST_LOG": environment["RUST_LOG"] ?? "railgun_helper=info,railgun=warn",
        ]
        let restore = setEnvironment(childEnv)
        defer { restore() }

        let pid: pid_t
        do {
            pid = try spawnHelper(
                execPath: helperBin,
                readyWrite: readyPipe[1],
                aliveRead: alivePipe[0],
                secretRead: secretPipe[0]
            )
        } catch {
            for fd in [readyPipe[0], readyPipe[1], alivePipe[0], alivePipe[1], secretPipe[0], secretPipe[1]] where fd >= 0 {
                close(fd)
            }
            throw DaemonError.launchFailed("\(error)")
        }

        // Parent closes the child ends.
        close(readyPipe[1])
        close(alivePipe[0])
        close(secretPipe[0])
        close(readyPipe[0]) // helper doesn't emit an fd-3 token; we poll the socket instead

        // Deliver the fd-5 secret (HelperFd5 = entropy only), then close so the child reads EOF.
        let secretJSON = try JSONSerialization.data(
            withJSONObject: [
                "entropyHex": secrets.entropyHex,
            ],
            options: [.sortedKeys]
        )
        writeAll(secretPipe[1], secretJSON)
        close(secretPipe[1])

        // Wait for the helper socket to accept connections (it builds the RAILGUN provider
        // + spawns the broadcaster first, so allow a generous window).
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if socketAccepts(path: helperSocket) {
                return RailgunHelperDaemon(
                    socketPath: helperSocket,
                    token: helperToken,
                    pid: pid,
                    aliveWriteFD: alivePipe[1]
                )
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        close(alivePipe[1])
        kill(pid, SIGTERM)
        throw DaemonError.notReady("helper socket \(helperSocket) did not come up in 45s")
    }

    // MARK: helpers

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func setCloseOnExec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if n == 0 { break }
                off += n
            }
        }
    }

    private static func socketAccepts(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0
    }

    /// setenv the given vars, returning a closure that restores prior values.
    private static func setEnvironment(_ vars: [String: String]) -> () -> Void {
        var previous: [String: String?] = [:]
        for (k, v) in vars {
            previous[k] = getenv(k).map { String(cString: $0) }
            setenv(k, v, 1)
        }
        return {
            for (k, old) in previous {
                if let old { setenv(k, old, 1) } else { unsetenv(k) }
            }
        }
    }

    private static func resolveBinary(
        name: String,
        envKeys: [String],
        environment: [String: String]
    ) throws -> String {
        var candidates: [String] = []
        for key in envKeys {
            if let path = environment[key] { candidates.append(path) }
        }
        if let path = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "bin")?.path {
            candidates.append(path)
        }
        if let path = Bundle.main.url(forResource: name, withExtension: nil)?.path {
            candidates.append(path)
        }
        candidates.append(sourceRootBinary(name: name, profile: "release"))
        candidates.append(sourceRootBinary(name: name, profile: "debug"))
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw DaemonError.binaryNotFound(
            "\(name) — set \(envKeys.first ?? "the env override") to an absolute path, or build it in local-wallet-railgun (`cargo build --release --bins`)."
        )
    }

    private static func sourceRootBinary(name: String, profile: String) -> String {
        // #filePath = <repo-root>/wallet-macos/Sources/WalletMacOSApp/RailgunHelperDaemon.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WalletMacOSApp
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // wallet-macos
            .deletingLastPathComponent() // <repo-root>
            .appendingPathComponent("local-wallet-railgun/target/\(profile)/\(name)")
            .path
    }
}
