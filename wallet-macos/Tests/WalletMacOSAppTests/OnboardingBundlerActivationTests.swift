import Foundation
import Testing
@testable import WalletMacOSApp

@Suite struct OnboardingBundlerActivationTests {
    @Test func defaultTimingUsesAModestPollInterval() {
        #expect(OnboardingBundlerActivationTiming.default.pollInterval == 2)
    }

    @MainActor
    @Test func monitorReadsImmediatelyThenStopsAtTheExactFloor() async throws {
        let reader = SequencedBalanceReader([
            "0x0",
            BundlerFundingPolicy.minimumBalanceWeiHex,
        ])
        let sleeper = RecordingSleeper()
        let service = OnboardingBundlerActivationService(
            readBalance: { address, rpcURL, chainID in
                try await reader.read(address, rpcURL, chainID)
            },
            sleep: { interval in
                await sleeper.sleep(interval)
            }
        )
        var observed: [String] = []

        let ready = try await service.waitUntilReady(
            address: "0x7A3f000000000000000000000000000000009C21",
            rpcURL: URL(string: "https://rpc.example")!,
            expectedChainID: 11_155_111,
            onBalance: { observed.append($0) }
        )

        #expect(observed == ["0x0", BundlerFundingPolicy.minimumBalanceWeiHex])
        #expect(ready == BundlerFundingPolicy.minimumBalanceWeiHex)
        #expect(await sleeper.callCount == 1)
    }

    @MainActor
    @Test func cancellationStopsFurtherReadsAndPublishes() async {
        let reader = RepeatingBalanceReader(value: "0x0")
        let service = OnboardingBundlerActivationService(
            readBalance: { address, rpcURL, chainID in
                await reader.read(address, rpcURL, chainID)
            },
            sleep: { _ in
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        )
        var observed: [String] = []
        let task = Task {
            try await service.waitUntilReady(
                address: "0x7A3f000000000000000000000000000000009C21",
                rpcURL: URL(string: "https://rpc.example")!,
                expectedChainID: 11_155_111,
                onBalance: { observed.append($0) }
            )
        }

        for _ in 0..<50 where await reader.callCount == 0 {
            await Task.yield()
        }
        #expect(await reader.callCount == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await reader.callCount == 1)
        #expect(observed == ["0x0"])
    }

    @Test func activationSourceHasNoDaemonOrProtectedKeyAccess() throws {
        let source = try appSource(named: "OnboardingBundlerActivation.swift")
        #expect(source.contains("ExecutionFeeOracle"))
        #expect(source.contains("WalletNodeDaemon") == false)
        #expect(source.contains("BundlerKeyStore") == false)
        #expect(source.contains("DeviceOwnerAuthentication") == false)
    }

    @Test func externalFundingActionsKeepCopyPrimaryAndFaucetSeparate() throws {
        let source = try appSource(named: "BundlerExternalFundingActions.swift")
        let copy = try sourceSlice(
            source,
            from: "Button {",
            until: "Link(destination: faucetURL)"
        )
        let faucet = try sourceSlice(
            source,
            from: "Link(destination: faucetURL)",
            until: ".accessibilityHint(\"Opens the faucet without changing the clipboard\")"
        )

        #expect(copy.contains("NSPasteboard.general.setString"))
        #expect(copy.contains(".buttonStyle(.borderedProminent)"))
        #expect(copy.contains(".controlSize(compact ? .small : .large)"))
        #expect(faucet.contains(".buttonStyle(.bordered)"))
        #expect(faucet.contains(".controlSize(compact ? .small : .large)"))
        #expect(faucet.contains("NSPasteboard") == false)
        #expect(source.firstRange(of: "Copy address")!.lowerBound
            < source.firstRange(of: "Open Sepolia faucet")!.lowerBound)
    }

    @Test func activationScreenUsesCompactParentheticalStatus() throws {
        let source = try appSource(named: "OnboardingView.swift")
        let activation = try sourceSlice(
            source,
            from: "private struct BundlerActivationStep",
            until: "private struct SyncStep"
        )
        let waiting = try sourceSlice(
            activation,
            from: "case .waiting:",
            until: "case .ready(let balance):"
        )

        #expect(activation.contains("OnboardingGlassCard") == false)
        #expect(activation.contains("statusText(") == false)
        #expect(waiting.contains("Waiting for deposit ("))
        #expect(waiting.contains(#"\(BundlerFundingPolicy.minimumBalanceDisplay) required)"#))
        #expect(!waiting.contains(" detected"))
        #expect(waiting.contains(" / ") == false)
        #expect(activation.contains("Deposit detected:"))
        #expect(activation.contains("Retry check"))
        #expect(activation.contains("·") == false)
    }

