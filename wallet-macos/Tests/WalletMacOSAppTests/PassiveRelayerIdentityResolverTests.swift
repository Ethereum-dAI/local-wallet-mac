import Testing
@testable import WalletMacOSApp

@Suite struct PassiveRelayerIdentityResolverTests {
    private let chainID: UInt64 = 11_155_111

    @Test func validatedJournalActiveIdentityBindsExactDaemonStatus() throws {
        let expected = try identity(index: 1)
        let snapshot = try activeSnapshot(index: 1)
        var requestedKeyRefs: [String] = []

        let resolved = try PassiveRelayerIdentityResolver.resolve(
            status: status(index: 1),
            expectedChainID: chainID,
            snapshot: snapshot,
            identityForKeyRef: { keyRef in
                requestedKeyRefs.append(keyRef)
                return keyRef == expected.keyRef ? expected : nil
            }
        )

        #expect(resolved == expected)
        #expect(requestedKeyRefs == [expected.keyRef])
    }

    @Test func missingJournalRequiresMigrationWithoutReadingPublicIdentity() throws {
        var identityReadCount = 0

        #expect(throws: PassiveRelayerIdentityResolver.Failure.migrationRequired(
            chainID: chainID
        )) {
            _ = try PassiveRelayerIdentityResolver.resolve(
                status: status(index: 1),
                expectedChainID: chainID,
                snapshot: nil,
                identityForKeyRef: { _ in
                    identityReadCount += 1
                    return nil
                }
            )
        }
        #expect(identityReadCount == 0)
    }

    @Test func daemonCannotSelectAnUnjournaledPublicIdentity() throws {
        let active = try identity(index: 1)
        let unjournaled = try identity(index: 2)

        #expect(throws: RelayerIdentityAuthority.Failure.unauthorizedKeyRef(
            unjournaled.keyRef
        )) {
            _ = try PassiveRelayerIdentityResolver.resolve(
                status: status(index: 2),
                expectedChainID: chainID,
                snapshot: try activeSnapshot(index: 1),
                identityForKeyRef: { keyRef in
                    [active.keyRef: active, unjournaled.keyRef: unjournaled][keyRef]
                }
            )
        }
    }

    @Test func pendingCandidateIsNotPublishedAsTheActiveDashboardIdentity() throws {
        let active = try identity(index: 1)
        let pending = try identity(index: 2)
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: active.keyRef
        )
        let pendingTransition = try RelayerChainStateTransition.beginRotation(
            from: try RelayerChainSnapshot.validate([genesis], expectedChainID: chainID),
            candidateKeyRef: pending.keyRef
        )
        let snapshot = try RelayerChainSnapshot.validate(
            [genesis, pendingTransition],
            expectedChainID: chainID
        )

        #expect(throws: PassiveRelayerIdentityResolver.Failure.inactiveJournalIdentity(
            pending.keyRef
        )) {
            _ = try PassiveRelayerIdentityResolver.resolve(
                status: status(index: 2, lifecycle: "pending_funding"),
                expectedChainID: chainID,
                snapshot: snapshot,
                identityForKeyRef: { keyRef in
                    [active.keyRef: active, pending.keyRef: pending][keyRef]
                }
            )
        }
    }

    @Test func compromisedOrIncoherentActiveStatusFailsClosed() throws {
        let expected = try identity(index: 1)

        #expect(throws: RelayerIdentityBindingPolicy.Failure.compromiseSuspected) {
            _ = try PassiveRelayerIdentityResolver.resolve(
                status: status(index: 1, compromiseSubmissionBlocked: true),
                expectedChainID: chainID,
                snapshot: try activeSnapshot(index: 1),
                identityForKeyRef: { _ in expected }
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

    private func identity(index: UInt64) throws -> VerifiedRelayerIdentity {
        try VerifiedRelayerIdentity(
            chainID: chainID,
            keyRef: keyRef(index),
            address: address(index)
        )
    }

    private func keyRef(_ index: UInt64) -> String {
        "bundler-eoa:default:\(chainID):\(index)"
    }

    private func address(_ index: UInt64) -> String {
        "0x" + String(repeating: String(format: "%02x", index & 0xff), count: 20)
    }

    private func status(
        index: UInt64,
        lifecycle: String = "active",
        compromiseSubmissionBlocked: Bool = false
    ) -> WalletNodeClient.RelayerStatus {
        WalletNodeClient.RelayerStatus(
            ready: !compromiseSubmissionBlocked && lifecycle == "active",
            keyLoaded: true,
            reason: nil,
            ownerScope: "default",
            chainId: Int(chainID),
            networkProfile: "sepolia",
            eoa: address(index),
            keyRef: keyRef(index),
            balance: "0x2386f26fc10000",
            thresholdLow: "0x11c37937e08000",
            needsTopup: false,
            lifecycle: lifecycle,
            compromiseSubmissionBlocked: compromiseSubmissionBlocked,
            pendingFundingAddress: lifecycle == "pending_funding" ? address(index) : nil,
            pendingFundingCount: lifecycle == "pending_funding" ? 1 : 0,
            retiringCount: 0,
            keyHistory: [],
            latestAuditEvent: nil,
            replacement: nil
        )
    }
}
