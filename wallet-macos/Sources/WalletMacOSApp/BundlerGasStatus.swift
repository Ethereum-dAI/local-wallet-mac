import Foundation
import WalletToolLayer

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
        case missingDaemonKeyRef
        case inactiveJournalIdentity(String)
    }

    static func resolve(
        status: WalletNodeClient.RelayerStatus,
        expectedChainID: UInt64,
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
            against: authorization.identity
        )
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
/// This is about the *local* bundler EOA only. A RAILGUN exit is sponsored by RAILGUN's privacy
/// paymaster and submitted by a public bundler, so it needs none of the user's gas and this
/// type does not gate it — see `BundlerGasPolicy.requiresBundlerGas`.
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
                  against: verifiedIdentity
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
        case compromiseSuspected
        case incoherentStatus
    }

    @discardableResult
    static func verify(
        status: WalletNodeClient.RelayerStatus,
        against identity: VerifiedRelayerIdentity
    ) throws -> VerifiedRelayerIdentity {
        guard UInt64(exactly: status.chainId) == identity.chainID else {
            throw Failure.wrongChain(expected: identity.chainID, actual: status.chainId)
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
        case .transfer, .swap, .shield, .topUpBundler:
            // All submitted as UserOperations the bundler relays and pays the gas for.
            return true
        case .unshield:
            // Sponsored by RAILGUN's privacy paymaster and submitted by a public bundler, so
            // the local bundler EOA's balance is irrelevant to it.
            return false
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
