import Testing
@testable import WalletMacOSApp

@Suite struct RelayerTargetedDeletionPolicyTests {
    private let chainID: UInt64 = 11_155_111

    @Test func exactHistoricalRetiredIdentityIsAuthorizedSecretBeforePublic() throws {
        let snapshot = try promotedSnapshot()
        let retiredIdentity = try identity(1)
        var requestedKeyRefs: [String] = []

        let authorization = try RelayerTargetedDeletionPolicy.authorizeIndividualDeletion(
            snapshot: snapshot,
            daemonClaim: claim(index: 1, lifecycle: "retired"),
            unsafeReset: false,
            identityForKeyRef: { keyRef in
                requestedKeyRefs.append(keyRef)
                return retiredIdentity
            }
        )

        #expect(authorization.identity == retiredIdentity)
        #expect(authorization.daemonDeletionPhase == .required)
        #expect(authorization.requiredLocalDeletionOrder == [
            .protectedSecret,
            .publicIdentity,
        ])
        #expect(requestedKeyRefs == [keyRef(1)])
    }

    @Test func activeIdentityIsProtectedEvenWhenUnsafeResetIsRequested() throws {
        let snapshot = try promotedSnapshot()
        var publicReadCount = 0

        for unsafeReset in [false, true] {
            #expect(throws: RelayerTargetedDeletionPolicy.Failure.activeIdentityProtected(
                keyRef(2)
            )) {
                _ = try RelayerTargetedDeletionPolicy.authorizeIndividualDeletion(
                    snapshot: snapshot,
                    daemonClaim: claim(index: 2, lifecycle: "retired"),
                    unsafeReset: unsafeReset,
                    identityForKeyRef: { _ in
                        publicReadCount += 1
                        return nil
                    }
                )
            }
        }
        #expect(publicReadCount == 0)
    }

    @Test func pendingIdentityIsProtectedEvenWhenUnsafeResetIsRequested() throws {
        let snapshot = try pendingSnapshot()
        var publicReadCount = 0

        for unsafeReset in [false, true] {
            #expect(throws: RelayerTargetedDeletionPolicy.Failure.pendingIdentityProtected(
                keyRef(2)
            )) {
                _ = try RelayerTargetedDeletionPolicy.authorizeIndividualDeletion(
                    snapshot: snapshot,
                    daemonClaim: claim(index: 2, lifecycle: "retired"),
                    unsafeReset: unsafeReset,
                    identityForKeyRef: { _ in
                        publicReadCount += 1
                        return nil
                    }
                )
            }
        }
        #expect(publicReadCount == 0)
    }

    @Test func retiringIdentityIsBlockedWhileLiveWorkMayExist() throws {
        #expect(throws: RelayerTargetedDeletionPolicy.Failure.retiringIdentityMayHaveLiveWork(
            keyRef(1)
        )) {
            _ = try RelayerTargetedDeletionPolicy.authorizeIndividualDeletion(
                snapshot: promotedSnapshot(),
                daemonClaim: claim(index: 1, lifecycle: "retiring"),
                unsafeReset: true,
                identityForKeyRef: { _ in try identity(1) }
            )
        }
    }

    @Test func exactDeletedHistoricalIdentityCanResumeLocalCleanupAfterACrash() throws {
        let snapshot = try promotedSnapshot()
        let deletedIdentity = try identity(1)

        let authorization = try RelayerTargetedDeletionPolicy.authorizeIndividualDeletion(
            snapshot: snapshot,
            daemonClaim: claim(index: 1, lifecycle: "deleted"),
            unsafeReset: false,
            identityForKeyRef: { _ in deletedIdentity }
        )
        #expect(authorization.identity == deletedIdentity)
        #expect(authorization.daemonDeletionPhase == .alreadyCompleted)
        #expect(authorization.requiredLocalDeletionOrder == [
            .protectedSecret,
            .publicIdentity,
        ])
    }

    @Test func arbitraryLifecycleClaimsStillFailClosed() throws {
        let snapshot = try promotedSnapshot()

        #expect(throws: RelayerTargetedDeletionPolicy.Failure.lifecycleNotRetired(
            "pending_funding"
        )) {
            _ = try RelayerTargetedDeletionPolicy.authorizeIndividualDeletion(
                snapshot: snapshot,
                daemonClaim: claim(index: 1, lifecycle: "pending_funding"),
                unsafeReset: false,
                identityForKeyRef: { _ in try identity(1) }
            )
        }
    }

    @Test func nonHistoricalIdentityFailsBeforePublicLookup() throws {
        var publicReadCount = 0

        #expect(throws: RelayerTargetedDeletionPolicy.Failure.nonHistoricalIdentity(
            keyRef(3)
        )) {
            _ = try RelayerTargetedDeletionPolicy.authorizeIndividualDeletion(
                snapshot: promotedSnapshot(),
                daemonClaim: claim(index: 3, lifecycle: "retired"),
                unsafeReset: false,
                identityForKeyRef: { _ in
                    publicReadCount += 1
                    return try identity(3)
                }
            )
        }
        #expect(publicReadCount == 0)
    }

    @Test func wrongClaimChainFailsBeforePublicLookup() throws {
        var publicReadCount = 0
        let wrongChain = chainID + 1
        let daemonClaim = RelayerIdentityAuthority.Claim(
            chainID: wrongChain,
            keyRef: keyRef(1),
            address: address(1),
            lifecycle: "retired"
        )

        #expect(throws: RelayerTargetedDeletionPolicy.Failure.wrongClaimChain(
            expected: chainID,
            actual: wrongChain
        )) {
            _ = try RelayerTargetedDeletionPolicy.authorizeIndividualDeletion(
                snapshot: promotedSnapshot(),
                daemonClaim: daemonClaim,
                unsafeReset: false,
                identityForKeyRef: { _ in
                    publicReadCount += 1
                    return try identity(1)
                }
            )
        }
        #expect(publicReadCount == 0)
    }

    @Test func missingAndMismatchedPublicIdentityFailClosed() throws {
        let snapshot = try promotedSnapshot()

        #expect(throws: RelayerTargetedDeletionPolicy.Failure.missingPublicIdentity(
            keyRef(1)
        )) {
            _ = try RelayerTargetedDeletionPolicy.authorizeIndividualDeletion(
                snapshot: snapshot,
                daemonClaim: claim(index: 1, lifecycle: "retired"),
                unsafeReset: false,
                identityForKeyRef: { _ in nil }
            )
        }

        #expect(throws: RelayerTargetedDeletionPolicy.Failure.publicIdentityKeyRefMismatch(
            expected: keyRef(1),
            actual: keyRef(2)
        )) {
            _ = try RelayerTargetedDeletionPolicy.authorizeIndividualDeletion(
                snapshot: snapshot,
                daemonClaim: claim(index: 1, lifecycle: "retired"),
                unsafeReset: false,
                identityForKeyRef: { _ in try identity(2) }
            )
        }
    }

    @Test func invalidAndWrongDaemonAddressesFailClosed() throws {
        let snapshot = try promotedSnapshot()

        #expect(throws: RelayerTargetedDeletionPolicy.Failure.invalidClaimAddress(
            "not-an-address"
        )) {
            _ = try RelayerTargetedDeletionPolicy.authorizeIndividualDeletion(
                snapshot: snapshot,
                daemonClaim: RelayerIdentityAuthority.Claim(
                    chainID: chainID,
                    keyRef: keyRef(1),
                    address: "not-an-address",
                    lifecycle: "retired"
                ),
                unsafeReset: false,
                identityForKeyRef: { _ in try identity(1) }
            )
        }

        #expect(throws: RelayerTargetedDeletionPolicy.Failure.wrongClaimAddress(
            expected: address(1),
            actual: address(3)
        )) {
            _ = try RelayerTargetedDeletionPolicy.authorizeIndividualDeletion(
                snapshot: snapshot,
                daemonClaim: claim(index: 1, addressIndex: 3, lifecycle: "retired"),
                unsafeReset: false,
                identityForKeyRef: { _ in try identity(1) }
            )
        }
    }

    private func promotedSnapshot() throws -> RelayerChainSnapshot {
        let genesis = try genesisState()
        let pending = try RelayerChainStateTransition.beginRotation(
            from: snapshot([genesis]),
            candidateKeyRef: keyRef(2)
        )
        let promoted = try RelayerChainStateTransition.promotePending(
            from: snapshot([genesis, pending]),
            activatedKeyRef: keyRef(2)
        )
        return try snapshot([genesis, pending, promoted])
    }

    private func pendingSnapshot() throws -> RelayerChainSnapshot {
        let genesis = try genesisState()
        let pending = try RelayerChainStateTransition.beginRotation(
            from: snapshot([genesis]),
            candidateKeyRef: keyRef(2)
        )
        return try snapshot([genesis, pending])
    }

    private func genesisState() throws -> RelayerChainState {
        try RelayerChainStateTransition.genesis(chainID: chainID, activeKeyRef: keyRef(1))
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

    private func claim(
        index: UInt64,
        addressIndex: UInt64? = nil,
        lifecycle: String
    ) -> RelayerIdentityAuthority.Claim {
        .init(
            chainID: chainID,
            keyRef: keyRef(index),
            address: address(addressIndex ?? index),
            lifecycle: lifecycle
        )
    }
}
