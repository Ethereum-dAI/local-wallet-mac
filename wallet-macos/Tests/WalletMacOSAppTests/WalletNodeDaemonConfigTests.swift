import Darwin
import Foundation
import Testing
@testable import WalletMacOSApp

private final class DaemonTerminationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var closedFileDescriptors: [Int32] = []
    private(set) var signals: [(pid: pid_t, signal: Int32)] = []
    private(set) var waits: [(pid: pid_t, timeout: TimeInterval, ranOnMainThread: Bool)] = []

    func recordClose(_ fd: Int32) {
        lock.lock()
        closedFileDescriptors.append(fd)
        lock.unlock()
    }

    func recordSignal(pid: pid_t, signal: Int32) {
        lock.lock()
        signals.append((pid, signal))
        lock.unlock()
    }

    func recordWait(pid: pid_t, timeout: TimeInterval) {
        lock.lock()
        waits.append((pid, timeout, Thread.isMainThread))
        lock.unlock()
    }

    var snapshot: (
        closedFileDescriptors: [Int32],
        signals: [(pid: pid_t, signal: Int32)],
        waits: [(pid: pid_t, timeout: TimeInterval, ranOnMainThread: Bool)]
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (closedFileDescriptors, signals, waits)
    }
}

private enum InjectedDaemonTerminationError: Error {
    case waitFailed
}

@Test @MainActor func managedDaemonTerminateAndWaitCoalescesOffTheMainActor() async throws {
    let recorder = DaemonTerminationRecorder()
    let lifetime = ManagedDaemonLifetime(
        pid: 741,
        aliveWriteFD: 48,
        closeFileDescriptor: recorder.recordClose,
        signalProcess: recorder.recordSignal,
        waitForExit: recorder.recordWait
    )

    async let first: Void = lifetime.terminateAndWait(timeout: 0.25)
    async let second: Void = lifetime.terminateAndWait(timeout: 0.5)
    _ = try await (first, second)

    let snapshot = recorder.snapshot
    #expect(snapshot.closedFileDescriptors == [48])
    #expect(snapshot.signals.count == 1)
    #expect(snapshot.signals.first?.pid == 741)
    #expect(snapshot.signals.first?.signal == SIGTERM)
    #expect(snapshot.waits.count == 1)
    #expect(snapshot.waits.first?.pid == 741)
    #expect(snapshot.waits.first?.timeout == 0.25 || snapshot.waits.first?.timeout == 0.5)
    #expect(snapshot.waits.first?.ranOnMainThread == false)
}

@Test func managedDaemonTerminateAndWaitPropagatesUnconfirmedExit() async {
    let recorder = DaemonTerminationRecorder()
    let lifetime = ManagedDaemonLifetime(
        pid: 742,
        aliveWriteFD: 49,
        closeFileDescriptor: recorder.recordClose,
        signalProcess: recorder.recordSignal,
        waitForExit: { _, _ in throw InjectedDaemonTerminationError.waitFailed }
    )

    await #expect(throws: InjectedDaemonTerminationError.waitFailed) {
        try await lifetime.terminateAndWait(timeout: 0.25)
    }

    let snapshot = recorder.snapshot
    #expect(snapshot.closedFileDescriptors == [49])
    #expect(snapshot.signals.count == 1)
    #expect(snapshot.signals.first?.pid == 742)
    #expect(snapshot.signals.first?.signal == SIGTERM)
}

@Test func managedDaemonTerminationIsIdempotent() {
    let recorder = DaemonTerminationRecorder()
    let lifetime = ManagedDaemonLifetime(
        pid: 321,
        aliveWriteFD: 45,
        closeFileDescriptor: recorder.recordClose,
        signalProcess: recorder.recordSignal
    )

    lifetime.terminate()
    lifetime.terminate()

    let snapshot = recorder.snapshot
    #expect(snapshot.closedFileDescriptors == [45])
    #expect(snapshot.signals.count == 1)
    #expect(snapshot.signals.first?.pid == 321)
    #expect(snapshot.signals.first?.signal == SIGTERM)
}

@Test func managedDaemonTerminationIsSafeAcrossConcurrentCallers() {
    let recorder = DaemonTerminationRecorder()
    let lifetime = ManagedDaemonLifetime(
        pid: 654,
        aliveWriteFD: 46,
        closeFileDescriptor: recorder.recordClose,
        signalProcess: recorder.recordSignal
    )

    DispatchQueue.concurrentPerform(iterations: 32) { _ in
        lifetime.terminate()
    }

    let snapshot = recorder.snapshot
    #expect(snapshot.closedFileDescriptors == [46])
    #expect(snapshot.signals.count == 1)
    #expect(snapshot.signals.first?.pid == 654)
    #expect(snapshot.signals.first?.signal == SIGTERM)
}

@Test func managedDaemonLifetimeTerminatesOnDeinit() {
    let recorder = DaemonTerminationRecorder()
    var lifetime: ManagedDaemonLifetime? = ManagedDaemonLifetime(
        pid: 987,
        aliveWriteFD: 47,
        closeFileDescriptor: recorder.recordClose,
        signalProcess: recorder.recordSignal
    )

    #expect(lifetime != nil)
    lifetime = nil

    let snapshot = recorder.snapshot
    #expect(snapshot.closedFileDescriptors == [47])
    #expect(snapshot.signals.count == 1)
    #expect(snapshot.signals.first?.pid == 987)
    #expect(snapshot.signals.first?.signal == SIGTERM)
}

