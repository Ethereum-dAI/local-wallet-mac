import Foundation
import Testing
@testable import WalletMacOSApp

@Suite struct RelayerBootstrapRegistrationPolicyTests {
    @Test func loadedRegistrationAndLockedRestartAreBothRequired() throws {
        let identity = try fixtureIdentity()

        try verify(
            status: fixtureStatus(identity: identity, keyLoaded: true),
            identity: identity,
            expectedKeyLoaded: true
        )
        try verify(
            status: fixtureStatus(identity: identity, keyLoaded: false),
            identity: identity,
            expectedKeyLoaded: false
        )
    }

    @Test func wrongChainIsRejected() throws {
        let identity = try fixtureIdentity()

        #expect(throws: RelayerIdentityBindingPolicy.Failure.wrongChain(
            expected: identity.chainID,
            actual: 1
        )) {
            try verify(
                status: fixtureStatus(identity: identity, chainID: 1),
                identity: identity,
                expectedKeyLoaded: true
            )
        }
    }

    @Test func wrongKeyReferenceIsRejected() throws {
        let identity = try fixtureIdentity()
        let wrongKeyRef = "bundler-eoa:default:11155111:2"

        #expect(throws: RelayerIdentityBindingPolicy.Failure.wrongKeyRef(
            expected: identity.keyRef,
            actual: wrongKeyRef
        )) {
            try verify(
                status: fixtureStatus(identity: identity, keyRef: wrongKeyRef),
                identity: identity,
                expectedKeyLoaded: true
            )
        }
    }

    @Test func wrongEOAIsRejected() throws {
        let identity = try fixtureIdentity()
        let wrongEOA = "0x2222222222222222222222222222222222222222"

        #expect(throws: RelayerIdentityBindingPolicy.Failure.wrongEOA(
            expected: identity.address,
            actual: wrongEOA
        )) {
            try verify(
                status: fixtureStatus(identity: identity, eoa: wrongEOA),
                identity: identity,
                expectedKeyLoaded: true
            )
        }
    }

    @Test func inactiveLifecycleIsRejected() throws {
        let identity = try fixtureIdentity()

        #expect(throws: RelayerIdentityBindingPolicy.Failure.inactiveLifecycle("retiring")) {
            try verify(
                status: fixtureStatus(identity: identity, lifecycle: "retiring"),
                identity: identity,
                expectedKeyLoaded: true
            )
        }
    }

    @Test func compromiseFlagIsRejected() throws {
        let identity = try fixtureIdentity()

        #expect(throws: RelayerIdentityBindingPolicy.Failure.compromiseSuspected) {
            try verify(
                status: fixtureStatus(
                    identity: identity,
                    keyLoaded: true,
                    compromiseSubmissionBlocked: true
                ),
                identity: identity,
                expectedKeyLoaded: true
            )
        }
    }

    @Test func registrationProbeMustHaveTheSecretLoaded() throws {
        let identity = try fixtureIdentity()

        #expect(throws: RelayerBootstrapRegistrationPolicy.Failure.unexpectedLoadedState(
            expected: true,
            actual: false
        )) {
            try verify(
                status: fixtureStatus(identity: identity, keyLoaded: false),
                identity: identity,
                expectedKeyLoaded: true
            )
        }
    }

    @Test func readOnlyRestartMustNotRetainTheSecret() throws {
        let identity = try fixtureIdentity()

        #expect(throws: RelayerBootstrapRegistrationPolicy.Failure.unexpectedLoadedState(
            expected: false,
            actual: true
        )) {
            try verify(
                status: fixtureStatus(identity: identity, keyLoaded: true),
                identity: identity,
                expectedKeyLoaded: false
            )
        }
    }

    @Test func wrongOwnerScopeAndNetworkProfileAreRejected() throws {
        let identity = try fixtureIdentity()

        #expect(throws: RelayerIdentityBindingPolicy.Failure.wrongOwnerScope(
            expected: "default",
            actual: "attacker"
        )) {
            try verify(
                status: fixtureStatus(identity: identity, ownerScope: "attacker"),
                identity: identity,
                expectedKeyLoaded: true
            )
        }
        #expect(throws: RelayerIdentityBindingPolicy.Failure.wrongNetworkProfile(
            expected: "sepolia",
            actual: "mainnet"
        )) {
            try verify(
                status: fixtureStatus(identity: identity, networkProfile: "mainnet"),
                identity: identity,
                expectedKeyLoaded: true
            )
        }
    }

    private func verify(
        status: WalletNodeClient.RelayerStatus,
        identity: VerifiedRelayerIdentity,
        expectedKeyLoaded: Bool
    ) throws {
        try RelayerBootstrapRegistrationPolicy.verify(
            status: status,
            identity: identity,
            expectedKeyLoaded: expectedKeyLoaded,
            expectedOwnerScope: "default",
            expectedNetworkProfile: "sepolia"
        )
    }
}

@Suite struct RelayerBootstrapRegistrationOrchestrationTests {
    private enum ProbeFailure: Error, Equatable {
        case registrationRejected
    }

