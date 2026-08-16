import CryptoKit
import Foundation

/// Secret availability is deliberately separate from daemon connectivity. A connected daemon
/// can serve reads while its relayer key remains locked, and every daemon restart forgets keys.
enum RelayerAccessState: Equatable, Sendable {
    case locked
    case installing(generation: UInt64)
    case available(generation: UInt64)
    case failed(generation: UInt64, message: String)

    func isAvailable(for generation: UInt64) -> Bool {
        self == .available(generation: generation)
    }

    func afterDaemonRestart() -> RelayerAccessState {
        .locked
    }
}

/// The privacy helper stays usable in memory after one explicit unlock. Hiding a view or moving
/// focus does not throw away the helper and therefore must not trigger another prompt.
enum PrivacyUnlockState: Equatable, Sendable {
    case locked
    case unlocking
    case loaded
    case failed(String)

    func afterCancellation() -> PrivacyUnlockState {
        .locked
    }
}

enum RelayerKeyInstallPolicy {
    struct HistoryEntry: Equatable, Sendable {
        let keyRef: String
        let lifecycle: String
    }

    static func relevantKeyRefs(
        activeKeyRef: String?,
        fallbackKeyRef: String?,
        history: [HistoryEntry]
    ) -> [String] {
        var result: [String] = []
        if let active = activeKeyRef ?? fallbackKeyRef {
            result.append(active)
        }
        for entry in history where entry.lifecycle == "retiring" {
            if !result.contains(entry.keyRef) {
                result.append(entry.keyRef)
            }
        }
        return result
    }
}

enum RelayerGenerationGate {
    static func accepts(resultGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        resultGeneration == currentGeneration
    }
}

// MARK: - Relayer identity selection journal

