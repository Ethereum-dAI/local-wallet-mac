import Foundation
import WalletToolLayer

/// Canonical parser for app-managed relayer key references.
///
/// Swift's integer parser accepts aliases such as `011155111` and `01`. The
/// daemon does not: authority-bearing key references must round-trip to the one
/// canonical decimal representation shared with Rust.
enum RelayerKeyReferenceAuthorityPolicy {
    struct Components: Equatable, Sendable {
        let ownerScope: String
        let chainID: UInt64
        let index: UInt64
    }

    static func components(_ keyRef: String) -> Components? {
        let parts = keyRef.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == "bundler-eoa",
              !parts[1].isEmpty,
              let chainID = UInt64(parts[2]),
              chainID > 0,
              String(parts[2]) == String(chainID),
              let index = UInt64(parts[3]),
              index > 0,
              String(parts[3]) == String(index) else {
            return nil
        }
        return Components(
            ownerScope: String(parts[1]),
            chainID: chainID,
            index: index
        )
    }

    static func matches(
        _ keyRef: String,
        ownerScope: String,
        chainID: UInt64
    ) -> Bool {
        guard let components = components(keyRef) else { return false }
        return components.ownerScope == ownerScope && components.chainID == chainID
    }
}

/// Result of the app's prompt-free, app-owned relayer selection check.
///
/// A daemon can report any public key reference. It is therefore only an observation, never
/// the authority that chooses which Keychain identity the dashboard displays. The validated
/// journal head makes that choice, the immutable public record supplies the expected address,
/// and the daemon status must match both exactly.
enum PassiveRelayerIdentityResolver {
    enum Failure: Error, Equatable {
        case migrationRequired(chainID: UInt64)
        case invalidDaemonChainID(Int)
        case wrongDaemonChain(expected: UInt64, actual: UInt64)
        case wrongJournalChain(expected: UInt64, actual: UInt64)
        case wrongOwnerScope(expected: String, actual: String)
        case wrongNetworkProfile(expected: String, actual: String)
        case missingDaemonKeyRef
        case inactiveJournalIdentity(String)
    }

    static func resolve(
        status: WalletNodeClient.RelayerStatus,
        expectedChainID: UInt64,
        expectedOwnerScope: String,
        expectedNetworkProfile: String,
        snapshot: RelayerChainSnapshot?,
        identityForKeyRef: (String) throws -> VerifiedRelayerIdentity?
    ) throws -> VerifiedRelayerIdentity {
        guard let snapshot else {
            throw Failure.migrationRequired(chainID: expectedChainID)
        }
        guard snapshot.head.chainID == expectedChainID else {
            throw Failure.wrongJournalChain(
                expected: expectedChainID,
                actual: snapshot.head.chainID
            )
        }
        guard let daemonChainID = UInt64(exactly: status.chainId) else {
            throw Failure.invalidDaemonChainID(status.chainId)
        }
        guard daemonChainID == expectedChainID else {
            throw Failure.wrongDaemonChain(expected: expectedChainID, actual: daemonChainID)
        }
        guard status.ownerScope == expectedOwnerScope else {
            throw Failure.wrongOwnerScope(
                expected: expectedOwnerScope,
                actual: status.ownerScope
            )
        }
        guard status.networkProfile == expectedNetworkProfile else {
            throw Failure.wrongNetworkProfile(
                expected: expectedNetworkProfile,
                actual: status.networkProfile
            )
        }
        guard let keyRef = status.keyRef else {
            throw Failure.missingDaemonKeyRef
        }

        let authority = try RelayerIdentityAuthority.resolve(
            head: snapshot.head,
            identityForKeyRef: identityForKeyRef
        )
        let authorization = try authority.authorize(.init(
            chainID: daemonChainID,
            keyRef: keyRef,
            address: status.eoa,
            lifecycle: status.lifecycle
        ))
        guard authorization.role == .active else {
            throw Failure.inactiveJournalIdentity(keyRef)
        }

        return try RelayerIdentityBindingPolicy.verify(
            status: status,
            against: authorization.identity,
            expectedOwnerScope: expectedOwnerScope,
            expectedNetworkProfile: expectedNetworkProfile
        )
    }
}