@Test func daemonConfigUsesHigherSepoliaGasCaps() throws {
    let toml = WalletNodeDaemon.daemonConfigTOML(chain: .ethereumSepolia)

    #expect(toml.contains(#"chain_id = 11155111"#))
    #expect(toml.contains(#"execution_rpc = "https://ethereum-sepolia-rpc.publicnode.com""#))
    #expect(toml.contains(#"consensus_rpc = "http://unstable.sepolia.beacon-api.nimbus.team""#))
    #expect(toml.contains(#"read_verification = "helios""#))
    #expect(toml.contains(#"max_fee_per_gas = "0xba43b7400""#))
    #expect(toml.contains(#"max_priority_fee_per_gas = "0x12a05f200""#))
}

@Test func startupFailureDescriptionIncludesStructuredDaemonCause() {
    let logTail = #"{"timestamp":"2026-08-11T12:00:00Z","level":"ERROR","fields":{"message":"execution RPC chain id validation failed","error":"rpc error: eth_chainId HTTP status 400 Bad Request"},"target":"wallet_node"}"#

    let message = WalletNodeDaemon.startupFailureDescription(
        pipeFailure: "wallet-node ready pipe closed before ready event",
        waitStatus: 256,
        logTail: logTail
    )

    #expect(message.contains("exited with status 1"))
    #expect(message.contains("execution RPC chain id validation failed"))
    #expect(message.contains("eth_chainId HTTP status 400 Bad Request"))
    #expect(message.contains("ready pipe closed") == false)
}

@Test func startupFailureDescriptionFallsBackWhenLogsAreUnavailable() {
    let message = WalletNodeDaemon.startupFailureDescription(
        pipeFailure: "wallet-node ready pipe closed before ready event",
        waitStatus: nil,
        logTail: "wallet-node log file not found"
    )

    #expect(message == "wallet-node ready pipe closed before ready event")
}

@Test func daemonConfigIncludesPolicyDefaultsRequiredByWalletNode() throws {
    let toml = WalletNodeDaemon.daemonConfigTOML(chain: .ethereumSepolia)

    #expect(toml.contains("[policy]"))
    #expect(toml.contains(#"max_user_ops_per_bundle = 1"#))
    #expect(toml.contains(#"max_call_gas_limit = "0x989680""#))
    #expect(toml.contains(#"max_verification_gas_limit = "0x4c4b40""#))
    #expect(toml.contains(#"max_pre_verification_gas = "0x0f4240""#))
    #expect(toml.contains(#"min_replacement_bump_pct = 12.5"#))
    #expect(toml.contains(#"max_request_body_bytes = 262144"#))
    #expect(toml.contains(#"max_user_ops_per_sender_per_minute = 10"#))
    #expect(toml.contains(#"max_gas_wei_per_sender_per_hour = "0x0""#))
}

@Test func daemonConfigUsesCustomGasCaps() throws {
    let policy = try WalletNodeDaemon.GasPolicy.custom(
        maxFeePerGasGwei: "60",
        maxPriorityFeePerGasGwei: "2.5"
    )
    let toml = WalletNodeDaemon.daemonConfigTOML(chain: .ethereumSepolia, gasPolicy: policy)

    #expect(toml.contains(#"max_fee_per_gas = "0xdf8475800""#))
    #expect(toml.contains(#"max_priority_fee_per_gas = "0x9502f900""#))
}

@Test func automaticDaemonCeilingMatchesImmutableAppCaps() {
    let ceiling = WalletNodeDaemon.GasPolicy.autoCeiling

    #expect(ceiling.maxFeePerGasGwei == "50")
    #expect(ceiling.maxPriorityFeePerGasGwei == "5")
    let toml = WalletNodeDaemon.daemonConfigTOML(chain: .ethereumSepolia, gasPolicy: ceiling)
    #expect(toml.contains(#"max_fee_per_gas = "0xba43b7400""#))
    #expect(toml.contains(#"max_priority_fee_per_gas = "0x12a05f200""#))
}

@Test func daemonConfigCanDisableHeliosVerification() throws {
    let toml = WalletNodeDaemon.daemonConfigTOML(
        chain: .ethereumSepolia,
        gasPolicy: .sepolia,
        heliosVerificationEnabled: false
    )

    #expect(toml.contains(#"read_verification = "execution_rpc""#))
}

@Test func daemonConfigUsesExecutionRPCModeWhenConsensusIsEmpty() throws {
    let chain = ChainConfiguration.ethereumSepolia.overridingNetworkURLs(
        rpcURL: ChainConfiguration.ethereumSepolia.rpcURL,
        archiveRPCURL: nil,
        consensusRPCURL: nil
    )
    let toml = WalletNodeDaemon.daemonConfigTOML(chain: chain)

    #expect(toml.contains(#"consensus_rpc = """#))
    #expect(toml.contains(#"read_verification = "execution_rpc""#))
}

@Test func gasPolicyRejectsPriorityAboveMax() throws {
    #expect(throws: WalletNodeDaemon.GasPolicyError.self) {
        _ = try WalletNodeDaemon.GasPolicy.custom(
            maxFeePerGasGwei: "1",
            maxPriorityFeePerGasGwei: "2"
        )
    }
}
