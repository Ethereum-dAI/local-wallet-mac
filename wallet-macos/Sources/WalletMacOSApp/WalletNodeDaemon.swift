import Darwin
import Foundation
import SpawnHelper

/// Owns the two process-lifetime handles shared by managed sidecars.
///
/// `terminate()` serializes taking and invalidating the handles with their system calls. That
/// makes explicit shutdown, concurrent shutdown, and `deinit` safely idempotent: no later caller
/// can close a recycled descriptor or signal a recycled PID.
final class ManagedDaemonLifetime: @unchecked Sendable {
    typealias CloseFileDescriptor = @Sendable (Int32) -> Void
    typealias SignalProcess = @Sendable (pid_t, Int32) -> Void
    typealias WaitForExit = @Sendable (pid_t, TimeInterval) throws -> Void

    enum TerminationError: LocalizedError {
        case waitFailed(pid: pid_t, code: Int32)
        case signalFailed(pid: pid_t, code: Int32)
        case forceKillTimedOut(pid: pid_t)

        var errorDescription: String? {
            switch self {
            case let .waitFailed(pid, code):
                return "Waiting for managed daemon pid \(pid) failed with errno \(code)."
            case let .signalFailed(pid, code):
                return "Stopping managed daemon pid \(pid) failed with errno \(code)."
            case let .forceKillTimedOut(pid):
                return "Managed daemon pid \(pid) did not exit after SIGKILL."
            }
        }
    }

    private let lock = NSLock()
    private let pid: pid_t
    private var aliveWriteFD: Int32
    private var didRequestTermination = false
    private var waitTask: Task<Void, Error>?
    private let closeFileDescriptor: CloseFileDescriptor
    private let signalProcess: SignalProcess
    private let waitForExit: WaitForExit

    init(
        pid: pid_t,
        aliveWriteFD: Int32,
        closeFileDescriptor: @escaping CloseFileDescriptor = { _ = Darwin.close($0) },
        signalProcess: @escaping SignalProcess = { _ = Darwin.kill($0, $1) },
        waitForExit: @escaping WaitForExit = ManagedDaemonLifetime.waitForExit
    ) {
        self.pid = pid
        self.aliveWriteFD = aliveWriteFD
        self.closeFileDescriptor = closeFileDescriptor
        self.signalProcess = signalProcess
        self.waitForExit = waitForExit
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        if aliveWriteFD >= 0 {
            closeFileDescriptor(aliveWriteFD)
            aliveWriteFD = -1
        }
        if !didRequestTermination, pid > 0 {
            didRequestTermination = true
            signalProcess(pid, SIGTERM)
        }
    }

    /// Request graceful shutdown, then wait off the caller's actor for the child to be reaped.
    /// After `timeout`, the waiter sends SIGKILL and allows one additional bounded reap window.
    /// Concurrent callers share the same detached waiter.
    func terminateAndWait(timeout: TimeInterval = 2) async throws {
        terminate()
        guard pid > 0 else { return }

        try await coalescedWaitTask(timeout: timeout).value
    }

    /// `NSLock` is deliberately confined to a synchronous function. Swift 6 rejects locking
    /// directly from an async context because suspension while holding the lock would deadlock.
    private func coalescedWaitTask(timeout: TimeInterval) -> Task<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = waitTask {
            return existing
        }

        let waitForExit = self.waitForExit
        let pid = self.pid
        let boundedTimeout = max(0, timeout)
        let created = Task.detached(priority: .userInitiated) {
            try waitForExit(pid, boundedTimeout)
        }
        waitTask = created
        return created
    }

    private static func waitForExit(pid: pid_t, timeout: TimeInterval) throws {
        let gracefulDeadline = ProcessInfo.processInfo.systemUptime + timeout
        if try pollUntilExited(pid: pid, deadline: gracefulDeadline) {
            return
        }

        if Darwin.kill(pid, SIGKILL) != 0 {
            let code = errno
            if code == ESRCH {
                return
            }
            throw TerminationError.signalFailed(pid: pid, code: code)
        }

        // SIGKILL should resolve immediately, but keep this bounded as well so a pathological
        // child cannot hang a destructive reset. If it somehow outlives the window, leave a
        // background waiter behind to reap it when the kernel finally reports the exit.
        let forceKillDeadline = ProcessInfo.processInfo.systemUptime + 1
        if try pollUntilExited(pid: pid, deadline: forceKillDeadline) {
            return
        }
        reapEventually(pid: pid)
        throw TerminationError.forceKillTimedOut(pid: pid)
    }

    private static func pollUntilExited(pid: pid_t, deadline: TimeInterval) throws -> Bool {
        while true {
            var status: Int32 = 0
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid {
                return true
            }
            if result == -1 {
                let code = errno
                switch code {
                case ECHILD, ESRCH:
                    return true
                case EINTR:
                    continue
                default:
                    throw TerminationError.waitFailed(pid: pid, code: code)
                }
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                return false
            }
            usleep(20_000)
        }
    }

    private static func reapEventually(pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while Darwin.waitpid(pid, &status, 0) == -1, errno == EINTR {}
        }
    }

    deinit {
        terminate()
    }
}