/// One legacy relayer identity that is eligible for explicit user verification.
///
/// This is only a public observation. It does not authorize the daemon identity or
/// access to the protected secret. The explicit migration action must authenticate,
/// re-derive this identity from the secret, and bind a fresh daemon status before it
/// creates the app-owned public record and journal genesis.
struct LegacyRelayerMigrationCandidate: Equatable, Sendable {
    let identity: VerifiedRelayerIdentity
}

/// Prompt-free eligibility for the explicit legacy relayer verification action.
///
/// An absent journal is the only state in which daemon identity may become a
/// migration candidate. A daemon observation is never adopted directly: it must be
/// structurally valid, coherent, active, uncompromised, and either have no immutable
/// public record yet or match that record exactly.
enum LegacyRelayerMigrationPolicy {
    static func candidate(
        status: WalletNodeClient.RelayerStatus,
        expectedChainID: UInt64,
        expectedOwnerScope: String,
        expectedNetworkProfile: String,
        snapshot: RelayerChainSnapshot?,
        identityForKeyRef: (String) throws -> VerifiedRelayerIdentity?
    ) throws -> LegacyRelayerMigrationCandidate? {
        // Any validated journal, including a tombstoned head, means this is not a
        // legacy wallet. Missing public data in that state is corruption/recovery,
        // not permission to trust daemon-selected identity.
        guard snapshot == nil,
              UInt64(exactly: status.chainId) == expectedChainID,
              status.ownerScope == expectedOwnerScope,
              status.networkProfile == expectedNetworkProfile,
              let keyRef = status.keyRef else {
            return nil
        }
        guard keyRefHasExpectedAuthority(
            keyRef,
            ownerScope: expectedOwnerScope,
            chainID: expectedChainID
        ) else {
            return nil
        }

        let observedIdentity: VerifiedRelayerIdentity
        do {
            observedIdentity = try VerifiedRelayerIdentity(
                chainID: expectedChainID,
                keyRef: keyRef,
                address: status.eoa
            )
            try RelayerIdentityBindingPolicy.verify(
                status: status,
                against: observedIdentity,
                expectedOwnerScope: expectedOwnerScope,
                expectedNetworkProfile: expectedNetworkProfile
            )
        } catch {
            return nil
        }
        guard hasCleanLegacyLifecycle(
            status: status,
            identity: observedIdentity
        ) else {
            return nil
        }

        let publicIdentity = try identityForKeyRef(keyRef)
        guard publicIdentity == nil || publicIdentity == observedIdentity else {
            return nil
        }
        return LegacyRelayerMigrationCandidate(identity: observedIdentity)
    }

    private static func keyRefHasExpectedAuthority(
        _ keyRef: String,
        ownerScope: String,
        chainID: UInt64
    ) -> Bool {
        RelayerKeyReferenceAuthorityPolicy.matches(
            keyRef,
            ownerScope: ownerScope,
            chainID: chainID
        )
    }

    /// Legacy migration may create a genesis record only when the daemon has
    /// exactly one clean active identity. Pending, retiring, historical, or
    /// replacement state needs a dedicated recovery flow instead of being dropped.
    private static func hasCleanLegacyLifecycle(
        status: WalletNodeClient.RelayerStatus,
        identity: VerifiedRelayerIdentity
    ) -> Bool {
        guard status.pendingFunding.isEmpty,
              status.retiringCount == 0,
              status.keyHistory.count == 1,
              let history = status.keyHistory.first,
              history.keyRef == identity.keyRef,
              history.lifecycle == "active",
              history.createdAt.map({ $0 >= 0 }) == true,
              history.retiredAt == nil,
              history.deletedAt == nil,
              let historyAddress = try? VerifiedRelayerIdentity.normalizedAddress(
                  history.eoa
              ),
              historyAddress == identity.address,
              let replacement = status.replacement,
              replacement.eligible == false,
              replacement.blocked == false,
              replacement.blockedReason == nil,
              replacement.txHash == nil,
              replacement.userOpHash == nil,
              replacement.nonce == nil else {
            return false
        }
        return true
    }
}