    @Test func activationScreenStartsAndCancelsItsPublicMonitor() throws {
        let source = try appSource(named: "OnboardingView.swift")
        let activation = try sourceSlice(
            source,
            from: "private struct BundlerActivationStep",
            until: "private struct SyncStep"
        )
        #expect(activation.contains("startBundlerActivationIfNeeded"))
        #expect(activation.contains("cancelBundlerActivation"))
        #expect(activation.contains("didBecomeActiveNotification"))
        #expect(activation.contains("refreshBundlerActivationNow"))
    }

    @MainActor
    @Test func visibleOrderAlwaysPlacesActivationAfterKeys() throws {
        let withSync = makeState(consensusURL: "https://beacon.example")
        #expect(withSync.visibleSteps == [.welcome, .network, .model, .keys, .activation, .sync])

        let withoutSync = makeState(consensusURL: "")
        #expect(withoutSync.visibleSteps == [.welcome, .network, .model, .keys, .activation])
    }

    @MainActor
    @Test func keysAdvanceToActivationInsteadOfCompleting() {
        let state = makeState(consensusURL: "")
        state.step = .keys
        state.keyState = .ready(
            kernelAddress: "0x1111111111111111111111111111111111111111",
            bundlerAddress: "0x7A3f000000000000000000000000000000009C21"
        )

        state.advance()

        #expect(state.step == .activation)
    }

    @MainActor
    @Test func completionFailsClosedUntilActivationIsReady() {
        let state = makeState(consensusURL: "")
        state.keyState = .ready(
            kernelAddress: "0x1111111111111111111111111111111111111111",
            bundlerAddress: "0x7A3f000000000000000000000000000000009C21"
        )
        #expect(state.complete() == false)

        state.bundlerActivationState = .ready(
            balanceWeiHex: BundlerFundingPolicy.minimumBalanceWeiHex
        )
        #expect(state.complete())
    }

    @MainActor
    @Test func invalidBundlerAddressReturnsToKeyCreation() {
        let state = makeState(consensusURL: "")
        state.step = .activation
        state.keyState = .ready(
            kernelAddress: "0x1111111111111111111111111111111111111111",
            bundlerAddress: "Unavailable"
        )

        state.startBundlerActivationIfNeeded()

        #expect(state.step == .keys)
        guard case .failed = state.keyState else {
            Issue.record("Invalid funding target was not rejected")
            return
        }
    }

    @MainActor
    @Test func staleMonitorResultCannotOverwriteANewerRun() async {
        let runs = ControllableActivationRuns()
        let state = makeState(consensusURL: "", activationService: runs.service())
        state.step = .activation
        state.keyState = .ready(
            kernelAddress: "0x1111111111111111111111111111111111111111",
            bundlerAddress: "0x7A3f000000000000000000000000000000009C21"
        )

        state.startBundlerActivationIfNeeded()
        for _ in 0..<50 where await runs.runCount < 1 {
            await Task.yield()
        }
        state.refreshBundlerActivationNow()
        for _ in 0..<50 where await runs.runCount < 2 {
            await Task.yield()
        }

        await runs.finish(run: 0, balance: BundlerFundingPolicy.minimumBalanceWeiHex)
        for _ in 0..<10 { await Task.yield() }
        #expect(
            state.bundlerActivationState != .ready(
                balanceWeiHex: BundlerFundingPolicy.minimumBalanceWeiHex
            )
        )