final class WalletNodeDaemon: @unchecked Sendable {
    enum ReadyPipeFailure: LocalizedError {
        case timedOut
        case pollFailed(code: Int32)
        case readFailed(code: Int32)
        case closed

        var errorDescription: String? {
            switch self {
            case .timedOut:
                return "timed out waiting for wallet-node ready event"
            case .pollFailed(let code):
                return "wallet-node ready pipe poll failed: errno \(code)"
            case .readFailed(let code):
                return "wallet-node ready pipe read failed: errno \(code)"
            case .closed:
                return "wallet-node ready pipe closed before ready event"
            }
        }
    }

    private enum ChildExitPollResult {
        case exited(Int32)
        case running
        case unavailable
    }

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

        static let sepolia = GasPolicy(
            maxFeePerGas: "0xba43b7400",       // 50 gwei
            maxPriorityFeePerGas: "0x12a05f200", // 5 gwei
            maxFeePerGasGwei: "50",
            maxPriorityFeePerGasGwei: "5"
        )

        /// Defense-in-depth ceiling used when automatic gas pricing is on. The
        /// app-side authorization policy independently enforces the same 50/5
        /// gwei caps; wallet-node must never be launched with a looser ceiling.
        static let autoCeiling: GasPolicy = sepolia

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

    private let lifetime: ManagedDaemonLifetime

    private init(pid: pid_t, aliveWriteFD: Int32, ready: ReadyEvent) {
        self.lifetime = ManagedDaemonLifetime(pid: pid, aliveWriteFD: aliveWriteFD)
        self.client = WalletNodeClient(
            configuration: WalletNodeClient.Configuration(
                transport: .unixSocket(ready.socketPath),
                bearerToken: ready.token
            )
        )
    }

    deinit {
        terminate()
    }

    /// Stop the managed child now instead of waiting for this owner to deallocate.
    /// Safe to call repeatedly or concurrently with deinitialization.
    func terminate() {
        lifetime.terminate()
    }

