import Darwin
import Foundation
import SpawnHelper

final class WalletNodeDaemon: @unchecked Sendable {
    struct ReadyEvent {
        let token: String
        let apiVersion: Int
        let socketPath: String
    }

    let client: WalletNodeClient

    private let pid: pid_t
    private var aliveWriteFD: Int32

    private init(pid: pid_t, aliveWriteFD: Int32, ready: ReadyEvent) {
        self.pid = pid
        self.aliveWriteFD = aliveWriteFD
        self.client = WalletNodeClient(
            configuration: WalletNodeClient.Configuration(
                transport: .unixSocket(ready.socketPath),
                bearerToken: ready.token
            )
        )
    }

    deinit {
        closeAlivePipe()
    }

    static func launch(
        bundlerSecret: BundlerSecretRecord,
        chain: ChainConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> WalletNodeDaemon {
        try await Task.detached(priority: .userInitiated) {
            try launchBlocking(
                bundlerSecret: bundlerSecret,
                chain: chain,
                environment: environment
            )
        }.value
    }

    private static func launchBlocking(
        bundlerSecret: BundlerSecretRecord,
        chain: ChainConfiguration,
        environment: [String: String]
    ) throws -> WalletNodeDaemon {
        let execPath = try resolveExecutablePath(environment: environment)
        try writeDaemonConfig(chain: chain)

        var readyPipe: [Int32] = [-1, -1]
        var alivePipe: [Int32] = [-1, -1]
        var secretPipe: [Int32] = [-1, -1]
        guard pipe(&readyPipe) == 0 else {
            throw AppError.localDaemonLaunchFailed("failed to create wallet-node ready pipe: errno \(errno)")
        }
        guard pipe(&alivePipe) == 0 else {
            closeIfOpen(&readyPipe[0])
            closeIfOpen(&readyPipe[1])
            throw AppError.localDaemonLaunchFailed("failed to create wallet-node alive pipe: errno \(errno)")
        }
        guard pipe(&secretPipe) == 0 else {
            closeIfOpen(&readyPipe[0])
            closeIfOpen(&readyPipe[1])
            closeIfOpen(&alivePipe[0])
            closeIfOpen(&alivePipe[1])
            throw AppError.localDaemonLaunchFailed("failed to create wallet-node secret pipe: errno \(errno)")
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
            try writeSecretPayload(bundlerSecret, to: secretPipe[1])
            closeIfOpen(&secretPipe[1])

            let readyData = try readLineWithTimeout(fd: readyPipe[0], timeout: 8)
            closeIfOpen(&readyPipe[0])
            let ready = try parseReadyEvent(readyData)
            return WalletNodeDaemon(pid: pid, aliveWriteFD: alivePipe[1], ready: ready)
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

    private static func resolveExecutablePath(environment: [String: String]) throws -> String {
        var candidates: [String] = []
        if let path = environment["LOCAL_WALLET_NODE_BIN"] {
            candidates.append(path)
        }
        if let path = environment["WALLET_NODE_BIN"] {
            candidates.append(path)
        }
        if let path = Bundle.main.url(forResource: "wallet-node", withExtension: nil)?.path {
            candidates.append(path)
        }
        candidates.append(sourceRootWalletNodePath(profile: "release"))
        candidates.append(sourceRootWalletNodePath(profile: "debug"))

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        throw AppError.localDaemonLaunchFailed("wallet-node binary was not found. Set WALLET_NODE_BIN (or LOCAL_WALLET_NODE_BIN) to an absolute path, or build wallet-node in a sibling local-wallet-daemon checkout.")
    }

    private static func sourceRootWalletNodePath(profile: String) -> String {
        // #filePath = <mac-repo>/wallet-macos/Sources/WalletMacOSApp/WalletNodeDaemon.swift
        // Walk up 5 levels to reach the parent of all sibling repo checkouts,
        // then descend into the sibling daemon repo's build output.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // .../WalletMacOSApp
            .deletingLastPathComponent()  // .../Sources
            .deletingLastPathComponent()  // .../wallet-macos
            .deletingLastPathComponent()  // <mac-repo>
            .deletingLastPathComponent()  // <parent dir holding sibling repos>
            .appendingPathComponent("local-wallet-daemon/target/\(profile)/wallet-node")
            .path
    }

    private static func writeDaemonConfig(chain: ChainConfiguration) throws {
        let directory = try daemonSupportDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let configURL = directory.appendingPathComponent("config.toml")
        let executionRPC = tomlEscaped(chain.rpcURL.absoluteString)
        let consensusRPC = tomlEscaped(consensusRPCURL(for: chain).absoluteString)
        let entryPoint = tomlEscaped(chain.entryPoint)
        let body = """
        [network]
        chain_id = \(chain.id)
        execution_rpc = "\(executionRPC)"
        consensus_rpc = "\(consensusRPC)"

        [bundler]
        entry_points = ["\(entryPoint)"]
        submit_rpcs = ["\(executionRPC)"]
        use_precompiled = false

        """
        try body.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private static func daemonSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("Local Wallet", isDirectory: true)
            .appendingPathComponent("wallet-node", isDirectory: true)
    }

    private static func consensusRPCURL(for chain: ChainConfiguration) -> URL {
        if chain.id == 11_155_111 {
            return URL(string: "https://ethereum-sepolia-beacon-api.publicnode.com")!
        }
        return URL(string: "https://lodestar-mainnet.chainsafe.io")!
    }

    private static func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func parseReadyEvent(_ data: Data) throws -> ReadyEvent {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String,
              let apiVersion = object["apiVersion"] as? Int,
              let socketPath = object["socketPath"] as? String,
              !token.isEmpty,
              !socketPath.isEmpty
        else {
            throw AppError.localDaemonLaunchFailed("wallet-node ready event was invalid")
        }
        return ReadyEvent(token: token, apiVersion: apiVersion, socketPath: socketPath)
    }

    private static func readLineWithTimeout(fd: Int32, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()

        while Date() < deadline {
            var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remainingMilliseconds = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
            let pollResult = poll(&pollFd, 1, remainingMilliseconds)
            if pollResult == 0 {
                throw AppError.localDaemonLaunchFailed("timed out waiting for wallet-node ready event")
            }
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                throw AppError.localDaemonLaunchFailed("wallet-node ready pipe poll failed: errno \(errno)")
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
                    throw AppError.localDaemonLaunchFailed("wallet-node ready pipe read failed: errno \(errno)")
                }
                if readCount == 0 {
                    throw AppError.localDaemonLaunchFailed("wallet-node ready pipe closed before ready event")
                }
                if byte == UInt8(ascii: "\n") {
                    return data
                }
                data.append(byte)
            }
        }

        throw AppError.localDaemonLaunchFailed("timed out waiting for wallet-node ready event")
    }

    private static func setCloseOnExec(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0 else {
            throw AppError.localDaemonLaunchFailed("fcntl(F_GETFD) failed: errno \(errno)")
        }
        guard fcntl(fd, F_SETFD, flags | FD_CLOEXEC) >= 0 else {
            throw AppError.localDaemonLaunchFailed("fcntl(F_SETFD) failed: errno \(errno)")
        }
    }

    private static func writeSecretPayload(_ record: BundlerSecretRecord, to fd: Int32) throws {
        let payload: [String: Any] = [
            "keys": [
                [
                    "keyRef": record.keyRef,
                    "secret": "0x" + record.secret.lowercaseHexString,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try writeAll(data, to: fd)
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
                    throw AppError.localDaemonLaunchFailed("wallet-node secret pipe write failed: errno \(errno)")
                }
                if written == 0 {
                    throw AppError.localDaemonLaunchFailed("wallet-node secret pipe write made no progress")
                }
                base = base.advanced(by: written)
                remaining -= written
            }
        }
    }

    private static func closeIfOpen(_ fd: inout Int32) {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private func closeAlivePipe() {
        if aliveWriteFD >= 0 {
            close(aliveWriteFD)
            aliveWriteFD = -1
        }
    }
}