/// One immutable entry in the app-owned relayer-selection journal.
///
/// The journal contains public identifiers only. Its digest chain makes ordering explicit,
/// while `RelayerChainSnapshot` enforces the allowed lifecycle transitions. A zero previous
/// digest anchors epoch zero. `activeKeyRef == nil` is an explicit tombstone, not permission
/// to fall back to daemon state or a cached key reference.
struct RelayerChainState: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let digestByteCount = 32
    static let zeroDigest = Data(repeating: 0, count: digestByteCount)

    enum ValidationError: Error, Equatable {
        case unsupportedVersion(Int)
        case invalidChainID(UInt64)
        case invalidPreviousDigestLength(Int)
        case invalidPreviousDigestEncoding(String)
        case invalidKeyRef(String)
        case keyRefChainMismatch(expected: UInt64, actual: UInt64, keyRef: String)
        case activeAndPendingMatch(String)
        case pendingWithoutActive(String)
        case malformedEncoding
        case nonCanonicalEncoding
    }

    let version: Int
    let chainID: UInt64
    let epoch: UInt64
    let previousDigest: Data
    let activeKeyRef: String?
    let pendingKeyRef: String?

    init(
        version: Int = RelayerChainState.currentVersion,
        chainID: UInt64,
        epoch: UInt64,
        previousDigest: Data,
        activeKeyRef: String?,
        pendingKeyRef: String?
    ) throws {
        guard version == Self.currentVersion else {
            throw ValidationError.unsupportedVersion(version)
        }
        guard chainID > 0 else {
            throw ValidationError.invalidChainID(chainID)
        }
        guard previousDigest.count == Self.digestByteCount else {
            throw ValidationError.invalidPreviousDigestLength(previousDigest.count)
        }
        try Self.validate(keyRef: activeKeyRef, chainID: chainID)
        try Self.validate(keyRef: pendingKeyRef, chainID: chainID)
        if let activeKeyRef, activeKeyRef == pendingKeyRef {
            throw ValidationError.activeAndPendingMatch(activeKeyRef)
        }
        if activeKeyRef == nil, let pendingKeyRef {
            throw ValidationError.pendingWithoutActive(pendingKeyRef)
        }

        self.version = version
        self.chainID = chainID
        self.epoch = epoch
        self.previousDigest = previousDigest
        self.activeKeyRef = activeKeyRef
        self.pendingKeyRef = pendingKeyRef
    }

    func canonicalEncoding() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func digest() throws -> Data {
        Data(SHA256.hash(data: try canonicalEncoding()))
    }

    func digestHex() throws -> String {
        try digest().map { String(format: "%02x", $0) }.joined()
    }

    static func decodeCanonical(_ data: Data) throws -> RelayerChainState {
        let state: RelayerChainState
        do {
            state = try JSONDecoder().decode(RelayerChainState.self, from: data)
        } catch let error as ValidationError {
            throw error
        } catch {
            throw ValidationError.malformedEncoding
        }
        guard try state.canonicalEncoding() == data else {
            throw ValidationError.nonCanonicalEncoding
        }
        return state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let previousDigestHex = try container.decode(String.self, forKey: .previousDigest)
        guard let previousDigest = Self.data(fromLowercaseHex: previousDigestHex) else {
            throw ValidationError.invalidPreviousDigestEncoding(previousDigestHex)
        }
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            chainID: container.decode(UInt64.self, forKey: .chainID),
            epoch: container.decode(UInt64.self, forKey: .epoch),
            previousDigest: previousDigest,
            activeKeyRef: container.decodeIfPresent(String.self, forKey: .activeKeyRef),
            pendingKeyRef: container.decodeIfPresent(String.self, forKey: .pendingKeyRef)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(chainID, forKey: .chainID)
        try container.encode(epoch, forKey: .epoch)
        try container.encode(previousDigest.map { String(format: "%02x", $0) }.joined(), forKey: .previousDigest)
        if let activeKeyRef {
            try container.encode(activeKeyRef, forKey: .activeKeyRef)
        } else {
            try container.encodeNil(forKey: .activeKeyRef)
        }
        if let pendingKeyRef {
            try container.encode(pendingKeyRef, forKey: .pendingKeyRef)
        } else {
            try container.encodeNil(forKey: .pendingKeyRef)
        }
    }

    private static func validate(keyRef: String?, chainID: UInt64) throws {
        guard let keyRef else { return }
        guard let keyRefChainID = BundlerLaunchKeyPolicy.chainId(ofKeyRef: keyRef) else {
            throw ValidationError.invalidKeyRef(keyRef)
        }
        guard keyRefChainID == chainID else {
            throw ValidationError.keyRefChainMismatch(
                expected: chainID,
                actual: keyRefChainID,
                keyRef: keyRef
            )
        }
    }

    private static func data(fromLowercaseHex value: String) -> Data? {
        guard value.utf8.count == digestByteCount * 2,
              value.utf8.allSatisfy({
                  ($0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue!)
                      || ($0 >= Character("a").asciiValue! && $0 <= Character("f").asciiValue!)
              }) else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digestByteCount)
        var index = value.startIndex
        for _ in 0..<digestByteCount {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private enum CodingKeys: String, CodingKey {
        case activeKeyRef
        case chainID
        case epoch
        case pendingKeyRef
        case previousDigest
        case version
    }
}

/// A fully validated, chronologically ordered view of one chain's immutable journal.
struct RelayerChainSnapshot: Equatable, Sendable {
    enum ValidationError: Error, Equatable {
        case emptyJournal
        case wrongChain(expected: UInt64, actual: UInt64, epoch: UInt64)
        case duplicateEpoch(UInt64)
        case forkedEpoch(UInt64)
        case epochGap(expected: UInt64, actual: UInt64)
        case epochOverflow
        case invalidGenesis
        case brokenPreviousDigest(epoch: UInt64)
        case invalidTransition(epoch: UInt64)
        case historicalKeyRevival(keyRef: String, epoch: UInt64)
    }

    let states: [RelayerChainState]

    var head: RelayerChainState {
        // Construction is private and validation rejects an empty sequence.
        states[states.count - 1]
    }

    var historicalKeyRefs: Set<String> {
        Set(states.flatMap { [$0.activeKeyRef, $0.pendingKeyRef].compactMap { $0 } })
    }

