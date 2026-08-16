import Foundation
import LocalAuthentication
import Testing
@testable import WalletMacOSApp

@Suite(.serialized)
@MainActor
struct LegacyRelayerVerificationCoordinatorTests {
    @Test func successUsesOneSessionContextAndProtectedRead() async throws {
        let harness = try Harness()
        let coordinator = LegacyRelayerVerificationCoordinator()

        let identity = try await coordinator.verify(
            harness.primaryCandidate,
            dependencies: harness.dependencies()
        )

        #expect(identity == harness.primaryCandidate.identity)
        #expect(harness.fetchCount == 3)
        #expect(harness.candidateCheckCount == 3)
        #expect(harness.authenticationFactoryCount == 1)
        #expect(harness.authenticationEvaluationCount == 1)
        #expect(harness.authenticationInvalidationCount == 1)
        #expect(harness.protectedReadCount == 1)
        #expect(harness.protectedReadUsedAuthenticationContext)
        #expect(harness.publicRecordWriteCount == 1)
        #expect(harness.finalizeCount == 1)
        #expect(harness.commitCount == 1)
        #expect(harness.passiveRefreshCount == 1)
        #expect(harness.passiveRefreshSawInvalidatedContext)
    }

    @Test func concurrentClicksForSameCandidateShareOnePromptAndRead() async throws {
        let gate = AuthenticationGate()
        let harness = try Harness(authenticationGate: gate)
        let coordinator = LegacyRelayerVerificationCoordinator()
        let dependencies = harness.dependencies()

        let first = Task {
            try await coordinator.verify(
                harness.primaryCandidate,
                dependencies: dependencies
            )
        }
        while gate.waiterCount == 0 {
            await Task.yield()
        }
        let second = Task {
            try await coordinator.verify(
                harness.primaryCandidate,
                dependencies: dependencies
            )
        }
        await Task.yield()

        #expect(harness.authenticationFactoryCount == 1)
        #expect(harness.authenticationEvaluationCount == 1)
        gate.open()

        #expect(try await first.value == harness.primaryCandidate.identity)
        #expect(try await second.value == harness.primaryCandidate.identity)
        #expect(harness.protectedReadCount == 1)
        #expect(harness.finalizeCount == 1)
        #expect(harness.commitCount == 1)
    }

    @Test func differentCandidateCannotJoinAnInFlightVerification() async throws {
        let gate = AuthenticationGate()
        let harness = try Harness(authenticationGate: gate)
        let coordinator = LegacyRelayerVerificationCoordinator()
        let dependencies = harness.dependencies()

        let first = Task {
            try await coordinator.verify(
                harness.primaryCandidate,
                dependencies: dependencies
            )
        }
        while gate.waiterCount == 0 {
            await Task.yield()
        }

        await #expect(throws: LegacyRelayerVerificationCoordinator.Failure.candidateChanged) {
            try await coordinator.verify(
                harness.secondaryCandidate,
                dependencies: dependencies
            )
        }
        gate.open()
        _ = try await first.value

