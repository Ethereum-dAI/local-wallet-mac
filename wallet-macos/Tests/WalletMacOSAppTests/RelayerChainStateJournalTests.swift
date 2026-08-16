import Foundation
import LocalAuthentication
import Security
import Testing
@testable import WalletMacOSApp

private final class JournalSecurityItemClient: SecurityItemClient, @unchecked Sendable {
    struct Response {
        let status: OSStatus
        let result: Any?
    }

    var addResponses: [Response]
    var copyResponses: [Response]
    var deleteStatuses: [OSStatus]
    private(set) var additions: [[String: Any]] = []
    private(set) var copies: [[String: Any]] = []
    private(set) var copyInteractionNotAllowed: [Bool] = []
    private(set) var deletions: [[String: Any]] = []

    init(
        addResponses: [Response] = [],
        copyResponses: [Response] = [],
        deleteStatuses: [OSStatus] = []
    ) {
        self.addResponses = addResponses
        self.copyResponses = copyResponses
        self.deleteStatuses = deleteStatuses
    }

    func add(_ attributes: [String: Any]) -> (status: OSStatus, result: Any?) {
        additions.append(attributes)
        let response = addResponses.isEmpty
            ? Response(status: errSecSuccess, result: nil)
            : addResponses.removeFirst()
        return (response.status, response.result)
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: Any?) {
        copies.append(query)
        copyInteractionNotAllowed.append(
            (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed
                ?? false
        )
        let response = copyResponses.isEmpty
            ? Response(status: errSecItemNotFound, result: nil)
            : copyResponses.removeFirst()
        return (response.status, response.result)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        deletions.append(query)
        return deleteStatuses.isEmpty ? errSecSuccess : deleteStatuses.removeFirst()
    }
}

@Suite struct RelayerChainStateJournalTests {
    private let chainID: UInt64 = 11_155_111

    @Test func genesisHasCanonicalEncodingAndStableDigest() throws {
        let state = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(1)
        )

        let expected = """
        {"activeKeyRef":"bundler-eoa:default:11155111:1","chainID":11155111,"epoch":0,"pendingKeyRef":null,"previousDigest":"0000000000000000000000000000000000000000000000000000000000000000","version":1}
        """
        #expect(String(decoding: try state.canonicalEncoding(), as: UTF8.self) == expected)
        #expect(try state.digestHex() == "0aa0a568248432834f38066ab3806034e32df7d706c474c02f72f01eea4f30d8")
        #expect(try RelayerChainState.decodeCanonical(Data(expected.utf8)) == state)
    }

