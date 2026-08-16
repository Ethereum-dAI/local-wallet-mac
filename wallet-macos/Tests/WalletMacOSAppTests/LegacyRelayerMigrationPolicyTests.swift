import Foundation
import Testing
@testable import WalletMacOSApp

@Suite struct LegacyRelayerMigrationPolicyTests {
    private let chainID: UInt64 = 11_155_111

    @Test func coherentActiveDaemonIdentityWithoutJournalIsEligible() throws {
        let status = status()
        let expected = try identity()
        var requestedKeyRefs: [String] = []

        let candidate = try LegacyRelayerMigrationPolicy.candidate(
            status: status,
            expectedChainID: chainID,
            expectedOwnerScope: "default",
            expectedNetworkProfile: "sepolia",
            snapshot: nil,
            identityForKeyRef: { keyRef in
                requestedKeyRefs.append(keyRef)
                return nil
            }
        )

        #expect(candidate?.identity == expected)
        #expect(requestedKeyRefs == [keyRef()])
    }

    @Test func exactExistingPublicIdentityIsEligible() throws {
        let expected = try identity()

        let candidate = try LegacyRelayerMigrationPolicy.candidate(
            status: status(),
            expectedChainID: chainID,
            expectedOwnerScope: "default",
            expectedNetworkProfile: "sepolia",
            snapshot: nil,
            identityForKeyRef: { _ in expected }
        )

        #expect(candidate?.identity == expected)
    }

    @Test func coherentLockedActiveDaemonIdentityIsEligibleForExplicitVerification() throws {
        let expected = try identity()
        let candidate = try LegacyRelayerMigrationPolicy.candidate(
            status: status(
                ready: false,
                keyLoaded: false,
                reason: "bundler_eoa_locked"
            ),
            expectedChainID: chainID,
            expectedOwnerScope: "default",
            expectedNetworkProfile: "sepolia",
            snapshot: nil,
            identityForKeyRef: { _ in nil }
        )

        #expect(candidate?.identity == expected)
    }

    @Test func anyExistingJournalDisablesLegacyMigrationWithoutPublicLookup() throws {
        let snapshot = try RelayerChainSnapshot.validate(
            [RelayerChainStateTransition.genesis(
                chainID: chainID,
                activeKeyRef: keyRef()
            )],
            expectedChainID: chainID
        )
        var publicLookupCount = 0

        let candidate = try LegacyRelayerMigrationPolicy.candidate(
            status: status(),
            expectedChainID: chainID,
            expectedOwnerScope: "default",
            expectedNetworkProfile: "sepolia",
            snapshot: snapshot,
            identityForKeyRef: { _ in
                publicLookupCount += 1
                return nil
            }
        )

        #expect(candidate == nil)
        #expect(publicLookupCount == 0)
    }

    @Test(arguments: [
        InvalidDaemonCase.wrongChain,
        .missingKeyRef,
        .keyRefForWrongChain,
        .keyRefWithLeadingZeroChain,
        .keyRefWithLeadingZeroIndex,
        .keyRefWithZeroChain,
        .keyRefWithZeroIndex,
        .malformedAddress,
        .inactiveLifecycle,
        .compromiseBlocked,
        .incoherentReadyState,
        .wrongOwnerScope,
        .wrongNetworkProfile,
        .keyRefForWrongOwnerScope,
        .pendingFunding,
        .retiringIdentity,
        .missingHistory,
        .mismatchedHistory,
        .extraHistory,
        .missingReplacement,
        .unresolvedReplacement,
    ])
    func invalidDaemonObservationsAreNotCandidates(testCase: InvalidDaemonCase) throws {
        var publicLookupCount = 0

        let candidate = try LegacyRelayerMigrationPolicy.candidate(
            status: testCase.status(from: self),
            expectedChainID: chainID,
            expectedOwnerScope: "default",
            expectedNetworkProfile: "sepolia",
            snapshot: nil,
            identityForKeyRef: { _ in
                publicLookupCount += 1
                return nil
            }
        )

        #expect(candidate == nil)
        #expect(publicLookupCount == 0)
    }

    @Test func conflictingPublicIdentityDisablesMigration() throws {
        let conflicting = try VerifiedRelayerIdentity(
            chainID: chainID,
            keyRef: keyRef(),
            address: address(byte: 2)
        )

        let candidate = try LegacyRelayerMigrationPolicy.candidate(
            status: status(),
            expectedChainID: chainID,
            expectedOwnerScope: "default",
            expectedNetworkProfile: "sepolia",
            snapshot: nil,
            identityForKeyRef: { _ in conflicting }
        )

        #expect(candidate == nil)
    }

