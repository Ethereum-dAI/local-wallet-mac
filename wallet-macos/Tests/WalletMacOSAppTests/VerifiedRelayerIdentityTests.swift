import Foundation
import Testing
@testable import WalletMacOSApp

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

    @Test func keyStorePersistsPromptFreeIdentityAttributesWhenEntitled() throws {
        let store = BundlerKeyStore.shared
        let uniqueChain = 900_000_000_000 + UInt64.random(in: 0..<1_000_000)
        let keyRef = "bundler-eoa:identity-test:\(uniqueChain):0"
        let secret = Data(repeating: 0x33, count: 32)
        defer { try? store.delete(keyRef: keyRef) }

        do {
            try store.add(keyRef: keyRef, secret: secret)
        } catch AppError.missingEntitlement {
            // The unsigned SwiftPM test runner cannot write biometric-gated
            // data-protection Keychain items. Signed Xcode tests exercise this path.
            return
        }

        let maybeStored = try store.verifiedIdentity(forKeyRef: keyRef)
        let stored = try #require(maybeStored)
        #expect(stored == (try VerifiedRelayerIdentity.derive(keyRef: keyRef, secret: secret)))
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
            against: identity
        ) == identity)
        #expect(try RelayerIdentityBindingPolicy.verify(
            status: status(
                ready: false,
                keyLoaded: false,
                reason: "bundler_eoa_locked"
            ),
            against: identity
        ) == identity)
        #expect(try RelayerIdentityBindingPolicy.verify(
            status: status(
                ready: false,
                keyLoaded: true,
                reason: "bundler_eoa_needs_topup",
                balance: "0x0",
                needsTopup: true
            ),
            against: identity
        ) == identity)
        #expect(try RelayerIdentityBindingPolicy.verify(
            status: status(
                ready: false,
                keyLoaded: true,
                reason: "bundler_balance_unavailable",
                balance: "unavailable"
            ),
            against: identity
        ) == identity)
    }

    @Test func chainKeyAddressLifecycleAndCompromiseMismatchesFailClosed() {
        #expect(throws: RelayerIdentityBindingPolicy.Failure.wrongChain(
            expected: 11_155_111,
            actual: 1
        )) {
            try RelayerIdentityBindingPolicy.verify(
                status: status(chainID: 1),
                against: identity
            )
        }
        #expect(throws: RelayerIdentityBindingPolicy.Failure.missingKeyRef) {
            try RelayerIdentityBindingPolicy.verify(
                status: status(keyRef: nil),
                against: identity
            )
        }
        #expect(throws: RelayerIdentityBindingPolicy.Failure.wrongKeyRef(
            expected: identity.keyRef,
            actual: "bundler-eoa:default:11155111:2"
        )) {
            try RelayerIdentityBindingPolicy.verify(
                status: status(keyRef: "bundler-eoa:default:11155111:2"),
                against: identity
            )
        }
        #expect(throws: RelayerIdentityBindingPolicy.Failure.wrongEOA(
            expected: identity.address,
            actual: "0x2222222222222222222222222222222222222222"
        )) {
            try RelayerIdentityBindingPolicy.verify(
                status: status(eoa: "0x2222222222222222222222222222222222222222"),
                against: identity
            )
        }
        #expect(throws: RelayerIdentityBindingPolicy.Failure.inactiveLifecycle("retiring")) {
            try RelayerIdentityBindingPolicy.verify(
                status: status(lifecycle: "retiring"),
                against: identity
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
                against: identity
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
                try RelayerIdentityBindingPolicy.verify(status: inconsistent, against: identity)
            }
        }
    }

    private func status(
        chainID: Int = 11_155_111,
        keyRef: String? = "bundler-eoa:default:11155111:1",
        eoa: String = "0x7A3F000000000000000000000000000000009C21",
        ready: Bool = true,
        keyLoaded: Bool = true,
        reason: String? = nil,
        balance: String = "0x2386f26fc10000",
        needsTopup: Bool = false,
        lifecycle: String = "active",
        compromiseSubmissionBlocked: Bool = false
    ) -> WalletNodeClient.RelayerStatus {
        do {
            var json: [String: Any] = [
                "ready": ready,
                "keyLoaded": keyLoaded,
                "ownerScope": "default",
                "chainId": chainID,
                "networkProfile": "sepolia",
                "eoa": eoa,
                "balance": balance,
                "thresholdLow": "0x11c37937e08000",
                "needsTopup": needsTopup,
                "lifecycle": lifecycle,
                "compromise": [
                    "suspected": compromiseSubmissionBlocked,
                    "submissionBlocked": compromiseSubmissionBlocked,
                ],
            ]
            json["keyRef"] = keyRef ?? NSNull()
            if let reason { json["reason"] = reason }
            return try WalletNodeClient.RelayerStatus(json: json)
        } catch {
            fatalError("Invalid relayer fixture: \(error)")
        }
    }
}
