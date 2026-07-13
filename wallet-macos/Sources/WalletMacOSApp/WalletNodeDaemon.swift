import Darwin
import Foundation
import SpawnHelper

final class WalletNodeDaemon: @unchecked Sendable {
    enum GasPolicyError: LocalizedError {
        case invalidGwei(field: String, value: String)
        case priorityAboveMax(maxField: String, priorityField: String)

        var errorDescription: String? {
            switch self {
            case .invalidGwei(let field, let value):
                return "\(field) must be a positive gwei amount with up to 9 decimal places. Current value: \(value)"
            case .priorityAboveMax(let maxField, let priorityField):
                return "\(priorityField) must be less than or equal to \(maxField)."
            }
        }
    }

    struct GasPolicy: Equatable {
        let maxFeePerGas: String
        let maxPriorityFeePerGas: String
        let maxFeePerGasGwei: String
        let maxPriorityFeePerGasGwei: String

        static let mainnet = GasPolicy(
            maxFeePerGas: "0x2540be400",      // 10 gwei
            maxPriorityFeePerGas: "0x3b9aca00", // 1 gwei
            maxFeePerGasGwei: "10",
            maxPriorityFeePerGasGwei: "1"
        )
        static let sepolia = GasPolicy(
            maxFeePerGas: "0xba43b7400",       // 50 gwei
            maxPriorityFeePerGas: "0x12a05f200", // 5 gwei
            maxFeePerGasGwei: "50",
            maxPriorityFeePerGasGwei: "5"
        )

        /// Generous ceiling used when automatic gas pricing is on, so the live
        /// fee is never rejected by the daemon `[policy]` caps. Auto mode follows
        /// the network; this is a safety bound, not a user-facing cap.
        // The `?? mainnet` fallback is never reached (100 <= 1500 and both are valid
        // gwei integers, so `custom` cannot throw). Do NOT change it to a low value
        // without thought: mainnet's 10 gwei cap would reject live gas under auto mode.
        static let autoCeiling: GasPolicy =
            (try? custom(maxFeePerGasGwei: "1500", maxPriorityFeePerGasGwei: "100")) ?? mainnet

        static func custom(
            maxFeePerGasGwei: String,
            maxPriorityFeePerGasGwei: String,
            maxField: String = "Max fee cap",
            priorityField: String = "Priority fee cap"
        ) throws -> GasPolicy {
            let normalizedMax = try normalizedGwei(maxFeePerGasGwei, field: maxField)
            let normalizedPriority = try normalizedGwei(maxPriorityFeePerGasGwei, field: priorityField)
            let maxWei = try wei(fromGwei: normalizedMax, field: maxField)
            let priorityWei = try wei(fromGwei: normalizedPriority, field: priorityField)
            guard priorityWei <= maxWei else {
                throw GasPolicyError.priorityAboveMax(maxField: maxField, priorityField: priorityField)
            }
            return GasPolicy(
                maxFeePerGas: "0x" + String(maxWei, radix: 16),
                maxPriorityFeePerGas: "0x" + String(priorityWei, radix: 16),
                maxFeePerGasGwei: normalizedMax,
                maxPriorityFeePerGasGwei: normalizedPriority
            )
        }

        static func normalizedGwei(_ value: String, field: String) throws -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try wei(fromGwei: trimmed, field: field)
            return normalizeGweiText(trimmed)
        }

        private static func wei(fromGwei value: String, field: String) throws -> UInt64 {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 1 || parts.count == 2 else {
                throw GasPolicyError.invalidGwei(field: field, value: value)
            }
            let wholeText = String(parts[0])
            guard wholeText.isEmpty == false, wholeText.allSatisfy(\.isNumber) else {
                throw GasPolicyError.invalidGwei(field: field, value: value)
            }
            let fractionalText = parts.count == 2 ? String(parts[1]) : ""
            guard fractionalText.allSatisfy(\.isNumber), fractionalText.count <= 9 else {
                throw GasPolicyError.invalidGwei(field: field, value: value)
            }
            guard let whole = UInt64(wholeText), whole <= UInt64.max / 1_000_000_000 else {
                throw GasPolicyError.invalidGwei(field: field, value: value)
            }
            let paddedFractional = fractionalText.padding(toLength: 9, withPad: "0", startingAt: 0)
            guard let fractional = UInt64(paddedFractional) else {
                throw GasPolicyError.invalidGwei(field: field, value: value)
            }
            let wei = whole * 1_000_000_000 + fractional
            guard wei > 0 else {
                throw GasPolicyError.invalidGwei(field: field, value: value)
            }
            return wei
        }

