import Foundation
import Testing
@testable import WalletMacOSApp

@Suite struct RelayerRotationCoordinatorTests {
    private let chainID: UInt64 = 11_155_111

    @Test func planSelectsTheNextNeverUsedMonotonicKeyReference() throws {
        let genesis = try genesisState()
        let pending = try pendingState(genesis: genesis, candidateIndex: 2)
        let promoted = try RelayerChainStateTransition.promotePending(
            from: try snapshot([genesis, pending]),
            activatedKeyRef: keyRef(2)
        )

        let plan = try RelayerRotationCoordinator.plan(
            from: try snapshot([genesis, pending, promoted])
        )

        #expect(plan.mode == .createCandidate)
        #expect(plan.activeKeyRef == keyRef(2))
        #expect(plan.candidateKeyRef == keyRef(3))
        #expect(plan.pendingTransition?.activeKeyRef == keyRef(2))
        #expect(plan.pendingTransition?.pendingKeyRef == keyRef(3))
        #expect(plan.candidateKeyRef != keyRef(1))
        #expect(plan.candidateKeyRef != keyRef(2))
    }

    @Test func rotationPlannerRejectsNoncanonicalAndZeroKeyReferenceComponents() {
        for malformed in [
            "bundler-eoa:default:011155111:1",
            "bundler-eoa:default:11155111:01",
            "bundler-eoa:default:0:1",
            "bundler-eoa:default:11155111:0",
            "bundler-eoa:default:18446744073709551616:1",
            "bundler-eoa:default:11155111:18446744073709551616",
        ] {
            #expect(RelayerRotationCoordinator.keyRefComponents(malformed) == nil)
        }

        let canonical = RelayerRotationCoordinator.keyRefComponents(keyRef(1))
        #expect(canonical?.ownerScope == "default")
        #expect(canonical?.chainID == chainID)
        #expect(canonical?.index == 1)

        let maximum = RelayerRotationCoordinator.keyRefComponents(
            "bundler-eoa:default:18446744073709551615:18446744073709551615"
        )
        #expect(maximum?.chainID == UInt64.max)
        #expect(maximum?.index == UInt64.max)
    }

    @Test func rotationPlannerRejectsCandidateIndexOverflow() throws {
        let maximumRef = "bundler-eoa:default:\(chainID):\(UInt64.max)"
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: maximumRef
        )

