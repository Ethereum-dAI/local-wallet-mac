import Foundation
import Testing
@testable import WalletMacOSApp

@Suite struct OnDemandAuthenticationAuditTests {
    @Test func appActivationAndManagedDaemonLaunchNeverReadProtectedSecrets() throws {
        let source = try appSource("AppModel.swift")
        let resume = try slice(
            source,
            from: "func handleAppBecameActive",
            until: "func recordSessionUserActivity"
        )
        #expect(!resume.contains("BundlerKeyStore"))
        #expect(!resume.contains("ensureRelayerUnlocked"))
        #expect(!resume.contains("authorizeDeviceOwner"))

        let launch = try slice(
            source,
            from: "private func ensureWalletNodeClient",
            until: "private func ensureRelayerUnlocked"
        )
        #expect(launch.contains("bundlerSecrets: []"))
        #expect(!launch.contains("BundlerKeyStore"))
    }

    @Test func returningToTheAppPassivelyRefreshesRelayerStatus() throws {
        let source = try appSource("AppModel.swift")
        let resume = try slice(
            source,
            from: "func handleAppBecameActive",
            until: "func recordSessionUserActivity"
        )
        #expect(resume.contains("refreshLocalRelayerStatus()"))
        #expect(resume.contains("BundlerKeyStore") == false)
        #expect(resume.contains("ensureRelayerUnlocked") == false)
        #expect(resume.contains("authorize") == false)
    }

    @Test func privacyBalanceHasAnExplicitUnlockAndNoViewLifecycleLoad() throws {
        let source = try appSource("ChatDashboardView.swift")
        let row = try slice(
            source,
            from: "private var shieldedBalanceRow",
            until: "private func explorerAddressURL"
        )
        #expect(row.contains("Unlock to view"))
        #expect(row.contains("unlockShieldedBalance"))
        #expect(!row.contains(".task"))

        let refresh = try slice(
            source,
            from: "func refreshShieldedBalance()",
            until: "private nonisolated static func isAuthenticationCancellation"
        )
        #expect(refresh.contains("loadedRailgunHelperClient"))
        #expect(!refresh.contains("RailgunSecretsStore"))
        #expect(!refresh.contains("authorize()"))
    }

    @Test func obsoleteStartupUnlockSettingIsRemovedEndToEnd() throws {
        for file in [
            "AppModel.swift",
            "ChatDashboardView.swift",
            "DemoSettingsStore.swift",
            "LocalWalletSettingsView.swift",
        ] {
            #expect(!(try appSource(file)).contains("unlockRelayerOnLaunch"))
        }
    }

    @Test func walletResetRequiresDeviceOwnerAuthorizationBeforeCleanup() throws {
        let source = try appSource("AppModel.swift")
        let reset = try slice(
            source,
            from: "func resetDemoWalletAuthorized",
            until: "func runDemo"
        )
        let authorization = try #require(reset.range(of: "try await authentication.authorize()"))
        let cleanup = try #require(reset.range(of: "WalletResetCleanup.standard"))
        #expect(authorization.lowerBound < cleanup.lowerBound)
    }

    @Test func passiveStatusCannotPromoteRelayerSecretAvailability() throws {
        let source = try appSource("AppModel.swift")
        let publish = try slice(
            source,
            from: "private func publishLocalRelayerStatus",
            until: "func rotateLocalRelayerKey"
        )
        #expect(!publish.contains(".available(generation:"))

        let install = try slice(
            source,
            from: "private func ensureRelayerUnlocked",
            until: "private func relevantRelayerKeyRefs"
        )
        #expect(!install.contains("if observedStatus.keyLoaded"))
        #expect(install.contains("relayerAccessState = .available(generation: generation)"))
        #expect(install.contains("walletNodeGeneration == generation"))
    }

    @Test func onboardingRegistersRelayerBeforePublishingFundingAddress() throws {
        let source = try appSource("OnboardingView.swift")
        let provisioning = try slice(
            source,
            from: "func provisionKeys()",
            until: "func startBundlerActivationIfNeeded"
        )
        let registration = try #require(
            provisioning.range(of: "try await relayerRegistrationService.register(")
        )
        let ready = try #require(provisioning.range(of: "keyState = .ready("))
        #expect(registration.lowerBound < ready.lowerBound)