    static func validate(
        _ records: [RelayerChainState],
        expectedChainID: UInt64
    ) throws -> RelayerChainSnapshot {
        guard !records.isEmpty else {
            throw ValidationError.emptyJournal
        }
        for state in records where state.chainID != expectedChainID {
            throw ValidationError.wrongChain(
                expected: expectedChainID,
                actual: state.chainID,
                epoch: state.epoch
            )
        }

        let ordered = records.sorted { $0.epoch < $1.epoch }
        for pair in zip(ordered, ordered.dropFirst()) where pair.0.epoch == pair.1.epoch {
            if pair.0 == pair.1 {
                throw ValidationError.duplicateEpoch(pair.0.epoch)
            }
            throw ValidationError.forkedEpoch(pair.0.epoch)
        }

        guard let genesis = ordered.first,
              genesis.epoch == 0,
              genesis.previousDigest == RelayerChainState.zeroDigest,
              genesis.activeKeyRef != nil,
              genesis.pendingKeyRef == nil else {
            throw ValidationError.invalidGenesis
        }

        var seen = Set([genesis.activeKeyRef!])
        var previous = genesis
        for current in ordered.dropFirst() {
            let (expectedEpoch, overflow) = previous.epoch.addingReportingOverflow(1)
            guard !overflow else { throw ValidationError.epochOverflow }
            guard current.epoch == expectedEpoch else {
                throw ValidationError.epochGap(expected: expectedEpoch, actual: current.epoch)
            }
            guard current.previousDigest == (try previous.digest()) else {
                throw ValidationError.brokenPreviousDigest(epoch: current.epoch)
            }
            try validateTransition(from: previous, to: current, seen: &seen)
            previous = current
        }
        return RelayerChainSnapshot(states: ordered)
    }

    private static func validateTransition(
        from previous: RelayerChainState,
        to current: RelayerChainState,
        seen: inout Set<String>
    ) throws {
        if previous.pendingKeyRef == nil,
           current.activeKeyRef == previous.activeKeyRef,
           let candidate = current.pendingKeyRef {
            guard seen.insert(candidate).inserted else {
                throw ValidationError.historicalKeyRevival(keyRef: candidate, epoch: current.epoch)
            }
            return
        }
        if let pending = previous.pendingKeyRef,
           current.activeKeyRef == pending,
           current.pendingKeyRef == nil {
            return
        }
        if previous.pendingKeyRef != nil,
           current.activeKeyRef == previous.activeKeyRef,
           current.pendingKeyRef == nil {
            return
        }
        if previous.activeKeyRef != nil,
           previous.pendingKeyRef == nil,
           current.activeKeyRef == nil,
           current.pendingKeyRef == nil {
            return
        }
        if previous.activeKeyRef == nil,
           previous.pendingKeyRef == nil,
           let replacement = current.activeKeyRef,
           current.pendingKeyRef == nil {
            guard seen.insert(replacement).inserted else {
                throw ValidationError.historicalKeyRevival(keyRef: replacement, epoch: current.epoch)
            }
            return
        }
        throw ValidationError.invalidTransition(epoch: current.epoch)
    }

    private init(states: [RelayerChainState]) {
        self.states = states
    }
}

/// Pure constructors for the only journal transitions the product permits.
enum RelayerChainStateTransition {
    enum Failure: Error, Equatable {
        case activeIdentityMissing
        case pendingCandidateExists(String)
        case unexpectedPendingCandidate(expected: String, actual: String)
        case pendingCandidateMissing
        case wrongActiveKeyRef(expected: String, actual: String?)
        case tombstoneRequired
        case pendingMustBeCleared(String)
        case historicalKeyRevival(String)
        case epochOverflow
    }

    static func genesis(chainID: UInt64, activeKeyRef: String) throws -> RelayerChainState {
        return try RelayerChainState(
            chainID: chainID,
            epoch: 0,
            previousDigest: RelayerChainState.zeroDigest,
            activeKeyRef: activeKeyRef,
            pendingKeyRef: nil
        )
    }

    static func beginRotation(
        from snapshot: RelayerChainSnapshot,
        candidateKeyRef: String
    ) throws -> RelayerChainState {
        let head = snapshot.head
        guard head.activeKeyRef != nil else { throw Failure.activeIdentityMissing }
        if let pending = head.pendingKeyRef {
            throw Failure.pendingCandidateExists(pending)
        }
        guard !snapshot.historicalKeyRefs.contains(candidateKeyRef) else {
            throw Failure.historicalKeyRevival(candidateKeyRef)
        }
        return try next(from: head, active: head.activeKeyRef, pending: candidateKeyRef)
    }

    static func promotePending(
        from snapshot: RelayerChainSnapshot,
        activatedKeyRef: String
    ) throws -> RelayerChainState {
        let head = snapshot.head
        guard let pending = head.pendingKeyRef else { throw Failure.pendingCandidateMissing }
        guard pending == activatedKeyRef else {
            throw Failure.unexpectedPendingCandidate(expected: pending, actual: activatedKeyRef)
        }
        return try next(from: head, active: pending, pending: nil)
    }

