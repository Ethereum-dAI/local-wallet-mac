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
}
