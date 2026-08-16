import Foundation
import LocalAuthentication
import Security
import Testing
@testable import WalletMacOSApp

private final class RecordingSecurityItemClient: SecurityItemClient, @unchecked Sendable {
    struct Response {
        let status: OSStatus
        let result: Any?
    }

    var addResponses: [Response]
    var copyResponses: [Response]
    var deleteStatuses: [OSStatus]
    private(set) var additions: [[String: Any]] = []
    private(set) var copies: [[String: Any]] = []
    private(set) var copyInteractionNotAllowed: [Bool?] = []
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
        return addResponses.isEmpty
            ? (errSecSuccess, nil)
            : consumeFirst(&addResponses)
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: Any?) {
        copies.append(query)
        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        copyInteractionNotAllowed.append(context?.interactionNotAllowed)
        return copyResponses.isEmpty
            ? (errSecItemNotFound, nil)
            : consumeFirst(&copyResponses)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        deletions.append(query)
        return deleteStatuses.isEmpty
            ? errSecSuccess
            : deleteStatuses.removeFirst()
    }

    private func consumeFirst(_ responses: inout [Response]) -> (OSStatus, Any?) {
        let response = responses.removeFirst()
        return (response.status, response.result)
    }
}

@Suite struct VerifiedRelayerIdentityTests {
    private let chainID: UInt64 = 11_155_111
    private let keyRef = "bundler-eoa:default:11155111:1"
    private let address = "0x7A3F000000000000000000000000000000009C21"