    static func clearPending(
        from snapshot: RelayerChainSnapshot,
        expectedPendingKeyRef: String
    ) throws -> RelayerChainState {
        let head = snapshot.head
        guard let pending = head.pendingKeyRef else { throw Failure.pendingCandidateMissing }
        guard pending == expectedPendingKeyRef else {
            throw Failure.unexpectedPendingCandidate(expected: pending, actual: expectedPendingKeyRef)
        }
        return try next(from: head, active: head.activeKeyRef, pending: nil)
    }

    static func tombstone(
        from snapshot: RelayerChainSnapshot,
        expectedActiveKeyRef: String
    ) throws -> RelayerChainState {
        let head = snapshot.head
        guard head.activeKeyRef == expectedActiveKeyRef else {
            throw Failure.wrongActiveKeyRef(expected: expectedActiveKeyRef, actual: head.activeKeyRef)
        }
        if let pending = head.pendingKeyRef {
            throw Failure.pendingMustBeCleared(pending)
        }
        return try next(from: head, active: nil, pending: nil)
    }

    static func activateReplacement(
        from snapshot: RelayerChainSnapshot,
        keyRef: String
    ) throws -> RelayerChainState {
        let head = snapshot.head
        guard head.activeKeyRef == nil, head.pendingKeyRef == nil else {
            throw Failure.tombstoneRequired
        }
        guard !snapshot.historicalKeyRefs.contains(keyRef) else {
            throw Failure.historicalKeyRevival(keyRef)
        }
        return try next(from: head, active: keyRef, pending: nil)
    }

    private static func next(
        from head: RelayerChainState,
        active: String?,
        pending: String?
    ) throws -> RelayerChainState {
        let (nextEpoch, overflow) = head.epoch.addingReportingOverflow(1)
        guard !overflow else { throw Failure.epochOverflow }
        return try RelayerChainState(
            chainID: head.chainID,
            epoch: nextEpoch,
            previousDigest: try head.digest(),
            activeKeyRef: active,
            pendingKeyRef: pending
        )
    }
}

enum RelayerChainStateAppendPolicy {
    enum Failure: Error, Equatable {
        case wrongSlot
        case conflictingAppend(chainID: UInt64, epoch: UInt64)
    }

    /// Resolves a `SecItemAdd` duplicate without allowing a concurrent writer to choose a
    /// different transition for the same epoch.
    static func resolveConcurrentAppend(
        proposed: RelayerChainState,
        stored: RelayerChainState
    ) throws -> RelayerChainState {
        guard proposed.chainID == stored.chainID, proposed.epoch == stored.epoch else {
            throw Failure.wrongSlot
        }
        guard proposed == stored else {
            throw Failure.conflictingAppend(chainID: proposed.chainID, epoch: proposed.epoch)
        }
        return stored
    }
}

