import Foundation
import WalletToolLayer

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
    /// The active bundler EOA, when the daemon has one installed.
    let address: String?
    /// Human balance for the bundler EOA, e.g. `0.0001 ETH`. `nil` when the read failed.
    let balance: String?
    /// Human form of the daemon's low-balance threshold, e.g. `0.005 ETH`.
    let thresholdDisplay: String?
    /// Short, user-facing network name used in funding instructions.
    let networkLabel: String
    /// `true` when the daemon would refuse a send with `bundler_eoa_needs_topup`.
    ///
    /// Mirrors `wallet_bundlerStatus.needsTopup`, which is `false` when the balance could not
    /// be read — an unavailable balance must not block the user locally; the daemon stays the
    /// authority and the send is attempted.
    let needsGas: Bool

    /// The daemon's `-32002` reason for a bundler that is under the threshold.
    static let needsTopupReason = "bundler_eoa_needs_topup"

    static let warningTitle = "Bundler doesn't have funds"

    static func from(
        relayer: WalletNodeClient.RelayerStatus?,
        fallbackAddress: String?,
        chain: ChainConfiguration
    ) -> BundlerGasStatus {
        let address = relayer?.availableEOA ?? fallbackAddress
        return BundlerGasStatus(
            address: (address?.hasPrefix("0x") == true) ? address : nil,
            balance: displayETH(relayer?.balance),
            thresholdDisplay: displayETH(relayer?.thresholdLow),
            networkLabel: chain.shortName.capitalized,
            needsGas: relayer?.needsTopup ?? false
        )
    }

    /// Badge text for the bundler card. Named for the consequence the user cares about
    /// ("can't send") rather than the daemon's internal state ("needs top-up").
    var badgeText: String { "Out of gas — can't send" }

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
        return URL(string: "https://cloud.google.com/application/web3/faucet/ethereum/sepolia")
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
enum BundlerGasPolicy {
    /// Whether the tool's execution path is relayed by the local bundler EOA.
    static func requiresBundlerGas(_ tool: ToolIntent.Tool) -> Bool {
        switch tool {
        case .transfer, .swap, .shield:
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
        guard disposition == .pending, requiresBundlerGas(tool), status.needsGas else {
            return nil
        }
        return status
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