    @Test func metadataIsVersionedCanonicalAndRoundTrips() throws {
        let identity = try VerifiedRelayerIdentity(
            chainID: chainID,
            keyRef: keyRef,
            address: address
        )

        #expect(identity.version == VerifiedRelayerIdentity.currentVersion)
        #expect(identity.chainID == chainID)
        #expect(identity.keyRef == keyRef)
        #expect(identity.address == address.lowercased())
        #expect(
            try VerifiedRelayerIdentity.decodeMetadata(identity.encodedMetadata()) == identity
        )
        #expect(
            String(data: try identity.encodedMetadata(), encoding: .utf8)
                == #"{"address":"0x7a3f000000000000000000000000000000009c21","chainID":11155111,"keyRef":"bundler-eoa:default:11155111:1","version":1}"#
        )
    }

    @Test func invalidAddressVersionAndKeyRefChainFailClosed() {
        for invalidAddress in [
            "7a3f000000000000000000000000000000009c21",
            "0x7a3f000000000000000000000000000000009c2",
            "0x7a3f000000000000000000000000000000009c2g",
            " 0x7a3f000000000000000000000000000000009c21",
        ] {
            #expect(throws: VerifiedRelayerIdentity.ValidationError.self) {
                try VerifiedRelayerIdentity(
                    chainID: chainID,
                    keyRef: keyRef,
                    address: invalidAddress
                )
            }
        }

        #expect(throws: VerifiedRelayerIdentity.ValidationError.self) {
            try VerifiedRelayerIdentity(
                version: VerifiedRelayerIdentity.currentVersion + 1,
                chainID: chainID,
                keyRef: keyRef,
                address: address
            )
        }
        #expect(throws: VerifiedRelayerIdentity.ValidationError.self) {
            try VerifiedRelayerIdentity(
                chainID: 1,
                keyRef: keyRef,
                address: address
            )
        }
        #expect(throws: VerifiedRelayerIdentity.ValidationError.self) {
            try VerifiedRelayerIdentity(
                chainID: chainID,
                keyRef: "not-a-bundler-key",
                address: address
            )
        }
        for malformedKeyRef in [
            "bundler-eoa:default:011155111:1",
            "bundler-eoa:default:11155111:01",
            "bundler-eoa:default:0:1",
            "bundler-eoa:default:11155111:0",
            "bundler-eoa:default:18446744073709551616:1",
            "bundler-eoa:default:11155111:18446744073709551616",
        ] {
            #expect(throws: VerifiedRelayerIdentity.ValidationError.invalidKeyRef(
                malformedKeyRef
            )) {
                try VerifiedRelayerIdentity(
                    chainID: chainID,
                    keyRef: malformedKeyRef,
                    address: address
                )
            }
            #expect(throws: VerifiedRelayerIdentity.ValidationError.invalidKeyRef(
                malformedKeyRef
            )) {
                try VerifiedRelayerIdentity.derive(
                    keyRef: malformedKeyRef,
                    secret: Data(repeating: 0x11, count: 32)
                )
            }
        }
    }

    @Test func authenticatedSecretDerivationAndLegacyMetadataDecisionAreFailClosed() throws {
        let derived = try VerifiedRelayerIdentity.derive(
            keyRef: keyRef,
            secret: Data(repeating: 0x11, count: 32)
        )
        #expect(derived.chainID == chainID)
        #expect(derived.address.count == 42)

        #expect(
            try VerifiedRelayerIdentityMetadataPolicy.decision(
                stored: nil,
                derived: derived
            ) == .migrate(derived)
        )
        #expect(
            try VerifiedRelayerIdentityMetadataPolicy.decision(
                stored: derived,
                derived: derived
            ) == .current
        )

        let different = try VerifiedRelayerIdentity.derive(
            keyRef: keyRef,
            secret: Data(repeating: 0x22, count: 32)
        )
        #expect(throws: VerifiedRelayerIdentity.ValidationError.storedIdentityMismatch) {
            try VerifiedRelayerIdentityMetadataPolicy.decision(
                stored: different,
                derived: derived
            )
        }
    }

    @Test func insertionStatusTreatsOnlyDuplicateAsAnExistingWinner() throws {
        #expect(try BundlerKeyStore.insertionResult(for: errSecSuccess) == .inserted)
        #expect(try BundlerKeyStore.insertionResult(for: errSecDuplicateItem) == .existing)
        #expect(throws: (any Error).self) {
            try BundlerKeyStore.insertionResult(for: errSecAuthFailed)
        }
    }

    @Test func publicIdentityStoreUsesCanonicalImmutableRecords() throws {
        let client = RecordingSecurityItemClient()
        let store = RelayerPublicIdentityStore(client: client)
        let identity = try VerifiedRelayerIdentity(
            chainID: chainID,
            keyRef: keyRef,
            address: address
        )

        try store.insertOrRequireIdentity(identity)

        let attributes = try #require(client.additions.first)
        #expect(attributes[kSecAttrService as String] as? String == RelayerPublicIdentityStore.service)
        #expect(attributes[kSecAttrAccount as String] as? String == keyRef)
        #expect(attributes[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(
            (attributes[kSecAttrAccessible as String] as? String)
                == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        )
        #expect(attributes[kSecAttrAccessControl as String] == nil)
        let encodedIdentity = try identity.encodedMetadata()
        #expect(attributes[kSecValueData as String] as? Data == encodedIdentity)
    }

    @Test func publicIdentityExactDuplicateIsIdempotent() throws {
        let identity = try VerifiedRelayerIdentity(
            chainID: chainID,
            keyRef: keyRef,
            address: address
        )
        let client = RecordingSecurityItemClient(
            addResponses: [.init(status: errSecDuplicateItem, result: nil)],
            copyResponses: [.init(status: errSecSuccess, result: try identity.encodedMetadata())]
        )

        try RelayerPublicIdentityStore(client: client).insertOrRequireIdentity(identity)

        #expect(client.additions.count == 1)
        #expect(client.copies.count == 1)
    }

    @Test func publicIdentityConflictingDuplicateFailsClosed() throws {
        let expected = try VerifiedRelayerIdentity(
            chainID: chainID,
            keyRef: keyRef,
            address: address
        )
        let conflicting = try VerifiedRelayerIdentity(
            chainID: chainID,
            keyRef: keyRef,
            address: "0x2222222222222222222222222222222222222222"
        )
        let client = RecordingSecurityItemClient(
            addResponses: [.init(status: errSecDuplicateItem, result: nil)],
            copyResponses: [.init(status: errSecSuccess, result: try conflicting.encodedMetadata())]
        )

        #expect(throws: RelayerPublicIdentityStore.StoreError.conflictingIdentity(keyRef)) {
            try RelayerPublicIdentityStore(client: client).insertOrRequireIdentity(expected)
        }
    }

    @Test func publicIdentityMalformedAndWrongAccountRecordsFailClosed() throws {
        let malformedClient = RecordingSecurityItemClient(
            copyResponses: [.init(status: errSecSuccess, result: Data("{}".utf8))]
        )
        #expect(throws: RelayerPublicIdentityStore.StoreError.malformedRecord(keyRef)) {
            _ = try RelayerPublicIdentityStore(client: malformedClient)
                .identity(forKeyRef: keyRef)
        }

        let otherKeyRef = "bundler-eoa:default:11155111:2"
        let wrongIdentity = try VerifiedRelayerIdentity(
            chainID: chainID,
            keyRef: otherKeyRef,
            address: address
        )
        let wrongClient = RecordingSecurityItemClient(
            copyResponses: [.init(status: errSecSuccess, result: try wrongIdentity.encodedMetadata())]
        )
        #expect(
            throws: RelayerPublicIdentityStore.StoreError.wrongKeyRef(
                expected: keyRef,
                actual: otherKeyRef
            )
        ) {
            _ = try RelayerPublicIdentityStore(client: wrongClient)
                .identity(forKeyRef: keyRef)
        }
    }

    @Test func publicIdentityReadsExplicitlyDisableInteraction() throws {
        let client = RecordingSecurityItemClient(
            copyResponses: [.init(status: errSecItemNotFound, result: nil)]
        )

        #expect(
            try RelayerPublicIdentityStore(client: client).identity(forKeyRef: keyRef) == nil
        )

        let query = try #require(client.copies.first)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecReturnData as String] as? Bool == true)
        #expect(query[kSecUseAuthenticationContext as String] is LAContext)
        #expect(client.copyInteractionNotAllowed == [true])
    }

    @Test func publicIdentityInteractionRequirementIsNotTreatedAsMissing() {
        let client = RecordingSecurityItemClient(
            copyResponses: [.init(status: errSecInteractionNotAllowed, result: nil)]
        )
        #expect(throws: RelayerPublicIdentityStore.StoreError.interactionRequired(keyRef)) {
            _ = try RelayerPublicIdentityStore(client: client).identity(forKeyRef: keyRef)
        }
    }

    @Test func freshSecretInsertionDoesNotReadProtectedKeychain() throws {
        let protectedClient = RecordingSecurityItemClient(
            addResponses: [.init(status: errSecSuccess, result: nil)]
        )
        let publicClient = RecordingSecurityItemClient()
        let store = BundlerKeyStore(
            client: protectedClient,
            publicIdentityStore: RelayerPublicIdentityStore(client: publicClient)
        )

        let record = try store.createIfNeeded(
            keyRef: keyRef,
            authenticationContext: LAContext()
        )

        #expect(record.keyRef == keyRef)
        #expect(record.secret.count == 32)
        #expect(protectedClient.additions.count == 1)
        #expect(protectedClient.copies.isEmpty)
        #expect(protectedClient.additions[0][kSecAttrGeneric as String] == nil)
        #expect(publicClient.additions.count == 1)
    }

    @Test func duplicateSecretReadsWinnerOnceWithExactCallerContext() throws {
        let winnerSecret = Data(repeating: 0x44, count: 32)
        let protectedClient = RecordingSecurityItemClient(
            addResponses: [.init(status: errSecDuplicateItem, result: nil)],
            copyResponses: [
                .init(
                    status: errSecSuccess,
                    result: [
                        kSecAttrAccount as String: keyRef,
                        kSecValueData as String: winnerSecret,
                    ]
                ),
            ]
        )
        let publicClient = RecordingSecurityItemClient()
        let store = BundlerKeyStore(
            client: protectedClient,
            publicIdentityStore: RelayerPublicIdentityStore(client: publicClient)
        )
        let context = LAContext()

        let record = try store.createIfNeeded(
            keyRef: keyRef,
            authenticationContext: context
        )

        #expect(record.secret == winnerSecret)
        #expect(protectedClient.copies.count == 1)
        let query = protectedClient.copies[0]
        #expect(query[kSecUseAuthenticationContext as String] as? LAContext === context)
        #expect(query[kSecReturnData as String] as? Bool == true)
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        #expect(publicClient.additions.count == 1)
    }

    @Test func legacyMetadataIsValidatedInsideTheSingleAuthenticatedRead() throws {
        let winnerSecret = Data(repeating: 0x44, count: 32)
        let conflicting = try VerifiedRelayerIdentity.derive(
            keyRef: keyRef,
            secret: Data(repeating: 0x55, count: 32)
        )
        let protectedClient = RecordingSecurityItemClient(
            copyResponses: [
                .init(
                    status: errSecSuccess,
                    result: [
                        kSecAttrAccount as String: keyRef,
                        kSecAttrGeneric as String: try conflicting.encodedMetadata(),
                        kSecValueData as String: winnerSecret,
                    ]
                ),
            ]
        )
        let publicClient = RecordingSecurityItemClient()
        let store = BundlerKeyStore(
            client: protectedClient,
            publicIdentityStore: RelayerPublicIdentityStore(client: publicClient)
        )

        #expect(throws: VerifiedRelayerIdentity.ValidationError.storedIdentityMismatch) {
            _ = try store.read(
                keyRef: keyRef,
                reason: "Test",
                authenticationContext: LAContext()
            )
        }
        #expect(protectedClient.copies.count == 1)
        #expect(publicClient.additions.isEmpty)
    }
}