    /// Stop and reap the managed wallet-node child without blocking the caller's actor.
    func terminateAndWait(timeout: TimeInterval = 2) async throws {
        try await lifetime.terminateAndWait(timeout: timeout)
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
        let executable: TrustedHelperExecutable
        do {
            executable = try TrustedHelperExecutableResolver.resolve(
                .walletNode,
                environment: environment
            )
        } catch {
            throw AppError.localDaemonLaunchFailed(error.localizedDescription)
        }
        try writeDaemonConfig(
            chain: chain,
            gasPolicy: gasPolicy,
            heliosVerificationEnabled: heliosVerificationEnabled
        )

        var readyPipe: [Int32] = [-1, -1]
        var alivePipe: [Int32] = [-1, -1]
        var secretPipe: [Int32] = [-1, -1]
        var spawnedPID: pid_t = -1
        let startupLogOffset = managedLogFileSize()
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

            spawnedPID = try withWalletNodeLoggingEnvironment(environment) {
                try spawnHelper(
                    execPath: executable.path,
                    readyWrite: readyPipe[1],
                    aliveRead: alivePipe[0],
                    secretRead: secretPipe[0],
                    startSuspended: true
                )
            }
            closeIfOpen(&readyPipe[1])
            closeIfOpen(&alivePipe[0])
            closeIfOpen(&secretPipe[0])
            do {
                try TrustedHelperLaunchGate.authenticateDeliverAndResume(
                    pid: spawnedPID,
                    executable: executable
                ) {
                    defer { closeIfOpen(&secretPipe[1]) }
                    try writeSecretPayload(bundlerSecrets, to: secretPipe[1])
                }
            } catch {
                // The gate owns and reaps a rejected suspended process. Prevent the outer
                // cleanup path from ever signalling a PID that the kernel could later reuse.
                spawnedPID = -1
                throw AppError.localDaemonLaunchFailed(error.localizedDescription)
            }

            let readyData = try readLineWithTimeout(
                fd: readyPipe[0],
                timeout: 8
            )
            closeIfOpen(&readyPipe[0])
            let ready = try parseReadyEvent(readyData)
            return WalletNodeDaemon(pid: spawnedPID, aliveWriteFD: alivePipe[1], ready: ready)
        } catch {
            closeIfOpen(&readyPipe[0])
            closeIfOpen(&readyPipe[1])
            closeIfOpen(&alivePipe[0])
            closeIfOpen(&alivePipe[1])
            closeIfOpen(&secretPipe[0])
            closeIfOpen(&secretPipe[1])
            let waitStatus = spawnedPID > 0 ? terminateAndReapFailedLaunch(pid: spawnedPID) : nil
            if let pipeFailure = error as? ReadyPipeFailure {
                throw AppError.localDaemonLaunchFailed(
                    startupFailureDescription(
                        pipeFailure: pipeFailure.localizedDescription,
                        waitStatus: waitStatus,
                        logTail: managedLogTail(
                            startingAt: startupLogOffset,
                            maxBytes: 32 * 1024
                        )
                    )
                )
            }
            throw error
        }
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
        managedLogTail(startingAt: nil, maxBytes: maxBytes, fileManager: fileManager)
    }

    private static func managedLogFileSize(fileManager: FileManager = .default) -> UInt64? {
        guard let logURL = managedLogFileURL(fileManager: fileManager),
              let attributes = try? fileManager.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? NSNumber
        else {
            return nil
        }
        return size.uint64Value
    }

    private static func managedLogTail(
        startingAt requestedOffset: UInt64?,
        maxBytes: Int,
        fileManager: FileManager = .default
    ) -> String {
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
            let boundedStart = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            let requestedStart = requestedOffset.flatMap { $0 <= size ? $0 : nil } ?? 0
            let offset = max(boundedStart, requestedStart)
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            let text = String(data: data, encoding: .utf8) ?? "<wallet-node log is not valid UTF-8>"
            if offset == 0 {
                return text.isEmpty ? "<wallet-node log is empty>" : text
            }
            if requestedOffset != nil, offset == requestedStart {
                return text
            }
            return "<tail truncated to last \(maxBytes) bytes>\n\(text)"
        } catch {
            return "wallet-node log read failed: \(error.localizedDescription)"
        }
    }

    static func gasPolicy(for _: ChainConfiguration) -> GasPolicy {
        .sepolia
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
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.localDaemonLaunchFailed("wallet-node ready event was invalid")
        }
        // A fatal startup failure arrives on this same pipe. The daemon knows
        // exactly why it is exiting, so prefer its reason over anything we
        // could infer from the fd closing.
        if let reason = object["error"] as? String, !reason.isEmpty {
            throw AppError.localDaemonLaunchFailed("wallet-node failed to start: \(reason)")
        }
        guard let token = object["token"] as? String,
              let apiVersion = object["apiVersion"] as? Int,
              let socketPath = object["socketPath"] as? String,
              !token.isEmpty,
              !socketPath.isEmpty
        else {
            throw AppError.localDaemonLaunchFailed("wallet-node ready event was invalid")
        }
        return ReadyEvent(token: token, apiVersion: apiVersion, socketPath: socketPath)
    }

    /// tracing writes microsecond precision (`…:57.751405Z`); `ISO8601DateFormatter`
    /// accepts only milliseconds, so trim the surplus digits before parsing.
    static func parseDaemonLogTimestamp(_ raw: String) -> Date? {
        // Built per call rather than cached: ISO8601DateFormatter is not
        // Sendable, and this only ever runs on a failed launch.
        guard raw.hasSuffix("Z"), let dot = raw.firstIndex(of: ".") else {
            return ISO8601DateFormatter().date(from: raw)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fraction = raw[raw.index(after: dot)..<raw.index(before: raw.endIndex)]
        let milliseconds = String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        return formatter.date(from: "\(raw[raw.startIndex..<dot]).\(milliseconds)Z")
    }

    /// The last error the daemon logged at or after `since`, for the case where
    /// it died without writing a failure event at all — a signal, a panic, a
    /// failed exec.
    ///
    /// The `since` bound is load-bearing: the log is appended across launches,
    /// so without it a stale error from a previous run would be reported as the
    /// reason this one failed.
    static func lastLoggedDaemonError(since: Date, tail: String? = nil) -> String? {
        let text = tail ?? managedLogTail(maxBytes: 16 * 1024)
        for line in text.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["level"] as? String == "ERROR",
                  let rawTimestamp = object["timestamp"] as? String,
                  let at = parseDaemonLogTimestamp(rawTimestamp),
                  at >= since,
                  let fields = object["fields"] as? [String: Any],
                  let message = fields["message"] as? String
            else { continue }
            guard let detail = fields["error"] as? String else { return message }
            return "\(message): \(detail)"
        }
        return nil
    }

    static func startupFailureDescription(
        pipeFailure: String,
        waitStatus: Int32?,
        logTail: String
    ) -> String {
        let processDescription = waitStatus.map(processExitDescription)
        if let daemonFailure = latestStructuredLogFailure(in: logTail) {
            if let processDescription {
                return "wallet-node \(processDescription): \(daemonFailure)"
            }
            return "wallet-node failed before ready: \(daemonFailure)"
        }
        if let processDescription {
            return "\(pipeFailure) (wallet-node \(processDescription))"
        }
        return pipeFailure
    }

    static func latestStructuredLogFailure(in logTail: String) -> String? {
        var fallback: String?
        for line in logTail.split(whereSeparator: \.isNewline).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fields = object["fields"] as? [String: Any],
                  let message = fields["message"] as? String,
                  message.isEmpty == false
            else {
                continue
            }
            let detail = fields["error"] as? String
            let diagnostic = detail.flatMap { $0.isEmpty ? nil : "\(message): \($0)" } ?? message
            if (object["level"] as? String)?.uppercased() == "ERROR" {
                return diagnostic
            }
            if fallback == nil, detail != nil {
                fallback = diagnostic
            }
        }
        return fallback
    }

    private static func processExitDescription(status: Int32) -> String {
        let signal = status & 0x7f
        if signal == 0 {
            return "exited with status \((status >> 8) & 0xff)"
        }
        if signal == 0x7f {
            return "stopped with status \((status >> 8) & 0xff)"
        }
        return "terminated by signal \(signal)"
    }

    private static func terminateAndReapFailedLaunch(pid: pid_t) -> Int32? {
        switch pollForChildExit(pid: pid, timeout: 0.25) {
        case .exited(let status):
            return status
        case .unavailable:
            return nil
        case .running:
            break
        }
        if Darwin.kill(pid, SIGTERM) != 0, errno != ESRCH {
            return nil
        }
        switch pollForChildExit(pid: pid, timeout: 0.25) {
        case .exited(let status):
            return status
        case .unavailable:
            return nil
        case .running:
            break
        }
        if Darwin.kill(pid, SIGKILL) != 0, errno != ESRCH {
            return nil
        }

        var status: Int32 = 0
        while true {
            let result = Darwin.waitpid(pid, &status, 0)
            if result == pid {
                return status
            }
            if result == -1, errno == EINTR {
                continue
            }
            return nil
        }
    }

    private static func pollForChildExit(pid: pid_t, timeout: TimeInterval) -> ChildExitPollResult {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            var status: Int32 = 0
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid {
                return .exited(status)
            }
            if result == -1 {
                if errno == EINTR {
                    continue
                }
                return .unavailable
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                return .running
            }
            usleep(10_000)
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
                throw ReadyPipeFailure.timedOut
            }
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                throw ReadyPipeFailure.pollFailed(code: errno)
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
                    throw ReadyPipeFailure.readFailed(code: errno)
                }
                if readCount == 0 {
                    throw ReadyPipeFailure.closed
                }
                if byte == UInt8(ascii: "\n") {
                    return data
                }
                data.append(byte)
            }
        }

        throw ReadyPipeFailure.timedOut
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

}