/// Public identities authorized by the current journal head. The resolver intentionally asks
/// only for head references; retired historical records remain hash-verifiable after deletion.
struct RelayerIdentityAuthority: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case active
        case pending
    }

    struct Claim: Equatable, Sendable {
        let chainID: UInt64
        let keyRef: String
        let address: String
        let lifecycle: String
    }

    struct Authorization: Equatable, Sendable {
        let role: Role
        let identity: VerifiedRelayerIdentity
    }

    enum Failure: Error, Equatable {
        case missingIdentity(String)
        case identityKeyRefMismatch(expected: String, actual: String)
        case identityChainMismatch(expected: UInt64, actual: UInt64, keyRef: String)
        case unauthorizedKeyRef(String)
        case wrongLifecycle(expected: String, actual: String)
        case wrongClaimChain(expected: UInt64, actual: UInt64)
        case invalidClaimAddress(String)
        case wrongClaimAddress(expected: String, actual: String)
    }

    let chainID: UInt64
    let active: VerifiedRelayerIdentity?
    let pending: VerifiedRelayerIdentity?

    static func resolve(
        head: RelayerChainState,
        identityForKeyRef: (String) throws -> VerifiedRelayerIdentity?
    ) throws -> RelayerIdentityAuthority {
        let active = try resolveIdentity(
            keyRef: head.activeKeyRef,
            chainID: head.chainID,
            identityForKeyRef: identityForKeyRef
        )
        let pending = try resolveIdentity(
            keyRef: head.pendingKeyRef,
            chainID: head.chainID,
            identityForKeyRef: identityForKeyRef
        )
        return RelayerIdentityAuthority(chainID: head.chainID, active: active, pending: pending)
    }

    func authorize(_ claim: Claim) throws -> Authorization {
        guard claim.chainID == chainID else {
            throw Failure.wrongClaimChain(expected: chainID, actual: claim.chainID)
        }

        let role: Role
        let identity: VerifiedRelayerIdentity
        let expectedLifecycle: String
        if let active, claim.keyRef == active.keyRef {
            role = .active
            identity = active
            expectedLifecycle = "active"
        } else if let pending, claim.keyRef == pending.keyRef {
            role = .pending
            identity = pending
            expectedLifecycle = "pending_funding"
        } else {
            throw Failure.unauthorizedKeyRef(claim.keyRef)
        }
        guard claim.lifecycle == expectedLifecycle else {
            throw Failure.wrongLifecycle(expected: expectedLifecycle, actual: claim.lifecycle)
        }

        let normalizedAddress: String
        do {
            normalizedAddress = try VerifiedRelayerIdentity.normalizedAddress(claim.address)
        } catch {
            throw Failure.invalidClaimAddress(claim.address)
        }
        guard normalizedAddress == identity.address else {
            throw Failure.wrongClaimAddress(expected: identity.address, actual: normalizedAddress)
        }
        return Authorization(role: role, identity: identity)
    }

    private static func resolveIdentity(
        keyRef: String?,
        chainID: UInt64,
        identityForKeyRef: (String) throws -> VerifiedRelayerIdentity?
    ) throws -> VerifiedRelayerIdentity? {
        guard let keyRef else { return nil }
        guard let identity = try identityForKeyRef(keyRef) else {
            throw Failure.missingIdentity(keyRef)
        }
        guard identity.keyRef == keyRef else {
            throw Failure.identityKeyRefMismatch(expected: keyRef, actual: identity.keyRef)
        }
        guard identity.chainID == chainID else {
            throw Failure.identityChainMismatch(
                expected: chainID,
                actual: identity.chainID,
                keyRef: keyRef
            )
        }
        return identity
    }
}

// MARK: - App-owned relayer rotation coordinator

/// Stateless orchestration policy for relayer rotation.
///
/// This type deliberately owns no Keychain or daemon client. AppModel supplies those effects as
/// closures, while the coordinator fixes their security-sensitive ordering: candidate creation,
/// immutable public identity persistence, pending-journal append, then daemon installation.
enum RelayerRotationCoordinator {
    enum PlanMode: Equatable, Sendable {
        case createCandidate
        case reusePending
    }

    struct Plan: Equatable, Sendable {
        let mode: PlanMode
        let activeKeyRef: String
        let candidateKeyRef: String
        let pendingTransition: RelayerChainState?

        fileprivate init(
            mode: PlanMode,
            activeKeyRef: String,
            candidateKeyRef: String,
            pendingTransition: RelayerChainState?
        ) {
            self.mode = mode
            self.activeKeyRef = activeKeyRef
            self.candidateKeyRef = candidateKeyRef
            self.pendingTransition = pendingTransition
        }
    }

    struct PreparedRotation: Equatable, Sendable {
        let plan: Plan
        let candidateIdentity: VerifiedRelayerIdentity
        let journalHead: RelayerChainState
    }

    struct DaemonIdentityObservation: Equatable, Sendable {
        let chainID: UInt64
        let keyRef: String
        let address: String
        let lifecycle: String
    }

    enum Failure: Error, Equatable {
        case missingActiveIdentity
        case malformedActiveKeyRef(String)
        case candidateIndexOverflow
        case candidateWasPreviouslyUsed(String)
        case stalePlan
        case missingPendingTransition(String)
        case unexpectedPendingTransition(String)
        case candidateIdentityMismatch(expected: String, actual: String)
        case candidateIdentityChainMismatch(expected: UInt64, actual: UInt64)
        case candidatePublicIdentityMismatch(String)
        case journalAppendMismatch(expectedEpoch: UInt64, actualEpoch: UInt64)
        case daemonChainMismatch(expected: UInt64, actual: UInt64)
        case daemonKeyRefMismatch(expected: String, actual: String)
        case daemonAddressMismatch(expected: String, actual: String)
        case invalidDaemonAddress(String)
        case daemonLifecycleMismatch(expected: String, actual: String)
        case priorActiveLifecycleNotRetiringOrRetired(String)
    }