        #expect(throws: RelayerRotationCoordinator.Failure.candidateIndexOverflow) {
            _ = try RelayerRotationCoordinator.plan(
                from: try RelayerChainSnapshot.validate(
                    [genesis],
                    expectedChainID: chainID
                )
            )
        }
    }

    @Test func planReusesTheExactPendingCandidateInsteadOfCreatingASecondOne() throws {
        let genesis = try genesisState()
        let pending = try pendingState(genesis: genesis, candidateIndex: 2)

        let plan = try RelayerRotationCoordinator.plan(
            from: try snapshot([genesis, pending])
        )

        #expect(plan.mode == .reusePending)
        #expect(plan.activeKeyRef == keyRef(1))
        #expect(plan.candidateKeyRef == keyRef(2))
        #expect(plan.pendingTransition == nil)
    }

    @Test func newCandidatePersistsPublicIdentityAndJournalBeforeDaemonInstall() async throws {
        let genesis = try genesisState()
        let currentSnapshot = try snapshot([genesis])
        let plan = try RelayerRotationCoordinator.plan(from: currentSnapshot)
        let activeIdentity = try identity(1)
        let candidateIdentity = try identity(2)
        var identities = [activeIdentity.keyRef: activeIdentity]
        var events: [String] = []

        let prepared = try await RelayerRotationCoordinator.prepareAndInstall(
            plan: plan,
            snapshot: currentSnapshot,
            createCandidateIdentity: { keyRef in
                events.append("create:\(keyRef)")
                return candidateIdentity
            },
            identityForKeyRef: { keyRef in
                events.append("read-public:\(keyRef)")
                return identities[keyRef]
            },
            persistPublicIdentity: { identity in
                events.append("persist-public:\(identity.keyRef)")
                identities[identity.keyRef] = identity
            },
            appendJournal: { transition in
                events.append("append-journal:\(transition.epoch)")
                return transition
            },
            installDaemon: { identity in
                events.append("install-daemon:\(identity.keyRef)")
            }
        )

        #expect(prepared.candidateIdentity == candidateIdentity)
        #expect(prepared.journalHead.pendingKeyRef == candidateIdentity.keyRef)
        #expect(events == [
            "create:\(keyRef(2))",
            "persist-public:\(keyRef(2))",
            "append-journal:1",
            "read-public:\(keyRef(1))",
            "read-public:\(keyRef(2))",
            "install-daemon:\(keyRef(2))",
        ])
    }

    @Test func retryUsesPendingPublicIdentityWithoutCreatingOrAppendingAnotherCandidate() async throws {
        let genesis = try genesisState()
        let pending = try pendingState(genesis: genesis, candidateIndex: 2)
        let currentSnapshot = try snapshot([genesis, pending])
        let plan = try RelayerRotationCoordinator.plan(from: currentSnapshot)
        let identities = [keyRef(1): try identity(1), keyRef(2): try identity(2)]
        var createCount = 0
        var persistCount = 0
        var appendCount = 0
        var installed: VerifiedRelayerIdentity?

        let prepared = try await RelayerRotationCoordinator.prepareAndInstall(
            plan: plan,
            snapshot: currentSnapshot,
            createCandidateIdentity: { _ in
                createCount += 1
                return try identity(99)
            },
            identityForKeyRef: { identities[$0] },
            persistPublicIdentity: { _ in persistCount += 1 },
            appendJournal: {
                appendCount += 1
                return $0
            },
            installDaemon: { installed = $0 }
        )

        #expect(prepared.candidateIdentity == identities[keyRef(2)])
        #expect(installed == identities[keyRef(2)])
        #expect(createCount == 0)
        #expect(persistCount == 0)
        #expect(appendCount == 0)
    }

    @Test func journalConflictStopsBeforeDaemonInstallation() async throws {
        let genesis = try genesisState()
        let currentSnapshot = try snapshot([genesis])
        let plan = try RelayerRotationCoordinator.plan(from: currentSnapshot)
        let identities = [keyRef(1): try identity(1), keyRef(2): try identity(2)]
        var installCount = 0

        await #expect(throws: RelayerRotationCoordinator.Failure.journalAppendMismatch(
            expectedEpoch: 1,
            actualEpoch: 0
        )) {
            _ = try await RelayerRotationCoordinator.prepareAndInstall(
                plan: plan,
                snapshot: currentSnapshot,
                createCandidateIdentity: { _ in identities[keyRef(2)]! },
                identityForKeyRef: { identities[$0] },
                persistPublicIdentity: { _ in },
                appendJournal: { _ in genesis },
                installDaemon: { _ in installCount += 1 }
            )
        }
        #expect(installCount == 0)
    }

    @Test func stalePlanCannotCreateASecondCandidateAfterConcurrentPendingAppend() async throws {
        let genesis = try genesisState()
        let originalSnapshot = try snapshot([genesis])
        let stalePlan = try RelayerRotationCoordinator.plan(from: originalSnapshot)
        let concurrentPending = try pendingState(genesis: genesis, candidateIndex: 2)
        let currentSnapshot = try snapshot([genesis, concurrentPending])
        var createCount = 0
        var persistCount = 0
        var appendCount = 0
        var installCount = 0

        await #expect(throws: RelayerRotationCoordinator.Failure.stalePlan) {
            _ = try await RelayerRotationCoordinator.prepareAndInstall(
                plan: stalePlan,
                snapshot: currentSnapshot,
                createCandidateIdentity: { _ in
                    createCount += 1
                    return try identity(2)
                },
                identityForKeyRef: { _ in nil },
                persistPublicIdentity: { _ in persistCount += 1 },
                appendJournal: {
                    appendCount += 1
                    return $0
                },
                installDaemon: { _ in installCount += 1 }
            )
        }
        #expect(createCount == 0)
        #expect(persistCount == 0)
        #expect(appendCount == 0)
        #expect(installCount == 0)
    }

    @Test func candidateIdentityConflictStopsBeforePublicPersistence() async throws {
        let genesis = try genesisState()
        let currentSnapshot = try snapshot([genesis])
        let plan = try RelayerRotationCoordinator.plan(from: currentSnapshot)
        var persistCount = 0
        var installCount = 0

        await #expect(throws: RelayerRotationCoordinator.Failure.candidateIdentityMismatch(
            expected: keyRef(2),
            actual: keyRef(3)
        )) {
            _ = try await RelayerRotationCoordinator.prepareAndInstall(
                plan: plan,
                snapshot: currentSnapshot,
                createCandidateIdentity: { _ in try identity(3) },
                identityForKeyRef: { _ in nil },
                persistPublicIdentity: { _ in persistCount += 1 },
                appendJournal: { $0 },
                installDaemon: { _ in installCount += 1 }
            )
        }
        #expect(persistCount == 0)
        #expect(installCount == 0)
    }

    @Test func promotionRequiresExactPendingActiveAndPriorRetiringIdentity() throws {
        let genesis = try genesisState()
        let pending = try pendingState(genesis: genesis, candidateIndex: 2)
        let currentSnapshot = try snapshot([genesis, pending])
        let identities = [keyRef(1): try identity(1), keyRef(2): try identity(2)]
        var appended: RelayerChainState?

        let promoted = try RelayerRotationCoordinator.promoteIfReady(
            snapshot: currentSnapshot,
            daemonActive: observation(index: 2, lifecycle: "active"),
            priorActive: observation(index: 1, lifecycle: "retiring"),
            identityForKeyRef: { identities[$0] },
            appendJournal: {
                appended = $0
                return $0
            }
        )

        #expect(promoted == appended)
        #expect(promoted?.activeKeyRef == keyRef(2))
        #expect(promoted?.pendingKeyRef == nil)
        #expect(promoted?.epoch == 2)
    }

    @Test func promotionRejectsWrongDaemonCandidateAndUnretiredPriorActive() throws {
        let genesis = try genesisState()
        let pending = try pendingState(genesis: genesis, candidateIndex: 2)
        let currentSnapshot = try snapshot([genesis, pending])
        let identities = [keyRef(1): try identity(1), keyRef(2): try identity(2)]
        var appendCount = 0

        #expect(throws: RelayerRotationCoordinator.Failure.daemonKeyRefMismatch(
            expected: keyRef(2),
            actual: keyRef(3)
        )) {
            _ = try RelayerRotationCoordinator.promoteIfReady(
                snapshot: currentSnapshot,
                daemonActive: observation(index: 3, lifecycle: "active"),
                priorActive: observation(index: 1, lifecycle: "retiring"),
                identityForKeyRef: { identities[$0] },
                appendJournal: {
                    appendCount += 1
                    return $0
                }
            )
        }
        #expect(appendCount == 0)

        #expect(throws: RelayerRotationCoordinator.Failure.priorActiveLifecycleNotRetiringOrRetired(
            "active"
        )) {
            _ = try RelayerRotationCoordinator.promoteIfReady(
                snapshot: currentSnapshot,
                daemonActive: observation(index: 2, lifecycle: "active"),
                priorActive: observation(index: 1, lifecycle: "active"),
                identityForKeyRef: { identities[$0] },
                appendJournal: {
                    appendCount += 1
                    return $0
                }
            )
        }
        #expect(appendCount == 0)
    }

    @Test func noPendingCandidateNeedsNoPromotionOrPublicReads() throws {
        let currentSnapshot = try snapshot([genesisState()])
        var readCount = 0
        var appendCount = 0

        let promoted = try RelayerRotationCoordinator.promoteIfReady(
            snapshot: currentSnapshot,
            daemonActive: observation(index: 1, lifecycle: "active"),
            priorActive: observation(index: 1, lifecycle: "retired"),
            identityForKeyRef: { _ in
                readCount += 1
                return nil
            },
            appendJournal: {
                appendCount += 1
                return $0
            }
        )

        #expect(promoted == nil)
        #expect(readCount == 0)
        #expect(appendCount == 0)
    }

    @Test func retryBindingAcceptsOnlyTheExactJournaledCandidateWhenDaemonInstallNeverStarted() throws {
        let genesis = try genesisState()
        let pending = try pendingState(genesis: genesis, candidateIndex: 2)
        let currentSnapshot = try snapshot([genesis, pending])
        let identities = [keyRef(1): try identity(1), keyRef(2): try identity(2)]

        try RelayerPendingRotationBindingPolicy.validate(
            status: try daemonStatus(),
            expectedChainID: chainID,
            expectedOwnerScope: "default",
            expectedNetworkProfile: "sepolia",
            snapshot: currentSnapshot,
            expectedIdentity: identities[keyRef(2)]!,
            allowUninstalledDaemonCandidate: true,
            identityForKeyRef: { identities[$0] }
        )

        #expect(throws: RelayerRotationCoordinator.Failure.unexpectedPendingTransition("none")) {
            try RelayerPendingRotationBindingPolicy.validate(
                status: try daemonStatus(),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: currentSnapshot,
                expectedIdentity: identities[keyRef(2)]!,
                allowUninstalledDaemonCandidate: false,
                identityForKeyRef: { identities[$0] }
            )
        }

        #expect(throws: RelayerPendingRotationBindingPolicy.Failure.unrelatedLiveLifecycle(
            keyRef: keyRef(3),
            lifecycle: "pending_funding"
        )) {
            try RelayerPendingRotationBindingPolicy.validate(
                status: try daemonStatus(pendingIndex: 3),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: currentSnapshot,
                expectedIdentity: identities[keyRef(2)]!,
                allowUninstalledDaemonCandidate: true,
                identityForKeyRef: { identities[$0] }
            )
        }

        #expect(throws: RelayerRotationCoordinator.Failure.unexpectedPendingTransition(keyRef(2))) {
            try RelayerPendingRotationBindingPolicy.validate(
                status: try daemonStatus(historicalCandidateLifecycle: "deleted"),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: currentSnapshot,
                expectedIdentity: identities[keyRef(2)]!,
                allowUninstalledDaemonCandidate: true,
                identityForKeyRef: { identities[$0] }
            )
        }

        #expect(throws: RelayerPendingRotationBindingPolicy.Failure.replacementInProgress) {
            try RelayerPendingRotationBindingPolicy.validate(
                status: try daemonStatus(replacementInProgress: true),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: currentSnapshot,
                expectedIdentity: identities[keyRef(2)]!,
                allowUninstalledDaemonCandidate: true,
                identityForKeyRef: { identities[$0] }
            )
        }
    }

    @Test func installedPendingBindingStillRequiresTheExactDaemonAddress() throws {
        let genesis = try genesisState()
        let pending = try pendingState(genesis: genesis, candidateIndex: 2)
        let currentSnapshot = try snapshot([genesis, pending])
        let identities = [keyRef(1): try identity(1), keyRef(2): try identity(2)]

        try RelayerPendingRotationBindingPolicy.validate(
            status: try daemonStatus(pendingIndex: 2),
            expectedChainID: chainID,
            expectedOwnerScope: "default",
            expectedNetworkProfile: "sepolia",
            snapshot: currentSnapshot,
            expectedIdentity: identities[keyRef(2)]!,
            allowUninstalledDaemonCandidate: false,
            identityForKeyRef: { identities[$0] }
        )

        #expect(throws: (any Error).self) {
            try RelayerPendingRotationBindingPolicy.validate(
                status: try daemonStatus(pendingIndex: 2, pendingAddressIndex: 3),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: currentSnapshot,
                expectedIdentity: identities[keyRef(2)]!,
                allowUninstalledDaemonCandidate: true,
                identityForKeyRef: { identities[$0] }
            )
        }
    }

    @Test func pendingRetryRejectsWrongScopeProfileAndIncoherentDaemonHistory() throws {
        let genesis = try genesisState()
        let pending = try pendingState(genesis: genesis, candidateIndex: 2)
        let currentSnapshot = try snapshot([genesis, pending])
        let identities = [keyRef(1): try identity(1), keyRef(2): try identity(2)]
        let coherent = try daemonStatus(pendingIndex: 2)

        #expect(throws: RelayerPendingRotationBindingPolicy.Failure.replacementStateMissing) {
            try RelayerPendingRotationBindingPolicy.validate(
                status: withReplacement(coherent, replacement: nil),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: currentSnapshot,
                expectedIdentity: identities[keyRef(2)]!,
                allowUninstalledDaemonCandidate: true,
                identityForKeyRef: { identities[$0] }
            )
        }

        for status in [
            copyStatus(coherent, ownerScope: "attacker"),
            copyStatus(coherent, networkProfile: "mainnet"),
        ] {
            #expect(throws: (any Error).self) {
                try RelayerPendingRotationBindingPolicy.validate(
                    status: status,
                    expectedChainID: chainID,
                    expectedOwnerScope: "default",
                    expectedNetworkProfile: "sepolia",
                    snapshot: currentSnapshot,
                    expectedIdentity: identities[keyRef(2)]!,
                    allowUninstalledDaemonCandidate: true,
                    identityForKeyRef: { identities[$0] }
                )
            }
        }

        #expect(throws: RelayerPendingRotationBindingPolicy.Failure.pendingHistoryMismatch(
            keyRef(2)
        )) {
            try RelayerPendingRotationBindingPolicy.validate(
                status: withHistory(
                    coherent,
                    history: coherent.keyHistory.filter { $0.keyRef != keyRef(2) }
                ),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: currentSnapshot,
                expectedIdentity: identities[keyRef(2)]!,
                allowUninstalledDaemonCandidate: true,
                identityForKeyRef: { identities[$0] }
            )
        }

        #expect(throws: RelayerPendingRotationBindingPolicy.Failure.pendingHistoryMismatch(
            keyRef(2)
        )) {
            let retiredCandidateHistory = coherent.keyHistory.map { entry in
                guard entry.keyRef == keyRef(2) else { return entry }
                return WalletNodeClient.RelayerStatus.KeyHistoryEntry(
                    eoa: entry.eoa,
                    keyRef: entry.keyRef,
                    lifecycle: "retired",
                    createdAt: entry.createdAt,
                    retiredAt: 1_723_456_800,
                    deletedAt: entry.deletedAt,
                    lastExportedAt: entry.lastExportedAt
                )
            }
            try RelayerPendingRotationBindingPolicy.validate(
                status: withHistory(coherent, history: retiredCandidateHistory),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: currentSnapshot,
                expectedIdentity: identities[keyRef(2)]!,
                allowUninstalledDaemonCandidate: true,
                identityForKeyRef: { identities[$0] }
            )
        }

        #expect(throws: RelayerPendingRotationBindingPolicy.Failure.retiringStatePresent(
            reported: 1,
            observed: 1
        )) {
            try RelayerPendingRotationBindingPolicy.validate(
                status: try daemonStatus(
                    pendingIndex: 2,
                    retiringCount: 1,
                    additionalHistory: [[
                        "eoa": address(9),
                        "keyRef": keyRef(3),
                        "lifecycle": "retiring",
                        "createdAt": 1_723_456_720,
                    ]]
                ),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: currentSnapshot,
                expectedIdentity: identities[keyRef(2)]!,
                allowUninstalledDaemonCandidate: true,
                identityForKeyRef: { identities[$0] }
            )
        }
    }

    @Test func absentDaemonRetryRejectsCandidateAddressUnderAnotherKeyReference() throws {
        let genesis = try genesisState()
        let pending = try pendingState(genesis: genesis, candidateIndex: 2)
        let currentSnapshot = try snapshot([genesis, pending])
        let identities = [keyRef(1): try identity(1), keyRef(2): try identity(2)]

        #expect(throws: RelayerRotationCoordinator.Failure.unexpectedPendingTransition(
            keyRef(2)
        )) {
            try RelayerPendingRotationBindingPolicy.validate(
                status: try daemonStatus(additionalHistory: [[
                    "eoa": address(2),
                    "keyRef": keyRef(3),
                    "lifecycle": "retired",
                    "createdAt": 1_723_456_720,
                ]]),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: currentSnapshot,
                expectedIdentity: identities[keyRef(2)]!,
                allowUninstalledDaemonCandidate: true,
                identityForKeyRef: { identities[$0] }
            )
        }
    }

    @Test func promotionObservationRejectsCompromisePendingAndDuplicateHistory() throws {
        let genesis = try genesisState()
        let pending = try pendingState(genesis: genesis, candidateIndex: 2)
        let currentSnapshot = try snapshot([genesis, pending])

        let observations = try #require(RelayerPromotionObservationPolicy.validate(
            status: try promotionStatus(),
            snapshot: currentSnapshot,
            expectedOwnerScope: "default",
            expectedNetworkProfile: "sepolia"
        ))
        #expect(observations.daemonActive.keyRef == keyRef(2))
        #expect(observations.priorActive.keyRef == keyRef(1))

        #expect(throws: RelayerPromotionObservationPolicy.Failure.compromiseBlocked) {
            _ = try RelayerPromotionObservationPolicy.validate(
                status: try promotionStatus(compromised: true),
                snapshot: currentSnapshot,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia"
            )
        }
        #expect(throws: RelayerPromotionObservationPolicy.Failure.pendingCandidateRemains) {
            _ = try RelayerPromotionObservationPolicy.validate(
                status: try promotionStatus(includePendingCandidate: true),
                snapshot: currentSnapshot,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia"
            )
        }
        #expect(throws: RelayerPromotionObservationPolicy.Failure.replacementStateMissing) {
            _ = try RelayerPromotionObservationPolicy.validate(
                status: withReplacement(try promotionStatus(), replacement: nil),
                snapshot: currentSnapshot,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia"
            )
        }
        #expect(throws: RelayerPromotionObservationPolicy.Failure.replacementInProgress) {
            _ = try RelayerPromotionObservationPolicy.validate(
                status: withReplacement(
                    try promotionStatus(),
                    replacement: .init(
                        eligible: true,
                        blocked: false,
                        blockedReason: nil,
                        txHash: "0xdead",
                        userOpHash: "0xbeef",
                        nonce: 7
                    )
                ),
                snapshot: currentSnapshot,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia"
            )
        }
        #expect(throws: RelayerPromotionObservationPolicy.Failure.wrongOwnerScope(
            expected: "default",
            actual: "attacker"
        )) {
            _ = try RelayerPromotionObservationPolicy.validate(
                status: copyStatus(try promotionStatus(), ownerScope: "attacker"),
                snapshot: currentSnapshot,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia"
            )
        }
        #expect(throws: RelayerPromotionObservationPolicy.Failure.wrongNetworkProfile(
            expected: "sepolia",
            actual: "mainnet"
        )) {
            _ = try RelayerPromotionObservationPolicy.validate(
                status: copyStatus(try promotionStatus(), networkProfile: "mainnet"),
                snapshot: currentSnapshot,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia"
            )
        }
        #expect(throws: RelayerPromotionObservationPolicy.Failure.duplicateKeyReference(
            keyRef(1)
        )) {
            _ = try RelayerPromotionObservationPolicy.validate(
                status: try promotionStatus(duplicatePrior: true),
                snapshot: currentSnapshot,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia"
            )
        }
    }

    private func genesisState() throws -> RelayerChainState {
        try RelayerChainStateTransition.genesis(chainID: chainID, activeKeyRef: keyRef(1))
    }

    private func pendingState(
        genesis: RelayerChainState,
        candidateIndex: UInt64
    ) throws -> RelayerChainState {
        try RelayerChainStateTransition.beginRotation(
            from: try snapshot([genesis]),
            candidateKeyRef: keyRef(candidateIndex)
        )
    }

    private func snapshot(_ states: [RelayerChainState]) throws -> RelayerChainSnapshot {
        try RelayerChainSnapshot.validate(states, expectedChainID: chainID)
    }

    private func keyRef(_ index: UInt64) -> String {
        "bundler-eoa:default:\(chainID):\(index)"
    }

    private func address(_ index: UInt64) -> String {
        "0x" + String(repeating: String(format: "%02x", index & 0xff), count: 20)
    }

    private func identity(_ index: UInt64) throws -> VerifiedRelayerIdentity {
        try VerifiedRelayerIdentity(
            chainID: chainID,
            keyRef: keyRef(index),
            address: address(index)
        )
    }

    private func observation(
        index: UInt64,
        lifecycle: String
    ) -> RelayerRotationCoordinator.DaemonIdentityObservation {
        .init(
            chainID: chainID,
            keyRef: keyRef(index),
            address: address(index),
            lifecycle: lifecycle
        )
    }

    private func daemonStatus(
        pendingIndex: UInt64? = nil,
        pendingAddressIndex: UInt64? = nil,
        historicalCandidateLifecycle: String? = nil,
        replacementInProgress: Bool = false,
        ownerScope: String = "default",
        networkProfile: String = "sepolia",
        retiringCount: Int = 0,
        additionalHistory: [[String: Any]] = []
    ) throws -> WalletNodeClient.RelayerStatus {
        var history: [[String: Any]] = [[
            "ownerScope": ownerScope,
            "chainId": Int(chainID),
            "eoa": address(1),
            "keyRef": keyRef(1),
            "lifecycle": "active",
            "createdAt": 1_723_456_700,
        ]]
        var json: [String: Any] = [
            "ready": true,
            "keyLoaded": true,
            "reason": NSNull(),
            "ownerScope": ownerScope,
            "chainId": Int(chainID),
            "networkProfile": networkProfile,
            "eoa": address(1),
            "keyRef": keyRef(1),
            "balance": "0x2386f26fc10000",
            "thresholdLow": "0x11c37937e08000",
            "needsTopup": false,
            "lifecycle": "active",
            "rotation": [
                "rotating": false,
                "pendingFunding": [],
                "retiring": [],
            ],
            "replacement": [
                "eligible": false,
                "blocked": false,
                "blockedReason": NSNull(),
                "txHash": NSNull(),
                "userOpHash": NSNull(),
                "nonce": NSNull(),
            ],
            "compromise": [
                "suspected": false,
                "reason": NSNull(),
                "submissionBlocked": false,
            ],
        ]
        if let historicalCandidateLifecycle {
            history.append([
                "ownerScope": ownerScope,
                "chainId": Int(chainID),
                "eoa": address(2),
                "keyRef": keyRef(2),
                "lifecycle": historicalCandidateLifecycle,
                "createdAt": 1_723_456_710,
            ])
        }
        if replacementInProgress {
            json["replacement"] = [
                "eligible": true,
                "blocked": false,
                "blockedReason": NSNull(),
                "txHash": "0x" + String(repeating: "ab", count: 32),
                "userOpHash": "0x" + String(repeating: "cd", count: 32),
                "nonce": 7,
            ]
        }
        if let pendingIndex {
            history.append([
                "ownerScope": ownerScope,
                "chainId": Int(chainID),
                "eoa": address(pendingAddressIndex ?? pendingIndex),
                "keyRef": keyRef(pendingIndex),
                "lifecycle": "pending_funding",
                "createdAt": 1_723_456_789,
            ])
        }
        if pendingIndex != nil || retiringCount > 0 {
            let pendingFunding: [[String: Any]]
            if let pendingIndex {
                pendingFunding = [[
                    "eoa": address(pendingAddressIndex ?? pendingIndex),
                    "keyRef": keyRef(pendingIndex),
                    "createdAt": 1_723_456_789,
                ]]
            } else {
                pendingFunding = []
            }
            json["rotation"] = [
                "rotating": true,
                "pendingFunding": pendingFunding,
                "retiring": Array(
                    repeating: address(9),
                    count: retiringCount
                ),
            ]
        }
        history.append(contentsOf: additionalHistory.map { source in
            var entry = source
            entry["ownerScope"] = entry["ownerScope"] ?? ownerScope
            entry["chainId"] = entry["chainId"] ?? Int(chainID)
            return entry
        })
        json["keyHistory"] = history
        return try WalletNodeClient.RelayerStatus(json: json)
    }

    private func copyStatus(
        _ status: WalletNodeClient.RelayerStatus,
        ownerScope: String? = nil,
        networkProfile: String? = nil
    ) -> WalletNodeClient.RelayerStatus {
        WalletNodeClient.RelayerStatus(
            ready: status.ready,
            keyLoaded: status.keyLoaded,
            reason: status.reason,
            ownerScope: ownerScope ?? status.ownerScope,
            chainId: status.chainId,
            networkProfile: networkProfile ?? status.networkProfile,
            eoa: status.eoa,
            keyRef: status.keyRef,
            balance: status.balance,
            thresholdLow: status.thresholdLow,
            needsTopup: status.needsTopup,
            lifecycle: status.lifecycle,
            compromiseSubmissionBlocked: status.compromiseSubmissionBlocked,
            pendingFunding: status.pendingFunding,
            retiringCount: status.retiringCount,
            keyHistory: status.keyHistory,
            latestAuditEvent: status.latestAuditEvent,
            replacement: status.replacement
        )
    }

    private func withReplacement(
        _ status: WalletNodeClient.RelayerStatus,
        replacement: WalletNodeClient.RelayerStatus.ReplacementStatus?
    ) -> WalletNodeClient.RelayerStatus {
        WalletNodeClient.RelayerStatus(
            ready: status.ready,
            keyLoaded: status.keyLoaded,
            reason: status.reason,
            ownerScope: status.ownerScope,
            chainId: status.chainId,
            networkProfile: status.networkProfile,
            eoa: status.eoa,
            keyRef: status.keyRef,
            balance: status.balance,
            thresholdLow: status.thresholdLow,
            needsTopup: status.needsTopup,
            lifecycle: status.lifecycle,
            compromiseSubmissionBlocked: status.compromiseSubmissionBlocked,
            pendingFunding: status.pendingFunding,
            retiringCount: status.retiringCount,
            keyHistory: status.keyHistory,
            latestAuditEvent: status.latestAuditEvent,
            replacement: replacement
        )
    }

    private func withHistory(
        _ status: WalletNodeClient.RelayerStatus,
        history: [WalletNodeClient.RelayerStatus.KeyHistoryEntry]
    ) -> WalletNodeClient.RelayerStatus {
        WalletNodeClient.RelayerStatus(
            ready: status.ready,
            keyLoaded: status.keyLoaded,
            reason: status.reason,
            ownerScope: status.ownerScope,
            chainId: status.chainId,
            networkProfile: status.networkProfile,
            eoa: status.eoa,
            keyRef: status.keyRef,
            balance: status.balance,
            thresholdLow: status.thresholdLow,
            needsTopup: status.needsTopup,
            lifecycle: status.lifecycle,
            compromiseSubmissionBlocked: status.compromiseSubmissionBlocked,
            pendingFunding: status.pendingFunding,
            retiringCount: status.retiringCount,
            keyHistory: history,
            latestAuditEvent: status.latestAuditEvent,
            replacement: status.replacement
        )
    }

    private func promotionStatus(
        compromised: Bool = false,
        includePendingCandidate: Bool = false,
        duplicatePrior: Bool = false
    ) throws -> WalletNodeClient.RelayerStatus {
        if duplicatePrior {
            let base = try promotionStatus(
                compromised: compromised,
                includePendingCandidate: includePendingCandidate,
                duplicatePrior: false
            )
            return WalletNodeClient.RelayerStatus(
                ready: base.ready,
                keyLoaded: base.keyLoaded,
                reason: base.reason,
                ownerScope: base.ownerScope,
                chainId: base.chainId,
                networkProfile: base.networkProfile,
                eoa: base.eoa,
                keyRef: base.keyRef,
                balance: base.balance,
                thresholdLow: base.thresholdLow,
                needsTopup: base.needsTopup,
                lifecycle: base.lifecycle,
                compromiseSubmissionBlocked: base.compromiseSubmissionBlocked,
                pendingFunding: base.pendingFunding,
                retiringCount: base.retiringCount,
                keyHistory: base.keyHistory + [.init(
                    eoa: address(3),
                    keyRef: keyRef(1),
                    lifecycle: "retired",
                    createdAt: 1_723_456_700,
                    retiredAt: 1_723_456_800,
                    deletedAt: nil,
                    lastExportedAt: nil
                )],
                latestAuditEvent: base.latestAuditEvent,
                replacement: base.replacement
            )
        }
        var history: [[String: Any]] = [
            [
                "ownerScope": "default",
                "chainId": Int(chainID),
                "eoa": address(2),
                "keyRef": keyRef(2),
                "lifecycle": "active",
                "createdAt": 1_723_456_790,
            ],
            [
                "ownerScope": "default",
                "chainId": Int(chainID),
                "eoa": address(1),
                "keyRef": keyRef(1),
                "lifecycle": "retiring",
                "createdAt": 1_723_456_700,
            ],
        ]
        var rotation: [String: Any] = [
            "rotating": true,
            "pendingFunding": [],
            "retiring": [address(1)],
        ]
        if includePendingCandidate {
            rotation["pendingFunding"] = [[
                "eoa": address(3),
                "keyRef": keyRef(3),
                "createdAt": 1_723_456_790,
            ]]
            history.append([
                "ownerScope": "default",
                "chainId": Int(chainID),
                "eoa": address(3),
                "keyRef": keyRef(3),
                "lifecycle": "pending_funding",
                "createdAt": 1_723_456_790,
            ])
        }
        let statusReason: Any
        let compromiseReason: Any
        if compromised {
            statusReason = "bundler_eoa_compromise_suspected"
            compromiseReason = "relayer_address_mismatch"
        } else {
            statusReason = NSNull()
            compromiseReason = NSNull()
        }
        let json: [String: Any] = [
            "ready": !compromised,
            "keyLoaded": true,
            "reason": statusReason,
            "ownerScope": "default",
            "chainId": Int(chainID),
            "networkProfile": "sepolia",
            "eoa": address(2),
            "keyRef": keyRef(2),
            "balance": "0x2386f26fc10000",
            "thresholdLow": "0x11c37937e08000",
            "needsTopup": false,
            "lifecycle": "active",
            "rotation": rotation,
            "keyHistory": history,
            "replacement": [
                "eligible": false,
                "blocked": false,
                "blockedReason": NSNull(),
                "txHash": NSNull(),
                "userOpHash": NSNull(),
                "nonce": NSNull(),
            ],
            "compromise": [
                "suspected": compromised,
                "reason": compromiseReason,
                "submissionBlocked": compromised,
            ],
        ]
        return try WalletNodeClient.RelayerStatus(json: json)
    }
}