        await runs.finish(run: 1, balance: BundlerFundingPolicy.recommendedBalanceWeiHex)
        for _ in 0..<50 where state.bundlerActivationState != .ready(
            balanceWeiHex: BundlerFundingPolicy.recommendedBalanceWeiHex
        ) {
            await Task.yield()
        }
        #expect(
            state.bundlerActivationState == .ready(
                balanceWeiHex: BundlerFundingPolicy.recommendedBalanceWeiHex
            )
        )
    }

    @MainActor
    @Test func aReadyBalanceCanBeDemotedWhileTheActivationScreenRemainsVisible() async {
        let reads = ControllableActivationRuns()
        let state = makeState(consensusURL: "", activationService: reads.service())
        state.step = .activation
        state.keyState = .ready(
            kernelAddress: "0x1111111111111111111111111111111111111111",
            bundlerAddress: "0x7A3f000000000000000000000000000000009C21"
        )

        state.startBundlerActivationIfNeeded()
        for _ in 0..<50 where await reads.runCount < 1 { await Task.yield() }
        await reads.finish(run: 0, balance: BundlerFundingPolicy.minimumBalanceWeiHex)
        for _ in 0..<50 where await reads.runCount < 2 { await Task.yield() }
        #expect(
            state.bundlerActivationState == .ready(
                balanceWeiHex: BundlerFundingPolicy.minimumBalanceWeiHex
            )
        )

        await reads.finish(run: 1, balance: "0x0")
        for _ in 0..<50 where state.bundlerActivationState != .waiting(balanceWeiHex: "0x0") {
            await Task.yield()
        }
        #expect(state.bundlerActivationState == .waiting(balanceWeiHex: "0x0"))
        #expect(state.canContinueFromActivation == false)
        state.cancelBundlerActivation(reset: false)
    }
}

private actor SequencedBalanceReader {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func read(_: String, _: URL, _: UInt64) throws -> String {
        guard values.isEmpty == false else { throw CancellationError() }
        return values.removeFirst()
    }
}

private actor RecordingSleeper {
    private(set) var callCount = 0

    func sleep(_: TimeInterval) {
        callCount += 1
    }
}

private actor RepeatingBalanceReader {
    let value: String
    private(set) var callCount = 0

    init(value: String) {
        self.value = value
    }

    func read(_: String, _: URL, _: UInt64) -> String {
        callCount += 1
        return value
    }
}

@MainActor
private func makeState(
    consensusURL: String,
    activationService: OnboardingBundlerActivationService = OnboardingBundlerActivationService(
        readBalance: { _, _, _ in BundlerFundingPolicy.minimumBalanceWeiHex },
        sleep: { _ in }
    )
) -> OnboardingState {
    let suite = "OnboardingBundlerActivationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    var network = DemoNetworkSettings.defaults
    network.sepoliaConsensusRPCURL = consensusURL
    let networkStore = DemoSettingsStore(defaults: defaults)
    networkStore.setNetworkSettings(network)
    let state = OnboardingState(
        settingsStore: OnboardingSettingsStore(defaults: defaults),
        networkSettingsStore: networkStore,
        downloadManager: ActivationTestModelManager(),
        bundlerActivationService: activationService,
        bundlerActivationTiming: .init(pollInterval: 0)
    )
    state.sepoliaConsensusRPCURL = consensusURL
    return state
}

private final class ActivationTestModelManager: LocalAIModelManaging, @unchecked Sendable {
    func existingFileURL(for _: LocalAIModel) -> URL? { nil }

    func verifyExistingFile(_: LocalAIModel, at fileURL: URL) async throws -> URL {
        fileURL
    }

    func download(
        _: LocalAIModel,
        progress _: @escaping LocalAIModelDownloadProgressHandler
    ) async throws -> URL {
        URL(fileURLWithPath: "/tmp/activation-test-model.gguf")
    }
}

private actor ControllableActivationRuns {
    private var continuations: [CheckedContinuation<String, Error>] = []

    var runCount: Int { continuations.count }

    nonisolated func service() -> OnboardingBundlerActivationService {
        OnboardingBundlerActivationService(
            readBalance: { [self] _, _, _ in try await nextBalance() },
            sleep: { _ in }
        )
    }

    private func nextBalance() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func finish(run: Int, balance: String) {
        continuations[run].resume(returning: balance)
    }
}

private func appSource(named fileName: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: packageRoot
            .appendingPathComponent("Sources/WalletMacOSApp")
            .appendingPathComponent(fileName),
        encoding: .utf8
    )
}

private func sourceSlice(
    _ source: String,
    from start: String,
    until end: String
) throws -> String {
    let startRange = try #require(source.range(of: start))
    let endRange = try #require(
        source.range(of: end, range: startRange.upperBound..<source.endIndex)
    )
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}