        let complete = try slice(
            source,
            from: "func complete() -> Bool",
            until: "private func cancelChainReadiness"
        )
        #expect(complete.contains("guard case .ready = keyState"))
    }

    @Test func replacementActionsAuthorizeEvenWithAWarmRelayer() throws {
        let source = try appSource("AppModel.swift")
        let cancel = try slice(
            source,
            from: "func cancelPendingOperation",
            until: "private func markCancellationSubmittedInHistory"
        )
        let speedUp = try slice(
            source,
            from: "func speedUpPendingOperation",
            until: "private func markReplacementUnavailableInHistory"
        )
        #expect(cancel.contains("try await authentication.authorize()"))
        #expect(speedUp.contains("try await authentication.authorize()"))
    }

    @Test func destructiveResetQuiescesBothManagedDaemonsBeforeDeletingKeys() throws {
        let appModel = try appSource("AppModel.swift")
        let reset = try slice(
            appModel,
            from: "func resetDemoWalletAuthorized",
            until: "private var hasNoSecretResetConflict"
        )
        let quiescence = try #require(reset.range(of: "quiesceManagedWalletNodeForSecretReset"))
        let storeCleanup = try #require(reset.range(of: "WalletNodeManagedStoreCleanup.clear"))
        let keyCleanup = try #require(reset.range(of: "WalletResetCleanup.standard"))
        #expect(quiescence.lowerBound < storeCleanup.lowerBound)
        #expect(storeCleanup.lowerBound < keyCleanup.lowerBound)

        let dashboard = try appSource("ChatDashboardView.swift")
        #expect(dashboard.contains("registerSecretResetQuiescenceHandler"))
        #expect(dashboard.contains("try await daemon?.terminateAndWait()"))
    }

    @Test func appMenuAndDashboardShareOneAppModelInstance() throws {
        let source = try appSource("WalletMacOSApp.swift")
        let dashboard = try slice(source, from: "private func showDashboard", until: "private func showLegacyDashboard")
        #expect(dashboard.contains("let model = AppModel()"))
        #expect(dashboard.contains("self.model = model"))
        #expect(dashboard.contains("model.bootstrap()"))
        #expect(dashboard.contains("WalletLaunchGateView(walletModel: model"))
    }

    @Test func recoveryViewRequiresExplicitResetAndDoesNotConstructAReplacementKey() throws {
        let source = try appSource("WalletRecoveryView.swift")
        #expect(source.contains("Wallet key unavailable"))
        #expect(source.contains("Reset local wallet"))
        #expect(source.contains("resetWalletForRecoveryAuthorized"))
        #expect(!source.contains("createOrLoadPublicKeyCoordinates"))
    }

    @Test func sessionLockRelocksSecretsButOrdinaryFocusLossDoesNot() throws {
        let dashboard = try appSource("ChatDashboardView.swift")
        #expect(dashboard.contains("NSWorkspace.sessionDidResignActiveNotification"))
        #expect(dashboard.contains("NSWorkspace.screensDidSleepNotification"))
        #expect(!dashboard.contains("NSApplication.didResignActiveNotification"))

        let appModel = try appSource("AppModel.swift")
        let activation = try slice(appModel, from: "func handleAppBecameActive", until: "func recordSessionUserActivity")
        #expect(!activation.contains("lockSecretRuntimesForSystemSession"))
        #expect(!activation.contains("BundlerKeyStore"))
    }

    @Test func commandLineResetAlsoAuthenticatesBeforeCleanup() throws {
        let source = try appSource("WalletMacOSApp.swift")
        let cliReset = try slice(
            source,
            from: "private static func resetDemoWalletAndExit",
            until: "@MainActor\nprivate final class AppDelegate"
        )
        let processPreflight = try #require(cliReset.range(of: "WalletResetPreflight.ensureNoOtherLocalWalletInstance"))
        let preflight = try #require(cliReset.range(of: "WalletResetPreflight.ensureNoExternalSecretRuntimes"))
        let authorization = try #require(cliReset.range(of: "try await authentication.authorize()"))
        let cleanup = try #require(cliReset.range(of: "WalletResetCleanup.standard"))
        #expect(processPreflight.lowerBound < authorization.lowerBound)
        #expect(preflight.lowerBound < authorization.lowerBound)
        #expect(authorization.lowerBound < cleanup.lowerBound)
    }

    @Test func bundlerTopUpChecksExactRelayCostBeforeAuthentication() throws {
        let source = try appSource("AppModel.swift")
        let relayGate = try slice(
            source,
            from: "private func verifiedBundlerRelayDecision",
            until: "func executeERC20Transfer("
        )
        #expect(relayGate.contains("BundlerRelayPrecheck.evaluate"))
        #expect(relayGate.contains("expectedEOA: expectedIdentity.address"))

        let send = try slice(
            source,
            from: "private func sendUserOperation",
            until: "private func activeSessionPlan"
        )
        let precheck = try #require(send.range(of: "phase: \"pre-auth\""))
        let authentication = try #require(
            send.range(of: "DeviceOwnerAuthenticationSession.ownerUserOperation")
        )
        let unlock = try #require(send.range(of: "ensureRelayerUnlocked"))
        #expect(precheck.lowerBound < authentication.lowerBound)
        #expect(precheck.lowerBound < unlock.lowerBound)
    }

    @Test func bundlerTopUpCannotInstallOrUseASessionKey() throws {
        let source = try appSource("AppModel.swift")
        #expect(source.contains("purpose.allowsSessionSigning"))
        #expect(source.contains("case bundlerTopUp(expectedIdentity: VerifiedRelayerIdentity)"))
    }

    @Test func reviewedBundlerAddressIsRevalidatedBeforeOwnerOnlyTopUp() throws {
        let source = try appSource("AppModel.swift")
        let wrapper = try slice(
            source,
            from: "func executeCurrentBundlerTopUp(",
            until: "func executeERC20Transfer("
        )
        #expect(wrapper.contains("fetchLocalRelayerStatusWithBalanceRetry()"))
        #expect(wrapper.contains("BundlerKeyStore.shared.verifiedIdentity("))
        #expect(wrapper.contains("RelayerIdentityBindingPolicy.verify("))
        #expect(wrapper.contains("executeBundlerTopUp("))
        #expect(wrapper.contains("identity: expectedIdentity"))
        #expect(wrapper.contains("recipient: expectedIdentity.address"))
        #expect(!wrapper.contains("executeNativeTransfer("))

        let send = try slice(
            source,
            from: "private func sendUserOperation",
            until: "private func activeSessionPlan"
        )
        let preAuthenticationCheck = try #require(send.range(of: "phase: \"pre-auth\""))
        let authentication = try #require(
            send.range(of: "DeviceOwnerAuthenticationSession.ownerUserOperation")
        )
        let unlock = try #require(send.range(of: "ensureRelayerUnlocked"))
        let protectedSecretRead = try #require(
            send.range(of: "let record = try BundlerKeyStore.shared.read")
        )
        let identityMatch = try #require(
            send.range(of: "authenticatedIdentity == expectedIdentity")
        )
        let postAuthenticationCheck = try #require(send.range(of: "phase: \"post-auth\""))
        let signing = try #require(send.range(of: "UserOperationSigning.signForSend"))

        #expect(preAuthenticationCheck.lowerBound < authentication.lowerBound)
        #expect(authentication.lowerBound < unlock.lowerBound)
        #expect(unlock.lowerBound < protectedSecretRead.lowerBound)
        #expect(protectedSecretRead.lowerBound < identityMatch.lowerBound)
        #expect(identityMatch.lowerBound < postAuthenticationCheck.lowerBound)
        #expect(postAuthenticationCheck.lowerBound < signing.lowerBound)
    }

    private func appSource(_ fileName: String) throws -> String {
        try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/WalletMacOSApp")
                .appendingPathComponent(fileName),
            encoding: .utf8
        )
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func slice(_ source: String, from start: String, until end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