enum RelayerSecretAuthorizationRole: Equatable, Sendable {
    case active
    case retiring
}

/// One protected relayer secret the app may read for the current daemon state.
///
/// The daemon only supplies observations. Authorization comes from the validated
/// app-owned journal and the immutable public identity record.
struct RelayerSecretAuthorization: Equatable, Sendable {
    let role: RelayerSecretAuthorizationRole
    let identity: VerifiedRelayerIdentity
}

struct RelayerSecretAuthorizationPlan: Equatable, Sendable {
    let journalHead: RelayerChainState
    let active: RelayerSecretAuthorization
    let retiring: [RelayerSecretAuthorization]

    var ordered: [RelayerSecretAuthorization] {
        [active] + retiring
    }

    func authorization(forKeyRef keyRef: String) -> RelayerSecretAuthorization? {
        ordered.first { $0.identity.keyRef == keyRef }
    }
}

/// Fail-closed authorization for every protected relayer read.
///
/// The active key must match the exact journal head, public identity record, and
/// daemon status. A historical key is readable only while the daemon reports it
/// as retiring and the validated journal proves it was previously selected.
enum RelayerSecretAuthorizationPolicy {
    enum Failure: Error, Equatable, LocalizedError {
        case retiringCountMismatch(reported: Int, observed: Int)
        case duplicateRetiringKeyRef(String)
        case activeKeyListedAsRetiring(String)
        case pendingKeyListedAsRetiring(String)
        case unjournaledRetiringKeyRef(String)
        case missingRetiringIdentity(String)
        case retiringIdentityKeyRefMismatch(expected: String, actual: String)
        case retiringIdentityChainMismatch(expected: UInt64, actual: UInt64, keyRef: String)
        case invalidRetiringAddress(keyRef: String, address: String)
        case wrongRetiringAddress(keyRef: String, expected: String, actual: String)
        case unauthorizedKeyRef(String)
        case authenticatedRecordKeyRefMismatch(expected: String, actual: String)
        case authenticatedIdentityMismatch(
            expected: VerifiedRelayerIdentity,
            actual: VerifiedRelayerIdentity
        )

        var errorDescription: String? {
            switch self {
            case .retiringCountMismatch:
                return "The daemon returned inconsistent retiring relayer state."
            case .duplicateRetiringKeyRef:
                return "The daemon returned a duplicate retiring relayer key."
            case .activeKeyListedAsRetiring:
                return "The active relayer was also reported as retiring."
            case .pendingKeyListedAsRetiring:
                return "The pending relayer was incorrectly reported as retiring."
            case .unjournaledRetiringKeyRef:
                return "The daemon selected a retiring relayer that the app never authorized."
            case .missingRetiringIdentity:
                return "A retiring relayer has no immutable public identity record."
            case .retiringIdentityKeyRefMismatch,
                 .retiringIdentityChainMismatch,
                 .invalidRetiringAddress,
                 .wrongRetiringAddress:
                return "A retiring relayer does not match the app-owned identity record."
            case .unauthorizedKeyRef:
                return "The requested relayer key is not authorized for the current state."
            case .authenticatedRecordKeyRefMismatch,
                 .authenticatedIdentityMismatch:
                return "The authenticated relayer secret does not match the authorized identity."
            }
        }
    }