        #expect(harness.authenticationFactoryCount == 1)
        #expect(harness.protectedReadCount == 1)
    }

    @Test func cancelledAuthorizationDoesNotReadOrWriteAndKeepsRetryEligible() async throws {
        let harness = try Harness()
        harness.authenticationError = AppError.userAuthorizationCancelled
        let coordinator = LegacyRelayerVerificationCoordinator()

        await #expect(throws: AppError.self) {
            try await coordinator.verify(
                harness.primaryCandidate,
                dependencies: harness.dependencies()
            )
        }

        #expect(harness.authenticationFactoryCount == 1)
        #expect(harness.authenticationEvaluationCount == 1)
        #expect(harness.authenticationInvalidationCount == 1)
        #expect(harness.protectedReadCount == 0)
        #expect(harness.publicRecordWriteCount == 0)
        #expect(harness.finalizeCount == 0)
        #expect(harness.commitCount == 0)
        #expect(
            LegacyRelayerVerificationErrorPolicy.candidateDisposition(
                for: AppError.userAuthorizationCancelled
            ) == .preserve
        )
    }

    @Test func candidateChangeAfterAuthenticationFailsBeforeProtectedRead() async throws {
        let harness = try Harness()
        harness.statuses = [
            harness.status(for: harness.primaryCandidate),
            harness.status(for: harness.secondaryCandidate),
        ]
        let coordinator = LegacyRelayerVerificationCoordinator()

        await #expect(throws: LegacyRelayerVerificationCoordinator.Failure.candidateChanged) {
            try await coordinator.verify(
                harness.primaryCandidate,
                dependencies: harness.dependencies()
            )
        }

        #expect(harness.authenticationEvaluationCount == 1)
        #expect(harness.protectedReadCount == 0)
        #expect(harness.publicRecordWriteCount == 0)
        #expect(harness.finalizeCount == 0)
        #expect(harness.commitCount == 0)
    }

    @Test func candidateChangeAfterReadLeavesOnlyInertPublicRecord() async throws {
        let harness = try Harness()
        harness.statuses = [
            harness.status(for: harness.primaryCandidate),
            harness.status(for: harness.primaryCandidate),
            harness.status(for: harness.secondaryCandidate),
        ]
        let coordinator = LegacyRelayerVerificationCoordinator()

        await #expect(throws: LegacyRelayerVerificationCoordinator.Failure.candidateChanged) {
            try await coordinator.verify(
                harness.primaryCandidate,
                dependencies: harness.dependencies()
            )
        }

        #expect(harness.protectedReadCount == 1)
        // BundlerKeyStore.read inserts or exact-matches public identity. With no journal
        // genesis this record is inert and cannot become passive funding authority.
        #expect(harness.publicRecordWriteCount == 1)
        #expect(harness.finalizeCount == 0)
        #expect(harness.commitCount == 0)
        #expect(harness.passiveRefreshCount == 0)
        #expect(
            LegacyRelayerVerificationErrorPolicy.candidateDisposition(
                for: LegacyRelayerVerificationCoordinator.Failure.candidateChanged
            ) == .clear
        )
    }

    @Test func staleGenerationFailsBeforeAuthentication() async throws {
        let harness = try Harness()
        harness.observedGenerations = [7]
        harness.currentGeneration = 8
        let coordinator = LegacyRelayerVerificationCoordinator()

        await #expect(
            throws: LegacyRelayerVerificationCoordinator.Failure.staleDaemonGeneration
        ) {
            try await coordinator.verify(
                harness.primaryCandidate,
                dependencies: harness.dependencies()
            )
        }

        #expect(harness.authenticationFactoryCount == 0)
        #expect(harness.protectedReadCount == 0)
        #expect(harness.finalizeCount == 0)
    }

    @Test func staleGenerationAfterAuthenticationFailsBeforeProtectedRead() async throws {
        let harness = try Harness()
        harness.observedGenerations = [7, 8]
        harness.currentGeneration = 7
        let coordinator = LegacyRelayerVerificationCoordinator()

        await #expect(
            throws: LegacyRelayerVerificationCoordinator.Failure.staleDaemonGeneration
        ) {
            try await coordinator.verify(
                harness.primaryCandidate,
                dependencies: harness.dependencies()
            )
        }

        #expect(harness.authenticationEvaluationCount == 1)
        #expect(harness.protectedReadCount == 0)
        #expect(harness.finalizeCount == 0)
        #expect(harness.commitCount == 0)
    }

    @Test func authenticatedSecretMismatchNeverCreatesJournalAuthority() async throws {
        let harness = try Harness()
        harness.secretReturnedByProtectedRead = harness.secondarySecret
        let coordinator = LegacyRelayerVerificationCoordinator()

        await #expect(
            throws: RelayerSecretAuthorizationPolicy.Failure.authenticatedIdentityMismatch(
                expected: harness.primaryCandidate.identity,
                actual: try VerifiedRelayerIdentity.derive(
                    keyRef: harness.primaryCandidate.identity.keyRef,
                    secret: harness.secondarySecret
                )
            )
        ) {
            try await coordinator.verify(
                harness.primaryCandidate,
                dependencies: harness.dependencies()
            )
        }

        #expect(harness.protectedReadCount == 1)
        #expect(harness.publicRecordWriteCount == 1)
        #expect(harness.finalizeCount == 0)
        #expect(harness.commitCount == 0)
        #expect(harness.passiveRefreshCount == 0)
    }

    @Test func finalAuthorityMismatchDoesNotPublishCommit() async throws {
        let harness = try Harness()
        harness.finalizedIdentityOverride = harness.secondaryCandidate.identity
        let coordinator = LegacyRelayerVerificationCoordinator()

        await #expect(
            throws: LegacyRelayerVerificationCoordinator.Failure.finalAuthorityMismatch(
                harness.primaryCandidate.identity.keyRef
            )
        ) {
            try await coordinator.verify(
                harness.primaryCandidate,
                dependencies: harness.dependencies()
            )
        }

        #expect(harness.protectedReadCount == 1)
        #expect(harness.finalizeCount == 1)
        #expect(harness.commitCount == 0)
        #expect(harness.passiveRefreshCount == 0)
    }

    @Test func refreshFailureAfterCommitCannotPromptOrCommitAgain() async throws {
        let harness = try Harness()
        harness.passiveRefreshError = TestFailure.refreshFailed
        let coordinator = LegacyRelayerVerificationCoordinator()
        let dependencies = harness.dependencies()

        await #expect(throws: TestFailure.refreshFailed) {
            try await coordinator.verify(
                harness.primaryCandidate,
                dependencies: dependencies
            )
        }

        #expect(harness.commitCount == 1)
        #expect(harness.authenticationInvalidationCount == 1)
        #expect(harness.passiveRefreshSawInvalidatedContext)
        await #expect(
            throws: LegacyRelayerVerificationCoordinator.Failure.alreadyCommitted(
                harness.primaryCandidate.identity.keyRef
            )
        ) {
            try await coordinator.verify(
                harness.primaryCandidate,
                dependencies: dependencies
            )
        }
        #expect(harness.authenticationFactoryCount == 1)
        #expect(harness.protectedReadCount == 1)
        #expect(harness.finalizeCount == 1)
        #expect(harness.commitCount == 1)
    }

    @Test func candidateErrorRoutingPreservesOnlyExplicitCancellation() {
        #expect(
            LegacyRelayerVerificationErrorPolicy.candidateDisposition(
                for: CancellationError()
            ) == .preserve
        )
        #expect(
            LegacyRelayerVerificationErrorPolicy.candidateDisposition(
                for: AppError.userAuthorizationCancelled
            ) == .preserve
        )
        #expect(
            LegacyRelayerVerificationErrorPolicy.candidateDisposition(
                for: LAError(.userCancel)
            ) == .preserve
        )
        #expect(
            LegacyRelayerVerificationErrorPolicy.candidateDisposition(
                for: LegacyRelayerVerificationCoordinator.Failure.candidateUnavailable
            ) == .clear
        )
        #expect(
            LegacyRelayerVerificationErrorPolicy.candidateDisposition(
                for: TestFailure.transportFailed
            ) == .clear
        )
    }

    @Test func productionWiringKeepsPassiveRefreshPromptFreeAndReadsOnceExplicitly() throws {
        let source = try String(
            contentsOf: appSourceURL("AppModel.swift"),
            encoding: .utf8
        )
        let refresh = try sourceSlice(
            source,
            from: "    func refreshLocalRelayerStatus() {",
            to: "    func checkLocalRelayerStatusForDiagnostics()"
        )
        #expect(refresh.contains("!isVerifyingLegacyRelayer"))
        #expect(!refresh.contains("DeviceOwnerAuthenticationSession"))
        #expect(!refresh.contains("bundlerKeyStore.read"))

        let verify = try sourceSlice(
            source,
            from: "    func verifyLegacyRelayer(",
            to: "    func monitorHeliosCheckpointAfterNetworkSettingsChange("
        )
        #expect(verify.contains("legacyRelayerVerificationCoordinator.verify"))
        #expect(verify.contains("readBoundRelayerSecret("))
        #expect(!verify.contains("bundlerKeyStore.read("))
        #expect(verify.contains("finalizeRegisteredBundlerIdentity"))
        #expect(!verify.contains("createIfNeeded"))
        #expect(!verify.contains("UserDefaults"))
        #expect(source.components(separatedBy: "bundlerKeyStore.read(").count - 1 == 1)

        let protectedBoundary = try sourceSlice(
            source,
            from: "    private func readBoundRelayerSecret(",
            to: "    /// The sole protected relayer read used by unlock, export, and top-up."
        )
        let authority = try #require(
            protectedBoundary.range(of: "try await validateAuthority()")
        )
        let cancellation = try #require(
            protectedBoundary.range(of: "try Task.checkCancellation()")
        )
        let protectedRead = try #require(
            protectedBoundary.range(of: "bundlerKeyStore.read(")
        )
        #expect(authority.lowerBound < cancellation.lowerBound)
        #expect(cancellation.lowerBound < protectedRead.lowerBound)
    }

    private enum TestFailure: Error, Equatable {
        case refreshFailed
        case transportFailed
    }

    @MainActor
    private final class AuthenticationGate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private(set) var waiterCount = 0

        func wait() async {
            waiterCount += 1
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }

        func open() {
            let waiting = continuations
            continuations.removeAll()
            for continuation in waiting {
                continuation.resume()
            }
        }
    }

    @MainActor
    private final class Harness {
        let chainID: UInt64 = 11_155_111
        let primarySecret = Data(repeating: 1, count: 32)
        let secondarySecret = Data(repeating: 2, count: 32)
        let primaryCandidate: LegacyRelayerMigrationCandidate
        let secondaryCandidate: LegacyRelayerMigrationCandidate

        var statuses: [WalletNodeClient.RelayerStatus] = []
        var observedGenerations: [UInt64] = []
        var currentGeneration: UInt64 = 7
        var authenticationError: Error?
        var secretReturnedByProtectedRead: Data
        var finalizedIdentityOverride: VerifiedRelayerIdentity?
        var finalizeError: Error?
        var passiveRefreshError: Error?

        private let authenticationGate: AuthenticationGate?
        private var authenticationContext: LAContext?

        var fetchCount = 0
        var candidateCheckCount = 0
        var authenticationFactoryCount = 0
        var authenticationEvaluationCount = 0
        var authenticationInvalidationCount = 0
        var protectedReadCount = 0
        var protectedReadUsedAuthenticationContext = false
        var publicRecordWriteCount = 0
        var finalizeCount = 0
        var commitCount = 0
        var passiveRefreshCount = 0
        var passiveRefreshSawInvalidatedContext = false

        init(authenticationGate: AuthenticationGate? = nil) throws {
            let primaryIdentity = try VerifiedRelayerIdentity.derive(
                keyRef: "bundler-eoa:default:\(chainID):1",
                secret: primarySecret
            )
            let secondaryIdentity = try VerifiedRelayerIdentity.derive(
                keyRef: "bundler-eoa:default:\(chainID):2",
                secret: secondarySecret
            )
            primaryCandidate = .init(identity: primaryIdentity)
            secondaryCandidate = .init(identity: secondaryIdentity)
            secretReturnedByProtectedRead = primarySecret
            self.authenticationGate = authenticationGate
            statuses = [
                status(for: primaryCandidate),
                status(for: primaryCandidate),
                status(for: primaryCandidate),
            ]
        }

        func dependencies() -> LegacyRelayerVerificationCoordinator.Dependencies {
            .init(
                fetchStatus: { [self] in
                    try nextObservation()
                },
                currentGeneration: { [self] in currentGeneration },
                candidateForStatus: { [self] status in
                    candidateCheckCount += 1
                    return candidate(matching: status)
                },
                makeAuthenticationSession: { [self] in
                    authenticationFactoryCount += 1
                    let context = LAContext()
                    authenticationContext = context
                    return DeviceOwnerAuthenticationSession(
                        reason: "Test legacy relayer verification",
                        context: context,
                        evaluator: { [self] evaluatedContext, _, _ in
                            authenticationEvaluationCount += 1
                            guard evaluatedContext === authenticationContext else {
                                throw TestFailure.transportFailed
                            }
                            if let authenticationGate {
                                await authenticationGate.wait()
                            }
                            if let authenticationError {
                                throw authenticationError
                            }
                            return true
                        },
                        invalidator: { [self] invalidatedContext in
                            guard invalidatedContext === authenticationContext else {
                                return
                            }
                            authenticationInvalidationCount += 1
                        }
                    )
                },
                readBoundSecret: { [self] identity, authentication in
                    try requireFreshBoundCandidate(identity)
                    protectedReadCount += 1
                    protectedReadUsedAuthenticationContext =
                        authentication.context === authenticationContext
                    // Mirrors BundlerKeyStore.read's public insert/exact-match side effect.
                    publicRecordWriteCount += 1
                    let record = BundlerSecretRecord(
                        keyRef: identity.keyRef,
                        secret: secretReturnedByProtectedRead
                    )
                    let actual = try VerifiedRelayerIdentity.derive(
                        keyRef: record.keyRef,
                        secret: record.secret
                    )
                    guard actual == identity else {
                        throw RelayerSecretAuthorizationPolicy.Failure
                            .authenticatedIdentityMismatch(
                                expected: identity,
                                actual: actual
                            )
                    }
                    try requireFreshBoundCandidate(identity)
                    return record
                },
                finalizeIdentity: { [self] identity in
                    finalizeCount += 1
                    if let finalizeError {
                        throw finalizeError
                    }
                    return finalizedIdentityOverride ?? identity
                },
                didCommit: { [self] _ in
                    commitCount += 1
                },
                refreshPassively: { [self] in
                    passiveRefreshCount += 1
                    passiveRefreshSawInvalidatedContext =
                        authenticationInvalidationCount == 1
                    if let passiveRefreshError {
                        throw passiveRefreshError
                    }
                }
            )
        }

        func status(
            for candidate: LegacyRelayerMigrationCandidate
        ) -> WalletNodeClient.RelayerStatus {
            let identity = candidate.identity
            return WalletNodeClient.RelayerStatus(
                ready: false,
                keyLoaded: false,
                reason: "bundler_eoa_locked",
                ownerScope: "default",
                chainId: Int(chainID),
                networkProfile: "sepolia",
                eoa: identity.address,
                keyRef: identity.keyRef,
                balance: "0x0",
                thresholdLow: BundlerFundingPolicy.minimumBalanceWeiHex,
                needsTopup: false,
                lifecycle: "active",
                compromiseSubmissionBlocked: false,
                pendingFundingAddress: nil,
                pendingFundingCount: 0,
                retiringCount: 0,
                keyHistory: [
                    .init(
                        eoa: identity.address,
                        keyRef: identity.keyRef,
                        lifecycle: "active",
                        createdAt: 1,
                        retiredAt: nil,
                        deletedAt: nil,
                        lastExportedAt: nil
                    ),
                ],
                latestAuditEvent: nil,
                replacement: .init(
                    eligible: false,
                    blocked: false,
                    blockedReason: nil,
                    txHash: nil,
                    userOpHash: nil,
                    nonce: nil
                )
            )
        }

        private func candidate(
            matching status: WalletNodeClient.RelayerStatus
        ) -> LegacyRelayerMigrationCandidate? {
            if status.keyRef == primaryCandidate.identity.keyRef,
               status.eoa == primaryCandidate.identity.address {
                return primaryCandidate
            }
            if status.keyRef == secondaryCandidate.identity.keyRef,
               status.eoa == secondaryCandidate.identity.address {
                return secondaryCandidate
            }
            return nil
        }

        private func nextObservation() throws
            -> LegacyRelayerVerificationCoordinator.StatusObservation {
            let index = fetchCount
            fetchCount += 1
            let status = statuses[min(index, statuses.count - 1)]
            let generation = observedGenerations.isEmpty
                ? currentGeneration
                : observedGenerations[min(index, observedGenerations.count - 1)]
            return .init(status: status, generation: generation)
        }

        private func requireFreshBoundCandidate(
            _ identity: VerifiedRelayerIdentity
        ) throws {
            let observation = try nextObservation()
            guard observation.generation == currentGeneration else {
                throw LegacyRelayerVerificationCoordinator.Failure
                    .staleDaemonGeneration
            }
            candidateCheckCount += 1
            guard candidate(matching: observation.status)?.identity == identity else {
                throw LegacyRelayerVerificationCoordinator.Failure.candidateChanged
            }
        }
    }

    private func appSourceURL(_ filename: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WalletMacOSApp")
            .appendingPathComponent(filename)
    }

    private func sourceSlice(
        _ source: String,
        from startMarker: String,
        to endMarker: String
    ) throws -> String {
        let start = try #require(source.range(of: startMarker))
        let end = try #require(
            source.range(of: endMarker, range: start.upperBound..<source.endIndex)
        )
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