    /// Plans from an already validated snapshot. A pending candidate is immutable and always
    /// reused. Otherwise the next key reference is the monotonic successor of every historical
    /// key in the active owner scope, so a retired key can never be revived.
    static func plan(from snapshot: RelayerChainSnapshot) throws -> Plan {
        let head = snapshot.head
        guard let activeKeyRef = head.activeKeyRef else {
            throw Failure.missingActiveIdentity
        }
        if let pendingKeyRef = head.pendingKeyRef {
            return Plan(
                mode: .reusePending,
                activeKeyRef: activeKeyRef,
                candidateKeyRef: pendingKeyRef,
                pendingTransition: nil
            )
        }

        guard let activeComponents = keyRefComponents(activeKeyRef) else {
            throw Failure.malformedActiveKeyRef(activeKeyRef)
        }
        let usedIndices = snapshot.historicalKeyRefs.compactMap { keyRef -> UInt64? in
            guard let components = keyRefComponents(keyRef),
                  components.ownerScope == activeComponents.ownerScope else {
                return nil
            }
            return components.index
        }
        guard let maximumIndex = usedIndices.max() else {
            throw Failure.malformedActiveKeyRef(activeKeyRef)
        }
        let (candidateIndex, overflow) = maximumIndex.addingReportingOverflow(1)
        guard !overflow else {
            throw Failure.candidateIndexOverflow
        }
        let candidateKeyRef = "bundler-eoa:\(activeComponents.ownerScope):\(head.chainID):\(candidateIndex)"
        guard !snapshot.historicalKeyRefs.contains(candidateKeyRef) else {
            throw Failure.candidateWasPreviouslyUsed(candidateKeyRef)
        }
        let transition = try RelayerChainStateTransition.beginRotation(
            from: snapshot,
            candidateKeyRef: candidateKeyRef
        )
        return Plan(
            mode: .createCandidate,
            activeKeyRef: activeKeyRef,
            candidateKeyRef: candidateKeyRef,
            pendingTransition: transition
        )
    }

    /// Executes preparation and installation in a fixed order. If daemon installation fails
    /// after the append, the next call plans `.reusePending` and therefore retries the same key.
    static func prepareAndInstall(
        plan: Plan,
        snapshot: RelayerChainSnapshot,
        createCandidateIdentity: (String) throws -> VerifiedRelayerIdentity,
        identityForKeyRef: (String) throws -> VerifiedRelayerIdentity?,
        persistPublicIdentity: (VerifiedRelayerIdentity) throws -> Void,
        appendJournal: (RelayerChainState) throws -> RelayerChainState,
        installDaemon: (VerifiedRelayerIdentity) async throws -> Void
    ) async throws -> PreparedRotation {
        guard try Self.plan(from: snapshot) == plan else {
            throw Failure.stalePlan
        }

        let candidateIdentity: VerifiedRelayerIdentity
        let journalHead: RelayerChainState
        switch plan.mode {
        case .createCandidate:
            guard snapshot.head.pendingKeyRef == nil else {
                throw Failure.unexpectedPendingTransition(snapshot.head.pendingKeyRef!)
            }
            guard let pendingTransition = plan.pendingTransition else {
                throw Failure.missingPendingTransition(plan.candidateKeyRef)
            }
            let createdIdentity = try createCandidateIdentity(plan.candidateKeyRef)
            try requireCandidateIdentity(createdIdentity, plan: plan, chainID: snapshot.head.chainID)
            try persistPublicIdentity(createdIdentity)

            let appended = try appendJournal(pendingTransition)
            guard appended == pendingTransition else {
                throw Failure.journalAppendMismatch(
                    expectedEpoch: pendingTransition.epoch,
                    actualEpoch: appended.epoch
                )
            }
            let authority = try RelayerIdentityAuthority.resolve(head: appended) {
                try identityForKeyRef($0)
            }
            guard authority.pending == createdIdentity else {
                throw Failure.candidatePublicIdentityMismatch(plan.candidateKeyRef)
            }
            candidateIdentity = createdIdentity
            journalHead = appended

        case .reusePending:
            guard snapshot.head.pendingKeyRef == plan.candidateKeyRef,
                  plan.pendingTransition == nil else {
                throw Failure.unexpectedPendingTransition(
                    snapshot.head.pendingKeyRef ?? "none"
                )
            }
            let authority = try RelayerIdentityAuthority.resolve(head: snapshot.head) {
                try identityForKeyRef($0)
            }
            guard let pendingIdentity = authority.pending else {
                throw Failure.candidatePublicIdentityMismatch(plan.candidateKeyRef)
            }
            try requireCandidateIdentity(
                pendingIdentity,
                plan: plan,
                chainID: snapshot.head.chainID
            )
            candidateIdentity = pendingIdentity
            journalHead = snapshot.head
        }

        try await installDaemon(candidateIdentity)
        return PreparedRotation(
            plan: plan,
            candidateIdentity: candidateIdentity,
            journalHead: journalHead
        )
    }

