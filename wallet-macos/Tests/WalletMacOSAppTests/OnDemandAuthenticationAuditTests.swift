import Foundation
import Testing
@testable import WalletMacOSApp

@Suite struct OnDemandAuthenticationAuditTests {
    @Test func promptFreeRelayerIdentityLookupUsesOnlyThePublicService() throws {
        let source = try appSource("BundlerKeyStore.swift")
        let lookup = try slice(
            source,
            from: "func identity(forKeyRef",
            until: "func insertOrRequireIdentity("
        )
        let publicStore = try slice(
            source,
            from: "struct RelayerPublicIdentityStore",
            until: "struct BundlerSecretRecord"
        )

        #expect(lookup.contains("kSecReturnData"))
        #expect(lookup.contains("kSecUseAuthenticationContext"))
        #expect(lookup.contains("interactionNotAllowed = true"))
        #expect(!lookup.contains("com.localwallet.bundler-eoa.app"))
        #expect(!lookup.contains("kSecValueData"))
        #expect(publicStore.contains("com.localwallet.bundler-eoa.public-identity"))
        #expect(publicStore.contains("kSecUseDataProtectionKeychain"))
        #expect(publicStore.contains("kSecAttrAccessibleWhenUnlockedThisDeviceOnly"))
        #expect(publicStore.contains("kSecAttrAccessControl") == false)
    }

    @Test func protectedRelayerReadUsesOneCallerOwnedDataAndAttributeQuery() throws {
        let source = try appSource("BundlerKeyStore.swift")
        let lookup = try slice(
            source,
            from: "private func read(\n        keyRef:",
            until: "private func withAuthenticationContext"
        )

        #expect(lookup.contains("kSecReturnData"))
        #expect(lookup.contains("kSecReturnAttributes"))
        #expect(lookup.contains("kSecUseAuthenticationContext"))
        #expect(lookup.contains("client.copyMatching(query)"))
        #expect(lookup.contains("SecItemCopyMatching") == false)
        #expect(lookup.contains("verifiedIdentity(forKeyRef") == false)
        #expect(lookup.contains("LAContext()") == false)
    }

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

    @Test func passiveRelayerPublicationUsesOnlyAppOwnedPublicAuthority() throws {
        let appModel = try appSource("AppModel.swift")
        let publish = try slice(
            appModel,
            from: "private func publishLocalRelayerStatus",
            until: "private func relayerSecretAuthorizationPlan"
        )
        #expect(publish.contains("relayerChainStateJournalStore.snapshot"))
        #expect(publish.contains("relayerPublicIdentityStore.identity"))
        #expect(publish.contains("PassiveRelayerIdentityResolver.resolve"))
        #expect(publish.contains("BundlerKeyStore") == false)
        #expect(publish.contains("LAContext") == false)
        #expect(publish.contains("authorize") == false)

        let dashboard = try appSource("ChatDashboardView.swift")
        let refresh = try slice(
            dashboard,
            from: "private func refreshAccountIdentity()",
            until: "private func bindPendingBundlerTopUpsIfNeeded"
        )
        #expect(refresh.contains("walletModel.verifiedLocalRelayerIdentity"))
        #expect(refresh.contains("BundlerKeyStore") == false)
        #expect(refresh.contains("try?") == false)
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
            until: "private func relayerSecretAuthorizationPlan"
        )
        #expect(!publish.contains(".available(generation:"))

