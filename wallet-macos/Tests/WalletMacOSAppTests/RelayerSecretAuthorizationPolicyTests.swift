import Foundation
import Testing
@testable import WalletMacOSApp

@Suite struct RelayerSecretAuthorizationPolicyTests {
    private let chainID: UInt64 = 11_155_111

    @Test func exactJournalActiveAndHistoricalRetiringKeysAreAuthorizedActiveFirst() throws {
        let identities = try identityMap(indices: [1, 2])
        let plan = try RelayerSecretAuthorizationPolicy.resolve(
            status: status(
                activeIndex: 2,
                retiring: [history(index: 1, lifecycle: "retiring")]
            ),
            expectedChainID: chainID,
            expectedOwnerScope: "default",
            expectedNetworkProfile: "sepolia",
            snapshot: try rotatedSnapshot(from: 1, to: 2),
            identityForKeyRef: { identities[$0] }
        )

        #expect(plan.active == .init(role: .active, identity: identities[keyRef(2)]!))
        #expect(plan.retiring == [
            .init(role: .retiring, identity: identities[keyRef(1)]!),
        ])
        #expect(plan.ordered.map(\.identity.keyRef) == [keyRef(2), keyRef(1)])
        #expect(plan.authorization(forKeyRef: keyRef(1))?.role == .retiring)
    }

    @Test func retiredPendingAndArbitraryStoredKeysAreNeverAuthorized() throws {
        let identities = try identityMap(indices: [1, 2, 3])
        let snapshot = try rotatedSnapshot(from: 1, to: 2)
        let plan = try RelayerSecretAuthorizationPolicy.resolve(
            status: status(
                activeIndex: 2,
                retiring: [history(index: 1, lifecycle: "retired")]
            ),
            expectedChainID: chainID,
            expectedOwnerScope: "default",
            expectedNetworkProfile: "sepolia",
            snapshot: snapshot,
            identityForKeyRef: { identities[$0] }
        )

        #expect(plan.authorization(forKeyRef: keyRef(1)) == nil)
        #expect(plan.authorization(forKeyRef: keyRef(3)) == nil)
        #expect(plan.ordered.map(\.identity.keyRef) == [keyRef(2)])
    }

    @Test func unjournaledRetiringKeyFailsClosedEvenWhenPublicIdentityExists() throws {
        let identities = try identityMap(indices: [1, 2, 3])

        #expect(throws: RelayerSecretAuthorizationPolicy.Failure.unjournaledRetiringKeyRef(
            keyRef(3)
        )) {
            _ = try RelayerSecretAuthorizationPolicy.resolve(
                status: status(
                    activeIndex: 2,
                    retiring: [history(index: 3, lifecycle: "retiring")]
                ),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: try rotatedSnapshot(from: 1, to: 2),
                identityForKeyRef: { identities[$0] }
            )
        }
    }

    @Test func pendingJournalCandidateCannotBeInstalledAsRetiring() throws {
        let identities = try identityMap(indices: [1, 2])
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(1)
        )
        let pending = try RelayerChainStateTransition.beginRotation(
            from: try RelayerChainSnapshot.validate([genesis], expectedChainID: chainID),
            candidateKeyRef: keyRef(2)
        )
        let snapshot = try RelayerChainSnapshot.validate(
            [genesis, pending],
            expectedChainID: chainID
        )

        #expect(throws: RelayerSecretAuthorizationPolicy.Failure.pendingKeyListedAsRetiring(
            keyRef(2)
        )) {
            _ = try RelayerSecretAuthorizationPolicy.resolve(
                status: status(
                    activeIndex: 1,
                    retiring: [history(index: 2, lifecycle: "retiring")]
                ),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: snapshot,
                identityForKeyRef: { identities[$0] }
            )
        }
    }

    @Test func clearedPendingCandidateCannotBeInstalledAsRetiring() throws {
        let identities = try identityMap(indices: [1, 2])
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(1)
        )
        let pending = try RelayerChainStateTransition.beginRotation(
            from: try RelayerChainSnapshot.validate([genesis], expectedChainID: chainID),
            candidateKeyRef: keyRef(2)
        )
        let cleared = try RelayerChainStateTransition.clearPending(
            from: try RelayerChainSnapshot.validate(
                [genesis, pending],
                expectedChainID: chainID
            ),
            expectedPendingKeyRef: keyRef(2)
        )
        let snapshot = try RelayerChainSnapshot.validate(
            [genesis, pending, cleared],
            expectedChainID: chainID
        )

        #expect(snapshot.historicalKeyRefs.contains(keyRef(2)))
        #expect(!snapshot.previouslyActiveKeyRefs.contains(keyRef(2)))
        #expect(throws: RelayerSecretAuthorizationPolicy.Failure.unjournaledRetiringKeyRef(
            keyRef(2)
        )) {
            _ = try RelayerSecretAuthorizationPolicy.resolve(
                status: status(
                    activeIndex: 1,
                    retiring: [history(index: 2, lifecycle: "retiring")]
                ),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: snapshot,
                identityForKeyRef: { identities[$0] }
            )
        }
    }

    @Test func journalHeadTransitionChangesThePlanEvenWhenActiveIdentityDoesNot() throws {
        let identities = try identityMap(indices: [1, 2])
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(1)
        )
        let genesisSnapshot = try RelayerChainSnapshot.validate(
            [genesis],
            expectedChainID: chainID
        )
        let pending = try RelayerChainStateTransition.beginRotation(
            from: genesisSnapshot,
            candidateKeyRef: keyRef(2)
        )
        let pendingSnapshot = try RelayerChainSnapshot.validate(
            [genesis, pending],
            expectedChainID: chainID
        )

        let before = try RelayerSecretAuthorizationPolicy.resolve(
            status: status(activeIndex: 1),
            expectedChainID: chainID,
            expectedOwnerScope: "default",
            expectedNetworkProfile: "sepolia",
            snapshot: genesisSnapshot,
            identityForKeyRef: { identities[$0] }
        )
        let after = try RelayerSecretAuthorizationPolicy.resolve(
            status: status(activeIndex: 1),
            expectedChainID: chainID,
            expectedOwnerScope: "default",
            expectedNetworkProfile: "sepolia",
            snapshot: pendingSnapshot,
            identityForKeyRef: { identities[$0] }
        )

        #expect(before.active == after.active)
        #expect(before != after)
        #expect(before.journalHead == genesis)
        #expect(after.journalHead == pending)
    }

    @Test func duplicateOrCountMismatchedRetiringHistoryFailsClosed() throws {
        let identities = try identityMap(indices: [1, 2])
        let snapshot = try rotatedSnapshot(from: 1, to: 2)
        let duplicate = history(index: 1, lifecycle: "retiring")

        #expect(throws: RelayerSecretAuthorizationPolicy.Failure.duplicateRetiringKeyRef(
            keyRef(1)
        )) {
            _ = try RelayerSecretAuthorizationPolicy.resolve(
                status: status(activeIndex: 2, retiring: [duplicate, duplicate]),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: snapshot,
                identityForKeyRef: { identities[$0] }
            )
        }

        #expect(throws: RelayerSecretAuthorizationPolicy.Failure.retiringCountMismatch(
            reported: 2,
            observed: 1
        )) {
            _ = try RelayerSecretAuthorizationPolicy.resolve(
                status: status(activeIndex: 2, retiring: [duplicate], retiringCount: 2),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: snapshot,
                identityForKeyRef: { identities[$0] }
            )
        }
    }

    @Test func retiringIdentityMustExactlyMatchImmutablePublicRecord() throws {
        let identities = try identityMap(indices: [1, 2])

        #expect(throws: RelayerSecretAuthorizationPolicy.Failure.wrongRetiringAddress(
            keyRef: keyRef(1),
            expected: address(1),
            actual: address(9)
        )) {
            _ = try RelayerSecretAuthorizationPolicy.resolve(
                status: status(
                    activeIndex: 2,
                    retiring: [history(index: 1, lifecycle: "retiring", addressIndex: 9)]
                ),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: try rotatedSnapshot(from: 1, to: 2),
                identityForKeyRef: { identities[$0] }
            )
        }
    }

    @Test func compromisedActiveStatusRejectsTheEntireSecretPlan() throws {
        let identities = try identityMap(indices: [1])

        #expect(throws: RelayerIdentityBindingPolicy.Failure.compromiseSuspected) {
            _ = try RelayerSecretAuthorizationPolicy.resolve(
                status: status(activeIndex: 1, compromiseSubmissionBlocked: true),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: try activeSnapshot(index: 1),
                identityForKeyRef: { identities[$0] }
            )
        }
    }

    @Test func wrongDaemonScopeOrProfileRejectsSecretAuthorizationBeforeIdentityRead() throws {
        var identityReadCount = 0
        let snapshot = try activeSnapshot(index: 1)

        #expect(throws: PassiveRelayerIdentityResolver.Failure.wrongOwnerScope(
            expected: "default",
            actual: "attacker"
        )) {
            _ = try RelayerSecretAuthorizationPolicy.resolve(
                status: status(activeIndex: 1, ownerScope: "attacker"),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: snapshot,
                identityForKeyRef: { _ in
                    identityReadCount += 1
                    return nil
                }
            )
        }
        #expect(throws: PassiveRelayerIdentityResolver.Failure.wrongNetworkProfile(
            expected: "sepolia",
            actual: "mainnet"
        )) {
            _ = try RelayerSecretAuthorizationPolicy.resolve(
                status: status(activeIndex: 1, networkProfile: "mainnet"),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: snapshot,
                identityForKeyRef: { _ in
                    identityReadCount += 1
                    return nil
                }
            )
        }
        #expect(identityReadCount == 0)
    }

    @Test func authenticatedSecretMustReDeriveTheExactAuthorizedIdentity() throws {
        let expectedSecret = Data(repeating: 0x11, count: 32)
        let wrongSecret = Data(repeating: 0x22, count: 32)
        let identity = try VerifiedRelayerIdentity.derive(
            keyRef: keyRef(1),
            secret: expectedSecret
        )
        let authorization = RelayerSecretAuthorization(
            role: .active,
            identity: identity
        )

        #expect(try RelayerSecretAuthorizationPolicy.verifyAuthenticated(
            record: .init(keyRef: keyRef(1), secret: expectedSecret),
            authorization: authorization
        ) == identity)
        #expect(throws: RelayerSecretAuthorizationPolicy.Failure.authenticatedIdentityMismatch(
            expected: identity,
            actual: try VerifiedRelayerIdentity.derive(
                keyRef: keyRef(1),
                secret: wrongSecret
            )
        )) {
            _ = try RelayerSecretAuthorizationPolicy.verifyAuthenticated(
                record: .init(keyRef: keyRef(1), secret: wrongSecret),
                authorization: authorization
            )
        }
    }

    private func activeSnapshot(index: UInt64) throws -> RelayerChainSnapshot {
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(index)
        )
        return try RelayerChainSnapshot.validate([genesis], expectedChainID: chainID)
    }

    private func rotatedSnapshot(from old: UInt64, to new: UInt64) throws -> RelayerChainSnapshot {
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(old)
        )
        let pending = try RelayerChainStateTransition.beginRotation(
            from: try RelayerChainSnapshot.validate([genesis], expectedChainID: chainID),
            candidateKeyRef: keyRef(new)
        )
        let promoted = try RelayerChainStateTransition.promotePending(
            from: try RelayerChainSnapshot.validate(
                [genesis, pending],
                expectedChainID: chainID
            ),
            activatedKeyRef: keyRef(new)
        )
        return try RelayerChainSnapshot.validate(
            [genesis, pending, promoted],
            expectedChainID: chainID
        )
    }

    private func identityMap(indices: [UInt64]) throws -> [String: VerifiedRelayerIdentity] {
        try Dictionary(uniqueKeysWithValues: indices.map { index in
            let identity = try VerifiedRelayerIdentity(
                chainID: chainID,
                keyRef: keyRef(index),
                address: address(index)
            )
            return (identity.keyRef, identity)
        })
    }

    private func status(
        activeIndex: UInt64,
        retiring: [WalletNodeClient.RelayerStatus.KeyHistoryEntry] = [],
        retiringCount: Int? = nil,
        compromiseSubmissionBlocked: Bool = false,
        ownerScope: String = "default",
        networkProfile: String = "sepolia"
    ) -> WalletNodeClient.RelayerStatus {
        WalletNodeClient.RelayerStatus(
            ready: !compromiseSubmissionBlocked,
            keyLoaded: true,
            reason: nil,
            ownerScope: ownerScope,
            chainId: Int(chainID),
            networkProfile: networkProfile,
            eoa: address(activeIndex),
            keyRef: keyRef(activeIndex),
            balance: "0x2386f26fc10000",
            thresholdLow: "0x11c37937e08000",
            needsTopup: false,
            lifecycle: "active",
            compromiseSubmissionBlocked: compromiseSubmissionBlocked,
            pendingFundingAddress: nil,
            pendingFundingCount: 0,
            retiringCount: retiringCount ?? retiring.filter { $0.lifecycle == "retiring" }.count,
            keyHistory: retiring,
            latestAuditEvent: nil,
            replacement: nil
        )
    }

    private func history(
        index: UInt64,
        lifecycle: String,
        addressIndex: UInt64? = nil
    ) -> WalletNodeClient.RelayerStatus.KeyHistoryEntry {
        .init(
            eoa: address(addressIndex ?? index),
            keyRef: keyRef(index),
            lifecycle: lifecycle,
            createdAt: nil,
            retiredAt: nil,
            deletedAt: nil,
            lastExportedAt: nil
        )
    }

    private func keyRef(_ index: UInt64) -> String {
        "bundler-eoa:default:\(chainID):\(index)"
    }

    private func address(_ index: UInt64) -> String {
        "0x" + String(repeating: String(format: "%02x", index & 0xff), count: 20)
    }
}