        private static func normalizeGweiText(_ value: String) -> String {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            let whole = String(parts[0]).drop(while: { $0 == "0" })
            let normalizedWhole = whole.isEmpty ? "0" : String(whole)
            guard parts.count == 2 else {
                return normalizedWhole
            }
            let fractional = String(parts[1]).reversed().drop(while: { $0 == "0" }).reversed()
            return fractional.isEmpty ? normalizedWhole : "\(normalizedWhole).\(String(fractional))"
        }
    }

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
        bundlerSecrets: [BundlerSecretRecord],
        chain: ChainConfiguration,
        gasPolicy: GasPolicy,
        heliosVerificationEnabled: Bool = true,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> WalletNodeDaemon {
        try await Task.detached(priority: .userInitiated) {
            try launchBlocking(
                bundlerSecrets: bundlerSecrets,
                chain: chain,
                gasPolicy: gasPolicy,
                heliosVerificationEnabled: heliosVerificationEnabled,
                environment: environment
            )
        }.value
    }

    private static func launchBlocking(
        bundlerSecrets: [BundlerSecretRecord],
        chain: ChainConfiguration,
        gasPolicy: GasPolicy,
        heliosVerificationEnabled: Bool,
        environment: [String: String]
    ) throws -> WalletNodeDaemon {
        guard !bundlerSecrets.isEmpty else {
            throw AppError.localRelayerKeyMissing
        }
        let execPath = try resolveExecutablePath(environment: environment)
        try writeDaemonConfig(
            chain: chain,
            gasPolicy: gasPolicy,
            heliosVerificationEnabled: heliosVerificationEnabled
        )

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

            let pid = try withWalletNodeLoggingEnvironment(environment) {
                try spawnHelper(
                    execPath: execPath,
                    readyWrite: readyPipe[1],
                    aliveRead: alivePipe[0],
                    secretRead: secretPipe[0]
                )
            }
            closeIfOpen(&readyPipe[1])
            closeIfOpen(&alivePipe[0])
            closeIfOpen(&secretPipe[0])
            try writeSecretPayload(bundlerSecrets, to: secretPipe[1])
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
        if let path = Bundle.main.url(forResource: "wallet-node", withExtension: nil, subdirectory: "bin")?.path {
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

        throw AppError.localDaemonLaunchFailed("wallet-node binary was not found. Set WALLET_NODE_BIN (or LOCAL_WALLET_NODE_BIN) to an absolute path, or build wallet-node in the in-repo local-wallet-daemon workspace.")
    }

    private static func sourceRootWalletNodePath(profile: String) -> String {
        // #filePath = <repo-root>/wallet-macos/Sources/WalletMacOSApp/WalletNodeDaemon.swift
        // Walk up 4 levels to reach the repo root, then descend into the
        // in-repo daemon directory's build output.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // .../WalletMacOSApp
            .deletingLastPathComponent()  // .../Sources
            .deletingLastPathComponent()  // .../wallet-macos
            .deletingLastPathComponent()  // <repo-root>
            .appendingPathComponent("local-wallet-daemon/target/\(profile)/wallet-node")
            .path
    }

    private static func writeDaemonConfig(
        chain: ChainConfiguration,
        gasPolicy: GasPolicy,
        heliosVerificationEnabled: Bool
    ) throws {
        let directory = try daemonSupportDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let configURL = directory.appendingPathComponent("config.toml")
        try daemonConfigTOML(
            chain: chain,
            gasPolicy: gasPolicy,
            heliosVerificationEnabled: heliosVerificationEnabled
        )
        .write(to: configURL, atomically: true, encoding: .utf8)
    }

    static func managedLogFileURL(fileManager: FileManager = .default) -> URL? {
        guard let directory = try? daemonSupportDirectory(fileManager: fileManager) else {
            return nil
        }
        return directory
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("wallet-node.log", isDirectory: false)
    }

    static func managedLogTail(maxBytes: Int = 96 * 1024, fileManager: FileManager = .default) -> String {
        guard let logURL = managedLogFileURL(fileManager: fileManager) else {
            return "wallet-node log path unavailable"
        }
        guard fileManager.fileExists(atPath: logURL.path) else {
            return "wallet-node log file not found at \(logURL.path)"
        }
        do {
            let handle = try FileHandle(forReadingFrom: logURL)
            defer {
                try? handle.close()
            }
            let size = try handle.seekToEnd()
            let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            let text = String(data: data, encoding: .utf8) ?? "<wallet-node log is not valid UTF-8>"
            if offset == 0 {
                return text.isEmpty ? "<wallet-node log is empty>" : text
            }
            return "<tail truncated to last \(maxBytes) bytes>\n\(text)"
        } catch {
            return "wallet-node log read failed: \(error.localizedDescription)"
        }
    }

    static func gasPolicy(for chain: ChainConfiguration) -> GasPolicy {
        chain.isTestnet ? .sepolia : .mainnet
    }

    static func daemonConfigTOML(chain: ChainConfiguration) -> String {
        daemonConfigTOML(chain: chain, gasPolicy: gasPolicy(for: chain))
    }

    static func daemonConfigTOML(
        chain: ChainConfiguration,
        gasPolicy: GasPolicy,
        heliosVerificationEnabled: Bool = true
    ) -> String {
        let executionRPC = tomlEscaped(chain.rpcURL.absoluteString)
        let consensusRPC = tomlEscaped(chain.consensusRPCURL?.absoluteString ?? "")
        let entryPoint = tomlEscaped(chain.entryPoint)
        let readVerification = heliosVerificationEnabled && chain.consensusRPCURL != nil ? "helios" : "execution_rpc"
        return """
        [network]
        chain_id = \(chain.id)
        execution_rpc = "\(executionRPC)"
        consensus_rpc = "\(consensusRPC)"
        read_verification = "\(readVerification)"

        [bundler]
        entry_points = ["\(entryPoint)"]
        submit_rpcs = ["\(executionRPC)"]
        use_precompiled = true

        [policy]
        max_user_ops_per_bundle = 1
        max_call_gas_limit = "0x989680"
        max_verification_gas_limit = "0x4c4b40"
        max_pre_verification_gas = "0x0f4240"
        max_fee_per_gas = "\(gasPolicy.maxFeePerGas)"
        max_priority_fee_per_gas = "\(gasPolicy.maxPriorityFeePerGas)"
        min_replacement_bump_pct = 12.5
        max_request_body_bytes = 262144
        max_user_ops_per_sender_per_minute = 10
        max_gas_wei_per_sender_per_hour = "0x0"

        """
    }

    private static func daemonSupportDirectory(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("Local Wallet", isDirectory: true)
            .appendingPathComponent("wallet-node", isDirectory: true)
    }

    private static func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func withWalletNodeLoggingEnvironment<T>(
        _ environment: [String: String],
        _ body: () throws -> T
    ) throws -> T {
        let rustLog = environment["LOCAL_WALLET_NODE_RUST_LOG"]
            ?? environment["WALLET_NODE_RUST_LOG"]
            ?? environment["RUST_LOG"]
            ?? defaultManagedRustLog
        let rustBacktrace = environment["RUST_BACKTRACE"] ?? "1"
        let oldRustLog = getenv("RUST_LOG").map { String(cString: $0) }
        let oldRustBacktrace = getenv("RUST_BACKTRACE").map { String(cString: $0) }

        setenv("RUST_LOG", rustLog, 1)
        setenv("RUST_BACKTRACE", rustBacktrace, 1)
        defer {
            restoreEnvironmentVariable("RUST_LOG", oldRustLog)
            restoreEnvironmentVariable("RUST_BACKTRACE", oldRustBacktrace)
        }

        return try body()
    }

    private static func restoreEnvironmentVariable(_ name: String, _ value: String?) {
        if let value {
            setenv(name, value, 1)
        } else {
            unsetenv(name)
        }
    }

    private static let defaultManagedRustLog = [
        "wallet_node=trace",
        "wallet_node_api=trace",
        "wallet_node_store=trace",
        "wallet_chain=trace",
        "wallet_bundler=trace",
        "helios=trace",
        "warn",
    ].joined(separator: ",")

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

    static func secretPayloadData(_ records: [BundlerSecretRecord]) throws -> Data {
        let payload: [String: Any] = [
            "keys": records.map { record in
                [
                    "keyRef": record.keyRef,
                    "secret": "0x" + record.secret.lowercaseHexString,
                ]
            },
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private static func writeSecretPayload(_ records: [BundlerSecretRecord], to fd: Int32) throws {
        try writeAll(try secretPayloadData(records), to: fd)
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
