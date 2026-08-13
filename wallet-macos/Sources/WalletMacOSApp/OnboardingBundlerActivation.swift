import Foundation

enum OnboardingBundlerActivationState: Equatable {
    case idle
    case checking
    case waiting(balanceWeiHex: String?)
    case ready(balanceWeiHex: String)
    case failed(String)
}

struct OnboardingBundlerActivationTiming: Equatable {
    let pollInterval: TimeInterval

    static let `default` = Self(pollInterval: 2)
}

struct OnboardingBundlerActivationService: @unchecked Sendable {
    typealias BalanceReader = @Sendable (String, URL, UInt64) async throws -> String
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let readBalance: BalanceReader
    private let sleep: Sleeper

    init(
        oracle: ExecutionFeeOracle = ExecutionFeeOracle(),
        sleep: @escaping Sleeper = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.readBalance = { address, rpcURL, chainID in
            try await oracle.balanceWeiHex(
                address: address,
                rpcURL: rpcURL,
                expectedChainID: chainID
            )
        }
        self.sleep = sleep
    }

    init(readBalance: @escaping BalanceReader, sleep: @escaping Sleeper) {
        self.readBalance = readBalance
        self.sleep = sleep
    }

    func waitUntilReady(
        address: String,
        rpcURL: URL,
        expectedChainID: UInt64,
        timing: OnboardingBundlerActivationTiming = .default,
        onBalance: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        while true {
            try Task.checkCancellation()
            let balance = try await readBalance(address, rpcURL, expectedChainID)
            try Task.checkCancellation()
            await onBalance(balance)
            try Task.checkCancellation()

            switch BundlerFundingPolicy.fromObservedBalance(balance) {
            case .kernelTopUpCandidate, .healthy:
                return balance
            case .externalRequired:
                try await sleep(timing.pollInterval)
            case .checking, .unavailable:
                throw ExecutionFeeOracleError.invalidQuantity(
                    field: "balance",
                    value: balance
                )
            }
        }
    }

    /// Uses the same injected clock as the below-floor polling loop so the
    /// coordinator can keep validating an already-ready balance while the
    /// activation screen remains visible.
    func waitBeforeNextObservation(
        timing: OnboardingBundlerActivationTiming = .default
    ) async throws {
        try await sleep(timing.pollInterval)
    }
}