    static func resolve(
        status: WalletNodeClient.RelayerStatus,
        expectedChainID: UInt64,
        expectedOwnerScope: String,
        expectedNetworkProfile: String,
        snapshot: RelayerChainSnapshot?,
        identityForKeyRef: (String) throws -> VerifiedRelayerIdentity?
    ) throws -> RelayerSecretAuthorizationPlan {
        guard let snapshot else {
            throw PassiveRelayerIdentityResolver.Failure.migrationRequired(
                chainID: expectedChainID
            )
        }

        let activeIdentity = try PassiveRelayerIdentityResolver.resolve(
            status: status,
            expectedChainID: expectedChainID,
            expectedOwnerScope: expectedOwnerScope,
            expectedNetworkProfile: expectedNetworkProfile,
            snapshot: snapshot,
            identityForKeyRef: identityForKeyRef
        )
        let active = RelayerSecretAuthorization(
            role: .active,
            identity: activeIdentity
        )

        let retiringEntries = status.keyHistory.filter { $0.lifecycle == "retiring" }
        guard status.retiringCount == retiringEntries.count else {
            throw Failure.retiringCountMismatch(
                reported: status.retiringCount,
                observed: retiringEntries.count
            )
        }

        var seen = Set<String>()
        var retiring: [RelayerSecretAuthorization] = []
        retiring.reserveCapacity(retiringEntries.count)
        for entry in retiringEntries {
            guard seen.insert(entry.keyRef).inserted else {
                throw Failure.duplicateRetiringKeyRef(entry.keyRef)
            }
            guard entry.keyRef != snapshot.head.activeKeyRef else {
                throw Failure.activeKeyListedAsRetiring(entry.keyRef)
            }
            guard entry.keyRef != snapshot.head.pendingKeyRef else {
                throw Failure.pendingKeyListedAsRetiring(entry.keyRef)
            }
            guard snapshot.previouslyActiveKeyRefs.contains(entry.keyRef) else {
                throw Failure.unjournaledRetiringKeyRef(entry.keyRef)
            }
            guard let identity = try identityForKeyRef(entry.keyRef) else {
                throw Failure.missingRetiringIdentity(entry.keyRef)
            }
            guard identity.keyRef == entry.keyRef else {
                throw Failure.retiringIdentityKeyRefMismatch(
                    expected: entry.keyRef,
                    actual: identity.keyRef
                )
            }
            guard identity.chainID == expectedChainID else {
                throw Failure.retiringIdentityChainMismatch(
                    expected: expectedChainID,
                    actual: identity.chainID,
                    keyRef: entry.keyRef
                )
            }

            let daemonAddress: String
            do {
                daemonAddress = try VerifiedRelayerIdentity.normalizedAddress(entry.eoa)
            } catch {
                throw Failure.invalidRetiringAddress(
                    keyRef: entry.keyRef,
                    address: entry.eoa
                )
            }
            guard daemonAddress == identity.address else {
                throw Failure.wrongRetiringAddress(
                    keyRef: entry.keyRef,
                    expected: identity.address,
                    actual: daemonAddress
                )
            }
            retiring.append(.init(role: .retiring, identity: identity))
        }

        retiring.sort { $0.identity.keyRef < $1.identity.keyRef }
        return RelayerSecretAuthorizationPlan(
            journalHead: snapshot.head,
            active: active,
            retiring: retiring
        )
    }

    @discardableResult
    static func verifyAuthenticated(
        record: BundlerSecretRecord,
        authorization: RelayerSecretAuthorization
    ) throws -> VerifiedRelayerIdentity {
        guard record.keyRef == authorization.identity.keyRef else {
            throw Failure.authenticatedRecordKeyRefMismatch(
                expected: authorization.identity.keyRef,
                actual: record.keyRef
            )
        }
        let actual = try VerifiedRelayerIdentity.derive(
            keyRef: record.keyRef,
            secret: record.secret
        )
        guard actual == authorization.identity else {
            throw Failure.authenticatedIdentityMismatch(
                expected: authorization.identity,
                actual: actual
            )
        }
        return actual
    }
}

enum PassiveRelayerIdentityIssue: Equatable, Sendable {
    case migrationRequired
    case unavailable

    var message: String {
        switch self {
        case .migrationRequired:
            return "Local relayer identity migration is required."
        case .unavailable:
            return "Local relayer identity could not be verified."
        }
    }
}