/// Exact state checks for the two halves of first-time relayer registration.
///
/// The first daemon must prove that wallet-node derived and loaded the expected
/// identity from the supplied secret. The second daemon must prove that only the
/// public mapping survived the restart. Keeping this separate from the process
/// orchestration makes every fail-closed branch deterministic to test.
enum RelayerBootstrapRegistrationPolicy {
    enum Failure: LocalizedError, Equatable {
        case unexpectedLoadedState(expected: Bool, actual: Bool)

        var errorDescription: String? {
            switch self {
            case let .unexpectedLoadedState(expected, actual):
                return expected
                    ? "wallet-node did not load the relayer secret during registration (keyLoaded=\(actual))."
                    : "wallet-node retained the relayer secret after the read-only restart (keyLoaded=\(actual))."
            }
        }
    }

    static func verify(
        status: WalletNodeClient.RelayerStatus,
        identity: VerifiedRelayerIdentity,
        expectedKeyLoaded: Bool,
        expectedOwnerScope: String,
        expectedNetworkProfile: String
    ) throws {
        guard status.keyLoaded == expectedKeyLoaded else {
            throw Failure.unexpectedLoadedState(
                expected: expectedKeyLoaded,
                actual: status.keyLoaded
            )
        }
        try RelayerIdentityBindingPolicy.verify(
            status: status,
            against: identity,
            expectedOwnerScope: expectedOwnerScope,
            expectedNetworkProfile: expectedNetworkProfile
        )
    }
}