    @Test func malformedPublicRecordErrorFailsClosed() {
        enum MalformedPublicRecord: Error, Equatable { case rejected }

        #expect(throws: MalformedPublicRecord.rejected) {
            _ = try LegacyRelayerMigrationPolicy.candidate(
                status: status(),
                expectedChainID: chainID,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia",
                snapshot: nil,
                identityForKeyRef: { _ in throw MalformedPublicRecord.rejected }
            )
        }
    }

    @Test(arguments: [false, true])
    func legacyVerificationOutranksExternalFundingRequirement(
        forceExternalFunding: Bool
    ) throws {
        let candidate = LegacyRelayerMigrationCandidate(identity: try identity())

        #expect(BundlerAccountActionPolicy.route(
            authority: .legacyVerification(candidate),
            forceExternalFunding: forceExternalFunding
        ) == .verifyLegacyRelayer(candidate))
    }

    @Test(arguments: [false, true])
    func unavailableAuthorityNeverExposesFunding(forceExternalFunding: Bool) {
        #expect(BundlerAccountActionPolicy.route(
            authority: .unavailable,
            forceExternalFunding: forceExternalFunding
        ) == .retryStatus)
    }

    @Test func verifiedAuthorityPreservesExistingFundingRoutes() {
        #expect(BundlerAccountActionPolicy.route(
            authority: .verified(.healthy(
                balanceWeiHex: BundlerFundingPolicy.recommendedBalanceWeiHex
            )),
            forceExternalFunding: false
        ) == .prefillTopUp)
        #expect(BundlerAccountActionPolicy.route(
            authority: .verified(.externalRequired(balanceWeiHex: "0x0")),
            forceExternalFunding: false
        ) == .externalFunding)
        #expect(BundlerAccountActionPolicy.route(
            authority: .verified(.checking),
            forceExternalFunding: false
        ) == .retryStatus)
        #expect(BundlerAccountActionPolicy.route(
            authority: .verified(.healthy(
                balanceWeiHex: BundlerFundingPolicy.recommendedBalanceWeiHex
            )),
            forceExternalFunding: true
        ) == .externalFunding)
    }

    private func identity() throws -> VerifiedRelayerIdentity {
        try VerifiedRelayerIdentity(
            chainID: chainID,
            keyRef: keyRef(),
            address: address()
        )
    }

    private func keyRef(chainID: UInt64? = nil) -> String {
        "bundler-eoa:default:\(chainID ?? self.chainID):1"
    }

    private func address(byte: UInt8 = 1) -> String {
        "0x" + String(repeating: String(format: "%02x", byte), count: 20)
    }

    private func status(
        chainID: UInt64? = nil,
        eoa: String? = nil,
        keyRef: String? = nil,
        includeKeyRef: Bool = true,
        ready: Bool = true,
        keyLoaded: Bool = true,
        reason: String? = nil,
        needsTopup: Bool = false,
        lifecycle: String = "active",
        compromiseSubmissionBlocked: Bool = false,
        ownerScope: String = "default",
        networkProfile: String = "sepolia",
        pendingFundingCount: Int = 0,
        retiringCount: Int = 0,
        keyHistory: [WalletNodeClient.RelayerStatus.KeyHistoryEntry]? = nil,
        replacement: WalletNodeClient.RelayerStatus.ReplacementStatus? = .init(
            eligible: false,
            blocked: false,
            blockedReason: nil,
            txHash: nil,
            userOpHash: nil,
            nonce: nil
        )
    ) -> WalletNodeClient.RelayerStatus {
        let actualChainID = chainID ?? self.chainID
        let actualEOA = eoa ?? address()
        let actualKeyRef = keyRef ?? self.keyRef(chainID: actualChainID)
        let actualHistory = keyHistory ?? [
            WalletNodeClient.RelayerStatus.KeyHistoryEntry(
                eoa: actualEOA,
                keyRef: actualKeyRef,
                lifecycle: lifecycle,
                createdAt: 1,
                retiredAt: nil,
                deletedAt: nil,
                lastExportedAt: nil
            )
        ]
        return WalletNodeClient.RelayerStatus(
            ready: ready,
            keyLoaded: keyLoaded,
            reason: reason,
            ownerScope: ownerScope,
            chainId: Int(actualChainID),
            networkProfile: networkProfile,
            eoa: actualEOA,
            keyRef: includeKeyRef ? actualKeyRef : nil,
            balance: BundlerFundingPolicy.recommendedBalanceWeiHex,
            thresholdLow: BundlerFundingPolicy.minimumBalanceWeiHex,
            needsTopup: needsTopup,
            lifecycle: lifecycle,
            compromiseSubmissionBlocked: compromiseSubmissionBlocked,
            pendingFundingAddress: pendingFundingCount > 0 ? address(byte: 9) : nil,
            pendingFundingCount: pendingFundingCount,
            retiringCount: retiringCount,
            keyHistory: actualHistory,
            latestAuditEvent: nil,
            replacement: replacement
        )
    }

    enum InvalidDaemonCase: CaseIterable, Sendable {
        case wrongChain
        case missingKeyRef
        case keyRefForWrongChain
        case keyRefWithLeadingZeroChain
        case keyRefWithLeadingZeroIndex
        case keyRefWithZeroChain
        case keyRefWithZeroIndex
        case malformedAddress
        case inactiveLifecycle
        case compromiseBlocked
        case incoherentReadyState
        case wrongOwnerScope
        case wrongNetworkProfile
        case keyRefForWrongOwnerScope
        case pendingFunding
        case retiringIdentity
        case missingHistory
        case mismatchedHistory
        case extraHistory
        case missingReplacement
        case unresolvedReplacement

        func status(from suite: LegacyRelayerMigrationPolicyTests) -> WalletNodeClient.RelayerStatus {
            switch self {
            case .wrongChain:
                return suite.status(chainID: 1)
            case .missingKeyRef:
                return suite.status(includeKeyRef: false)
            case .keyRefForWrongChain:
                return suite.status(keyRef: suite.keyRef(chainID: 1))
            case .keyRefWithLeadingZeroChain:
                return suite.status(
                    keyRef: "bundler-eoa:default:011155111:1"
                )
            case .keyRefWithLeadingZeroIndex:
                return suite.status(
                    keyRef: "bundler-eoa:default:\(suite.chainID):01"
                )
            case .keyRefWithZeroChain:
                return suite.status(keyRef: "bundler-eoa:default:0:1")
            case .keyRefWithZeroIndex:
                return suite.status(
                    keyRef: "bundler-eoa:default:\(suite.chainID):0"
                )
            case .malformedAddress:
                return suite.status(eoa: "0x1234")
            case .inactiveLifecycle:
                return suite.status(lifecycle: "retiring")
            case .compromiseBlocked:
                return suite.status(compromiseSubmissionBlocked: true)
            case .incoherentReadyState:
                return suite.status(ready: true, needsTopup: true)
            case .wrongOwnerScope:
                return suite.status(ownerScope: "other")
            case .wrongNetworkProfile:
                return suite.status(networkProfile: "mainnet")
            case .keyRefForWrongOwnerScope:
                return suite.status(
                    keyRef: "bundler-eoa:other:\(suite.chainID):1"
                )
            case .pendingFunding:
                return suite.status(pendingFundingCount: 1)
            case .retiringIdentity:
                return suite.status(retiringCount: 1)
            case .missingHistory:
                return suite.status(keyHistory: [])
            case .mismatchedHistory:
                return suite.status(keyHistory: [
                    WalletNodeClient.RelayerStatus.KeyHistoryEntry(
                        eoa: suite.address(byte: 2),
                        keyRef: suite.keyRef(),
                        lifecycle: "active",
                        createdAt: 1,
                        retiredAt: nil,
                        deletedAt: nil,
                        lastExportedAt: nil
                    )
                ])
            case .extraHistory:
                return suite.status(keyHistory: [
                    WalletNodeClient.RelayerStatus.KeyHistoryEntry(
                        eoa: suite.address(),
                        keyRef: suite.keyRef(),
                        lifecycle: "active",
                        createdAt: 1,
                        retiredAt: nil,
                        deletedAt: nil,
                        lastExportedAt: nil
                    ),
                    WalletNodeClient.RelayerStatus.KeyHistoryEntry(
                        eoa: suite.address(byte: 2),
                        keyRef: "bundler-eoa:default:\(suite.chainID):2",
                        lifecycle: "retired",
                        createdAt: 2,
                        retiredAt: 3,
                        deletedAt: nil,
                        lastExportedAt: nil
                    )
                ])
            case .missingReplacement:
                return suite.status(replacement: nil)
            case .unresolvedReplacement:
                return suite.status(replacement: .init(
                    eligible: true,
                    blocked: false,
                    blockedReason: nil,
                    txHash: "0x01",
                    userOpHash: "0x02",
                    nonce: 1
                ))
            }
        }
    }
}