    /// Appends promotion only after the daemon proves that the exact pending public identity is
    /// active and the exact prior active identity has entered a retiring or retired lifecycle.
    /// A journal without a pending candidate needs no promotion and returns `nil` without reads.
    static func promoteIfReady(
        snapshot: RelayerChainSnapshot,
        daemonActive: DaemonIdentityObservation,
        priorActive: DaemonIdentityObservation,
        identityForKeyRef: (String) throws -> VerifiedRelayerIdentity?,
        appendJournal: (RelayerChainState) throws -> RelayerChainState
    ) throws -> RelayerChainState? {
        let head = snapshot.head
        guard let pendingKeyRef = head.pendingKeyRef else { return nil }
        guard let activeKeyRef = head.activeKeyRef else {
            throw Failure.missingActiveIdentity
        }
        let authority = try RelayerIdentityAuthority.resolve(head: head) {
            try identityForKeyRef($0)
        }
        guard let pendingIdentity = authority.pending,
              let activeIdentity = authority.active else {
            throw Failure.candidatePublicIdentityMismatch(pendingKeyRef)
        }

        try requireDaemonObservation(
            daemonActive,
            identity: pendingIdentity,
            expectedLifecycle: "active"
        )
        guard priorActive.keyRef == activeKeyRef else {
            throw Failure.daemonKeyRefMismatch(
                expected: activeKeyRef,
                actual: priorActive.keyRef
            )
        }
        guard priorActive.lifecycle == "retiring" || priorActive.lifecycle == "retired" else {
            throw Failure.priorActiveLifecycleNotRetiringOrRetired(priorActive.lifecycle)
        }
        try requireDaemonObservation(
            priorActive,
            identity: activeIdentity,
            expectedLifecycle: priorActive.lifecycle
        )

        let proposed = try RelayerChainStateTransition.promotePending(
            from: snapshot,
            activatedKeyRef: pendingKeyRef
        )
        let appended = try appendJournal(proposed)
        guard appended == proposed else {
            throw Failure.journalAppendMismatch(
                expectedEpoch: proposed.epoch,
                actualEpoch: appended.epoch
            )
        }
        return appended
    }

    private static func requireCandidateIdentity(
        _ identity: VerifiedRelayerIdentity,
        plan: Plan,
        chainID: UInt64
    ) throws {
        guard identity.keyRef == plan.candidateKeyRef else {
            throw Failure.candidateIdentityMismatch(
                expected: plan.candidateKeyRef,
                actual: identity.keyRef
            )
        }
        guard identity.chainID == chainID else {
            throw Failure.candidateIdentityChainMismatch(
                expected: chainID,
                actual: identity.chainID
            )
        }
    }

    private static func requireDaemonObservation(
        _ observation: DaemonIdentityObservation,
        identity: VerifiedRelayerIdentity,
        expectedLifecycle: String
    ) throws {
        guard observation.chainID == identity.chainID else {
            throw Failure.daemonChainMismatch(
                expected: identity.chainID,
                actual: observation.chainID
            )
        }
        guard observation.keyRef == identity.keyRef else {
            throw Failure.daemonKeyRefMismatch(
                expected: identity.keyRef,
                actual: observation.keyRef
            )
        }
        let address: String
        do {
            address = try VerifiedRelayerIdentity.normalizedAddress(observation.address)
        } catch {
            throw Failure.invalidDaemonAddress(observation.address)
        }
        guard address == identity.address else {
            throw Failure.daemonAddressMismatch(
                expected: identity.address,
                actual: address
            )
        }
        guard observation.lifecycle == expectedLifecycle else {
            throw Failure.daemonLifecycleMismatch(
                expected: expectedLifecycle,
                actual: observation.lifecycle
            )
        }
    }