    @Test func canonicalDecoderRejectsEquivalentButNonCanonicalJSON() throws {
        let nonCanonical = """
        { "version": 1, "chainID": 11155111, "epoch": 0, "previousDigest": "0000000000000000000000000000000000000000000000000000000000000000", "activeKeyRef": "bundler-eoa:default:11155111:1", "pendingKeyRef": null }
        """

        #expect(throws: RelayerChainState.ValidationError.nonCanonicalEncoding) {
            try RelayerChainState.decodeCanonical(Data(nonCanonical.utf8))
        }
    }

    @Test func stateRejectsInvalidHeadReferences() throws {
        #expect(throws: RelayerChainState.ValidationError.activeAndPendingMatch(keyRef(1))) {
            try RelayerChainState(
                chainID: chainID,
                epoch: 1,
                previousDigest: Data(repeating: 0x11, count: 32),
                activeKeyRef: keyRef(1),
                pendingKeyRef: keyRef(1)
            )
        }
        #expect(throws: RelayerChainState.ValidationError.pendingWithoutActive(keyRef(2))) {
            try RelayerChainState(
                chainID: chainID,
                epoch: 1,
                previousDigest: Data(repeating: 0x11, count: 32),
                activeKeyRef: nil,
                pendingKeyRef: keyRef(2)
            )
        }
        #expect(throws: RelayerChainState.ValidationError.keyRefChainMismatch(
            expected: chainID,
            actual: 1,
            keyRef: "bundler-eoa:default:1:1"
        )) {
            try RelayerChainState(
                chainID: chainID,
                epoch: 1,
                previousDigest: Data(repeating: 0x11, count: 32),
                activeKeyRef: "bundler-eoa:default:1:1",
                pendingKeyRef: nil
            )
        }
    }

    @Test func journalRejectsNoncanonicalOrWrongScopeKeyReferences() {
        let invalidKeyRefs = [
            "bundler-eoa:default:011155111:1",
            "bundler-eoa:default:11155111:01",
            "bundler-eoa:default:0:1",
            "bundler-eoa:default:11155111:0",
            "bundler-eoa:other:11155111:1",
        ]

        for invalidKeyRef in invalidKeyRefs {
            #expect(throws: RelayerChainState.ValidationError.invalidKeyRef(
                invalidKeyRef
            )) {
                try RelayerChainState(
                    chainID: chainID,
                    epoch: 0,
                    previousDigest: RelayerChainState.zeroDigest,
                    activeKeyRef: invalidKeyRef,
                    pendingKeyRef: nil
                )
            }
        }
    }

    @Test func canonicalDecoderRejectsLeadingZeroKeyReferenceAliases() {
        for invalidKeyRef in [
            "bundler-eoa:default:011155111:1",
            "bundler-eoa:default:11155111:01",
            "bundler-eoa:default:0:1",
            "bundler-eoa:default:11155111:0",
        ] {
            let encoded = """
            {"activeKeyRef":"\(invalidKeyRef)","chainID":11155111,"epoch":0,"pendingKeyRef":null,"previousDigest":"0000000000000000000000000000000000000000000000000000000000000000","version":1}
            """
            #expect(throws: RelayerChainState.ValidationError.invalidKeyRef(
                invalidKeyRef
            )) {
                try RelayerChainState.decodeCanonical(Data(encoded.utf8))
            }
        }
    }

    @Test func snapshotRequiresAContiguousDigestLinkedSequence() throws {
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(1)
        )
        let pending = try RelayerChainStateTransition.beginRotation(
            from: try RelayerChainSnapshot.validate([genesis], expectedChainID: chainID),
            candidateKeyRef: keyRef(2)
        )
        let promoted = try RelayerChainStateTransition.promotePending(
            from: try RelayerChainSnapshot.validate([genesis, pending], expectedChainID: chainID),
            activatedKeyRef: keyRef(2)
        )

        let snapshot = try RelayerChainSnapshot.validate(
            [promoted, genesis, pending],
            expectedChainID: chainID
        )
        #expect(snapshot.states == [genesis, pending, promoted])
        #expect(snapshot.head == promoted)

        let broken = try RelayerChainState(
            chainID: chainID,
            epoch: 1,
            previousDigest: Data(repeating: 0x99, count: 32),
            activeKeyRef: keyRef(1),
            pendingKeyRef: keyRef(2)
        )
        #expect(throws: RelayerChainSnapshot.ValidationError.brokenPreviousDigest(epoch: 1)) {
            try RelayerChainSnapshot.validate([genesis, broken], expectedChainID: chainID)
        }
    }

    @Test func snapshotRejectsGapsWrongChainsDuplicatesAndForks() throws {
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(1)
        )
        let epochTwo = try RelayerChainState(
            chainID: chainID,
            epoch: 2,
            previousDigest: try genesis.digest(),
            activeKeyRef: keyRef(1),
            pendingKeyRef: keyRef(2)
        )
        #expect(throws: RelayerChainSnapshot.ValidationError.epochGap(expected: 1, actual: 2)) {
            try RelayerChainSnapshot.validate([genesis, epochTwo], expectedChainID: chainID)
        }

        #expect(throws: RelayerChainSnapshot.ValidationError.duplicateEpoch(0)) {
            try RelayerChainSnapshot.validate([genesis, genesis], expectedChainID: chainID)
        }

        let fork = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(2)
        )
        #expect(throws: RelayerChainSnapshot.ValidationError.forkedEpoch(0)) {
            try RelayerChainSnapshot.validate([genesis, fork], expectedChainID: chainID)
        }

        let otherChain = try RelayerChainStateTransition.genesis(
            chainID: 1,
            activeKeyRef: "bundler-eoa:default:1:1"
        )
        #expect(throws: RelayerChainSnapshot.ValidationError.wrongChain(
            expected: chainID,
            actual: 1,
            epoch: 0
        )) {
            try RelayerChainSnapshot.validate([otherChain], expectedChainID: chainID)
        }
    }

    @Test func aSecondPendingCandidateIsRejected() throws {
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(1)
        )
        let pending = try RelayerChainStateTransition.beginRotation(
            from: try RelayerChainSnapshot.validate([genesis], expectedChainID: chainID),
            candidateKeyRef: keyRef(2)
        )
        let snapshot = try RelayerChainSnapshot.validate([genesis, pending], expectedChainID: chainID)

        #expect(throws: RelayerChainStateTransition.Failure.pendingCandidateExists(keyRef(2))) {
            try RelayerChainStateTransition.beginRotation(
                from: snapshot,
                candidateKeyRef: keyRef(3)
            )
        }
    }

    @Test func promotionMustNameTheExactPendingCandidate() throws {
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(1)
        )
        let pending = try RelayerChainStateTransition.beginRotation(
            from: try RelayerChainSnapshot.validate([genesis], expectedChainID: chainID),
            candidateKeyRef: keyRef(2)
        )
        let snapshot = try RelayerChainSnapshot.validate([genesis, pending], expectedChainID: chainID)

        #expect(throws: RelayerChainStateTransition.Failure.unexpectedPendingCandidate(
            expected: keyRef(2),
            actual: keyRef(3)
        )) {
            try RelayerChainStateTransition.promotePending(
                from: snapshot,
                activatedKeyRef: keyRef(3)
            )
        }

        let promoted = try RelayerChainStateTransition.promotePending(
            from: snapshot,
            activatedKeyRef: keyRef(2)
        )
        #expect(promoted.activeKeyRef == keyRef(2))
        #expect(promoted.pendingKeyRef == nil)
        #expect(promoted.epoch == 2)
        #expect(promoted.previousDigest == (try pending.digest()))
    }

    @Test func historicalKeysCannotBeRevivedAfterPromotionOrTombstone() throws {
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(1)
        )
        let pending = try RelayerChainStateTransition.beginRotation(
            from: try RelayerChainSnapshot.validate([genesis], expectedChainID: chainID),
            candidateKeyRef: keyRef(2)
        )
        let promoted = try RelayerChainStateTransition.promotePending(
            from: try RelayerChainSnapshot.validate([genesis, pending], expectedChainID: chainID),
            activatedKeyRef: keyRef(2)
        )
        let promotedSnapshot = try RelayerChainSnapshot.validate(
            [genesis, pending, promoted],
            expectedChainID: chainID
        )

        #expect(throws: RelayerChainStateTransition.Failure.historicalKeyRevival(keyRef(1))) {
            try RelayerChainStateTransition.beginRotation(
                from: promotedSnapshot,
                candidateKeyRef: keyRef(1)
            )
        }

        let tombstone = try RelayerChainStateTransition.tombstone(
            from: promotedSnapshot,
            expectedActiveKeyRef: keyRef(2)
        )
        let emptySnapshot = try RelayerChainSnapshot.validate(
            [genesis, pending, promoted, tombstone],
            expectedChainID: chainID
        )
        #expect(emptySnapshot.head.activeKeyRef == nil)
        #expect(emptySnapshot.head.pendingKeyRef == nil)
        #expect(throws: RelayerChainStateTransition.Failure.historicalKeyRevival(keyRef(1))) {
            try RelayerChainStateTransition.activateReplacement(
                from: emptySnapshot,
                keyRef: keyRef(1)
            )
        }
    }

    @Test func exactConcurrentAppendIsIdempotentButConflictFailsClosed() throws {
        let proposed = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(1)
        )
        #expect(try RelayerChainStateAppendPolicy.resolveConcurrentAppend(
            proposed: proposed,
            stored: proposed
        ) == proposed)

        let conflict = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(2)
        )
        #expect(throws: RelayerChainStateAppendPolicy.Failure.conflictingAppend(
            chainID: chainID,
            epoch: 0
        )) {
            try RelayerChainStateAppendPolicy.resolveConcurrentAppend(
                proposed: proposed,
                stored: conflict
            )
        }
    }

    @Test func snapshotValidationRejectsAWellHashedHistoricalRevival() throws {
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(1)
        )
        let pending = try RelayerChainStateTransition.beginRotation(
            from: try RelayerChainSnapshot.validate([genesis], expectedChainID: chainID),
            candidateKeyRef: keyRef(2)
        )
        let promoted = try RelayerChainStateTransition.promotePending(
            from: try RelayerChainSnapshot.validate([genesis, pending], expectedChainID: chainID),
            activatedKeyRef: keyRef(2)
        )
        let malicious = try RelayerChainState(
            chainID: chainID,
            epoch: 3,
            previousDigest: try promoted.digest(),
            activeKeyRef: keyRef(2),
            pendingKeyRef: keyRef(1)
        )

        #expect(throws: RelayerChainSnapshot.ValidationError.historicalKeyRevival(
            keyRef: keyRef(1),
            epoch: 3
        )) {
            try RelayerChainSnapshot.validate(
                [genesis, pending, promoted, malicious],
                expectedChainID: chainID
            )
        }
    }

    @Test func authorityResolvesOnlyHeadActiveAndPendingIdentities() throws {
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(1)
        )
        let pending = try RelayerChainStateTransition.beginRotation(
            from: try RelayerChainSnapshot.validate([genesis], expectedChainID: chainID),
            candidateKeyRef: keyRef(2)
        )
        let snapshot = try RelayerChainSnapshot.validate([genesis, pending], expectedChainID: chainID)
        var requested: [String] = []
        let identities = [
            keyRef(1): try identity(index: 1),
            keyRef(2): try identity(index: 2),
            keyRef(99): try identity(index: 99),
        ]

        let authority = try RelayerIdentityAuthority.resolve(head: snapshot.head) { ref in
            requested.append(ref)
            return identities[ref]
        }
        #expect(requested == [keyRef(1), keyRef(2)])
        #expect(authority.active?.keyRef == keyRef(1))
        #expect(authority.pending?.keyRef == keyRef(2))

        #expect(try authority.authorize(.init(
            chainID: chainID,
            keyRef: keyRef(1),
            address: address(index: 1),
            lifecycle: "active"
        )).role == .active)
        #expect(try authority.authorize(.init(
            chainID: chainID,
            keyRef: keyRef(2),
            address: address(index: 2),
            lifecycle: "pending_funding"
        )).role == .pending)

        #expect(throws: RelayerIdentityAuthority.Failure.unauthorizedKeyRef(keyRef(99))) {
            try authority.authorize(.init(
                chainID: chainID,
                keyRef: keyRef(99),
                address: address(index: 99),
                lifecycle: "active"
            ))
        }
    }

    @Test func authorityRejectsMissingOrMismatchedHeadIdentities() throws {
        let head = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(1)
        )

        #expect(throws: RelayerIdentityAuthority.Failure.missingIdentity(keyRef(1))) {
            try RelayerIdentityAuthority.resolve(head: head) { _ in nil }
        }

        let wrongIdentity = try identity(index: 2)
        #expect(throws: RelayerIdentityAuthority.Failure.identityKeyRefMismatch(
            expected: keyRef(1),
            actual: keyRef(2)
        )) {
            try RelayerIdentityAuthority.resolve(head: head) { _ in wrongIdentity }
        }
    }

    @Test func journalStoreWritesCanonicalPromptFreeDataProtectionRecords() throws {
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(1)
        )
        let client = JournalSecurityItemClient(
            addResponses: [.init(status: errSecSuccess, result: nil)],
            copyResponses: [.init(status: errSecItemNotFound, result: nil)]
        )

        #expect(try RelayerChainStateJournalStore(client: client).append(genesis) == genesis)

        let addition = try #require(client.additions.first)
        #expect(addition[kSecAttrService as String] as? String == RelayerChainStateJournalStore.service)
        #expect(addition[kSecAttrAccount as String] as? String == "v1:11155111:0")
        #expect(addition[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(
            addition[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        #expect(addition[kSecAttrAccessControl as String] == nil)
        #expect(addition[kSecValueData as String] as? Data == (try genesis.canonicalEncoding()))

        let read = try #require(client.copies.first)
        #expect(read[kSecUseAuthenticationContext as String] is LAContext)
        #expect(client.copyInteractionNotAllowed == [true])
        #expect(read[kSecUseDataProtectionKeychain as String] as? Bool == true)
    }

    @Test func journalStoreAcceptsOnlyAnExactDuplicateWinner() throws {
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(1)
        )
        let item = try journalItem(genesis)
        let exactClient = JournalSecurityItemClient(
            addResponses: [.init(status: errSecDuplicateItem, result: nil)],
            copyResponses: [
                .init(status: errSecSuccess, result: [item]),
                .init(status: errSecSuccess, result: item),
            ]
        )
        #expect(try RelayerChainStateJournalStore(client: exactClient).append(genesis) == genesis)

        let competing = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(2)
        )
        let conflictClient = JournalSecurityItemClient(
            addResponses: [.init(status: errSecDuplicateItem, result: nil)],
            copyResponses: [
                .init(status: errSecItemNotFound, result: nil),
                .init(status: errSecSuccess, result: try journalItem(competing)),
            ]
        )
        #expect(throws: RelayerChainStateJournalStore.StoreError.conflictingAppend(
            chainID: chainID,
            epoch: 0
        )) {
            try RelayerChainStateJournalStore(client: conflictClient).append(genesis)
        }
    }

    @Test func journalStoreLoadsAndValidatesAChainSnapshot() throws {
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(1)
        )
        let pending = try RelayerChainStateTransition.beginRotation(
            from: try RelayerChainSnapshot.validate([genesis], expectedChainID: chainID),
            candidateKeyRef: keyRef(2)
        )
        let mainnet = try RelayerChainStateTransition.genesis(
            chainID: 1,
            activeKeyRef: "bundler-eoa:default:1:1"
        )
        let client = JournalSecurityItemClient(copyResponses: [
            .init(status: errSecSuccess, result: [
                try journalItem(pending),
                try journalItem(mainnet),
                try journalItem(genesis),
            ]),
        ])

        let snapshot = try #require(
            try RelayerChainStateJournalStore(client: client).snapshot(chainID: chainID)
        )
        #expect(snapshot.states == [genesis, pending])
        #expect(snapshot.head == pending)
        let query = try #require(client.copies.first)
        #expect(query[kSecUseAuthenticationContext as String] is LAContext)
        #expect(client.copyInteractionNotAllowed == [true])
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String)
    }

    @Test func journalStoreRejectsInvalidAppendBeforeWriting() throws {
        let genesis = try RelayerChainStateTransition.genesis(
            chainID: chainID,
            activeKeyRef: keyRef(1)
        )
        let gap = try RelayerChainState(
            chainID: chainID,
            epoch: 2,
            previousDigest: try genesis.digest(),
            activeKeyRef: keyRef(1),
            pendingKeyRef: keyRef(2)
        )
        let client = JournalSecurityItemClient(copyResponses: [
            .init(status: errSecSuccess, result: [try journalItem(genesis)]),
        ])

        #expect(throws: RelayerChainSnapshot.ValidationError.epochGap(expected: 1, actual: 2)) {
            try RelayerChainStateJournalStore(client: client).append(gap)
        }
        #expect(client.additions.isEmpty)
    }

    @Test func journalStoreRejectsMalformedAccountsAndInteractiveReads() throws {
        let malformedClient = JournalSecurityItemClient(copyResponses: [
            .init(status: errSecSuccess, result: [[
                kSecAttrAccount as String: "not-a-journal-slot",
                kSecValueData as String: Data(),
            ]]),
        ])
        #expect(throws: RelayerChainStateJournalStore.StoreError.malformedAccount(
            "not-a-journal-slot"
        )) {
            try RelayerChainStateJournalStore(client: malformedClient).snapshot(chainID: chainID)
        }

        let interactiveClient = JournalSecurityItemClient(copyResponses: [
            .init(status: errSecInteractionNotAllowed, result: nil),
        ])
        #expect(throws: RelayerChainStateJournalStore.StoreError.interactionRequired) {
            try RelayerChainStateJournalStore(client: interactiveClient).snapshot(chainID: chainID)
        }
    }

    @Test func journalStoreDeleteAllIsScopedToItsDataProtectionService() throws {
        let client = JournalSecurityItemClient(deleteStatuses: [errSecSuccess])
        try RelayerChainStateJournalStore(client: client).deleteAll()

        let query = try #require(client.deletions.first)
        #expect(query[kSecAttrService as String] as? String == RelayerChainStateJournalStore.service)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrAccount as String] == nil)
    }

    private func keyRef(_ index: UInt64) -> String {
        "bundler-eoa:default:\(chainID):\(index)"
    }

    private func address(index: UInt64) -> String {
        "0x" + String(repeating: String(format: "%02x", index & 0xff), count: 20)
    }

    private func identity(index: UInt64) throws -> VerifiedRelayerIdentity {
        try VerifiedRelayerIdentity(
            chainID: chainID,
            keyRef: keyRef(index),
            address: address(index: index)
        )
    }

    private func journalItem(_ state: RelayerChainState) throws -> [String: Any] {
        [
            kSecAttrAccount as String: RelayerChainStateJournalStore.account(
                chainID: state.chainID,
                epoch: state.epoch
            ),
            kSecValueData as String: try state.canonicalEncoding(),
        ]
    }
}