        let install = try slice(
            source,
            from: "private func ensureRelayerUnlocked",
            until: "private func syncUnlockedRelayerAddress"
        )
        #expect(!install.contains("if observedStatus.keyLoaded"))
        #expect(install.contains("relayerAccessState = .available(generation: generation)"))
        #expect(install.contains("requireCurrentRelayerConnection"))
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
        let persistedIdentity = try #require(
            provisioning.range(of: "finalizeRegisteredBundlerIdentity(")
        )
        let ready = try #require(provisioning.range(of: "keyState = .ready("))
        #expect(registration.lowerBound < ready.lowerBound)
        #expect(registration.lowerBound < persistedIdentity.lowerBound)
        #expect(persistedIdentity.lowerBound < ready.lowerBound)

        let complete = try slice(
            source,
            from: "func complete() -> Bool",
            until: "private func cancelChainReadiness"
        )
        #expect(complete.contains("guard case .ready = keyState"))
    }

    @Test func onboardingProvisioningUsesAnImmutableAtomicKeychainWinner() throws {
        let keyStoreSource = try appSource("BundlerKeyStore.swift")
        let insertion = try slice(
            keyStoreSource,
            from: "func addIfAbsent(",
            until: "static func insertionResult("
        )
        #expect(insertion.contains("client.add(query)"))
        #expect(insertion.contains("delete(keyRef:") == false)

        let insertionStatus = try slice(
            keyStoreSource,
            from: "static func insertionResult(",
            until: "func read("
        )
        #expect(insertionStatus.contains("case errSecDuplicateItem:"))
        #expect(insertionStatus.contains("return .existing"))

        let provisioningSource = try appSource("OnboardingProvisioningService.swift")
        let selection = try slice(
            provisioningSource,
            from: "let generatedSecret = try generateBundlerSecret()",
            until: "\n    }\n\n    private func requireExactHead"
        )
        let existing = try slice(selection, from: "case .existing:", until: "case .inserted:")
        let inserted = String(selection[(try #require(selection.range(of: "case .inserted:"))).lowerBound...])
        #expect(selection.contains("addIfAbsent("))
        #expect(selection.contains("verifiedIdentity(forKeyRef:") == false)
        #expect(existing.contains("bundlerKeyStore.read("))
        #expect(inserted.contains("bundlerKeyStore.read(") == false)
    }

    @Test func onboardingProvisioningTaskIsCancelledOnBackAndDeinit() throws {
        let source = try appSource("OnboardingView.swift")
        let back = try slice(source, from: "func back()", until: "func advance()")
        #expect(back.contains("if step == .keys"))
        #expect(back.contains("cancelProvisioning(reset: true)"))

        let deinitializer = try slice(source, from: "deinit {", until: "var selectedModel:")
        #expect(deinitializer.contains("provisioningTask?.cancel()"))
        #expect(deinitializer.contains("provisioningAuthenticationContext?.invalidate()"))

        let provisioning = try slice(
            source,
            from: "func provisionKeys()",
            until: "func startBundlerActivationIfNeeded"
        )
        #expect(provisioning.contains("provisioningTask = Task { @MainActor [weak self] in"))
        #expect(provisioning.contains("try Task.checkCancellation()"))
        #expect(provisioning.contains("provisioningRunID == runID"))
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
        #expect(reset.contains("authenticationContext: authentication.context"))

        let dashboard = try appSource("ChatDashboardView.swift")
        #expect(dashboard.contains("registerSecretResetQuiescenceHandler"))
        #expect(dashboard.contains("try await daemon?.terminateAndWait()"))
    }

    @Test func dashboardResetRegistersReplacementRelayerBeforePublishingIt() throws {
        let source = try appSource("AppModel.swift")
        let reset = try slice(
            source,
            from: "func resetDemoWalletAuthorized",
            until: "private var hasNoSecretResetConflict"
        )
        let storeCleanup = try #require(
            reset.range(of: "WalletNodeManagedStoreCleanup.clear")
        )
        let replacement = try #require(
            reset.range(of: "bundlerKeyStore.createIfNeeded(")
        )
        let registration = try #require(
            reset.range(of: "try await relayerBootstrapRegistrationService.register(")
        )
        let authorityPersistence = try #require(
            reset.range(of: "finalizeRegisteredBundlerIdentity(registeredIdentity)")
        )
        let cacheSync = try #require(
            reset.range(of: "syncUnlockedRelayerAddress(")
        )
        let stateClear = try #require(
            reset.range(of: "clearInMemoryWalletStateAfterReset()")
        )

        #expect(storeCleanup.lowerBound < replacement.lowerBound)
        #expect(replacement.lowerBound < registration.lowerBound)
        #expect(registration.lowerBound < authorityPersistence.lowerBound)
        #expect(authorityPersistence.lowerBound < cacheSync.lowerBound)
        #expect(cacheSync.lowerBound < stateClear.lowerBound)
        #expect(reset.contains("BundlerKeyStore.shared") == false)
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
        #expect(cliReset.contains("authenticationContext: authentication.context"))
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
        #expect(wrapper.contains("relayerSecretAuthorizationPlan(for:"))
        #expect(wrapper.contains("plan.active.identity == expectedIdentity"))
        #expect(wrapper.contains("verifiedIdentity(forKeyRef:") == false)
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
            send.range(of: "readAuthorizedRelayerSecret(")
        )
        let identityMatch = try #require(
            send.range(of: "authenticatedPlan.active.identity == expectedIdentity")
        )
        let postAuthenticationCheck = try #require(send.range(of: "phase: \"post-auth\""))
        let signing = try #require(send.range(of: "UserOperationSigning.signForSend"))
        let daemonBoundExpectedIdentity = try #require(
            send.range(of: "expectedRelayer: expectedSubmissionRelayer")
        )

        #expect(preAuthenticationCheck.lowerBound < authentication.lowerBound)
        #expect(authentication.lowerBound < unlock.lowerBound)
        #expect(unlock.lowerBound < identityMatch.lowerBound)
        #expect(identityMatch.lowerBound < protectedSecretRead.lowerBound)
        #expect(protectedSecretRead.lowerBound < postAuthenticationCheck.lowerBound)
        #expect(postAuthenticationCheck.lowerBound < signing.lowerBound)
        #expect(signing.lowerBound < daemonBoundExpectedIdentity.lowerBound)
    }

    @Test func appModelHasOneJournalAuthorizedProtectedRelayerReadBoundary() throws {
        let source = try appSource("AppModel.swift")
        #expect(occurrences(of: "bundlerKeyStore.read(", in: source) == 1)
        #expect(source.contains("BundlerKeyStore.shared.read(") == false)
        #expect(source.contains("verifiedIdentity(forKeyRef:") == false)

        let protectedRead = try slice(
            source,
            from: "private func readBoundRelayerSecret(",
            until: "private func readAuthorizedRelayerSecret("
        )
        let authorityWrapper = try slice(
            source,
            from: "private func readAuthorizedRelayerSecret(",
            until: "private func requireCurrentRelayerConnection"
        )
        let beforeAuthority = try #require(protectedRead.range(of: "try await validateAuthority()"))
        let keychainRead = try #require(
            protectedRead.range(of: "let record = try bundlerKeyStore.read(")
        )
        let secretBinding = try #require(
            protectedRead.range(of: "VerifiedRelayerIdentity.derive(")
        )
        let afterAuthority = try #require(
            protectedRead.range(
                of: "try await validateAuthority()",
                range: secretBinding.upperBound..<protectedRead.endIndex
            )
        )

        #expect(beforeAuthority.lowerBound < keychainRead.lowerBound)
        #expect(keychainRead.lowerBound < secretBinding.lowerBound)
        #expect(secretBinding.lowerBound < afterAuthority.lowerBound)
        #expect(protectedRead.contains("authenticationContext: authenticationSession.context"))
        #expect(protectedRead.contains("requireCurrentRelayerConnection"))
        #expect(authorityWrapper.contains("relayerSecretAuthorizationPlan(for: status)"))
        #expect(authorityWrapper.contains("plan == expectedPlan"))
    }

    @Test func liveRotationUsesTheAppOwnedRetrySafeCoordinator() throws {
        let source = try appSource("AppModel.swift")
        let rotation = try slice(
            source,
            from: "func rotateLocalRelayerKey() async throws",
            until: "func exportLocalRelayerKey("
        )
        let snapshot = try #require(rotation.range(of: "requiredRelayerSnapshot()"))
        let plan = try #require(
            rotation.range(of: "RelayerRotationCoordinator.plan(from:")
        )
        let authorize = try #require(
            rotation.range(of: "try await authentication.authorize()")
        )
        let prepare = try #require(
            rotation.range(of: "RelayerRotationCoordinator.prepareAndInstall(")
        )
        let create = try #require(
            rotation.range(of: "bundlerKeyStore.createIfNeeded(")
        )
        let install = try #require(
            rotation.range(of: "client.installBundlerEOA(")
        )

        #expect(snapshot.lowerBound < plan.lowerBound)
        #expect(plan.lowerBound < authorize.lowerBound)
        #expect(authorize.lowerBound < prepare.lowerBound)
        #expect(prepare.lowerBound < create.lowerBound)
        #expect(create.lowerBound < install.lowerBound)
        #expect(rotation.contains("appendJournal:"))
        #expect(rotation.contains("readBoundRelayerSecret("))
        #expect(rotation.contains("expectedPendingHead"))
        #expect(rotation.contains("requirePendingRotationBinding("))
        #expect(rotation.contains("BundlerKeyStore.shared") == false)
        #expect(rotation.contains("UserDefaults") == false)
    }

    @Test func journalPromotionRequiresExactDaemonLifecycleObservations() throws {
        let source = try appSource("AppModel.swift")
        let promotion = try slice(
            source,
            from: "private func promotePendingRelayerIfReady(",
            until: "private func readBoundRelayerSecret("
        )
        #expect(promotion.contains("RelayerPromotionObservationPolicy.validate("))
        #expect(promotion.contains("RelayerRotationCoordinator.promoteIfReady("))
        #expect(promotion.contains("observations.daemonActive"))
        #expect(promotion.contains("observations.priorActive"))
        #expect(promotion.contains("relayerPublicIdentityStore.identity"))
        #expect(promotion.contains("relayerChainStateJournalStore.append"))
        #expect(promotion.contains("BundlerKeyStore") == false)
    }

    @Test func targetedDeletionQuiescesThenDeletesDaemonSecretAndPublicInOrder() throws {
        let source = try appSource("AppModel.swift")
        let deletion = try slice(
            source,
            from: "func deleteLocalRelayerKey(",
            until: "func cancelPendingOperation("
        )
        let firstAuthority = try #require(
            deletion.range(of: "targetedRelayerDeletionAuthorization(")
        )
        let authorize = try #require(
            deletion.range(of: "try await authentication.authorize()")
        )
        let secondAuthority = try #require(
            deletion.range(
                of: "targetedRelayerDeletionAuthorization(",
                range: authorize.upperBound..<deletion.endIndex
            )
        )
        let quiesce = try #require(
            deletion.range(of: "quiesceRelayerInstallForTargetedDeletion(")
        )
        let daemonDelete = try #require(
            deletion.range(of: "client.deleteBundlerEOA(")
        )
        let daemonStop = try #require(
            deletion.range(of: "terminateManagedWalletNodeAfterTargetedDeletion(")
        )
        let publicDelete = try #require(
            deletion.range(of: "relayerPublicIdentityStore.delete(")
        )
        let secretDelete = try #require(
            deletion.range(of: "bundlerKeyStore.delete(")
        )

        #expect(firstAuthority.lowerBound < authorize.lowerBound)
        #expect(authorize.lowerBound < secondAuthority.lowerBound)
        #expect(secondAuthority.lowerBound < quiesce.lowerBound)
        #expect(quiesce.lowerBound < daemonDelete.lowerBound)
        #expect(daemonDelete.lowerBound < daemonStop.lowerBound)
        #expect(daemonStop.lowerBound < secretDelete.lowerBound)
        #expect(secretDelete.lowerBound < publicDelete.lowerBound)
        #expect(deletion.contains("RelayerTargetedDeletionPolicy.authorizeIndividualDeletion"))
        #expect(deletion.contains("unsafeReset: false"))
        #expect(deletion.contains("relayerInstallTask == nil"))
        #expect(deletion.contains("guard relayerInstallTask == nil"))
        #expect(deletion.contains("relayerInstallTask?.cancel()") == false)
        #expect(deletion.contains("try await relayerInstallTask.value") == false)
        #expect(deletion.contains("walletNodeGeneration &+= 1"))
        #expect(deletion.contains("status.ownerScope == \"default\""))
        #expect(deletion.contains("status.networkProfile == activeChain.shortName"))
        #expect(deletion.contains("BundlerKeyStore.shared") == false)
        #expect(deletion.contains("targetKeyRef ??") == false)
        #expect(deletion.contains("Unsafe Reset Local Relayer") == false)
        #expect(deletion.contains("func canDeleteLocalRelayerKey(keyRef: String) -> Bool"))
        #expect(deletion.contains("targetedRelayerDeletionAuthorization("))
    }

    @Test func targetedDeletionUIOnlyOffersExplicitRetiredKeyCleanup() throws {
        let appKitSource = try appSource("WalletMacOSApp.swift")
        let adminDeletion = try slice(
            appKitSource,
            from: "private func deleteLocalRelayer()",
            until: "private func clearDebugLog()"
        )
        #expect(adminDeletion.contains("Delete Retired Key"))
        #expect(adminDeletion.contains("Finish Cleanup"))
        #expect(adminDeletion.contains("keyRef: target.keyRef"))
        #expect(adminDeletion.contains("Unsafe Reset") == false)
        #expect(adminDeletion.contains("Safe Delete") == false)

        let settingsSource = try appSource("LocalWalletSettingsView.swift")
        #expect(settingsSource.contains("onDeleteRelayerKey") == false)
        #expect(settingsSource.contains("Safe delete relayer") == false)
        #expect(settingsSource.contains("Unsafe reset relayer") == false)
        #expect(settingsSource.contains("pendingConfirmation = .resetWallet"))
    }

    @Test func relayerMutationsAreSerializedAgainstSigningAndInstallation() throws {
        let source = try appSource("AppModel.swift")
        let rotation = try slice(
            source,
            from: "func rotateLocalRelayerKey() async throws",
            until: "func exportLocalRelayerKey("
        )
        let send = try slice(
            source,
            from: "private func executeUserOperation(",
            until: "private func sendUserOperation("
        )
        let unlock = try slice(
            source,
            from: "private func ensureRelayerUnlocked(",
            until: "private func syncUnlockedRelayerAddress"
        )
        let replacement = try slice(
            source,
            from: "func cancelPendingOperation(",
            until: "private func markReplacementUnavailableInHistory("
        )
        let previewBuild = try slice(
            source,
            from: "func buildUserOperationDraftPreview()",
            until: "func sendCurrentUserOperation()"
        )

        #expect(rotation.contains("hasNoSecretResetConflict"))
        #expect(rotation.contains("relayerInstallTask == nil"))
        #expect(send.contains("!isRotatingLocalRelayer"))
        #expect(send.contains("!isDeletingLocalRelayer"))
        #expect(unlock.contains("guard !isDeletingLocalRelayer"))
        #expect(replacement.contains("guard hasNoSecretResetConflict"))
        #expect(previewBuild.contains("!isRotatingLocalRelayer"))
        #expect(previewBuild.contains("!isDeletingLocalRelayer"))
    }

    @Test func firstUnlockStatusPublishesAnExactPromotionBeforeResolvingSecretAuthority() throws {
        let source = try appSource("AppModel.swift")
        let unlock = try slice(
            source,
            from: "private func ensureRelayerUnlocked(",
            until: "private func syncUnlockedRelayerAddress"
        )
        let status = try #require(
            unlock.range(of: "let observedStatus = try await client.bundlerStatus()")
        )
        let publish = try #require(
            unlock.range(of: "publishLocalRelayerStatus(")
        )
        let plan = try #require(
            unlock.range(of: "relayerSecretAuthorizationPlan(for: observedStatus)")
        )

        #expect(status.lowerBound < publish.lowerBound)
        #expect(publish.lowerBound < plan.lowerBound)
        #expect(unlock.contains("passiveRelayerIdentityIssue == nil"))
    }

    @Test func everyLocalSubmissionCarriesTheFreshJournalActiveRelayerToTheDaemon() throws {
        let source = try appSource("AppModel.swift")
        let selection = try slice(
            source,
            from: "private func expectedRelayerIdentityForSubmission(",
            until: "func rotateLocalRelayerKey() async throws"
        )
        #expect(selection.contains("client.bundlerStatus()"))
        #expect(selection.contains("publishLocalRelayerStatus"))
        #expect(selection.contains("relayerSecretAuthorizationPlan(for: status)"))
        #expect(selection.contains("return plan.active.identity"))

        let send = try slice(
            source,
            from: "private func sendUserOperation(",
            until: "private func activeSessionPlan"
        )
        let selected = try #require(
            send.range(of: "expectedRelayerIdentityForSubmission(")
        )
        let signing = try #require(
            send.range(of: "UserOperationSigning.signForSend")
        )
        let submission = try #require(
            send.range(of: "expectedRelayer: expectedSubmissionRelayer")
        )
        #expect(selected.lowerBound < signing.lowerBound)
        #expect(signing.lowerBound < submission.lowerBound)
        #expect(send.contains("pendingKeyRef == nil") == false)
    }

    @Test func relayerUnlockRejectsCacheAndDaemonSelectedFallbacks() throws {
        let source = try appSource("AppModel.swift")
        let install = try slice(
            source,
            from: "private func ensureRelayerUnlocked",
            until: "private func syncUnlockedRelayerAddress"
        )

        #expect(install.contains("relayerSecretAuthorizationPlan(for: observedStatus)"))
        #expect(install.contains("authorizationPlan.ordered"))
        #expect(install.contains("installedRelayerAuthorizationPlan == authorizationPlan"))
        #expect(install.contains("guard relayerInstallAuthorizationPlan == authorizationPlan"))
        #expect(install.contains("relayerInstallAuthorizationPlan = authorizationPlan"))
        #expect(install.contains("readAuthorizedRelayerSecret("))
        #expect(install.contains("authenticationSession: authenticationSession"))
        #expect(install.contains("installedRelayerAuthorizationPlan = nil"))
        #expect(install.contains("onboardingSettingsStore.bundlerKeyRef") == false)
        #expect(install.contains("RelayerKeyInstallPolicy") == false)
        #expect(install.contains("status?.keyRef") == false)
    }

    @Test func relayerAuthorityCacheIsClearedAtEveryConnectionInvalidationBoundary() throws {
        let source = try appSource("AppModel.swift")
        let invalidationSlices = try [
            slice(
                source,
                from: "func lockSecretRuntimesForSystemSession() async",
                until: "func resetDemoWalletAuthorized() async throws"
            ),
            slice(
                source,
                from: "private func quiesceManagedWalletNodeForSecretReset() async throws",
                until: "private func clearInMemoryWalletStateAfterReset()"
            ),
            slice(
                source,
                from: "private func clearInMemoryWalletStateAfterReset()",
                until: "func runDemo()"
            ),
            slice(
                source,
                from: "private func resetWalletNodeConnectionAfterNetworkChange()",
                until: "func setTransactionKind("
            ),
            slice(
                source,
                from: "func deleteLocalRelayerKey(",
                until: "func cancelPendingOperation("
            ),
            slice(
                source,
                from: "private func adoptManagedWalletNodeDaemon(",
                until: "private func ensureRelayerUnlocked("
            ),
            slice(
                source,
                from: "private func withWalletNodeClient<T: Sendable>(",
                until: "private func withPrivilegedWalletNodeClient<T: Sendable>("
            ),
        ]

        for invalidation in invalidationSlices {
            #expect(invalidation.contains("relayerInstallTask = nil"))
            #expect(invalidation.contains("relayerInstallAuthorizationPlan = nil"))
            #expect(invalidation.contains("installedRelayerAuthorizationPlan = nil"))
            #expect(invalidation.contains("relayerAccessState = .locked"))
        }

        let passivePublication = try slice(
            source,
            from: "private func publishLocalRelayerStatus(",
            until: "private func relayerSecretAuthorizationPlan("
        )
        #expect(passivePublication.contains("installedRelayerAuthorizationPlan = nil"))
    }

    @Test func relayerExportUsesFreshAuthorityAndOneCallerContext() throws {
        let source = try appSource("AppModel.swift")
        let export = try slice(
            source,
            from: "func exportLocalRelayerKey(",
            until: "func deleteLocalRelayerKey("
        )
        let status = try #require(export.range(of: "let status = try await client.bundlerStatus()"))
        let plan = try #require(export.range(of: "relayerSecretAuthorizationPlan(for: status)"))
        let authorize = try #require(export.range(of: "try await authentication.authorize()"))
        let read = try #require(export.range(of: "readAuthorizedRelayerSecret("))

        #expect(status.lowerBound < plan.lowerBound)
        #expect(plan.lowerBound < authorize.lowerBound)
        #expect(authorize.lowerBound < read.lowerBound)
        #expect(export.contains("authenticationSession: authentication"))
        #expect(export.contains("localRelayerStatus") == false)
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

    private func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }
}