@Suite struct RelayerIdentityBindingPolicyTests {
    private let identity: VerifiedRelayerIdentity

    init() throws {
        identity = try VerifiedRelayerIdentity(
            chainID: 11_155_111,
            keyRef: "bundler-eoa:default:11155111:1",
            address: "0x7a3f000000000000000000000000000000009c21"
        )
    }

    @Test func legitimateReadyLockedAndUnderfundedStatesBind() throws {
        #expect(try RelayerIdentityBindingPolicy.verify(
            status: status(),
            against: identity,
            expectedOwnerScope: "default",
            expectedNetworkProfile: "sepolia"
        ) == identity)
        #expect(try RelayerIdentityBindingPolicy.verify(
            status: status(
                ready: false,
                keyLoaded: false,
                reason: "bundler_eoa_locked"
            ),
            against: identity,
            expectedOwnerScope: "default",
            expectedNetworkProfile: "sepolia"
        ) == identity)
        #expect(try RelayerIdentityBindingPolicy.verify(
            status: status(
                ready: false,
                keyLoaded: true,
                reason: "bundler_eoa_needs_topup",
                balance: "0x0",
                needsTopup: true
            ),
            against: identity,
            expectedOwnerScope: "default",
            expectedNetworkProfile: "sepolia"
        ) == identity)
        #expect(try RelayerIdentityBindingPolicy.verify(
            status: status(
                ready: false,
                keyLoaded: true,
                reason: "bundler_balance_unavailable",
                balance: "unavailable"
            ),
            against: identity,
            expectedOwnerScope: "default",
            expectedNetworkProfile: "sepolia"
        ) == identity)
    }

    @Test func chainKeyAddressLifecycleAndCompromiseMismatchesFailClosed() {
        #expect(throws: RelayerIdentityBindingPolicy.Failure.wrongChain(
            expected: 11_155_111,
            actual: 1
        )) {
            try RelayerIdentityBindingPolicy.verify(
                status: status(chainID: 1),
                against: identity,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia"
            )
        }
        #expect(throws: RelayerIdentityBindingPolicy.Failure.missingKeyRef) {
            try RelayerIdentityBindingPolicy.verify(
                status: status(keyRef: nil),
                against: identity,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia"
            )
        }
        #expect(throws: RelayerIdentityBindingPolicy.Failure.wrongKeyRef(
            expected: identity.keyRef,
            actual: "bundler-eoa:default:11155111:2"
        )) {
            try RelayerIdentityBindingPolicy.verify(
                status: status(keyRef: "bundler-eoa:default:11155111:2"),
                against: identity,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia"
            )
        }
        #expect(throws: RelayerIdentityBindingPolicy.Failure.wrongEOA(
            expected: identity.address,
            actual: "0x2222222222222222222222222222222222222222"
        )) {
            try RelayerIdentityBindingPolicy.verify(
                status: status(eoa: "0x2222222222222222222222222222222222222222"),
                against: identity,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia"
            )
        }
        #expect(throws: RelayerIdentityBindingPolicy.Failure.inactiveLifecycle("retiring")) {
            try RelayerIdentityBindingPolicy.verify(
                status: status(lifecycle: "retiring"),
                against: identity,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia"
            )
        }
        #expect(throws: RelayerIdentityBindingPolicy.Failure.compromiseSuspected) {
            try RelayerIdentityBindingPolicy.verify(
                status: status(
                    ready: false,
                    keyLoaded: true,
                    reason: "bundler_eoa_compromise_suspected",
                    compromiseSubmissionBlocked: true
                ),
                against: identity,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia"
            )
        }
    }

    @Test func contradictoryReadyAndReasonShapesFailClosed() {
        for inconsistent in [
            status(ready: true, keyLoaded: false),
            status(ready: true, keyLoaded: true, reason: "bundler_eoa_locked"),
            status(ready: false, keyLoaded: false, reason: nil),
            status(ready: false, keyLoaded: true, reason: "bundler_eoa_locked"),
            status(
                ready: false,
                keyLoaded: true,
                reason: "bundler_eoa_needs_topup",
                needsTopup: false
            ),
            status(
                ready: false,
                keyLoaded: true,
                reason: "bundler_balance_unavailable",
                balance: "0x1"
            ),
        ] {
            #expect(throws: RelayerIdentityBindingPolicy.Failure.incoherentStatus) {
                try RelayerIdentityBindingPolicy.verify(
                    status: inconsistent,
                    against: identity,
                    expectedOwnerScope: "default",
                    expectedNetworkProfile: "sepolia"
                )
            }
        }
    }

    @Test func wrongOwnerScopeAndNetworkProfileFailClosed() {
        #expect(throws: RelayerIdentityBindingPolicy.Failure.wrongOwnerScope(
            expected: "default",
            actual: "attacker"
        )) {
            try RelayerIdentityBindingPolicy.verify(
                status: status(ownerScope: "attacker"),
                against: identity,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia"
            )
        }
        #expect(throws: RelayerIdentityBindingPolicy.Failure.wrongNetworkProfile(
            expected: "sepolia",
            actual: "mainnet"
        )) {
            try RelayerIdentityBindingPolicy.verify(
                status: status(networkProfile: "mainnet"),
                against: identity,
                expectedOwnerScope: "default",
                expectedNetworkProfile: "sepolia"
            )
        }
    }

    private func status(
        chainID: Int = 11_155_111,
        keyRef: String? = "bundler-eoa:default:11155111:1",
        eoa: String = "0x7A3F000000000000000000000000000000009C21",
        ownerScope: String = "default",
        networkProfile: String = "sepolia",
        ready: Bool = true,
        keyLoaded: Bool = true,
        reason: String? = nil,
        balance: String = "0x2386f26fc10000",
        needsTopup: Bool = false,
        lifecycle: String = "active",
        compromiseSubmissionBlocked: Bool = false
    ) -> WalletNodeClient.RelayerStatus {
        WalletNodeClient.RelayerStatus(
            ready: ready,
            keyLoaded: keyLoaded,
            reason: reason,
            ownerScope: ownerScope,
            chainId: chainID,
            networkProfile: networkProfile,
            eoa: eoa,
            keyRef: keyRef,
            balance: balance,
            thresholdLow: "0x11c37937e08000",
            needsTopup: needsTopup,
            lifecycle: lifecycle,
            compromiseSubmissionBlocked: compromiseSubmissionBlocked,
            pendingFundingAddress: nil,
            pendingFundingCount: 0,
            retiringCount: 0,
            keyHistory: [],
            latestAuditEvent: nil,
            replacement: nil
        )
    }
}
