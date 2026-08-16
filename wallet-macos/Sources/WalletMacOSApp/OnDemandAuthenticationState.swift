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