/// Whether the local bundler EOA can pay for the next transaction — and the copy the UI
/// shows when it can't.
///
/// The bundler self-relays every UserOp and pays the L1 gas for `handleOps`, so the daemon
/// fails closed while its balance is under `thresholdLow`
/// (`bundler_eoa_needs_topup`, `send_user_operation.rs`). Two consequences drive this type:
///
/// 1. The bundler cannot relay its own top-up, so the in-app "Fund → Send" control (a UserOp
///    from the Kernel account) can only fail while it is empty. The first top-up has to come
///    from an external wallet or faucet.
/// 2. The gate is a *threshold*, not zero — 0.004 ETH dead-ends exactly like 0 ETH — so the UI
///    keys off the daemon's `needsTopup`, never a local `balance == 0` check.
///
/// This is about the *local* bundler EOA only — see `BundlerGasPolicy.requiresBundlerGas`.
struct BundlerGasStatus: Equatable {
    /// App-owned identity derived from the protected Keychain secret and matched against the
    /// daemon status. All funding and top-up destinations come from this value.
    let verifiedIdentity: VerifiedRelayerIdentity?
    /// The active bundler EOA, when the daemon has one installed.
    let address: String?
    /// Human balance for the bundler EOA, e.g. `0.0001 ETH`. `nil` when the read failed.
    let balance: String?
    /// Human form of the daemon's low-balance threshold, e.g. `0.005 ETH`.
    let thresholdDisplay: String?
    /// Short, user-facing network name used in funding instructions.
    let networkLabel: String
    /// Explicit funding state. Unknown and unreadable balances remain distinct from a funded
    /// relayer so the dashboard cannot accidentally expose an impossible Kernel-funded action.
    let fundingState: BundlerFundingState

    /// Existing intent blocking remains tied only to a known daemon top-up requirement. An
    /// unknown status may still reach the authoritative daemon, but cannot expose a dedicated
    /// Kernel-to-bundler funding control.
    var needsGas: Bool { fundingState.needsExternalFunding }

    /// The daemon's `-32002` reason for a bundler that is under the threshold.
    static let needsTopupReason = "bundler_eoa_needs_topup"

    static let warningTitle = "Bundler doesn't have funds"

    static func from(
        relayer: WalletNodeClient.RelayerStatus?,
        verifiedIdentity: VerifiedRelayerIdentity?,
        chain: ChainConfiguration
    ) -> BundlerGasStatus {
        guard let relayer else {
            return BundlerGasStatus(
                verifiedIdentity: nil,
                address: nil,
                balance: nil,
                thresholdDisplay: nil,
                networkLabel: chain.shortName.capitalized,
                fundingState: .checking
            )
        }
        guard let verifiedIdentity,
              verifiedIdentity.chainID == chain.id,
              (try? RelayerIdentityBindingPolicy.verify(
                  status: relayer,
                  against: verifiedIdentity,
                  expectedOwnerScope: "default",
                  expectedNetworkProfile: chain.shortName
              )) != nil else {
            return BundlerGasStatus(
                verifiedIdentity: nil,
                address: nil,
                balance: nil,
                thresholdDisplay: nil,
                networkLabel: chain.shortName.capitalized,
                fundingState: .unavailable
            )
        }
        return BundlerGasStatus(
            verifiedIdentity: verifiedIdentity,
            address: verifiedIdentity.address,
            balance: displayETH(relayer.balance),
            thresholdDisplay: displayETH(relayer.thresholdLow),
            networkLabel: chain.shortName.capitalized,
            fundingState: BundlerFundingPolicy.fromObservedBalance(relayer.balance)
        )
    }

    /// Badge text for the bundler card. Named for the consequence the user cares about
    /// ("can't send") rather than the daemon's internal state ("needs top-up").
    var badgeText: String { "Out of gas. Can't send" }

    var topUpBlockTitle: String {
        switch fundingState {
        case .checking:
            return "Checking bundler balance"
        case .unavailable:
            return "Bundler balance unavailable"
        case .externalRequired:
            return "Fund the bundler externally first"
        case .kernelTopUpCandidate, .healthy:
            return "Bundler ready"
        }
    }

