import Foundation

struct OnboardingChainReadinessTiming: Equatable {
    let takingLongerDelay: TimeInterval
    let timeout: TimeInterval
    let pollInterval: TimeInterval

    static let `default` = OnboardingChainReadinessTiming(
        takingLongerDelay: 60,
        timeout: 120,
        pollInterval: 2
    )

    func isTakingLonger(elapsed: TimeInterval) -> Bool {
        elapsed >= takingLongerDelay
    }

    func hasTimedOut(elapsed: TimeInterval) -> Bool {
        elapsed >= timeout
    }
}

extension WalletNodeClient.NetworkStatus {
    static func onboardingPreviewReady(chain: ChainConfiguration) -> WalletNodeClient.NetworkStatus {
        WalletNodeClient.NetworkStatus(
            status: "preview_ready",
            reason: nil,
            chainId: chain.id,
            networkProfile: chain.shortName,
            helios: WalletNodeClient.NetworkStatus.Helios(
                ready: true,
                checkpointLoaded: true,
                checkpointAgeDays: nil,
                head: nil
            ),
            bundler: nil
        )
    }
}

enum OnboardingChainReadinessError: LocalizedError {
    case timedOut(lastStatus: WalletNodeClient.NetworkStatus?)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Helios did not finish syncing within two minutes."
        }
    }
}

@MainActor
struct OnboardingChainReadinessService {
    private let onboardingSettingsStore: OnboardingSettingsStore
    private let networkSettingsStore: DemoSettingsStore

    init(
        onboardingSettingsStore: OnboardingSettingsStore = OnboardingSettingsStore(),
        networkSettingsStore: DemoSettingsStore = DemoSettingsStore()
    ) {
        self.onboardingSettingsStore = onboardingSettingsStore
        self.networkSettingsStore = networkSettingsStore
    }

    func waitForHeliosReady(
        kernelAddress: String,
        timing: OnboardingChainReadinessTiming = .default,
        onStatus: (WalletNodeClient.NetworkStatus) -> Void
    ) async throws -> WalletNodeClient.NetworkStatus {
        let startedAt = Date()
        let chain = networkSettingsStore.networkSettings.activeChain
        let gasPolicy = networkSettingsStore.networkSettings.resolvedDaemonGasPolicy
        let keyRef = "bundler-eoa:default:\(chain.id):1"
        let bundlerSecret = try BundlerKeyStore.shared.unlockForOnboardingDaemonLaunch(keyRef: keyRef)
        syncUnlockedRelayerAddress(keyRef: keyRef, secret: bundlerSecret.secret)

        let daemon = try await WalletNodeDaemon.launch(
            bundlerSecret: bundlerSecret,
            chain: chain,
            gasPolicy: gasPolicy
        )
        var lastStatus: WalletNodeClient.NetworkStatus?

        while true {
            try Task.checkCancellation()
            let elapsed = Date().timeIntervalSince(startedAt)
            guard !timing.hasTimedOut(elapsed: elapsed) else {
                throw OnboardingChainReadinessError.timedOut(lastStatus: lastStatus)
            }

            let status = try await daemon.client.networkStatus()
            lastStatus = status
            onStatus(status)
            if status.helios.ready {
                _ = try? await daemon.client.inspectAccount(address: kernelAddress)
                _ = try? await daemon.client.userOperationGasPrice()
                return status
            }

            let remaining = max(0.1, timing.timeout - Date().timeIntervalSince(startedAt))
            let delay = min(timing.pollInterval, remaining)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func syncUnlockedRelayerAddress(keyRef: String, secret: Data) {
        do {
            let address = try RelayerAddressCachePolicy.address(fromSecret: secret)
            onboardingSettingsStore.bundlerKeyRef = keyRef
            if RelayerAddressCachePolicy.shouldUpdate(
                cached: onboardingSettingsStore.bundlerAddress,
                unlocked: address
            ) {
                onboardingSettingsStore.bundlerAddress = address
            }
        } catch {
            onboardingSettingsStore.bundlerKeyRef = keyRef
        }
    }
}