    private static func keyRefComponents(
        _ keyRef: String
    ) -> (ownerScope: String, chainID: UInt64, index: UInt64)? {
        let parts = keyRef.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == "bundler-eoa",
              !parts[1].isEmpty,
              let chainID = UInt64(parts[2]),
              let index = UInt64(parts[3]) else {
            return nil
        }
        return (String(parts[1]), chainID, index)
    }
}

// MARK: - Targeted relayer deletion policy

/// Authorizes individual relayer-key deletion without weakening the full-wallet reset boundary.
///
/// An `unsafeReset` daemon flag is deliberately not authority to remove an app-selected active
/// or pending identity. Individual deletion is restricted to an exact public identity that the
/// app journal remembers and the daemon reports as retired. The returned local deletion order
/// makes the public authority record disappear before the protected secret can be removed.
enum RelayerTargetedDeletionPolicy {
    enum LocalDeletionStep: Equatable, Sendable {
        case publicIdentity
        case protectedSecret
    }

    struct Authorization: Equatable, Sendable {
        let identity: VerifiedRelayerIdentity
        let requiredLocalDeletionOrder: [LocalDeletionStep]

        fileprivate init(identity: VerifiedRelayerIdentity) {
            self.identity = identity
            self.requiredLocalDeletionOrder = [.publicIdentity, .protectedSecret]
        }
    }

    enum Failure: Error, Equatable {
        case wrongClaimChain(expected: UInt64, actual: UInt64)
        case activeIdentityProtected(String)
        case pendingIdentityProtected(String)
        case nonHistoricalIdentity(String)
        case retiringIdentityMayHaveLiveWork(String)
        case identityAlreadyDeleted(String)
        case lifecycleNotRetired(String)
        case missingPublicIdentity(String)
        case publicIdentityKeyRefMismatch(expected: String, actual: String)
        case publicIdentityChainMismatch(expected: UInt64, actual: UInt64, keyRef: String)
        case invalidClaimAddress(String)
        case wrongClaimAddress(expected: String, actual: String)
    }

    static func authorizeIndividualDeletion(
        snapshot: RelayerChainSnapshot,
        daemonClaim claim: RelayerIdentityAuthority.Claim,
        unsafeReset _: Bool,
        identityForKeyRef: (String) throws -> VerifiedRelayerIdentity?
    ) throws -> Authorization {
        let head = snapshot.head
        guard claim.chainID == head.chainID else {
            throw Failure.wrongClaimChain(expected: head.chainID, actual: claim.chainID)
        }
        if claim.keyRef == head.activeKeyRef {
            throw Failure.activeIdentityProtected(claim.keyRef)
        }
        if claim.keyRef == head.pendingKeyRef {
            throw Failure.pendingIdentityProtected(claim.keyRef)
        }
        guard snapshot.historicalKeyRefs.contains(claim.keyRef) else {
            throw Failure.nonHistoricalIdentity(claim.keyRef)
        }

        switch claim.lifecycle {
        case "retired":
            break
        case "retiring":
            throw Failure.retiringIdentityMayHaveLiveWork(claim.keyRef)
        case "deleted":
            throw Failure.identityAlreadyDeleted(claim.keyRef)
        default:
            throw Failure.lifecycleNotRetired(claim.lifecycle)
        }

        guard let identity = try identityForKeyRef(claim.keyRef) else {
            throw Failure.missingPublicIdentity(claim.keyRef)
        }
        guard identity.keyRef == claim.keyRef else {
            throw Failure.publicIdentityKeyRefMismatch(
                expected: claim.keyRef,
                actual: identity.keyRef
            )
        }
        guard identity.chainID == head.chainID else {
            throw Failure.publicIdentityChainMismatch(
                expected: head.chainID,
                actual: identity.chainID,
                keyRef: identity.keyRef
            )
        }

        let normalizedAddress: String
        do {
            normalizedAddress = try VerifiedRelayerIdentity.normalizedAddress(claim.address)
        } catch {
            throw Failure.invalidClaimAddress(claim.address)
        }
        guard normalizedAddress == identity.address else {
            throw Failure.wrongClaimAddress(
                expected: identity.address,
                actual: normalizedAddress
            )
        }
        return Authorization(identity: identity)
    }
}