    @Test @MainActor func probesLoadedThenLockedAndReturnsSecretDerivedIdentity() async throws {
        let record = fixtureRecord()
        let identity = try VerifiedRelayerIdentity.derive(
            keyRef: record.keyRef,
            secret: record.secret
        )
        var suppliedRecords: [[BundlerSecretRecord]] = []

        let service = RelayerBootstrapRegistrationService { records, chain, gasPolicy in
            suppliedRecords.append(records)
            #expect(chain == .ethereumSepolia)
            #expect(gasPolicy == .sepolia)
            switch suppliedRecords.count {
            case 1:
                return fixtureStatus(identity: identity, keyLoaded: true)
            case 2:
                return fixtureStatus(identity: identity, keyLoaded: false)
            default:
                Issue.record("Registration must use exactly two daemon probes")
                return fixtureStatus(identity: identity, keyLoaded: false)
            }
        }

        let returned = try await service.register(
            record: record,
            chain: .ethereumSepolia,
            gasPolicy: .sepolia
        )

        #expect(returned == identity)
        #expect(suppliedRecords.count == 2)
        #expect(suppliedRecords[0].count == 1)
        #expect(suppliedRecords[0][0].keyRef == record.keyRef)
        #expect(suppliedRecords[0][0].secret == record.secret)
        #expect(suppliedRecords[1].isEmpty)
    }

    @Test @MainActor func firstProbeFailurePreventsReadOnlyRestartProbe() async {
        let record = fixtureRecord()
        var probeCount = 0
        let service = RelayerBootstrapRegistrationService { _, _, _ in
            probeCount += 1
            throw ProbeFailure.registrationRejected
        }

        await #expect(throws: ProbeFailure.registrationRejected) {
            try await service.register(
                record: record,
                chain: .ethereumSepolia,
                gasPolicy: .sepolia
            )
        }

        #expect(probeCount == 1)
    }

    @Test @MainActor func cancellationAfterRegistrationPreventsReadOnlyRestartProbe() async throws {
        let record = fixtureRecord()
        let identity = try VerifiedRelayerIdentity.derive(
            keyRef: record.keyRef,
            secret: record.secret
        )
        var probeCount = 0
        let service = RelayerBootstrapRegistrationService { _, _, _ in
            probeCount += 1
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return fixtureStatus(identity: identity, keyLoaded: true)
        }

        let registration = Task {
            try await service.register(
                record: record,
                chain: .ethereumSepolia,
                gasPolicy: .sepolia
            )
        }
        await #expect(throws: CancellationError.self) {
            try await registration.value
        }

        #expect(probeCount == 1)
    }

    @Test @MainActor func failedRegistrationStatusPreventsReadOnlyRestartProbe() async throws {
        let record = fixtureRecord()
        let identity = try VerifiedRelayerIdentity.derive(
            keyRef: record.keyRef,
            secret: record.secret
        )
        var probeCount = 0
        let service = RelayerBootstrapRegistrationService { _, _, _ in
            probeCount += 1
            return fixtureStatus(identity: identity, keyLoaded: false)
        }

        await #expect(throws: RelayerBootstrapRegistrationPolicy.Failure.unexpectedLoadedState(
            expected: true,
            actual: false
        )) {
            try await service.register(
                record: record,
                chain: .ethereumSepolia,
                gasPolicy: .sepolia
            )
        }

        #expect(probeCount == 1)
    }

    @Test @MainActor func readOnlyRestartRejectsASecretThatRemainsLoaded() async throws {
        let record = fixtureRecord()
        let identity = try VerifiedRelayerIdentity.derive(
            keyRef: record.keyRef,
            secret: record.secret
        )
        var probeCount = 0
        let service = RelayerBootstrapRegistrationService { _, _, _ in
            probeCount += 1
            return fixtureStatus(identity: identity, keyLoaded: true)
        }

        await #expect(throws: RelayerBootstrapRegistrationPolicy.Failure.unexpectedLoadedState(
            expected: false,
            actual: true
        )) {
            try await service.register(
                record: record,
                chain: .ethereumSepolia,
                gasPolicy: .sepolia
            )
        }

        #expect(probeCount == 2)
    }
}

private func fixtureRecord() -> BundlerSecretRecord {
    BundlerSecretRecord(
        keyRef: "bundler-eoa:default:11155111:1",
        secret: Data(repeating: 0x11, count: 32)
    )
}

private func fixtureIdentity() throws -> VerifiedRelayerIdentity {
    let record = fixtureRecord()
    return try VerifiedRelayerIdentity.derive(keyRef: record.keyRef, secret: record.secret)
}

private func fixtureStatus(
    identity: VerifiedRelayerIdentity,
    chainID: Int? = nil,
    keyRef: String? = nil,
    eoa: String? = nil,
    keyLoaded: Bool = true,
    lifecycle: String = "active",
    ownerScope: String = "default",
    networkProfile: String = "sepolia",
    compromiseSubmissionBlocked: Bool = false
) -> WalletNodeClient.RelayerStatus {
    WalletNodeClient.RelayerStatus(
        ready: false,
        keyLoaded: keyLoaded,
        reason: keyLoaded ? "bundler_eoa_needs_topup" : "bundler_eoa_locked",
        ownerScope: ownerScope,
        chainId: chainID ?? Int(identity.chainID),
        networkProfile: networkProfile,
        eoa: eoa ?? identity.address,
        keyRef: keyRef ?? identity.keyRef,
        balance: "0x0",
        thresholdLow: "0x11c37937e08000",
        needsTopup: true,
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