    var topUpBlockDetail: String {
        switch fundingState {
        case .checking, .unavailable:
            return "Retry the status check. Funding stays unavailable until the app verifies the bundler identity."
        case .externalRequired:
            return "Copy the bundler address or open the Sepolia faucet, then try again."
        case .kernelTopUpCandidate, .healthy:
            return "The bundler can relay this top-up."
        }
    }

    /// Card body: why the in-app top-up is not offered and what to do instead.
    var cardDetail: String {
        var sentences: [String] = []
        if let thresholdDisplay {
            sentences.append("Needs at least \(thresholdDisplay).")
        }
        sentences.append(
            "It relays every transaction and pays the gas, so it can't fund itself."
        )
        sentences.append("\(sendInstruction) here from another wallet\(faucetSuffix).")
        return sentences.joined(separator: " ")
    }

    /// Why a send was refused, and how to unblock it. Used by the intent card, the chat
    /// error bubble, and the card's own funding error.
    var declineDetail: String {
        var sentences: [String] = []
        switch (balance, thresholdDisplay) {
        case let (balance?, threshold?):
            sentences.append("Your bundler holds \(balance) and needs at least \(threshold) to relay this.")
        case let (balance?, nil):
            sentences.append("Your bundler holds \(balance), which is not enough to relay this.")
        case let (nil, threshold?):
            sentences.append("Your bundler needs at least \(threshold) to relay this.")
        case (nil, nil):
            sentences.append("Your bundler needs gas to relay this.")
        }
        if let address {
            sentences.append("\(sendInstruction) to \(address) from another wallet, then try again.")
        } else {
            sentences.append("Top it up from another wallet, then try again.")
        }
        return sentences.joined(separator: " ")
    }

    /// Faucet for Sepolia, the only supported app network.
    var faucetURL: URL? {
        BundlerFundingPolicy.sepoliaFaucetURL
    }

    private var sendInstruction: String {
        "Send \(networkLabel) ETH"
    }

    private var faucetSuffix: String {
        " or a faucet"
    }

    private static func displayETH(_ rawHexWei: String?) -> String? {
        guard let rawHexWei, !rawHexWei.isEmpty, rawHexWei != "unavailable" else {
            return nil
        }
        return WeiFormatter.ethDisplayString(fromHexWei: rawHexWei)
    }
}

/// Which intents the bundler-gas block applies to, and when.
/// Pure fail-closed binding between wallet-node's public relayer status and an
/// identity previously derived from the app's protected Keychain secret.
enum RelayerIdentityBindingPolicy {
    enum Failure: Error, Equatable {
        case wrongChain(expected: UInt64, actual: Int)
        case missingKeyRef
        case wrongKeyRef(expected: String, actual: String)
        case invalidEOA(String)
        case wrongEOA(expected: String, actual: String)
        case inactiveLifecycle(String)
        case wrongOwnerScope(expected: String, actual: String)
        case wrongNetworkProfile(expected: String, actual: String)
        case compromiseSuspected
        case incoherentStatus
    }

    @discardableResult
    static func verify(
        status: WalletNodeClient.RelayerStatus,
        against identity: VerifiedRelayerIdentity,
        expectedOwnerScope: String,
        expectedNetworkProfile: String
    ) throws -> VerifiedRelayerIdentity {
        guard UInt64(exactly: status.chainId) == identity.chainID else {
            throw Failure.wrongChain(expected: identity.chainID, actual: status.chainId)
        }
        guard status.ownerScope == expectedOwnerScope else {
            throw Failure.wrongOwnerScope(
                expected: expectedOwnerScope,
                actual: status.ownerScope
            )
        }
        guard status.networkProfile == expectedNetworkProfile else {
            throw Failure.wrongNetworkProfile(
                expected: expectedNetworkProfile,
                actual: status.networkProfile
            )
        }
        guard let statusKeyRef = status.keyRef else {
            throw Failure.missingKeyRef
        }
        guard statusKeyRef == identity.keyRef else {
            throw Failure.wrongKeyRef(expected: identity.keyRef, actual: statusKeyRef)
        }

        let statusEOA: String
        do {
            statusEOA = try VerifiedRelayerIdentity.normalizedAddress(status.eoa)
        } catch {
            throw Failure.invalidEOA(status.eoa)
        }
        guard statusEOA == identity.address else {
            throw Failure.wrongEOA(expected: identity.address, actual: statusEOA)
        }
        guard status.lifecycle == "active" else {
            throw Failure.inactiveLifecycle(status.lifecycle)
        }
        guard status.compromiseSubmissionBlocked == false else {
            throw Failure.compromiseSuspected
        }
        guard isCoherent(status) else {
            throw Failure.incoherentStatus
        }
        return identity
    }

