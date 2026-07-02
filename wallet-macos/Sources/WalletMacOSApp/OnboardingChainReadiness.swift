import Foundation

struct OnboardingChainReadinessTiming: Equatable {
    let takingLongerDelay: TimeInterval
    let timeout: TimeInterval
    let pollInterval: TimeInterval

    static let `default` = OnboardingChainReadinessTiming(
        takingLongerDelay: 60,
        timeout: 30 * 60,
        pollInterval: 2
    )

    func isTakingLonger(elapsed: TimeInterval) -> Bool {
        elapsed >= takingLongerDelay
    }

    func hasTimedOut(elapsed: TimeInterval) -> Bool {
        elapsed >= timeout
    }
}

enum OnboardingChainReadinessError: LocalizedError {
    case timedOut(lastStatus: WalletNodeClient.NetworkStatus?)
    case probeFailed(step: String, message: String, lastStatus: WalletNodeClient.NetworkStatus?)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Helios did not finish syncing within 30 minutes."
        case let .probeFailed(step, message, _):
            return "Verified-read probe failed during \(step): \(message)"
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
        onEvent: (String) -> Void = { _ in },
        onStatus: (WalletNodeClient.NetworkStatus) -> Void
    ) async throws -> WalletNodeClient.NetworkStatus {
        let startedAt = Date()
        let networkSettings = networkSettingsStore.networkSettings
        let chain = networkSettings.activeChain
        let gasPolicy = networkSettings.resolvedDaemonGasPolicy
        onEvent("launch: preparing wallet-node for \(chain.name) chainId=\(chain.id)")
        let bundlerSecrets = try BundlerKeyStore.shared.unlockAllForOnboardingDaemonLaunch(chainId: chain.id)
        onEvent("launch: unlocked \(bundlerSecrets.count) bundler key(s) for chainId=\(chain.id)")
        if let primary = bundlerSecrets.first {
            syncUnlockedRelayerAddress(keyRef: primary.keyRef, secret: primary.secret)
        }

        let daemon = try await WalletNodeDaemon.launch(
            bundlerSecrets: bundlerSecrets,
            chain: chain,
            gasPolicy: gasPolicy,
            heliosVerificationEnabled: networkSettings.isHeliosVerificationActive
        )
        onEvent("launch: wallet-node started; polling network status")
        if let logURL = WalletNodeDaemon.managedLogFileURL() {
            onEvent("launch: wallet-node logs \(logURL.path)")
        }
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
            onEvent("status: \(status.onboardingDebugSummary)")
            if status.helios.ready {
                let readSurface = status.readVerification.verified ? "Helios ready" : "execution RPC reads ready"
                onEvent("probe: \(readSurface); inspecting kernel account \(kernelAddress.onboardingShortAddress)")
                do {
                    let inspection = try await daemon.client.inspectAccount(address: kernelAddress)
                    onEvent(
                        "probe: account ok deployed=\(inspection.isDeployed) balanceWei=\(inspection.balanceWeiHex) codeBytes=\(max(0, (inspection.codeHex.count - 2) / 2))"
                    )
                } catch {
                    onEvent("probe: account inspection failed - \(error.localizedDescription)")
                    throw OnboardingChainReadinessError.probeFailed(
                        step: "account inspection",
                        message: error.localizedDescription,
                        lastStatus: status
                    )
                }

                onEvent("probe: reading wallet-node gas tiers")
                do {
                    let gasPrice = try await daemon.client.userOperationGasPrice()
                    onEvent(
                        "probe: gas tiers ok slow=\(gasPrice.slow.maxFeePerGas.onboardingShortHex)/\(gasPrice.slow.maxPriorityFeePerGas.onboardingShortHex) standard=\(gasPrice.standard.maxFeePerGas.onboardingShortHex)/\(gasPrice.standard.maxPriorityFeePerGas.onboardingShortHex) fast=\(gasPrice.fast.maxFeePerGas.onboardingShortHex)/\(gasPrice.fast.maxPriorityFeePerGas.onboardingShortHex)"
                    )
                } catch {
                    onEvent("probe: gas tier read failed - \(error.localizedDescription)")
                    throw OnboardingChainReadinessError.probeFailed(
                        step: "gas tier read",
                        message: error.localizedDescription,
                        lastStatus: status
                    )
                }

                onEvent(
                    status.readVerification.verified
                        ? "ready: verified reads passed onboarding probes"
                        : "ready: execution RPC reads passed onboarding probes"
                )
                return status
            }

            let remaining = max(0.1, timing.timeout - Date().timeIntervalSince(startedAt))
            let delay = min(timing.pollInterval, remaining)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func syncUnlockedRelayerAddress(keyRef: String, secret: Data) {
        guard let chainId = BundlerLaunchKeyPolicy.chainId(ofKeyRef: keyRef) else {
            return
        }
        do {
            let address = try RelayerAddressCachePolicy.address(fromSecret: secret)
            onboardingSettingsStore.setBundlerKeyRef(keyRef, chainId: chainId)
            if RelayerAddressCachePolicy.shouldUpdate(
                cached: onboardingSettingsStore.bundlerAddress(chainId: chainId),
                unlocked: address
            ) {
                onboardingSettingsStore.setBundlerAddress(address, chainId: chainId)
            }
        } catch {
            onboardingSettingsStore.setBundlerKeyRef(keyRef, chainId: chainId)
        }
    }
}

extension WalletNodeClient.NetworkStatus {
    var onboardingDebugSummary: String {
        var fields = [
            "status=\(status)",
            "chainId=\(chainId)",
            "profile=\(networkProfile)",
            "readVerification=\(readVerification.mode)",
            "readsVerified=\(readVerification.verified)",
            "helios.ready=\(helios.ready)",
            "checkpointLoaded=\(helios.checkpointLoaded)",
        ]
        if let checkpointAgeDays = helios.checkpointAgeDays {
            fields.append(String(format: "checkpointAgeDays=%.3f", checkpointAgeDays))
        }
        if let head = helios.head {
            fields.append("head=#\(head.number):\(head.hash.shortHash)")
        } else {
            fields.append("head=nil")
        }
        if let bundler {
            fields.append("bundler.ready=\(bundler.ready)")
            if let needsTopup = bundler.needsTopup {
                fields.append("bundler.needsTopup=\(needsTopup)")
            }
            if let reason = bundler.reason {
                fields.append("bundler.reason=\(reason)")
            }
            if let eoa = bundler.eoa {
                fields.append("bundler.eoa=\(eoa.onboardingShortAddress)")
            }
        } else {
            fields.append("bundler=nil")
        }
        if let reason {
            fields.append("reason=\(reason)")
        }
        return fields.joined(separator: " ")
    }
}

private extension String {
    var onboardingShortAddress: String {
        guard count > 14 else {
            return self
        }
        return "\(prefix(8))...\(suffix(6))"
    }

    var shortHash: String {
        guard count > 18 else {
            return self
        }
        return "\(prefix(10))...\(suffix(6))"
    }
}

private extension Data {
    var onboardingShortHex: String {
        let hex = hexEncodedString
        guard hex.count > 16 else {
            return "0x\(hex)"
        }
        return "0x\(hex.prefix(8))...\(hex.suffix(8))"
    }
}