/// Registers a freshly provisioned relayer from the secret, then proves that a
/// clean restart keeps only its public database row.
///
/// This service is used only by explicit setup/reset actions. Ordinary launches
/// continue to pass an empty key list and never touch protected Keychain data.
@MainActor
struct RelayerBootstrapRegistrationService {
    typealias Probe = @MainActor (
        [BundlerSecretRecord],
        ChainConfiguration,
        WalletNodeDaemon.GasPolicy
    ) async throws -> WalletNodeClient.RelayerStatus

    private let probe: Probe

    init() {
        probe = Self.runProbe
    }

    init(probe: @escaping Probe) {
        self.probe = probe
    }

    func register(
        record: BundlerSecretRecord,
        chain: ChainConfiguration,
        gasPolicy: WalletNodeDaemon.GasPolicy
    ) async throws -> VerifiedRelayerIdentity {
        let identity = try VerifiedRelayerIdentity.derive(
            keyRef: record.keyRef,
            secret: record.secret
        )
        guard identity.chainID == chain.id else {
            throw VerifiedRelayerIdentity.ValidationError.keyRefChainMismatch(
                expected: chain.id,
                actual: identity.chainID
            )
        }

        try Task.checkCancellation()
        let registeredStatus = try await probe([record], chain, gasPolicy)
        try Task.checkCancellation()
        try RelayerBootstrapRegistrationPolicy.verify(
            status: registeredStatus,
            identity: identity,
            expectedKeyLoaded: true,
            expectedOwnerScope: "default",
            expectedNetworkProfile: chain.shortName
        )

        try Task.checkCancellation()
        let lockedStatus = try await probe([], chain, gasPolicy)
        try Task.checkCancellation()
        try RelayerBootstrapRegistrationPolicy.verify(
            status: lockedStatus,
            identity: identity,
            expectedKeyLoaded: false,
            expectedOwnerScope: "default",
            expectedNetworkProfile: chain.shortName
        )
        return identity
    }

    /// Helios is deliberately disabled for these short-lived registration
    /// probes. The durable relayer mapping does not depend on consensus sync,
    /// and the next normal launch restores the user's configured read mode.
    private static func runProbe(
        bundlerSecrets: [BundlerSecretRecord],
        chain: ChainConfiguration,
        gasPolicy: WalletNodeDaemon.GasPolicy
    ) async throws -> WalletNodeClient.RelayerStatus {
        let daemon = try await WalletNodeDaemon.launch(
            bundlerSecrets: bundlerSecrets,
            chain: chain,
            gasPolicy: gasPolicy,
            heliosVerificationEnabled: false
        )
        do {
            let status = try await daemon.client.bundlerStatus()
            try await daemon.terminateAndWait()
            return status
        } catch {
            let originalError = error
            daemon.terminate()
            // Cleanup is load-bearing when this was the secret-bearing probe.
            // Preserve the operation failure, but do not return until the child
            // has had the bounded termination/reap sequence applied.
            try? await daemon.terminateAndWait()
            throw originalError
        }
    }
}