    private static func isCoherent(_ status: WalletNodeClient.RelayerStatus) -> Bool {
        guard let threshold = BundlerFundingPolicy.quantity(status.thresholdLow) else {
            return false
        }
        if status.balance != "unavailable" {
            guard let balance = BundlerFundingPolicy.quantity(status.balance),
                  status.needsTopup == GasPricing.isWeiLessThan(balance, threshold) else {
                return false
            }
        }

        if status.ready {
            return status.keyLoaded
                && status.reason == nil
                && status.needsTopup == false
                && status.balance != "unavailable"
        }

        if status.keyLoaded == false {
            // wallet_bundlerStatus prioritizes locked over balance state, so a
            // locked identity may legitimately also need a top-up.
            return status.reason == "bundler_eoa_locked"
        }

        switch status.reason {
        case "bundler_eoa_needs_topup":
            return status.needsTopup && status.balance != "unavailable"
        case "bundler_balance_unavailable":
            return status.needsTopup == false && status.balance == "unavailable"
        default:
            return false
        }
    }
}

enum BundlerGasPolicy {
    /// Whether the tool's execution path is relayed by the local bundler EOA.
    static func requiresBundlerGas(_ tool: ToolIntent.Tool) -> Bool {
        switch tool {
        case .transfer, .swap, .topUpBundler:
            // All submitted as UserOperations the bundler relays and pays the gas for.
            return true
        }
    }

    /// The blocking status for an intent, or `nil` when it should be allowed through.
    ///
    /// Only pending intents are blocked: a confirmed or rejected card is history, and
    /// re-decorating it after the fact would relabel a transaction that already ran.
    static func block(
        tool: ToolIntent.Tool,
        disposition: ToolIntent.Disposition,
        status: BundlerGasStatus
    ) -> BundlerGasStatus? {
        guard disposition == .pending, requiresBundlerGas(tool) else {
            return nil
        }
        if tool == .topUpBundler {
            return status.fundingState.isOperational ? nil : status
        }
        return status.needsGas ? status : nil
    }
}

extension BundlerGasStatus {
    /// True when `error` is the daemon refusing because the bundler is under the threshold.
    ///
    /// Matches on the structured `reason` first; the message check is the fallback for
    /// errors that crossed a boundary which kept only the text (e.g. a persisted tool
    /// response replayed from `chat.sqlite`).
    static func isNeedsTopupError(_ error: Error) -> Bool {
        if case let WalletNodeClient.ClientError.rpcError(_, _, message, reason, _, _) = error {
            return reason == needsTopupReason || message.contains(needsTopupReason)
        }
        return error.localizedDescription.contains(needsTopupReason)
    }

    /// Replaces a raw `-32002 … bundler_eoa_needs_topup` with the same sentence the intent
    /// card shows. Returns `nil` for every other error so callers keep their own message.
    ///
    /// This is the backstop for the paths that can still reach the daemon's refusal — a
    /// relayer status too stale to pre-flight against, Settings, and the bundler card's own
    /// Fund control.
    static func friendlyMessage(for error: Error, status: BundlerGasStatus?) -> String? {
        guard isNeedsTopupError(error) else { return nil }
        guard let status else {
            return "\(warningTitle). Top up the bundler EOA from another wallet, then try again."
        }
        return "\(warningTitle). \(status.declineDetail)"
    }
}
