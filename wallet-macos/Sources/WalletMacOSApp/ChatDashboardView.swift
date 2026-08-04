import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WalletToolLayer

extension Notification.Name {
    static let chatComposerFocusRequested = Notification.Name("com.localwallet.chat.composer.focus")
}

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Kind: String, Codable {
        case userText
        case assistantText
        case assistantError
        case toolIntent
        case toolResponse
        case onchainTransaction
    }
    enum Role: String, Codable { case user, assistant, tool }
    var id = UUID()
    var kind: Kind
    var role: Role
    var text: String? = nil
    var thinking: String? = nil
    var stats: ChatGenerationStats? = nil
    var toolIntent: ToolIntent? = nil
    var toolCallId: String? = nil
    var toolFeedback: ToolIntentFeedback? = nil

    static func userText(_ text: String) -> ChatMessage {
        ChatMessage(kind: .userText, role: .user, text: text)
    }
    static func assistantText(_ text: String, thinking: String? = nil, stats: ChatGenerationStats? = nil) -> ChatMessage {
        ChatMessage(kind: .assistantText, role: .assistant, text: text, thinking: thinking, stats: stats)
    }

    static func onchainTransaction(_ summary: OnchainTransactionSummary) -> ChatMessage {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let text = (try? encoder.encode(summary))
            .flatMap { String(data: $0, encoding: .utf8) }
        return ChatMessage(kind: .onchainTransaction, role: .assistant, text: text)
    }
}

struct ChatGenerationStats: Equatable, Codable {
    let duration: TimeInterval
    let promptTokens: Int
    let generatedTokens: Int
    let contextSize: Int

    var usedContextTokens: Int {
        promptTokens + generatedTokens
    }

    var contextTokensLeft: Int {
        max(contextSize - usedContextTokens, 0)
    }
}

struct ChatConversation: Identifiable, Equatable, Codable {
    var id = UUID()
    var title: String
    var messages: [ChatMessage]
    var createdAt = Date()
    var updatedAt = Date()
}

private struct ChatAccountIdentity: Equatable {
    let chainName: String
    let chainID: UInt64
    let isTestnet: Bool
    let kernelAddress: String
    let kernelBalance: String
    let kernelState: String
    let bundlerAddress: String
    let bundlerBalance: String
    let bundlerState: String
    /// Whether the bundler can pay for the next transaction. Drives both the card's funding
    /// controls and the pre-flight decline on the intent card.
    let bundlerGas: BundlerGasStatus

    static func placeholder(
        chain: ChainConfiguration,
        kernelAddress: String,
        bundlerAddress: String
    ) -> ChatAccountIdentity {
        ChatAccountIdentity(
            chainName: chain.name,
            chainID: chain.id,
            isTestnet: chain.isTestnet,
            kernelAddress: kernelAddress,
            kernelBalance: "Balance unavailable",
            kernelState: "Not inspected",
            bundlerAddress: bundlerAddress,
            bundlerBalance: "Balance unavailable",
            bundlerState: "Not checked",
            bundlerGas: BundlerGasStatus.from(
                relayer: nil,
                fallbackAddress: bundlerAddress,
                chain: chain
            )
        )
    }
}

private struct ChatTokenBalance: Identifiable, Equatable {
    let token: WalletToken
    let rawBalanceHex: String?
    let displayBalance: String

    var id: String {
        token.id
    }
}

struct OnchainTransactionSummary: Codable, Equatable {
    enum Operation: String, Codable {
        case transfer
        case swap
        case shield
        case unshield
    }

    enum Status: String, Codable {
        case included
        case submitted
        case reverted
        case pending
        case cancelled

        var title: String {
            switch self {
            case .included:
                return "Transaction included"
            case .submitted:
                return "Transaction submitted"
            case .reverted:
                return "Transaction reverted"
            case .pending:
                return "Transaction pending"
            case .cancelled:
                return "Transaction cancelled"
            }
        }

        var icon: String {
            switch self {
            case .included:
                return "checkmark.circle.fill"
            case .submitted:
                return "paperplane.circle.fill"
            case .reverted:
                return "xmark.octagon.fill"
            case .pending:
                return "clock.fill"
            case .cancelled:
                return "xmark.circle.fill"
            }
        }
    }

    let chainName: String
    let chainID: UInt64
    let amount: String
    let token: String
    let recipient: String
    let recipientName: String?
    let resolvedRecipient: String?
    let resolutionChainName: String?
    let resolutionChainID: UInt64?
    let ccipReadUsed: Bool?
    let operation: Operation?
    let signingMode: String?
    let amountOut: String?
    let minimumReceived: String?
    let route: String?
    let userOpHash: String
    let transactionHash: String?
    let status: Status
    let createdAt: Date

    init(
        chainName: String,
        chainID: UInt64,
        amount: String,
        token: String,
        recipient: String,
        recipientName: String?,
        resolvedRecipient: String?,
        resolutionChainName: String?,
        resolutionChainID: UInt64?,
        ccipReadUsed: Bool?,
        operation: Operation?,
        signingMode: String? = nil,
        amountOut: String?,
        minimumReceived: String?,
        route: String?,
        userOpHash: String,
        transactionHash: String?,
        status: Status,
        createdAt: Date
    ) {
        self.chainName = chainName
        self.chainID = chainID
        self.amount = amount
        self.token = token
        self.recipient = recipient
        self.recipientName = recipientName
        self.resolvedRecipient = resolvedRecipient
        self.resolutionChainName = resolutionChainName
        self.resolutionChainID = resolutionChainID
        self.ccipReadUsed = ccipReadUsed
        self.operation = operation
        self.signingMode = signingMode
        self.amountOut = amountOut
        self.minimumReceived = minimumReceived
        self.route = route
        self.userOpHash = userOpHash
        self.transactionHash = transactionHash
        self.status = status
        self.createdAt = createdAt
    }
}

enum OnchainTransactionActions {
    static func canEscape(status: OnchainTransactionSummary.Status, blocked: Bool) -> Bool {
        status == .submitted || status == .pending
    }

    static func displayBlockedReason(blocked: Bool, reason: String?) -> String? {
        guard blocked else { return nil }
        switch reason {
        case "gas_relay_stuck":
            return "Speed up unavailable: gas exceeds cap. Cancel is still available."
        case let reason?:
            return reason
        case nil:
            return "Replacement unavailable"
        }
    }
}

private enum ReplacementActionState: Equatable {
    case speedingUp
    case cancelling
    case speedUpSubmitted
    case cancelSubmitted

    var title: String {
        switch self {
        case .speedingUp:
            return "Speeding up..."
        case .cancelling:
            return "Cancelling..."
        case .speedUpSubmitted:
            return "Speed-up submitted"
        case .cancelSubmitted:
            return "Cancellation submitted"
        }
    }

    var iconName: String {
        switch self {
        case .speedingUp, .speedUpSubmitted:
            return "bolt.fill"
        case .cancelling, .cancelSubmitted:
            return "xmark.circle"
        }
    }

    var showsProgress: Bool {
        switch self {
        case .speedingUp, .cancelling:
            return true
        case .speedUpSubmitted, .cancelSubmitted:
            return false
        }
    }
}

extension OnchainTransactionSummary.Status {
    init(historyStatus: WalletTransactionStatus) {
        switch historyStatus {
        case .included:
            self = .included
        case .reverted, .failed, .dropped:
            self = .reverted
        case .cancelled:
            self = .cancelled
        case .submitted:
            self = .submitted
        case .created, .pending, .looksIncluded, .unknown:
            self = .pending
        }
    }
}

extension OnchainTransactionSummary {
    static func decode(from message: ChatMessage) -> OnchainTransactionSummary? {
        guard let data = message.text?.data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OnchainTransactionSummary.self, from: data)
    }

    func reconciled(with record: WalletTransactionRecord) -> OnchainTransactionSummary {
        guard record.userOpHash.caseInsensitiveCompare(userOpHash) == .orderedSame else {
            return self
        }
        let newStatus = OnchainTransactionSummary.Status(historyStatus: record.status)
        let recordSigningMode = signingModeFromDetailsJSON(record.detailsJSON)
        if isTerminalStatus(status), !isTerminalStatus(newStatus) {
            return with(
                status: status,
                transactionHash: record.transactionHash ?? transactionHash,
                signingMode: recordSigningMode
            )
        }
        return with(
            status: newStatus,
            transactionHash: record.transactionHash ?? transactionHash,
            signingMode: recordSigningMode
        )
    }

    func with(status: Status, transactionHash: String?, signingMode: String? = nil) -> OnchainTransactionSummary {
        OnchainTransactionSummary(
            chainName: chainName,
            chainID: chainID,
            amount: amount,
            token: token,
            recipient: recipient,
            recipientName: recipientName,
            resolvedRecipient: resolvedRecipient,
            resolutionChainName: resolutionChainName,
            resolutionChainID: resolutionChainID,
            ccipReadUsed: ccipReadUsed,
            operation: operation,
            signingMode: signingMode ?? self.signingMode,
            amountOut: amountOut,
            minimumReceived: minimumReceived,
            route: route,
            userOpHash: userOpHash,
            transactionHash: transactionHash,
            status: status,
            createdAt: createdAt
        )
    }

    private func isTerminalStatus(_ status: Status) -> Bool {
        status == .included || status == .reverted || status == .cancelled
    }
}

private func signingModeFromDetailsJSON(_ detailsJSON: String?) -> String? {
    guard let detailsJSON,
          let data = detailsJSON.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let value = object["signingMode"] as? String
    else {
        return nil
    }
    switch value {
    case "session", "passkey":
        return value
    default:
        return nil
    }
}

func reconcileMessages(
    _ messages: [ChatMessage],
    with records: [WalletTransactionRecord]
) -> [ChatMessage] {
    messages.map { message in
        guard message.kind == .onchainTransaction,
              let summary = OnchainTransactionSummary.decode(from: message),
              let record = records.first(where: {
                  $0.userOpHash.caseInsensitiveCompare(summary.userOpHash) == .orderedSame
              })
        else {
            return message
        }
        let reconciled = summary.reconciled(with: record)
        guard reconciled != summary else {
            return message
        }
        var updated = message
        updated.text = ChatMessage.onchainTransaction(reconciled).text
        return updated
    }
}

enum ChatIntentExecutionStatus: Equatable {
    case idle
    case running(String)
    case submitted(userOpHash: String, transactionHash: String?, success: Bool?)
    case failed(String)
    /// Estimation could not run. Distinct from `.failed` because it is
    /// recoverable: the daemon told us what limit would work if the user
    /// consents to submitting without a real estimate.
    case gasEstimationUnavailable(detail: String, suggestedCallGasLimit: UInt64)

    static func fromToolResponse(_ text: String) -> ChatIntentExecutionStatus? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String
        else {
            return nil
        }

        switch status {
        case "submitted":
            return .submitted(
                userOpHash: object["user_op_hash"] as? String ?? "",
                transactionHash: object["transaction_hash"] as? String,
                success: object["success"] as? Bool
            )
        case "failed":
            return .failed(object["error"] as? String ?? "Transaction failed")
        case "gas_estimation_unavailable":
            // UInt64(exactly:) rather than UInt64.init: this decodes a
            // chat.sqlite round-trip, and a negative Int would trap.
            guard let suggested = object["suggested_call_gas_limit"] as? UInt64
                    ?? (object["suggested_call_gas_limit"] as? Int).flatMap(UInt64.init(exactly:))
            else {
                return .failed("Gas estimation unavailable")
            }
            return .gasEstimationUnavailable(
                detail: object["detail"] as? String ?? "Gas estimation unavailable",
                suggestedCallGasLimit: suggested
            )
        default:
            return nil
        }
    }

    static func gasEstimationUnavailable(from error: Error) -> ChatIntentExecutionStatus? {
        guard case let WalletNodeClient.ClientError.rpcError(_, _, _, reason, detail, suggested) = error,
              reason == "gas_estimation_unavailable",
              let suggested
        else {
            return nil
        }
        return .gasEstimationUnavailable(
            detail: detail ?? "Gas estimation unavailable",
            suggestedCallGasLimit: suggested
        )
    }
}

enum ChatTransferPreflightStatus: Equatable {
    case resolving
    case resolved(WalletNodeClient.ResolvedName)
    case failed(String)
}

struct ChatSwapPreview: Equatable {
    let fromToken: WalletToken
    let toToken: WalletToken
    let amount: String
    let quote: SwapQuote
    let quotedAt: Date
}

enum ChatSwapPreflightStatus: Equatable {
    case quoting
    case quoted(ChatSwapPreview)
    case failed(String)
}

enum ChatPreflightReusePolicy {
    static let swapQuoteTTL: TimeInterval = 30

    static func canReuseSwapQuote(
        preview: ChatSwapPreview,
        fromToken: WalletToken,
        toToken: WalletToken,
        amount: String,
        now: Date = Date(),
        ttl: TimeInterval = swapQuoteTTL
    ) -> Bool {
        preview.fromToken == fromToken
            && preview.toToken == toToken
            && preview.amount.trimmingCharacters(in: .whitespacesAndNewlines) == amount.trimmingCharacters(in: .whitespacesAndNewlines)
            && now.timeIntervalSince(preview.quotedAt) <= ttl
    }
}

/// User-facing copy for a failed RAILGUN exit, keyed off the sidecar's stable failure codes.
///
/// Deliberately a free-standing pure type rather than a method on the view model: it is the
/// only part of the exit-failure path worth testing directly, and the model is file-private.
enum RailgunExitCopy {
    /// Copy for a RAILGUN exit failure, or `nil` when `error` isn't one (so callers keep their
    /// own message). Both the synchronous rejection (`rpcError`) and the async job failure
    /// (`exitFailed`) carry a stable code, and they share one code space.
    static func failureCopy(for error: Error) -> String? {
        switch error as? RailgunHelperClient.ClientError {
        case let .exitFailed(code, message), let .rpcError(code, message):
            return exitFailureMessage(code: code, message: message)
        default:
            return nil
        }
    }

    /// Whether a failed poll is evidence that the EXIT failed — the only thing that justifies
    /// flipping the card to Reverted.
    ///
    /// Only `exitFailed` qualifies: it is the sidecar's own report that the job reached a
    /// terminal failure. Every other error is evidence about the POLL, not the exit, and each
    /// one has a routine, non-failing cause:
    ///
    /// - `rpcError(unknownJobId)` — the sidecar evicts terminal jobs ON READ
    ///   (`railgun-helper.rs`), and phase 1 returns on `done` as well as `submitted`. A fast
    ///   inclusion means phase 1 already read the job to `done` and consumed it, so a phase-2
    ///   poll finds nothing. The card is already correctly Done at that point.
    /// - `connectFailed` — the helper was torn down and re-spawned (e.g. an RPC/chain switch,
    ///   see `railgunHelperClient()`), so the socket the detached task is polling is gone.
    /// - `ioFailed` — a poll queued behind a long UTXO sync exceeded the client timeout (the
    ///   sidecar serves one connection to completion), or phase 1 hit its own deadline. The
    ///   sidecar calls phase 1 UNBOUNDED, so any fixed client deadline can be exceeded while
    ///   the job goes on to submit and deliver.
    /// - `decodeFailed` — a wire-shape mismatch says nothing about the exit either.
    ///
    /// Reverting on any of those tells a user whose funds actually arrived that they didn't,
    /// which is the worst outcome in this feature. It is the same invariant the sidecar keeps
    /// on its side, where `await_exit` reports a budget overrun as `included: false` rather
    /// than as an error, for exactly this reason.
    static func shouldRevertCard(for error: Error) -> Bool {
        guard let client = error as? RailgunHelperClient.ClientError else { return false }
        if case .exitFailed = client { return true }
        return false
    }

    /// Copy for a poll that gave up without learning anything about the exit. It must not read
    /// as a failure — the exit is probably still in flight — and must steer the user away from
    /// retrying, because a second exit would spend more notes.
    static let exitStillInFlightMessage = "This exit is still in progress — the wallet stopped waiting for it, which is not the same as the exit stopping. Proving a first exit can take several minutes. Check the recipient's balance before trying again, so you don't exit twice."

    /// Map the sidecar's stable exit codes onto copy that tells the user what to do.
    ///
    /// Switching on the code is the whole point: the sidecar deliberately stripped its message
    /// prefixes so that nobody substring-matches them. Unknown codes fall through to the raw
    /// message rather than being swallowed into something generic — a code the sidecar grows
    /// later must still say *something* true, and a generic string would hide it instead.
    static func exitFailureMessage(code: String?, message: String) -> String {
        switch code {
        case "feeDidNotConverge":
            return "Gas prices are moving too quickly to price this exit. Your shielded funds are untouched — please try again shortly."
        case "bundlerRejected":
            // Deliberately NOT worded as "rejected", matching `ExitError::BundlerRejected`: if
            // `eth_sendUserOperation` reached the bundler but the response was lost, the op is
            // already in the mempool and may still land, pass validation and execute the
            // unshield. So this must never claim the funds are untouched, and it must keep the
            // sidecar's message, which carries the recoverable exit index and sender for
            // exactly that case (`bundler_rejection_names_the_recoverable_index_and_sender`).
            return "The bundler didn't confirm this exit, so it may or may not have been submitted. Check the recipient's balance before trying again — and keep the details below, which locate the funds if it did go through.\n\(message)"
        case "bundlerUnavailable":
            // Distinct from bundlerRejected: nothing was submitted, so nothing can be in flight.
            return "No public bundler is reachable right now, so this exit can't be priced. Your shielded funds are untouched — please try again shortly."
        case "paymasterNotConfigured":
            return "RAILGUN's privacy paymaster isn't available on this network, so there is no way to exit the pool here. Your shielded funds are untouched."
        case "deliveryReverted":
            // The ONE case where the raw detail must survive: it carries the exit index, which
            // is what makes stranded funds re-derivable. Keep it verbatim for a bug report.
            return "The exit landed on-chain but delivery to the recipient failed. Your funds are recoverable — please report this with the details below.\n\(message)"
        case "insufficientShieldedBalance":
            // Keep the numbers: the exact ceiling tells the user what WOULD fit, and the gas-fee
            // headroom that must stay in the pool is why it is below their balance.
            return "That's more than this exit can move out of the pool right now.\n\(message)"
        case "unknownJobId":
            // The helper restarted mid-job, so its outcome is unknown to us. Never imply it did
            // not happen — a user who assumes that may exit twice.
            return "The privacy helper restarted before this exit finished, so its outcome is unknown. Check the recipient's balance before trying again."
        default:
            return message
        }
    }
}

enum ChatIntentPreviewPolicy {
    static func shouldAutomaticallyPreparePreview(
        for message: ChatMessage,
        in messages: [ChatMessage]
    ) -> Bool {
        guard messages.reversed().first(where: { $0.kind == .toolIntent && $0.toolIntent != nil })?.id == message.id else {
            return false
        }
        return isPendingUnexecutedToolIntent(message, in: messages)
    }

    private static func isPendingUnexecutedToolIntent(
        _ message: ChatMessage,
        in messages: [ChatMessage]
    ) -> Bool {
        guard message.kind == .toolIntent,
              let intent = message.toolIntent,
              intent.disposition == .pending
        else {
            return false
        }
        return !messages.contains {
            $0.kind == .toolResponse && $0.toolCallId == intent.id.uuidString
        }
    }
}

private enum ChatIntentExecutionError: LocalizedError {
    case unsupportedTransferToken
    case unsupportedTransferAmount
    case invalidTransferRecipient
    case unsupportedENSRecipient
    case unsupportedChain
    case unsupportedSwapAmountSide
    case unsupportedSwapToken
    case unsupportedSwapAmount
    case sameSwapToken

    var errorDescription: String? {
        switch self {
        case .unsupportedTransferToken:
            return "That token is not in the local token registry for the active chain yet."
        case .unsupportedTransferAmount:
            return "Only explicit decimal token amounts are executable right now."
        case .invalidTransferRecipient:
            return "Enter a 0x Ethereum address or an ENS name with at least one dot."
        case .unsupportedENSRecipient:
            return "That ENS name could not be resolved to an EVM address on the active chain."
        case .unsupportedChain:
            return "The active chain does not have a local token registry yet."
        case .unsupportedSwapAmountSide:
            return "Only exact-input swaps are supported. Say how much of the input token to spend, for example “swap 10 USDC to ETH”."
        case .unsupportedSwapToken:
            return "That swap token is not in the local token registry for the active chain yet."
        case .unsupportedSwapAmount:
            return "Only explicit decimal input amounts are executable for swaps right now."
        case .sameSwapToken:
            return "Choose two different tokens for a swap."
        }
    }
}

private struct ChatTransferRequest {
    let recipient: String
    let recipientName: String?
    let resolvedName: WalletNodeClient.ResolvedName?
    let amount: String
    let token: WalletToken
}

private struct ChatSwapRequest {
    let fromToken: WalletToken
    let toToken: WalletToken
    let amount: String
    let quote: SwapQuote
}

enum ContextUsageLevel {
    case warning
    case critical
}

private enum ChatSidebarBucket: String, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case lastSevenDays = "Last 7 days"
    case lastThirtyDays = "Last 30 days"
    case older = "Older"

    static func bucket(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ChatSidebarBucket {
        if calendar.isDateInToday(date) {
            return .today
        }
        if calendar.isDateInYesterday(date) {
            return .yesterday
        }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days <= 7 {
            return .lastSevenDays
        }
        if days <= 30 {
            return .lastThirtyDays
        }
        return .older
    }
}

@MainActor
private final class ChatDashboardModel: ObservableObject {
    @Published var inputText = ""
    @Published private(set) var conversations: [ChatConversation]
    @Published private(set) var activeConversationID: UUID
    @Published private(set) var isGenerating = false
    @Published private(set) var runtimeStatus: String
    @Published var thinkingEnabled = true
    @Published var isSidebarVisible = true
    @Published private(set) var accountIdentity: ChatAccountIdentity
    @Published private(set) var streamingText: String = ""
    @Published private(set) var streamingMessageID: UUID? = nil
    @Published var feedbackExportMessage: String? = nil
    @Published private(set) var walletHistoryRecords: [WalletTransactionRecord] = []
    @Published private(set) var isRefreshingWalletHistory = false
    @Published var walletHistoryMessage: String? = nil
    @Published var selectedHistoryUserOpHash: String? = nil
    @Published private(set) var kernelTokenBalances: [ChatTokenBalance] = []
    @Published private(set) var bundlerTokenBalances: [ChatTokenBalance] = []
    @Published private(set) var isRefreshingTokenBalances = false
    // Shielded (RAILGUN) balance, split by pool status. `confirmed` = cleared and spendable;
    // `pending` = deposited but not yet included by the pool's approval set.
    @Published private(set) var shieldedConfirmed: String?
    @Published private(set) var shieldedPending: String?
    @Published private(set) var isRefreshingShieldedBalance = false
    @Published private(set) var shieldedBalanceError: String?
    // Which helper EOA is mid gas-funding, so its card shows a spinner and disables its Send
    // button; nil when idle. Plus the last funding error. The bundler is the only gas-paying
    // helper the user funds — exits are sponsored by RAILGUN's privacy paymaster.
    @Published private(set) var fundingHelperAddress: String?
    @Published private(set) var helperFundError: String?
    @Published private(set) var helperFundErrorAddress: String?
    @Published private(set) var tokenBalanceMessage: String? = nil
    @Published private var transferPreflightStatuses: [UUID: ChatTransferPreflightStatus] = [:]
    @Published private var swapPreflightStatuses: [UUID: ChatSwapPreflightStatus] = [:]
    @Published private var replacementActionStates: [String: ReplacementActionState] = [:]

    private var generationTask: Task<Void, Never>? = nil
    private var transferPreflightTasks: [UUID: Task<Void, Never>] = [:]
    private var swapPreflightTasks: [UUID: Task<Void, Never>] = [:]
    private var walletModelCancellable: AnyCancellable?
    private var gasPollTask: Task<Void, Never>?
    private var sessionActivityEventMonitor: Any?
    private var appDidBecomeActiveObserver: NSObjectProtocol?
    private let inferenceService: EmbeddedLlamaInferenceService
    private let chatStore: ChatSQLiteStore
    private let walletHistoryStore: WalletTransactionHistoryStore
    private let preferencesStore: ChatPreferencesStore
    private let onboardingSettingsStore: OnboardingSettingsStore
    private let walletModel: AppModel
    private var executingIntentIDs: Set<UUID> = []
    /// The railgun-helper sidecar (spawned lazily on first /shield or /unshield, on the
    /// app's active chain). Killed when this model is torn down (daemon deinit).
    private var railgunDaemon: RailgunHelperDaemon?
    // The active-chain RPC the cached `railgunDaemon` was launched with. If the active RPC
    // changes (e.g. the user switches providers), the spawned helper is still bound to the old
    // RPC, so we must tear it down and re-spawn — see `railgunHelperClient()`.
    private var railgunDaemonRPC: String?
    private var lastTokenBalanceKey: String?
    private var lastTokenBalanceAttemptKey: String?
    private var lastTokenBalanceAttemptAt: Date?
    private static let tokenBalanceRetryCooldown: TimeInterval = 20

    init(
        inferenceService: EmbeddedLlamaInferenceService = EmbeddedLlamaInferenceService(),
        chatStore: ChatSQLiteStore = ChatSQLiteStore(),
        walletHistoryStore: WalletTransactionHistoryStore = WalletTransactionHistoryStore(),
        preferencesStore: ChatPreferencesStore = ChatPreferencesStore(),
        settingsStore: OnboardingSettingsStore = OnboardingSettingsStore(),
        metadataStore: WalletMetadataStore = WalletMetadataStore(),
        walletModel: AppModel? = nil
    ) {
        self.inferenceService = inferenceService
        self.chatStore = chatStore
        self.walletHistoryStore = walletHistoryStore
        self.preferencesStore = preferencesStore
        self.onboardingSettingsStore = settingsStore
        self.walletModel = walletModel ?? AppModel(
            onboardingSettingsStore: settingsStore,
            walletHistoryStore: walletHistoryStore
        )
        self.runtimeStatus = inferenceService.runtimeStatus
        self.thinkingEnabled = preferencesStore.thinkingEnabled
        self.isSidebarVisible = preferencesStore.sidebarVisible

        if !preferencesStore.migratedToSQLite {
            let legacyConversations = preferencesStore.loadLegacyConversations()
            if !legacyConversations.isEmpty {
                try? chatStore.replaceConversations(legacyConversations)
            }
            preferencesStore.migratedToSQLite = true
        }

        let loadedConversations = ((try? chatStore.loadConversations()) ?? []).sorted { $0.updatedAt > $1.updatedAt }
        if loadedConversations.isEmpty {
            let conversation = ChatConversation(title: "New chat", messages: [])
            self.conversations = [conversation]
            self.activeConversationID = conversation.id
            try? chatStore.createConversation(conversation)
        } else {
            self.conversations = loadedConversations
            self.activeConversationID = preferencesStore.activeConversationID.flatMap { savedID in
                loadedConversations.contains { $0.id == savedID } ? savedID : nil
            } ?? loadedConversations[0].id
        }

        let kernelAddress = (try? metadataStore.load())?.kernelAccountAddress ?? "Not available"
        self.accountIdentity = ChatAccountIdentity.placeholder(
            chain: self.walletModel.activeChain,
            kernelAddress: kernelAddress,
            bundlerAddress: settingsStore.bundlerAddress(chainId: self.walletModel.activeChain.id) ?? "Not available"
        )
        preferencesStore.activeConversationID = self.activeConversationID
        walletModelCancellable = self.walletModel.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.objectWillChange.send()
                self?.refreshAccountIdentity()
                self?.reloadWalletHistory()
                self?.refreshTokenBalancesIfNeeded()
            }
        }
        refreshAccountIdentity()
        self.walletModel.bootstrap()
        // Capture the AppModel, not self: the poll loop runs until cancelled, so a
        // strong self-capture would keep this model alive forever and prevent deinit
        // (hence the cancel) from ever running.
        let gasModel = self.walletModel
        gasPollTask = Task {
            await gasModel.runGasPriceUpdates()
        }
        // Picks up operations left unfinalised by a previous session. Goes through the AppModel
        // entry point rather than the loop body so this launch-time start and the post-send start
        // share one dedup guard, instead of each owning a loop over the same history store.
        self.walletModel.startUserOperationReconcilerIfNeeded()
        backfillWalletHistoryFromChat()
        reloadWalletHistory()
        refreshTokenBalancesIfNeeded()
    }

    deinit {
        gasPollTask?.cancel()
        // The reconciler task now lives on the AppModel, and `deinit` is nonisolated, so stopping it
        // means hopping to the main actor. Capture the model, not `self`, which is mid-deallocation.
        // The running loop retains the AppModel for the duration of its current call, so without
        // this it would keep polling after the dashboard is gone.
        let walletModel = self.walletModel
        Task { @MainActor in
            walletModel.stopUserOperationReconciler()
        }
    }

    var activeConversation: ChatConversation? {
        conversations.first { $0.id == activeConversationID }
    }

    var messages: [ChatMessage] {
        activeConversation?.messages ?? []
    }

    var gasPillText: String {
        guard let price = walletModel.liveGasPrice else { return "— gwei" }
        let headWei = walletModel.liveBaseFeeWei ?? price.standard.maxFeePerGas
        let head = GasPricing.gweiText(fromWei: headWei)
        let priority = GasPricing.gweiText(fromWei: price.standard.maxPriorityFeePerGas)
        let policy = walletModel.networkSettings
        let policyText = policy.autoGasModeEnabled
            ? "Auto \(policy.autoGasTier.label)"
            : "Cap \(policy.activeMaxFeePerGasGwei)/\(policy.activeMaxPriorityFeePerGasGwei)"
        return "Live \(head)/\(priority) · \(policyText)"
    }

    var gasBreakdown: GasBreakdownDisplay {
        let price = walletModel.liveGasPrice
        func row(_ id: String, _ name: String, _ tier: WalletNodeClient.UserOperationGasPriceTier?) -> GasTierRow {
            GasTierRow(
                id: id,
                name: name,
                maxFee: tier.map { GasPricing.gweiText(fromWei: $0.maxFeePerGas) } ?? "—",
                priority: tier.map { GasPricing.gweiText(fromWei: $0.maxPriorityFeePerGas) } ?? "—"
            )
        }
        let baseFee = walletModel.liveBaseFeeWei.map { GasPricing.gweiText(fromWei: $0) }
        let updated: String
        if let at = walletModel.liveGasUpdatedAt {
            let seconds = max(0, Int(Date().timeIntervalSince(at)))
            updated = seconds < 5 ? "Updated just now" : "Updated \(seconds)s ago"
        } else {
            updated = "Not loaded yet"
        }
        let settings = walletModel.networkSettings
        let mode = settings.autoGasModeEnabled
            ? "Auto · \(settings.autoGasTier.label.lowercased()) tier"
            : "Manual · capped at \(settings.activeMaxFeePerGasGwei)/\(settings.activeMaxPriorityFeePerGasGwei) gwei"
        let appliedFee: (maxPriorityFeePerGas: Data, maxFeePerGas: Data)?
        if let price {
            appliedFee = GasPricing.resolveUserOperationFees(
                gasPrice: price,
                autoEnabled: settings.autoGasModeEnabled,
                autoTier: settings.autoGasTier,
                manualCap: settings.activeGasPolicy
            )
        } else {
            appliedFee = nil
        }
        return GasBreakdownDisplay(
            baseFee: baseFee,
            tiers: [
                row("slow", "Slow", price?.slow),
                row("standard", "Standard", price?.standard),
                row("fast", "Fast", price?.fast),
            ],
            policyTitle: "Applied userOp fee",
            policyMaxFee: appliedFee.map { GasPricing.gweiText(fromWei: $0.maxFeePerGas) } ?? "—",
            policyPriority: appliedFee.map { GasPricing.gweiText(fromWei: $0.maxPriorityFeePerGas) } ?? "—",
            modeText: mode,
            updatedText: updated
        )
    }

    func refreshGasPricesNow() {
        Task { await walletModel.refreshLiveGasPrices() }
    }

    /// Quiet balance re-read for a user action that reveals the balance. Subject to the same
    /// coalescing floor as the other event-driven triggers, so repeatedly toggling the cards
    /// doesn't repeatedly hit the chain.
    func refreshAccountBalanceOnDemand() {
        Task { await walletModel.refreshAccountBalanceQuietly(logContext: "balance-reveal") }
    }

    func startSessionActivityTracking() {
        walletModel.handleAppBecameActive()
        if sessionActivityEventMonitor == nil {
            sessionActivityEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [
                    .leftMouseDown,
                    .rightMouseDown,
                    .otherMouseDown,
                    .keyDown,
                    .scrollWheel,
                    .magnify,
                    .swipe,
                    .rotate,
                ]
            ) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.walletModel.recordSessionUserActivity()
                }
                return event
            }
        }
        if appDidBecomeActiveObserver == nil {
            appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.walletModel.handleAppBecameActive()
                }
            }
        }
    }

    func stopSessionActivityTracking() {
        if let sessionActivityEventMonitor {
            NSEvent.removeMonitor(sessionActivityEventMonitor)
            self.sessionActivityEventMonitor = nil
        }
        if let appDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(appDidBecomeActiveObserver)
            self.appDidBecomeActiveObserver = nil
        }
    }

    var settingsSnapshot: LocalWalletSettingsSnapshot {
        let chain = walletModel.activeChain
        let selectedModel = LocalAIModel.available.first { $0.id == onboardingSettingsStore.selectedModelID } ?? .recommended
        let storedInstalledPath = onboardingSettingsStore.installedModelPath ?? ""
        let bundledInstalledPath = LocalAIModelDownloadManager.bundledFileURL(for: selectedModel)?.path ?? ""
        let installedPath = storedInstalledPath.isEmpty ? bundledInstalledPath : storedInstalledPath
        let installedModelID = onboardingSettingsStore.installedModelID ?? (bundledInstalledPath.isEmpty ? nil : selectedModel.id)
        let modelFileExists = installedPath.isEmpty == false && FileManager.default.fileExists(atPath: installedPath)
        let installStatus: String
        if installedModelID == selectedModel.id, modelFileExists {
            installStatus = "Installed"
        } else if installedModelID == selectedModel.id {
            installStatus = "Missing file"
        } else {
            installStatus = "Not installed"
        }

        let appBuild = LocalWalletSettingsSnapshot.appVersionText()
        let networkSettings = walletModel.networkSettings
        let gasPolicy = networkSettings.activeGasPolicy
        let relayerStatus = walletModel.localRelayerStatus
        let now = Date()
        let sessionRecord = walletModel.walletRecord?.sessionRecords.first { $0.chainId == chain.id }
        let walletNodeMode = WalletNodeClient.Configuration.fromEnvironment() == nil
            ? "Managed local daemon"
            : "External wallet-node"
        let databaseSize = Self.byteFormatter.string(fromByteCount: Int64(chatStore.databaseFileSizeBytes()))
        let rankingCount = (try? chatStore.loadToolIntentFeedbackExportRecords().count) ?? 0

        return LocalWalletSettingsSnapshot(
            capturedAt: now,
            appVersion: appBuild.version,
            appBuild: appBuild.build,
            textModelName: selectedModel.name,
            textModelIdentifier: selectedModel.id,
            textModelSize: selectedModel.size,
            textModelDetail: selectedModel.detail,
            textModelArtifactRepo: selectedModel.artifactRepo,
            textModelArtifactFileName: selectedModel.artifactFileName,
            textModelRuntimeStatus: runtimeStatus,
            textModelInstallStatus: installStatus,
            textModelPath: installedPath.isEmpty ? "Not set" : installedPath,
            contextWindow: "\(inferenceService.contextSize) tokens",
            contextWindowTokens: onboardingSettingsStore.contextWindowTokens,
            contextWindowMaxTokens: selectedModel.maxContextTokens,
            multimodalModelName: "Not configured",
            multimodalModelStatus: "No local vision model selected",
            networkSettings: networkSettings,
            chainName: chain.name,
            chainID: String(chain.id),
            executionRPCURL: chain.rpcURL.absoluteString,
            configuredRPCURL: networkSettings.activeRPCURL,
            archiveNodeURL: chain.archiveRPCURL?.absoluteString ?? "Not set",
            consensusRPCURL: chain.consensusRPCURL?.absoluteString ?? "Not set",
            maxFeePerGasCap: "\(gasPolicy.maxFeePerGasGwei) gwei",
            maxPriorityFeePerGasCap: "\(gasPolicy.maxPriorityFeePerGasGwei) gwei",
            entryPointAddress: chain.entryPoint,
            kernelFactoryAddress: chain.kernel.factory,
            kernelImplementationAddress: chain.kernel.implementation,
            validatorAddress: chain.kernel.webAuthnValidator,
            kernelAccountAddress: accountIdentity.kernelAddress,
            kernelAccountState: accountIdentity.kernelState,
            kernelAccountBalance: accountIdentity.kernelBalance,
            relayerAddress: accountIdentity.bundlerAddress,
            relayerState: accountIdentity.bundlerState,
            relayerNeedsGas: accountIdentity.bundlerGas.needsGas,
            relayerBalance: accountIdentity.bundlerBalance,
            relayerKeyRef: relayerStatus?.keyRef ?? "Not available",
            relayerLifecycle: relayerStatus?.lifecycle.capitalized ?? accountIdentity.bundlerState,
            relayerPendingFundingAddress: relayerStatus?.pendingFundingAddress ?? "None",
            relayerPendingFundingCount: relayerStatus?.pendingFundingCount ?? 0,
            relayerRetiringCount: relayerStatus?.retiringCount ?? 0,
            relayerLatestAuditEvent: relayerStatus?.latestAuditEvent ?? "None",
            relayerMessage: walletModel.localRelayerMessage,
            databasePath: chatStore.databaseFileURL.path,
            databaseSize: databaseSize,
            conversationCount: conversations.count,
            messageCount: conversations.reduce(0) { $0 + $1.messages.count },
            rankingCount: rankingCount,
            walletNodeMode: walletNodeMode,
            walletNodeConfigPath: LocalWalletSettingsSnapshot.walletNodeConfigPath(),
            walletNodeLogPath: WalletNodeClient.Configuration.fromEnvironment() == nil
                ? LocalWalletSettingsSnapshot.walletNodeLogPath()
                : "External wallet-node; inspect that daemon's configured logs directory.",
            unlockRelayerOnLaunch: walletModel.unlockRelayerOnLaunch,
            walletKeyPolicy: "Secure Enclave P-256 key; local user presence required for signing.",
            relayerKeyPolicy: "Keychain generic password protected by current biometric set.",
            session: LocalWalletSessionSettingsSnapshot(
                isEnabled: walletModel.sessionKeysEnabled,
                configuredPolicy: walletModel.sessionPolicy,
                record: sessionRecord,
                capturedAt: now
            ),
            bridgeStatus: walletModel.bridgeStatus,
            activeBundlerStatus: walletModel.activeBundlerStatus,
            lastSubmittedUserOperationHash: walletModel.lastSubmittedUserOperationHash ?? "None",
            lastBundledTransactionHash: walletModel.lastBundledTransactionHash ?? "None",
            lastError: walletModel.lastError ?? "None",
            releaseChannel: "Preview",
            walletNodeVersion: "Managed by local wallet-node",
            rustFFIBuild: "Linked libwallet_ffi",
            localLLMBackend: "llama.cpp",
            swapSlippageBps: walletModel.swapSlippageBps
        )
    }

    var selectedHistoryRecord: WalletTransactionRecord? {
        if let selectedHistoryUserOpHash,
           let record = walletHistoryRecords.first(where: {
               $0.userOpHash.caseInsensitiveCompare(selectedHistoryUserOpHash) == .orderedSame
           }) {
            return record
        }
        return walletHistoryRecords.first
    }

    var slashSuggestions: [SlashCommand] {
        SlashCatalog.suggestions(for: inputText)
    }

    func insertSlashCommand(_ command: SlashCommand) {
        inputText = command.scaffold
        NotificationCenter.default.post(name: .chatComposerFocusRequested, object: nil)
    }

    func selectHistoryRecord(_ record: WalletTransactionRecord) {
        selectedHistoryUserOpHash = record.userOpHash
    }

    func selectHistoryRecord(userOpHash: String) {
        selectedHistoryUserOpHash = userOpHash
    }

    func clearSelectedHistoryRecord() {
        selectedHistoryUserOpHash = nil
    }

    func reloadWalletHistory() {
        let records = (try? walletHistoryStore.loadRecords(
            accountAddress: walletModel.walletRecord?.kernelAccountAddress,
            chainID: walletModel.activeChain.id,
            limit: 200
        )) ?? []
        walletHistoryRecords = records
        reconcileOnchainCards(with: records)
        if let selectedHistoryUserOpHash,
           !records.contains(where: { $0.userOpHash.caseInsensitiveCompare(selectedHistoryUserOpHash) == .orderedSame }) {
            self.selectedHistoryUserOpHash = nil
        }
    }

    private func reconcileOnchainCards(with records: [WalletTransactionRecord]) {
        for conversationIndex in conversations.indices {
            let updatedMessages = reconcileMessages(conversations[conversationIndex].messages, with: records)
            for messageIndex in conversations[conversationIndex].messages.indices
                where conversations[conversationIndex].messages[messageIndex].text != updatedMessages[messageIndex].text {
                conversations[conversationIndex].messages[messageIndex].text = updatedMessages[messageIndex].text
                try? chatStore.updateMessage(
                    conversations[conversationIndex].messages[messageIndex],
                    in: conversations[conversationIndex].id
                )
            }
        }
    }

    func refreshWalletHistory() {
        guard !isRefreshingWalletHistory else {
            return
        }
        isRefreshingWalletHistory = true
        walletHistoryMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let records = try await self.walletModel.refreshWalletHistoryReceipts()
                self.walletHistoryRecords = records
                self.reconcileOnchainCards(with: records)
                self.walletHistoryMessage = self.walletHistoryRecords.isEmpty
                    ? nil
                    : "History refreshed."
            } catch {
                self.walletHistoryMessage = "Could not refresh receipts: \(error.localizedDescription)"
                self.reloadWalletHistory()
            }
            self.isRefreshingWalletHistory = false
        }
    }

    func speedUpPendingOperation(_ userOpHash: String) {
        let key = replacementActionKey(for: userOpHash)
        guard replacementActionStates[key] == nil else {
            return
        }
        replacementActionStates[key] = .speedingUp
        Task { @MainActor [weak self] in
            guard let self else { return }
            let didSubmit = await self.walletModel.speedUpPendingOperation(userOpHash: userOpHash)
            self.reloadWalletHistory()
            if didSubmit {
                self.replacementActionStates[key] = .speedUpSubmitted
                self.clearReplacementAction(key, matching: .speedUpSubmitted)
            } else {
                self.replacementActionStates[key] = nil
            }
        }
    }

    func cancelPendingOperation(_ userOpHash: String) {
        let key = replacementActionKey(for: userOpHash)
        guard replacementActionStates[key] == nil else {
            return
        }
        replacementActionStates[key] = .cancelling
        Task { @MainActor [weak self] in
            guard let self else { return }
            let didSubmit = await self.walletModel.cancelPendingOperation(userOpHash: userOpHash)
            self.reloadWalletHistory()
            if didSubmit {
                self.replacementActionStates[key] = .cancelSubmitted
                self.clearReplacementAction(key, matching: .cancelSubmitted)
            } else {
                self.replacementActionStates[key] = nil
            }
        }
    }

    func replacementStatus(for summary: OnchainTransactionSummary) -> WalletNodeClient.RelayerStatus.ReplacementStatus? {
        guard let replacement = walletModel.localRelayerStatus?.replacement else {
            return nil
        }
        if let replacementHash = replacement.userOpHash,
           replacementHash.caseInsensitiveCompare(summary.userOpHash) != .orderedSame {
            return nil
        }
        return replacement
    }

    func replacementActionState(for userOpHash: String) -> ReplacementActionState? {
        replacementActionStates[replacementActionKey(for: userOpHash)]
    }

    private func replacementActionKey(for userOpHash: String) -> String {
        userOpHash.lowercased()
    }

    private func clearReplacementAction(_ key: String, matching state: ReplacementActionState) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.replacementActionStates[key] == state else {
                return
            }
            self.replacementActionStates[key] = nil
        }
    }

    func exportWalletHistory() {
        reloadWalletHistory()
        let records = walletHistoryRecords
        guard !records.isEmpty else {
            walletHistoryMessage = "No wallet history to export."
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)

            let panel = NSSavePanel()
            panel.title = "Download wallet history"
            panel.nameFieldStringValue = "local-wallet-history-\(Self.exportDateStamp()).json"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false

            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }

            try data.write(to: url, options: [.atomic])
            walletHistoryMessage = "Exported \(records.count) history record\(records.count == 1 ? "" : "s")."
        } catch {
            walletHistoryMessage = "Could not export wallet history: \(error.localizedDescription)"
        }
    }

    func refreshTokenBalances(force: Bool = false) {
        guard !isRefreshingTokenBalances else {
            return
        }
        let chain = walletModel.activeChain
        let kernelAddress = walletModel.walletRecord?.kernelAccountAddress ?? accountIdentity.kernelAddress
        let bundlerAddress = walletModel.localRelayerStatus?.eoa ?? accountIdentity.bundlerAddress
        guard kernelAddress.hasPrefix("0x"), bundlerAddress.hasPrefix("0x") else {
            return
        }
        if !force,
           accountIdentity.kernelBalance == "Balance unavailable"
            || accountIdentity.bundlerBalance == "Balance unavailable" {
            return
        }

        let key = "\(chain.id):\(kernelAddress.lowercased()):\(bundlerAddress.lowercased())"
        let hasIncompleteBalances = Self.hasIncompleteTokenBalances(kernelTokenBalances)
            || Self.hasIncompleteTokenBalances(bundlerTokenBalances)
        if !force,
           let attemptKey = lastTokenBalanceAttemptKey,
           attemptKey == key,
           let attemptAt = lastTokenBalanceAttemptAt,
           Date().timeIntervalSince(attemptAt) < Self.tokenBalanceRetryCooldown,
           key != lastTokenBalanceKey {
            return
        }
        guard force || key != lastTokenBalanceKey || hasIncompleteBalances else {
            return
        }
        lastTokenBalanceAttemptKey = key
        lastTokenBalanceAttemptAt = Date()
        isRefreshingTokenBalances = true
        tokenBalanceMessage = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            async let kernel = self.loadTokenBalances(address: kernelAddress, chain: chain)
            async let bundler = self.loadTokenBalances(address: bundlerAddress, chain: chain)
            let loaded = await (kernel, bundler)
            self.kernelTokenBalances = loaded.0
            self.bundlerTokenBalances = loaded.1
            if Self.hasIncompleteTokenBalances(loaded.0) || Self.hasIncompleteTokenBalances(loaded.1) {
                self.lastTokenBalanceKey = nil
                self.tokenBalanceMessage = "Some token balances are unavailable."
            } else {
                self.lastTokenBalanceKey = key
                self.tokenBalanceMessage = nil
            }
            self.isRefreshingTokenBalances = false
        }
    }

    private func refreshTokenBalancesIfNeeded() {
        refreshTokenBalances(force: false)
    }

    private func loadTokenBalances(address: String, chain: ChainConfiguration) async -> [ChatTokenBalance] {
        var balances: [ChatTokenBalance] = []
        for token in WalletTokenRegistry.tokens(on: chain.id) {
            do {
                let balanceHex: String
                if token.isNative {
                    balanceHex = try await withBalanceReadRetry {
                        try await walletModel.ethBalance(address: address)
                    }
                } else if let tokenAddress = token.contractAddress {
                    balanceHex = try await withBalanceReadRetry {
                        try await walletModel.erc20Balance(
                            tokenAddress: tokenAddress,
                            ownerAddress: address
                        )
                    }
                } else {
                    continue
                }
                balances.append(ChatTokenBalance(
                    token: token,
                    rawBalanceHex: balanceHex,
                    displayBalance: try TokenBalanceDisplay.displayString(
                        balanceHex: balanceHex,
                        decimals: token.decimals,
                        symbol: token.symbol
                    )
                ))
            } catch {
                balances.append(ChatTokenBalance(
                    token: token,
                    rawBalanceHex: nil,
                    displayBalance: "Unavailable"
                ))
            }
        }
        return balances
    }

    private func backfillWalletHistoryFromChat() {
        let accountAddress = walletModel.walletRecord?.kernelAccountAddress ?? accountIdentity.kernelAddress
        guard accountAddress.hasPrefix("0x") else {
            return
        }

        for conversation in conversations {
            for message in conversation.messages where message.kind == .onchainTransaction {
                guard let summary = OnchainTransactionCard.summary(from: message) else {
                    continue
                }
                let record = WalletTransactionRecord(
                    chainID: summary.chainID,
                    chainName: summary.chainName,
                    accountAddress: accountAddress,
                    operation: historyOperation(from: summary.operation),
                    status: historyStatus(from: summary.status),
                    userOpHash: summary.userOpHash,
                    transactionHash: summary.transactionHash,
                    amount: summary.amount,
                    token: summary.token,
                    counterparty: summary.recipient,
                    counterpartyName: summary.recipientName,
                    route: summary.route,
                    amountOut: summary.amountOut,
                    minimumReceived: summary.minimumReceived,
                    conversationID: conversation.id,
                    messageID: message.id,
                    detailsJSON: summary.signingMode.map { #"{"signingMode":"\#($0)"}"# },
                    createdAt: summary.createdAt,
                    updatedAt: summary.createdAt
                )
                try? walletHistoryStore.upsert(record)
            }
        }
    }

    private func historyOperation(from operation: OnchainTransactionSummary.Operation?) -> WalletTransactionOperation {
        switch operation {
        case .transfer:
            return .transfer
        case .swap:
            return .swap
        case .shield:
            return .shield
        case .unshield:
            return .unshield
        case nil:
            return .unknown
        }
    }

    private func historyStatus(from status: OnchainTransactionSummary.Status) -> WalletTransactionStatus {
        switch status {
        case .included:
            return .included
        case .submitted:
            return .submitted
        case .reverted:
            return .reverted
        case .pending:
            return .pending
        case .cancelled:
            return .cancelled
        }
    }

    var contextUsageLevel: ContextUsageLevel? {
        guard let stats = messages.last(where: { $0.stats != nil })?.stats else {
            return nil
        }
        let ratio = Double(stats.usedContextTokens) / Double(max(stats.contextSize, 1))
        if ratio >= 0.92 {
            return .critical
        }
        if ratio >= 0.75 {
            return .warning
        }
        return nil
    }

    var contextUsageSnapshot: (used: Int, total: Int)? {
        guard let stats = messages.last(where: { $0.stats != nil })?.stats else {
            return nil
        }
        return (stats.usedContextTokens, stats.contextSize)
    }

    var contextStatsText: String {
        guard let stats = messages.last(where: { $0.stats != nil })?.stats else {
            return "Context 0 / \(inferenceService.contextSize) · \(inferenceService.contextSize) left"
        }
        return "Context \(stats.usedContextTokens) / \(stats.contextSize) · \(stats.contextTokensLeft) left"
    }

    var hasExecutingIntent: Bool {
        !executingIntentIDs.isEmpty
    }

    var executionStatusText: String {
        hasExecutingIntent ? walletModel.bridgeStatus : runtimeStatus
    }

    var isRefreshingAccountIdentity: Bool {
        walletModel.isRefreshingBalance || walletModel.isRefreshingLocalRelayer
    }

    func toggleThinking() {
        thinkingEnabled.toggle()
        preferencesStore.thinkingEnabled = thinkingEnabled
    }

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSidebarVisible.toggle()
        }
        preferencesStore.sidebarVisible = isSidebarVisible
    }

    func refreshOnchainAccountStatus() {
        walletModel.refreshOnchainAccountStatus()
        refreshTokenBalances(force: true)
    }

    func createNewChat() {
        guard !isGenerating else {
            return
        }
        let conversation = ChatConversation(title: "New chat", messages: [])
        conversations.insert(conversation, at: 0)
        activeConversationID = conversation.id
        preferencesStore.activeConversationID = conversation.id
        try? chatStore.createConversation(conversation)
    }

    func selectConversation(_ conversation: ChatConversation) {
        guard !isGenerating else {
            return
        }
        activeConversationID = conversation.id
        preferencesStore.activeConversationID = conversation.id
    }

    func renameConversation(_ conversationID: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }
        guard conversations[index].title != trimmed else {
            return
        }
        conversations[index].title = String(trimmed.prefix(120))
        conversations[index].updatedAt = Date()
        try? chatStore.updateConversationMetadata(conversations[index])
        sortConversationsKeepingActive()
    }

    func deleteConversation(_ conversationID: UUID) {
        guard !isGenerating else {
            return
        }
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }
        let wasActive = conversationID == activeConversationID
        conversations.remove(at: index)
        try? chatStore.deleteConversation(conversationID)

        if conversations.isEmpty {
            let replacement = ChatConversation(title: "New chat", messages: [])
            conversations = [replacement]
            try? chatStore.createConversation(replacement)
            activeConversationID = replacement.id
            preferencesStore.activeConversationID = replacement.id
        } else if wasActive {
            let nextID = conversations[0].id
            activeConversationID = nextID
            preferencesStore.activeConversationID = nextID
        }
    }

    func send(_ text: String? = nil) {
        let prompt = (text ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isGenerating else {
            return
        }

        let conversationID = activeConversationID
        let existingMessages = messages
        let history = existingMessages.map { message in
            EmbeddedLlamaChatTurn(
                role: message.role == .user ? .user : .assistant,
                text: message.text ?? ""
            )
        }
        inputText = ""
        appendMessage(.userText(prompt), to: conversationID)
        updateTitleIfNeeded(for: conversationID, prompt: prompt)

        if prompt.hasPrefix("/") {
            do {
                let intent = try SlashCommandParser().parse(prompt)
                appendMessage(
                    ChatMessage(kind: .toolIntent, role: .assistant, toolIntent: intent),
                    to: conversationID
                )
                return
            } catch {
                // Let the model clarify malformed slash commands in the normal chat flow.
            }
        }

        isGenerating = true
        streamingText = ""
        streamingMessageID = UUID()
        runtimeStatus = thinkingEnabled ? "Gemma is thinking" : "Gemma is generating"

        let stream = inferenceService.stream(
            prompt: prompt,
            history: history,
            thinkingEnabled: thinkingEnabled
        )

        generationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .token(let token):
                        self.streamingText += token
                    case .completed(let response):
                        let stats = ChatGenerationStats(
                            duration: response.duration,
                            promptTokens: response.promptTokens,
                            generatedTokens: response.generatedTokens,
                            contextSize: response.contextSize
                        )
                        if let firstToolCall = response.toolCalls.first,
                           let tool = ToolIntent.Tool(rawValue: firstToolCall.name) {
                            let intent = ToolIntent(
                                tool: tool,
                                args: firstToolCall.arguments,
                                rawDSL: nil,
                                source: .model
                            )
                            self.appendMessage(
                                ChatMessage(kind: .toolIntent, role: .assistant, stats: stats, toolIntent: intent),
                                to: conversationID
                            )
                        } else if let firstToolCall = response.toolCalls.first {
                            let warning = "[warn] unknown tool: \(firstToolCall.name)\n\n\(response.response)"
                            self.appendMessage(.assistantText(warning, thinking: response.thinking, stats: stats), to: conversationID)
                        } else {
                            self.appendMessage(.assistantText(response.response, thinking: response.thinking, stats: stats), to: conversationID)
                        }
                    }
                }
                self.runtimeStatus = self.inferenceService.runtimeStatus
            } catch is CancellationError {
                self.runtimeStatus = "Stopped"
            } catch {
                self.appendMessage(
                    ChatMessage(
                        kind: .assistantError,
                        role: .assistant,
                        text: error.localizedDescription
                    ),
                    to: conversationID
                )
                self.runtimeStatus = "Needs attention"
            }
            self.streamingText = ""
            self.streamingMessageID = nil
            self.isGenerating = false
            self.generationTask = nil
        }
    }

    func stop() {
        generationTask?.cancel()
    }

    func editAndResend(_ userMessage: ChatMessage, newText: String) {
        guard !isGenerating else {
            return
        }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == activeConversationID }) else {
            return
        }
        let messages = conversations[conversationIndex].messages
        guard let userIndex = messages.firstIndex(where: { $0.id == userMessage.id }) else {
            return
        }
        guard messages[userIndex].kind == .userText else {
            return
        }

        let conversationID = conversations[conversationIndex].id
        let toRemove = Array(messages[userIndex...])
        for message in toRemove {
            try? chatStore.deleteMessage(message.id, from: conversationID)
        }
        conversations[conversationIndex].messages.removeSubrange(userIndex...)
        conversations[conversationIndex].updatedAt = Date()
        try? chatStore.updateConversationMetadata(conversations[conversationIndex])

        send(trimmed)
    }

    func regenerate(from assistantMessage: ChatMessage) {
        guard !isGenerating else {
            return
        }
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == activeConversationID }) else {
            return
        }
        let messages = conversations[conversationIndex].messages
        guard let assistantIndex = messages.firstIndex(where: { $0.id == assistantMessage.id }) else {
            return
        }

        var userIndex: Int?
        var lookbackIndex = assistantIndex - 1
        while lookbackIndex >= 0 {
            if messages[lookbackIndex].role == .user, messages[lookbackIndex].kind == .userText {
                userIndex = lookbackIndex
                break
            }
            lookbackIndex -= 1
        }
        guard let userIndex else {
            return
        }
        let userPrompt = messages[userIndex].text ?? ""
        guard !userPrompt.isEmpty else {
            return
        }

        let conversationID = conversations[conversationIndex].id
        let removed = Array(messages[userIndex...])
        for message in removed {
            try? chatStore.deleteMessage(message.id, from: conversationID)
        }
        conversations[conversationIndex].messages.removeSubrange(userIndex...)
        conversations[conversationIndex].updatedAt = Date()
        try? chatStore.updateConversationMetadata(conversations[conversationIndex])

        send(userPrompt)
    }

    func confirmIntent(_ message: ChatMessage) {
        // The card disables confirm while the bundler is out of gas; this is the model-side
        // half of the same gate, so no path can sign a UserOp the daemon would refuse.
        if let intent = message.toolIntent, bundlerGasStatus(for: intent) != nil {
            return
        }
        let transferPreflightStatus = message.toolIntent.flatMap {
            transferPreflightStatuses[$0.id]
        }
        let swapPreview: ChatSwapPreview? = message.toolIntent.flatMap { intent in
            if case .quoted(let preview) = swapPreflightStatuses[intent.id] {
                return preview
            }
            return nil
        }
        if message.toolIntent != nil,
           let preflightStatus = transferPreflightStatus {
            switch preflightStatus {
            case .resolving, .failed:
                return
            case .resolved:
                break
            }
        }
        if let intent = message.toolIntent,
           let preflightStatus = swapPreflightStatuses[intent.id] {
            switch preflightStatus {
            case .quoting, .failed:
                return
            case .quoted:
                break
            }
        }
        if let intent = updateIntent(message, disposition: .confirmed, args: nil) {
            executeIfSupported(
                intent,
                transferPreflightStatus: transferPreflightStatus,
                swapPreview: swapPreview
            )
        }
    }

    /// The user consented, from the execution status row, to submit with the
    /// daemon-suggested `callGasLimit` after a real estimate could not run.
    ///
    /// Deliberately does not pass cached `transferPreflightStatus`/`swapPreview`
    /// through, so `executeIfSupported` re-resolves ENS and re-quotes the swap
    /// from scratch rather than reusing whatever was current on the first
    /// attempt. That is the safer choice on its own -- calldata built from a
    /// stale quote/resolution could differ from what the user actually
    /// reviewed -- and it is now also required for correctness: the daemon
    /// floors `acknowledgedCallGasLimit` against a suggestion it re-derives
    /// from *this* retry's calldata, so a headroom value sized for a different
    /// (e.g. smaller-batch) attempt can only be raised, never trusted as-is.
    /// Do not "optimize" this into passing stale cached preflight state.
    func retryIntentWithGasHeadroom(_ intent: ToolIntent, callGasLimit: UInt64) {
        Task { await executeIfSupported(intent, acknowledgedCallGasLimit: callGasLimit) }
    }

    func rejectIntent(_ message: ChatMessage) {
        _ = updateIntent(message, disposition: .rejected, args: nil)
    }

    func editIntent(_ message: ChatMessage, with args: [String: String]) {
        // "Save & confirm" executes, so it is gated exactly like `confirmIntent`.
        if let intent = message.toolIntent, bundlerGasStatus(for: intent) != nil {
            return
        }
        if let intent = updateIntent(message, disposition: .edited, args: args) {
            executeIfSupported(intent)
        }
    }

    func submitIntentFeedback(
        for message: ChatMessage,
        rating: ToolIntentFeedback.Rating,
        note: String?
    ) {
        guard
            let conversationIndex = conversations.firstIndex(where: { $0.id == activeConversationID }),
            let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == message.id }),
            let intent = conversations[conversationIndex].messages[messageIndex].toolIntent
        else {
            return
        }

        let now = Date()
        let existingFeedback = conversations[conversationIndex].messages[messageIndex].toolFeedback
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNote = trimmedNote?.isEmpty == true ? nil : trimmedNote
        let feedback = ToolIntentFeedback(
            id: existingFeedback?.id ?? UUID(),
            conversationID: conversations[conversationIndex].id,
            messageID: message.id,
            intentID: intent.id,
            tool: intent.tool,
            prompt: promptBeforeToolIntent(at: messageIndex, in: conversations[conversationIndex].messages),
            args: intent.args,
            rating: rating,
            note: normalizedNote,
            createdAt: existingFeedback?.createdAt ?? now,
            updatedAt: now
        )

        do {
            try chatStore.saveToolIntentFeedback(feedback)
            conversations[conversationIndex].messages[messageIndex].toolFeedback = feedback
        } catch {
            feedbackExportMessage = "Could not save ranking: \(error.localizedDescription)"
        }
    }

    func executionStatus(for intent: ToolIntent) -> ChatIntentExecutionStatus {
        if executingIntentIDs.contains(intent.id) {
            return .running(walletModel.bridgeStatus)
        }

        for message in messages.reversed()
        where message.kind == .toolResponse && message.toolCallId == intent.id.uuidString {
            guard let text = message.text,
                  let status = ChatIntentExecutionStatus.fromToolResponse(text)
            else {
                continue
            }
            return status
        }

        return .idle
    }

    func transferPreflightStatus(for intent: ToolIntent) -> ChatTransferPreflightStatus? {
        transferPreflightStatuses[intent.id]
    }

    /// The bundler-gas block for a still-pending intent, or `nil` when nothing is blocking.
    ///
    /// Pre-flighting here means an intent the daemon would refuse with
    /// `bundler_eoa_needs_topup` never reaches the Secure Enclave prompt. The daemon remains
    /// the authority: this is a client-side read of the last `wallet_bundlerStatus`, so a
    /// stale cache falls through to the daemon's own refusal, translated by
    /// `BundlerGasStatus.friendlyMessage(for:status:)`.
    func bundlerGasStatus(for intent: ToolIntent) -> BundlerGasStatus? {
        BundlerGasPolicy.block(
            tool: intent.tool,
            disposition: intent.disposition,
            status: accountIdentity.bundlerGas
        )
    }

    func swapPreflightStatus(for intent: ToolIntent) -> ChatSwapPreflightStatus? {
        swapPreflightStatuses[intent.id]
    }

    func signingPreview(
        for intent: ToolIntent,
        transferPreflightStatus: ChatTransferPreflightStatus?,
        swapPreflightStatus: ChatSwapPreflightStatus?
    ) -> ChatSigningPreview? {
        guard intent.disposition == .pending else {
            return nil
        }
        switch intent.tool {
        case .transfer:
            guard let transactionIntent = transferTransactionIntent(
                from: intent,
                preflightStatus: transferPreflightStatus
            ) else {
                if case .resolving = transferPreflightStatus {
                    return ChatSigningPreview(
                        mode: .pending,
                        title: "Checking signing path",
                        detail: "Recipient resolution has to finish before the app can choose session key or passkey."
                    )
                }
                return nil
            }
            return chatSigningPreview(for: walletModel.sessionSigningPreview(for: transactionIntent))
        case .swap:
            guard let transactionIntent = swapTransactionIntent(
                from: intent,
                preflightStatus: swapPreflightStatus
            ) else {
                if case .quoting = swapPreflightStatus {
                    return ChatSigningPreview(
                        mode: .pending,
                        title: "Checking signing path",
                        detail: "The route quote has to finish before the app can choose session key or passkey."
                    )
                }
                return nil
            }
            return chatSigningPreview(for: walletModel.sessionSigningPreview(for: transactionIntent))
        case .shield, .unshield:
            // Shield goes through executeBatch (its own signing path); the unshield exit is
            // signed by the sidecar — neither uses the session/passkey preview.
            return nil
        }
    }

    func prepareIntentPreview(_ message: ChatMessage, automatically: Bool = true) {
        guard let intent = message.toolIntent else {
            return
        }
        if automatically,
           !ChatIntentPreviewPolicy.shouldAutomaticallyPreparePreview(for: message, in: messages) {
            return
        }
        // Only preview intents still awaiting a decision. Once an intent is
        // confirmed/edited/rejected — including restored historical cards after
        // the app reopens — there's nothing to preview, and re-running the
        // quote/resolve would surface a stale failure (e.g. "Swap quote failed"
        // or a Helios "Internal error") on a transaction that already executed.
        guard intent.disposition == .pending else {
            return
        }
        if intent.tool == .swap {
            prepareSwapPreview(intent)
            return
        }
        guard intent.tool == .transfer else {
            return
        }
        guard intent.disposition != .rejected else {
            transferPreflightTasks[intent.id]?.cancel()
            transferPreflightTasks[intent.id] = nil
            transferPreflightStatuses[intent.id] = nil
            return
        }
        guard transferPreflightStatuses[intent.id] == nil,
              transferPreflightTasks[intent.id] == nil
        else {
            return
        }

        transferPreflightStatuses[intent.id] = .resolving
        transferPreflightTasks[intent.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.transferPreflightTasks[intent.id] = nil
            }

            do {
                let request = try await self.transferRequest(from: intent)
                if let resolvedName = request.resolvedName {
                    self.transferPreflightStatuses[intent.id] = .resolved(resolvedName)
                } else {
                    self.transferPreflightStatuses[intent.id] = nil
                }
            } catch is CancellationError {
                self.transferPreflightStatuses[intent.id] = nil
            } catch {
                self.transferPreflightStatuses[intent.id] = .failed(error.localizedDescription)
            }
        }
    }

    private func transferTransactionIntent(
        from intent: ToolIntent,
        preflightStatus: ChatTransferPreflightStatus?
    ) -> TransactionIntent? {
        guard let token = WalletTokenRegistry.token(
            matching: intent.args["token"],
            on: walletModel.activeChain.id
        ),
              let amount = intent.args["amount"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !amount.isEmpty,
              amount.lowercased() != "all",
              let recipient = transferRecipient(from: intent, preflightStatus: preflightStatus)
        else {
            return nil
        }
        if token.isNative {
            return .nativeTransfer(recipient: recipient, amountETH: amount)
        }
        return .erc20Transfer(token: token, recipient: recipient, amount: amount)
    }

    private func transferRecipient(
        from intent: ToolIntent,
        preflightStatus: ChatTransferPreflightStatus?
    ) -> String? {
        guard let rawRecipient = intent.args["to"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawRecipient.isEmpty
        else {
            return nil
        }
        if let recipientBytes = try? Data(hexString: rawRecipient), recipientBytes.count == 20 {
            return "0x" + recipientBytes.hexEncodedString
        }
        if case .resolved(let resolvedName) = preflightStatus {
            return resolvedName.address
        }
        return nil
    }

    private func swapTransactionIntent(
        from intent: ToolIntent,
        preflightStatus: ChatSwapPreflightStatus?
    ) -> TransactionIntent? {
        guard case .quoted(let preview) = preflightStatus,
              let walletAddress = walletModel.walletRecord?.kernelAccountAddress
        else {
            return nil
        }
        let request = SwapExecutionRequest(
            quote: preview.quote,
            recipient: walletAddress,
            tokenInIsNative: preview.fromToken.isNative,
            tokenOutIsNative: preview.toToken.isNative
        )
        return .exactInputSwap(request)
    }

    private func chatSigningPreview(for preview: SessionSigningPreview) -> ChatSigningPreview {
        switch preview {
        case .session(let mode):
            return ChatSigningPreview(
                mode: .session,
                title: mode == .install ? "Will use session key" : "Will use active session key",
                detail: mode == .install
                    ? "This in-policy action will install the approved session permission and submit without another Touch ID prompt."
                    : "This action is inside the active guardrails and should submit without another Touch ID prompt."
            )
        case .passkey(let reason):
            return ChatSigningPreview(
                mode: .passkey,
                title: "Passkey required",
                detail: passkeyReasonDetail(reason)
            )
        }
    }

    private func passkeyReasonDetail(_ reason: SessionSigningPasskeyReason) -> String {
        switch reason {
        case .sessionOff:
            return "Assistant session is off. Confirming this action will request Touch ID."
        case .accountNotDeployed:
            return "Session keys can only be used after the smart account has been deployed once."
        case .noSessionRecord:
            return "No session permission is stored for this chain."
        case .pendingRevoke:
            return "A session revoke is already in progress, so this action will use the passkey path."
        case .expired(.duration):
            return "The session duration has ended. Enable a fresh session to use silent signing again."
        case .expired(.inactivity):
            return "The session locked after inactivity. Enable a fresh session to use silent signing again."
        case .missingSigningArtifacts:
            return "The stored session record is incomplete, so the app will fall back to passkey approval."
        case .policy(let reason):
            return policyRejectionDetail(reason)
        }
    }

    private func policyRejectionDetail(_ reason: SessionPolicyMirror.RejectionReason) -> String {
        switch reason {
        case .expired:
            return "The session duration has ended. Enable a fresh session to use silent signing again."
        case .inactive:
            return "The session locked after inactivity. Enable a fresh session to use silent signing again."
        case .rateLimited:
            return "The active session has reached its action limit for the current window."
        case .invalidLimit:
            return "The active session limit is invalid, so the app will use passkey approval."
        case .nativeTransfersDisabled:
            return "Native transfers are outside the current assistant guardrails."
        case .erc20TransfersDisabled:
            return "ERC-20 transfers are outside the current session key guardrails."
        case .erc20ApprovalsDisabled:
            return "This swap needs an ERC-20 approval, but session key approvals are disabled."
        case .erc20TokenDisabled:
            return "This token is disabled in the current session key guardrails."
        case .swapsDisabled:
            return "Swaps are outside the current assistant guardrails."
        case .invalidRecipient:
            return "The recipient is not a valid onchain address after preflight."
        case .invalidAmount:
            return "The amount could not be parsed into onchain units."
        case .overValueLimit:
            return "This action is above the active per-action session limit."
        case .unsupportedToken:
            return "This token is not in the session key's known-token allowlist."
        case .wrongChain:
            return "The action does not match the active chain for this session."
        case .unsupportedSwapRouter:
            return "The quoted swap router is not allowlisted for session signing."
        case .unsupportedApprovalSpender:
            return "The required ERC-20 approval spender is not allowed for session signing."
        case .unsupportedSwapToken:
            return "The quoted swap uses a token outside the session key's allowlist."
        }
    }

    private func prepareSwapPreview(_ intent: ToolIntent) {
        guard intent.disposition != .rejected else {
            swapPreflightTasks[intent.id]?.cancel()
            swapPreflightTasks[intent.id] = nil
            swapPreflightStatuses[intent.id] = nil
            return
        }
        guard swapPreflightStatuses[intent.id] == nil,
              swapPreflightTasks[intent.id] == nil
        else {
            return
        }

        swapPreflightStatuses[intent.id] = .quoting
        swapPreflightTasks[intent.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.swapPreflightTasks[intent.id] = nil
            }

            do {
                let request = try await self.swapRequest(from: intent, allowApprovalRequired: true)
                self.swapPreflightStatuses[intent.id] = .quoted(
                    ChatSwapPreview(
                        fromToken: request.fromToken,
                        toToken: request.toToken,
                        amount: request.amount,
                        quote: request.quote,
                        quotedAt: Date()
                    )
                )
            } catch is CancellationError {
                self.swapPreflightStatuses[intent.id] = nil
            } catch {
                self.swapPreflightStatuses[intent.id] = .failed(error.localizedDescription)
            }
        }
    }

    func exportFeedbackRankings() {
        do {
            let records = try chatStore.loadToolIntentFeedbackExportRecords()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)

            let panel = NSSavePanel()
            panel.title = "Download rankings"
            panel.nameFieldStringValue = "local-wallet-tool-rankings-\(Self.exportDateStamp()).json"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false

            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }

            try data.write(to: url, options: [.atomic])
            feedbackExportMessage = "Exported \(records.count) ranking\(records.count == 1 ? "" : "s")."
        } catch {
            feedbackExportMessage = "Could not export rankings: \(error.localizedDescription)"
        }
    }

    func exportChatDatabase() throws -> String {
        let panel = NSSavePanel()
        panel.title = "Export chat database"
        panel.nameFieldStringValue = "local-wallet-chat-\(Self.exportDateStamp()).sqlite"
        panel.allowedContentTypes = [.database]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return "Export cancelled."
        }

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.copyItem(at: chatStore.databaseFileURL, to: url)
        return "Exported chat database to \(url.lastPathComponent)."
    }

    func revealChatDatabase() {
        NSWorkspace.shared.activateFileViewerSelecting([chatStore.databaseFileURL])
    }

    func clearChatHistory() throws -> String {
        guard !isGenerating else {
            throw AppError.walletOperationInProgress
        }
        let conversation = ChatConversation(title: "New chat", messages: [])
        try chatStore.replaceConversations([conversation])
        conversations = [conversation]
        activeConversationID = conversation.id
        preferencesStore.activeConversationID = conversation.id
        transferPreflightTasks.values.forEach { $0.cancel() }
        swapPreflightTasks.values.forEach { $0.cancel() }
        transferPreflightTasks = [:]
        swapPreflightTasks = [:]
        transferPreflightStatuses = [:]
        swapPreflightStatuses = [:]
        return "Cleared chat history."
    }

    func clearFeedbackRankings() throws -> String {
        try chatStore.deleteAllToolIntentFeedback()
        for conversationIndex in conversations.indices {
            for messageIndex in conversations[conversationIndex].messages.indices {
                conversations[conversationIndex].messages[messageIndex].toolFeedback = nil
            }
        }
        return "Cleared tool rankings."
    }

    func revealModelFile() throws -> String {
        let path = onboardingSettingsStore.installedModelPath ?? ""
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw AppError.modelNotInstalled
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        return "Revealed model file."
    }

    func saveNetworkSettings(_ settings: DemoNetworkSettings) throws -> String {
        let validated = try settings.validated()
        let requiresRestart = NetworkSettingsChangePolicy.requiresWalletNodeRestart(
            from: walletModel.networkSettings,
            to: validated
        )
        let monitorsHeliosCheckpoint = NetworkSettingsChangePolicy.requiresHeliosCheckpointResync(
            from: walletModel.networkSettings,
            to: validated
        )
        try walletModel.updateNetworkSettings(validated)
        onboardingSettingsStore.rpcURL = validated.sepoliaRPCURL
        onboardingSettingsStore.archiveNodeURL = validated.sepoliaArchiveNodeURL
        onboardingSettingsStore.consensusRPCURL = validated.sepoliaConsensusRPCURL
        refreshAccountIdentity()
        if !requiresRestart {
            return "Saved \(validated.activeNetworkName) network settings. No wallet-node restart was needed."
        }
        let readVerification = validated.isHeliosVerificationActive ? "Helios read verification" : "execution RPC reads"
        if monitorsHeliosCheckpoint {
            return "Saved \(validated.activeNetworkName) network settings. Helios checkpoint resync is running in the background."
        }
        return "Saved \(validated.activeNetworkName) network settings. wallet-node will use \(readVerification), max \(validated.activeMaxFeePerGasGwei) gwei and priority \(validated.activeMaxPriorityFeePerGasGwei) gwei caps."
    }

    func enableSessionKeysFromSettings() async throws -> String {
        let record = try await walletModel.enableSessionKeys()
        refreshAccountIdentity()
        return "Session keys enabled for permission 0x\(record.permissionId.hexEncodedString)."
    }

    func revokeSessionKeysFromSettings() async throws -> String {
        let result = try await walletModel.revokeSessionKeysAndWaitForReceipt()
        refreshAccountIdentity()
        if let transactionHash = result.transactionHash {
            return "Session key disabled. Revoke confirmed in transaction \(transactionHash)."
        }
        return "Session key disabled. Revoke receipt confirmed for \(result.userOpHash)."
    }

    func updateSessionPolicyFromSettings(_ policy: SessionPolicyConfig) throws -> String {
        try walletModel.updateSessionPolicy(policy)
        if walletModel.sessionKeysEnabled {
            return "Saved limits for the next session enable. Disable and enable again to apply them onchain."
        }
        return "Saved session limits."
    }

    func testNetworkSettings(_ settings: DemoNetworkSettings) async throws -> String {
        try await walletModel.testNetworkSettings(settings)
    }

    func runSettingsDiagnostics(_ settings: DemoNetworkSettings) async -> SettingsDiagnosticsReport {
        var checks: [SettingsHealthCheck] = []
        let validated: DemoNetworkSettings
        do {
            validated = try settings.validated()
        } catch {
            return SettingsDiagnosticsReport(
                generatedAt: Date(),
                checks: [
                    SettingsHealthCheck(
                        title: "Network settings",
                        state: .failed,
                        detail: error.localizedDescription,
                        latencyMilliseconds: nil
                    ),
                ]
            )
        }

        let chain = validated.activeChain

        let executionStart = Date()
        do {
            let chainID = try await Self.probeExecutionChainID(rpcURL: chain.rpcURL)
            let matches = chainID == chain.id
            checks.append(SettingsHealthCheck(
                title: "Execution RPC",
                state: matches ? .healthy : .failed,
                detail: matches
                    ? "eth_chainId returned \(chainID). wallet-node/Helios will use this endpoint after save."
                    : "RPC returned chain ID \(chainID), expected \(chain.id).",
                latencyMilliseconds: Self.latencyMilliseconds(since: executionStart)
            ))
        } catch {
            checks.append(SettingsHealthCheck(
                title: "Execution RPC",
                state: .failed,
                detail: error.localizedDescription,
                latencyMilliseconds: Self.latencyMilliseconds(since: executionStart)
            ))
        }

        if let archiveURL = chain.archiveRPCURL {
            let archiveStart = Date()
            do {
                let chainID = try await Self.probeExecutionChainID(rpcURL: archiveURL)
                let matches = chainID == chain.id
                checks.append(SettingsHealthCheck(
                    title: "Archive RPC",
                    state: matches ? .healthy : .warning,
                    detail: matches
                        ? "Archive endpoint responded for chain \(chainID)."
                        : "Archive endpoint returned chain ID \(chainID), expected \(chain.id).",
                    latencyMilliseconds: Self.latencyMilliseconds(since: archiveStart)
                ))
            } catch {
                checks.append(SettingsHealthCheck(
                    title: "Archive RPC",
                    state: .failed,
                    detail: error.localizedDescription,
                    latencyMilliseconds: Self.latencyMilliseconds(since: archiveStart)
                ))
            }
        } else {
            checks.append(SettingsHealthCheck(
                title: "Archive RPC",
                state: .skipped,
                detail: "No archive endpoint configured.",
                latencyMilliseconds: nil
            ))
        }

        if validated.isHeliosVerificationActive, let consensusURL = chain.consensusRPCURL {
            let consensusStart = Date()
            do {
                let statusCode = try await Self.probeConsensusHealth(url: consensusURL)
                checks.append(SettingsHealthCheck(
                    title: "Consensus RPC",
                    state: statusCode == 200 ? .healthy : .warning,
                    detail: "Beacon health endpoint returned HTTP \(statusCode).",
                    latencyMilliseconds: Self.latencyMilliseconds(since: consensusStart)
                ))
            } catch {
                checks.append(SettingsHealthCheck(
                    title: "Consensus RPC",
                    state: .failed,
                    detail: error.localizedDescription,
                    latencyMilliseconds: Self.latencyMilliseconds(since: consensusStart)
                ))
            }
        } else {
            checks.append(SettingsHealthCheck(
                title: "Consensus RPC",
                state: .skipped,
                detail: "No consensus endpoint configured; wallet-node uses execution RPC reads.",
                latencyMilliseconds: nil
            ))
        }

        let relayerStart = Date()
        do {
            let status = try await walletModel.checkLocalRelayerStatusForDiagnostics()
            let balanceUnavailable = Self.isUnavailableETHBalance(status.balance)
            checks.append(SettingsHealthCheck(
                title: "wallet-node relayer",
                state: status.ready && !balanceUnavailable ? .healthy : .warning,
                detail: "\(status.lifecycle.capitalized) \(status.eoa.walletDisplayShortAddress). Balance \(Self.displayETHBalance(status.balance)).",
                latencyMilliseconds: Self.latencyMilliseconds(since: relayerStart)
            ))
            refreshAccountIdentity()
        } catch {
            checks.append(SettingsHealthCheck(
                title: "wallet-node relayer",
                state: .failed,
                detail: error.localizedDescription,
                latencyMilliseconds: Self.latencyMilliseconds(since: relayerStart)
            ))
        }

        return SettingsDiagnosticsReport(generatedAt: Date(), checks: checks)
    }

    func monitorHeliosCheckpointFromSettings(_ settings: DemoNetworkSettings) async throws -> SettingsHeliosCheckpointResult {
        try await walletModel.monitorHeliosCheckpointAfterNetworkSettingsChange(settings)
    }

    func refreshLocalRelayerFromSettings() {
        walletModel.refreshLocalRelayerStatus()
    }

    func rotateLocalRelayerFromSettings() async throws -> String {
        try await walletModel.rotateLocalRelayerKey()
        refreshAccountIdentity()
        return "Relayer rotation requested. The new key waits for top-up before it becomes active."
    }

    func exportLocalRelayerKeyFromSettings() async throws -> String {
        try await walletModel.exportLocalRelayerKey()
    }

    func deleteLocalRelayerKeyFromSettings(unsafe: Bool) async throws -> String {
        try await walletModel.deleteLocalRelayerKey(unsafeReset: unsafe)
        refreshAccountIdentity()
        return unsafe
            ? "Relayer key reset. Submissions stay blocked until a funded relayer exists."
            : "Relayer key deleted. Submissions stay blocked until a funded relayer exists."
    }

    func resetWalletFromSettings() throws -> String {
        walletModel.resetDemoWallet()
        refreshAccountIdentity()
        return "Wallet reset requested. Local wallet, relayer, and session keys were deleted; the app will create fresh key material."
    }

    func debugSessionReportFromSettings() async -> String {
        await walletModel.debugSessionReport(snapshot: settingsSnapshot)
    }

    func clearDebugLogFromSettings() {
        walletModel.clearDebugLog()
    }

    func setUnlockRelayerOnLaunch(_ isEnabled: Bool) {
        walletModel.setUnlockRelayerOnLaunch(isEnabled)
        refreshAccountIdentity()
    }

    func setSwapSlippageBps(_ bps: UInt64) {
        walletModel.setSwapSlippageBps(bps)
    }

    func setContextWindowTokens(_ tokens: Int) {
        walletModel.setContextWindowTokens(tokens)
    }

    private func appendMessage(_ message: ChatMessage, to conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }
        conversations[index].messages.append(message)
        conversations[index].updatedAt = Date()
        let updatedConversation = conversations[index]
        try? chatStore.appendMessage(message, to: conversationID)
        try? chatStore.updateConversationMetadata(updatedConversation)
        sortConversationsKeepingActive()
        prepareIntentPreview(message)
    }

    private func refreshAccountIdentity() {
        let chain = walletModel.activeChain
        let kernelAddress = walletModel.walletRecord?.kernelAccountAddress
            ?? accountIdentity.kernelAddress
        let kernelBalance = walletModel.accountInspection?.balanceDisplay ?? "Balance unavailable"
        let kernelState = walletModel.accountInspection?.stateTitle ?? "Not inspected"
        let bundlerAddress = walletModel.localRelayerStatus?.eoa
            ?? onboardingSettingsStore.bundlerAddress(chainId: chain.id)
            ?? "Not available"
        let bundlerBalance = Self.displayETHBalance(walletModel.localRelayerStatus?.balance)
        let bundlerGas = BundlerGasStatus.from(
            relayer: walletModel.localRelayerStatus,
            fallbackAddress: bundlerAddress,
            chain: chain
        )
        let bundlerState: String
        if let status = walletModel.localRelayerStatus {
            // "Out of gas — can't send" over "Needs top-up": under the threshold every send is
            // refused, and the badge is the only place that says so before the user tries.
            bundlerState = status.ready
                ? "Ready"
                : bundlerGas.needsGas ? bundlerGas.badgeText : status.lifecycle.capitalized
        } else {
            bundlerState = walletModel.localRelayerMessage
        }

        accountIdentity = ChatAccountIdentity(
            chainName: chain.name,
            chainID: chain.id,
            isTestnet: chain.isTestnet,
            kernelAddress: kernelAddress,
            kernelBalance: kernelBalance,
            kernelState: kernelState,
            bundlerAddress: bundlerAddress,
            bundlerBalance: bundlerBalance,
            bundlerState: bundlerState,
            bundlerGas: bundlerGas
        )
    }

    private static func displayETHBalance(_ rawBalance: String?) -> String {
        guard let rawBalance, !rawBalance.isEmpty, rawBalance != "unavailable" else {
            return "Balance unavailable"
        }
        return WeiFormatter.ethDisplayString(fromHexWei: rawBalance)
    }

    private static func isUnavailableETHBalance(_ rawBalance: String?) -> Bool {
        guard let rawBalance else {
            return true
        }
        return rawBalance.isEmpty || rawBalance == "unavailable"
    }

    private static func hasIncompleteTokenBalances(_ balances: [ChatTokenBalance]) -> Bool {
        balances.isEmpty || balances.contains { $0.rawBalanceHex == nil }
    }

    private static func latencyMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }

    private static func probeExecutionChainID(rpcURL: URL) async throws -> UInt64 {
        let response = try await jsonRPC(method: "eth_chainId", rpcURL: rpcURL)
        guard let hexValue = response["result"] as? String,
              let chainID = UInt64(hexValue.removingHexPrefix, radix: 16) else {
            throw AppError.localDaemonLaunchFailed("Execution RPC returned an invalid eth_chainId response.")
        }
        return chainID
    }

    private static func jsonRPC(method: String, rpcURL: URL) async throws -> [String: Any] {
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": [],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw AppError.localDaemonLaunchFailed("Execution RPC request failed.")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.localDaemonLaunchFailed("Execution RPC returned invalid JSON.")
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown RPC error"
            throw AppError.localDaemonLaunchFailed(message)
        }
        return object
    }

    private static func probeConsensusHealth(url: URL) async throws -> Int {
        let healthURL = url.appendingPathComponent("eth/v1/node/health")
        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.localDaemonLaunchFailed("Consensus RPC returned an invalid response.")
        }
        return httpResponse.statusCode
    }

    private func updateIntent(
        _ message: ChatMessage,
        disposition: ToolIntent.Disposition,
        args: [String: String]?
    ) -> ToolIntent? {
        guard
            let conversationIndex = conversations.firstIndex(where: { $0.id == activeConversationID }),
            let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == message.id }),
            var intent = conversations[conversationIndex].messages[messageIndex].toolIntent
        else {
            return nil
        }

        if let args {
            intent.args = args
        }
        intent.disposition = disposition
        intent.updatedAt = Date()

        transferPreflightTasks[intent.id]?.cancel()
        transferPreflightTasks[intent.id] = nil
        transferPreflightStatuses[intent.id] = nil
        swapPreflightTasks[intent.id]?.cancel()
        swapPreflightTasks[intent.id] = nil
        swapPreflightStatuses[intent.id] = nil

        conversations[conversationIndex].messages[messageIndex].toolIntent = intent
        conversations[conversationIndex].updatedAt = Date()
        let updatedConversation = conversations[conversationIndex]
        try? chatStore.updateMessage(conversations[conversationIndex].messages[messageIndex], in: updatedConversation.id)
        try? chatStore.updateConversationMetadata(updatedConversation)

        let responseText: String
        switch disposition {
        case .confirmed:
            responseText = #"{"status":"acknowledged","intent_id":"\#(intent.id.uuidString)"}"#
        case .edited:
            responseText = editedIntentResponseText(for: intent)
        case .rejected:
            responseText = #"{"status":"rejected","intent_id":"\#(intent.id.uuidString)"}"#
        case .pending:
            return intent
        }

        appendMessage(
            ChatMessage(
                kind: .toolResponse,
                role: .tool,
                text: responseText,
                toolCallId: intent.id.uuidString
            ),
            to: updatedConversation.id
        )
        if disposition != .rejected {
            prepareIntentPreview(conversations[conversationIndex].messages[messageIndex])
        }
        return intent
    }

    /// Resolve a client for the railgun-helper sidecar (the wallet's privacy entry point).
    /// Configured via env for now (`LOCAL_WALLET_PRIVACY_SOCKET` / `_TOKEN`); the in-app
    /// sidecar-spawn + live (non-fork) mode are the next integration step.
    private func railgunHelperClient() async throws -> RailgunHelperClient {
        // Env override points at a manually-run sidecar (e.g. an anvil fork); otherwise the
        // app spawns + owns one on its active chain.
        let env = ProcessInfo.processInfo.environment
        if let socket = env["LOCAL_WALLET_PRIVACY_SOCKET"],
           let token = env["LOCAL_WALLET_PRIVACY_TOKEN"] {
            return RailgunHelperClient(socketPath: socket, bearerToken: token)
        }
        let currentRPC = walletModel.activeChain.rpcURL.absoluteString
        // Reuse the spawned sidecar only if it was launched on the CURRENT active-chain RPC.
        // If the RPC changed under it (e.g. the user switched providers to escape rate limits),
        // the helper is still bound to the old RPC — tear it down (deinit SIGTERMs it) and
        // re-spawn on the new RPC.
        if let daemon = railgunDaemon, railgunDaemonRPC == currentRPC {
            return daemon.client
        }
        railgunDaemon = nil
        railgunDaemonRPC = nil
        let secrets = try RailgunSecretsStore.loadOrCreate()
        let daemon = try await RailgunHelperDaemon.launch(
            rpcURL: currentRPC,
            secrets: secrets
        )
        railgunDaemon = daemon
        railgunDaemonRPC = currentRPC
        return daemon.client
    }

    /// Fetch the shielded (RAILGUN) balance from the sidecar and publish it split into
    /// confirmed (cleared/spendable) vs pending (deposited, awaiting pool inclusion).
    func refreshShieldedBalance() {
        guard !isRefreshingShieldedBalance else { return }
        isRefreshingShieldedBalance = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRefreshingShieldedBalance = false }
            do {
                let client = try await self.railgunHelperClient()
                let split = try await client.balance()
                self.shieldedConfirmed = WeiFormatter.ethDisplayString(fromHexWei: split.valid)
                self.shieldedPending = WeiFormatter.ethDisplayString(fromHexWei: split.pending)
                self.shieldedBalanceError = nil
            } catch {
                self.shieldedBalanceError = error.localizedDescription
            }
        }
    }

    /// After a shield/unshield, the RAILGUN pool (Subsquid index + note scan) lags the chain,
    /// so a single immediate `refreshShieldedBalance()` reads stale totals. Poll for a bounded
    /// window, refreshing each pass, until the confirmed/pending split changes from what it was
    /// when the operation completed (or the window elapses).
    func refreshShieldedBalanceUntilSettled(attempts: Int = 12, interval: TimeInterval = 3) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let baseline = [self.shieldedConfirmed, self.shieldedPending]
            for _ in 0..<max(1, attempts) {
                self.refreshShieldedBalance()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if [self.shieldedConfirmed, self.shieldedPending] != baseline {
                    return
                }
            }
        }
    }

    /// Top up the bundler EOA with native ETH so it can pay gas. The ETH comes from the Kernel
    /// account as a passkey-signed UserOp — the same primitive as a chat transfer. This only
    /// works once the bundler already has enough gas to relay one op; when it's empty, its
    /// card's copy-address button is the external fallback.
    func fundHelper(address: String, amountETH: String, label: String) {
        guard fundingHelperAddress == nil else { return }
        let amount = amountETH.trimmingCharacters(in: .whitespaces)
        guard address.hasPrefix("0x"), address.count == 42 else {
            setHelperFundError("\(label) has no address to fund yet.", address: address)
            return
        }
        guard let value = Double(amount), value > 0 else {
            setHelperFundError("Enter an amount greater than 0 to fund \(label).", address: address)
            return
        }
        // Every helper top-up is a UserOp the bundler has to relay — including one aimed at
        // the bundler itself — so an out-of-gas bundler refuses all of them. Decline here
        // rather than after a Secure Enclave prompt the daemon will reject anyway.
        let gas = accountIdentity.bundlerGas
        if gas.needsGas {
            setHelperFundError("\(BundlerGasStatus.warningTitle). \(gas.declineDetail)", address: address)
            return
        }
        fundingHelperAddress = address
        helperFundError = nil
        helperFundErrorAddress = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.fundingHelperAddress = nil }
            do {
                let result = try await self.walletModel.executeNativeTransfer(
                    recipient: address,
                    amountETH: amount,
                    logContext: "fund-helper",
                    signingReason: "Authorize \(amount) ETH to the \(label) for gas on \(self.walletModel.activeChain.name)"
                )
                // Hold the funding lock until this op is actually mined. Two reasons:
                // (1) balances only reflect it once it lands; (2) the shared lock stops a
                // second helper-funding op building on a nonce this one hasn't consumed yet —
                // that op would otherwise fail estimation with AA25 (invalid account nonce).
                let receipt = await self.walletModel.awaitUserOperationInclusion(
                    userOpHash: result.userOpHash,
                    logContext: "fund-helper"
                )
                self.appendHelperFundingResult(result, receipt: receipt, amount: amount, address: address, label: label)
                // Reflect the new gas balance on the card. refreshOnchainAccountStatus re-reads
                // chain state (kernel + bundler balances, relayer status) — a plain
                // refreshAccountIdentity only re-maps the stale cache.
                self.refreshOnchainAccountStatus()
            } catch {
                // An empty bundler cannot relay its own top-up, so name the real blocker
                // instead of the RPC reason string.
                self.setHelperFundError(
                    self.fundingFailureMessage(error, label: label),
                    address: address
                )
                self.appendFundingError(error, label: label)
            }
        }
    }

    private func fundingFailureMessage(_ error: Error, label: String) -> String {
        BundlerGasStatus.friendlyMessage(for: error, status: accountIdentity.bundlerGas)
            ?? "Funding the \(label) failed: \(error.localizedDescription)"
    }

    private func setHelperFundError(_ message: String, address: String) {
        helperFundError = message
        helperFundErrorAddress = address
    }

    private func appendHelperFundingResult(
        _ result: AppModel.UserOperationSendResult,
        receipt: WalletNodeClient.UserOperationReceipt?,
        amount: String,
        address: String,
        label: String
    ) {
        guard let conversationID = activeConversationIDIfPresent else { return }
        let status: OnchainTransactionSummary.Status
        if let receipt {
            status = receipt.success ? .included : .reverted
        } else if result.transactionHash != nil {
            status = .submitted
        } else {
            status = .pending
        }
        let summary = OnchainTransactionSummary(
            chainName: walletModel.activeChain.name,
            chainID: walletModel.activeChain.id,
            amount: amount,
            token: "ETH",
            recipient: address,
            recipientName: "\(label) (gas)",
            resolvedRecipient: nil,
            resolutionChainName: nil,
            resolutionChainID: nil,
            ccipReadUsed: nil,
            operation: .transfer,
            signingMode: result.signedBySession ? "session" : "passkey",
            amountOut: nil,
            minimumReceived: nil,
            route: nil,
            userOpHash: result.userOpHash,
            transactionHash: receipt?.txHash ?? result.transactionHash,
            status: status,
            createdAt: Date()
        )
        appendMessage(.onchainTransaction(summary), to: conversationID)
        reloadWalletHistory()
    }

    private func appendFundingError(_ error: Error, label: String) {
        guard let conversationID = activeConversationIDIfPresent else { return }
        appendMessage(
            ChatMessage(
                kind: .assistantError,
                role: .assistant,
                text: fundingFailureMessage(error, label: label)
            ),
            to: conversationID
        )
    }

    /// `/shield <amount>` — deposit ETH into the RAILGUN pool. The sidecar builds the pool
    /// deposit tx(s); the OWNER self-submits them as a Kernel `execute` UserOp (passkey).
    private func executeShield(intent: ToolIntent, acknowledgedCallGasLimit: UInt64? = nil) async throws {
        guard let amount = intent.args["amount"] else { throw AppError.invalidAmount }
        let amountWei = try EtherAmountParser.weiDecimalString(fromETHString: amount)
        let client = try await railgunHelperClient()
        let txs = try await client.prepareShield(amountWei: amountWei)
        let executions = try txs.map { try Self.kernelExecution(from: $0) }
        let result = try await walletModel.executeBatch(
            executions: executions,
            logContext: "chat-shield",
            signingReason: "Authorize shielding \(amount) ETH into the RAILGUN pool on \(walletModel.activeChain.name)",
            acknowledgedCallGasLimit: acknowledgedCallGasLimit
        )
        appendShieldExecutionResult(result, amount: amount, for: intent)
        refreshShieldedBalanceUntilSettled()
    }

    /// `/unshield <amount> to <addr>` — withdraw ETH from the pool to a recipient as native
    /// ETH. The exit is an ERC-4337 UserOperation sponsored by RAILGUN's privacy paymaster and
    /// submitted by a PUBLIC bundler, so the user needs no gas of their own. Async: the sidecar
    /// returns a jobId while it proves + submits; we poll for the op hash, then for inclusion.
    private func executeUnshield(intent: ToolIntent) async throws {
        guard let amount = intent.args["amount"], let to = intent.args["to"] else {
            throw AppError.invalidAmount
        }
        guard to.hasPrefix("0x"), to.count == 42 else {
            throw RailgunHelperClient.ClientError.rpcError(
                code: nil,
                message: "unshield recipient must be a 0x address (ENS/contact resolution is not yet wired for unshield)"
            )
        }
        let amountWei = try EtherAmountParser.weiDecimalString(fromETHString: amount)
        // The exit is signed by the sidecar's own exit key and never crosses the Secure
        // Enclave, so — unlike shield/transfer — it wouldn't prompt on its own. Require an
        // explicit device-owner (biometric) authorization before moving funds out of the pool.
        try await walletModel.authorizeDeviceOwner(
            reason: "Authorize unshielding \(amount) ETH from the RAILGUN pool to \(to) on \(walletModel.activeChain.name)"
        )
        let client = try await railgunHelperClient()
        let jobId = try await client.unshield(amountWei: amountWei, to: to)
        // The sidecar accepted the job and is proving + submitting (tens of seconds). Show an
        // immediate "submitted" card now; the exit is not a daemon UserOp, so nothing
        // reconciles it for us — we drive the submitted → included transition by hand.
        // Key the card by the per-command intent id, NOT the sidecar jobId: job_seq resets to
        // 1 on every helper launch, so "unshield:job-1" collides across sessions and (via the
        // history store's UNIQUE(chain_id, user_op_hash) upsert) makes a new unshield inherit a
        // previous one's stale transactionHash. intent.id is globally unique per command.
        let cardID = "unshield:\(intent.id.uuidString)"
        // Capture the conversation the card was actually appended to and address every later
        // update to it explicitly. Phase 2 can outlive the user's attention on this chat, and
        // resolving the ACTIVE conversation at completion time would leave this card stuck on
        // Submitted in conversation A while a failure notice lands in conversation B, which
        // never had this intent.
        let cardConversationID = appendUnshieldSubmittedCard(
            id: cardID, amount: amount, to: to, for: intent
        )
        // Phase 1: wait only for a UserOperation hash.
        //
        // A failure here reverts the card ONLY if the sidecar itself reported the job failed.
        // The client's deadline is not such a report: the sidecar calls phase 1 unbounded
        // (first-exit circuit-artifact download plus up to ten Groth16 proofs across the
        // authorised retry), so the deadline can pass while the job goes on to submit and
        // deliver — and the first exit on a cold machine is both the likeliest to exceed it and
        // the worst one to falsely mark reverted.
        let submitted: JSONValue
        do {
            submitted = try await client.awaitUnshieldSubmitted(jobId: jobId)
        } catch {
            guard RailgunExitCopy.shouldRevertCard(for: error) else {
                // The exit is probably still running. Leave the card submitted, say so, and do
                // NOT throw — this is not an execution failure and must not be reported as one.
                appendUnshieldStillInFlightNotice(for: intent, in: cardConversationID)
                // The notes may already have left the pool, so still reconcile the balance.
                refreshShieldedBalanceUntilSettled()
                return
            }
            markUnshieldCardReverted(id: cardID, amount: amount, to: to, in: cardConversationID)
            // Report in place rather than rethrowing: the generic catch resolves the ACTIVE
            // conversation, and phase 1 can run for minutes, so a rethrow could revert the card
            // in one conversation and explain it in another. Errors raised BEFORE the card
            // exists still propagate normally, where "active" is by definition correct.
            appendExecutionError(error, for: intent, in: cardConversationID)
            return
        }
        confirmUnshieldCard(
            id: cardID, result: submitted, amount: amount, to: to, in: cardConversationID
        )
        // Phase 1 returns on `submitted` OR `done`, so a fast inclusion is already complete —
        // and that read EVICTED the terminal job from the sidecar's map. Spawning phase 2
        // anyway would poll a job that no longer exists and get `unknownJobId` back.
        guard submitted["included"]?.boolValue != true else {
            refreshShieldedBalanceUntilSettled()
            return
        }
        // Phase 2: inclusion runs on the bundler's schedule, so it must never block the user.
        // `awaitUnshieldIncluded` returns nil on timeout meaning "still pending" — leave the
        // card submitted in that case. Marking a slow-but-valid exit reverted would tell a user
        // whose funds actually arrived that they didn't, the worst outcome in this feature.
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let included = try await client.awaitUnshieldIncluded(jobId: jobId) else {
                    // Still pending: the card stays submitted, but the pool may well have moved
                    // by now, so reconcile the balance rather than leaving it stale until the
                    // user happens to refresh by hand.
                    self.refreshShieldedBalanceUntilSettled()
                    return
                }
                self.confirmUnshieldCard(
                    id: cardID, result: included, amount: amount, to: to, in: cardConversationID
                )
                self.refreshShieldedBalanceUntilSettled()
            } catch {
                guard RailgunExitCopy.shouldRevertCard(for: error) else {
                    // The poll broke, not the exit (evicted job, re-spawned helper, timed-out
                    // read). The card's current state — Submitted, or already Done — is still
                    // the most accurate thing we know, so say nothing and change nothing; only
                    // reconcile the balance, since the exit may well have landed.
                    self.refreshShieldedBalanceUntilSettled()
                    return
                }
                // The sidecar reported a terminal failure. Nothing is awaiting this task, so
                // surface the reason itself rather than letting the card revert unexplained.
                self.markUnshieldCardReverted(
                    id: cardID, amount: amount, to: to, in: cardConversationID
                )
                self.appendExecutionError(error, for: intent, in: cardConversationID)
            }
        }
    }

    /// Rich on-chain feedback for `/shield`, mirroring transfer: a tool-response message +
    /// an on-chain transaction card (which also refreshes the wallet history panel).
    private func appendShieldExecutionResult(
        _ result: AppModel.UserOperationSendResult,
        amount: String,
        for intent: ToolIntent
    ) {
        guard let conversationID = activeConversationIDIfPresent else { return }
        var payload: [String: Any] = [
            "status": "submitted",
            "intent_id": intent.id.uuidString,
            "user_op_hash": result.userOpHash,
            "signed_by": result.signedBySession ? "session_key" : "passkey",
            "operation": "shield",
        ]
        if let tx = result.transactionHash { payload["transaction_hash"] = tx }
        if let success = result.success { payload["success"] = success }
        appendMessage(
            ChatMessage(kind: .toolResponse, role: .tool, text: jsonString(payload), toolCallId: intent.id.uuidString),
            to: conversationID
        )

        let status: OnchainTransactionSummary.Status =
            result.success == true ? .included
            : result.success == false ? .reverted
            : result.transactionHash != nil ? .submitted : .pending
        let summary = OnchainTransactionSummary(
            chainName: walletModel.activeChain.name,
            chainID: walletModel.activeChain.id,
            amount: amount,
            token: "ETH",
            recipient: "RAILGUN shielded pool",
            recipientName: nil,
            resolvedRecipient: nil,
            resolutionChainName: nil,
            resolutionChainID: nil,
            ccipReadUsed: nil,
            operation: .shield,
            signingMode: result.signedBySession ? "session" : "passkey",
            amountOut: nil,
            minimumReceived: nil,
            route: nil,
            userOpHash: result.userOpHash,
            transactionHash: result.transactionHash,
            status: status,
            createdAt: Date()
        )
        appendMessage(.onchainTransaction(summary), to: conversationID)
        reloadWalletHistory()
    }

    /// Build an unshield transaction card. `id` is a stable synthetic key (the exit is not a
    /// *daemon* UserOp, so the daemon has no userOpHash for it) used to find and update the
    /// card in place. `delivered` is display text, not raw wei — the card renders it verbatim.
    ///
    /// The real `userOpHash` therefore goes in the summary's `transactionHash` slot: it is the
    /// hash the user can look up, and the summary's own `userOpHash` field is taken by `id`.
    private func unshieldCardSummary(
        id: String,
        amount: String,
        to: String,
        status: OnchainTransactionSummary.Status,
        userOpHash: String?,
        delivered: String?,
        createdAt: Date
    ) -> OnchainTransactionSummary {
        OnchainTransactionSummary(
            chainName: walletModel.activeChain.name,
            chainID: walletModel.activeChain.id,
            amount: amount,
            token: "ETH",
            recipient: to,
            recipientName: nil,
            resolvedRecipient: nil,
            resolutionChainName: nil,
            resolutionChainID: nil,
            ccipReadUsed: nil,
            operation: .unshield,
            signingMode: "privacy-paymaster",
            amountOut: delivered,
            minimumReceived: nil,
            route: nil,
            userOpHash: id,
            transactionHash: userOpHash,
            status: status,
            createdAt: createdAt
        )
    }

    /// `/unshield` accepted: emit the tool response and a "submitted" card immediately, before
    /// proving + submission finish (mirrors how `/shield` shows a submitted card up front).
    ///
    /// Returns the conversation the card landed in, so every later update can address that
    /// conversation explicitly instead of whichever one happens to be active by then.
    private func appendUnshieldSubmittedCard(
        id: String, amount: String, to: String, for intent: ToolIntent
    ) -> UUID? {
        guard let conversationID = activeConversationIDIfPresent else { return nil }
        let payload: [String: Any] = [
            "status": "submitted",
            "intent_id": intent.id.uuidString,
            "operation": "unshield",
            "recipient": to,
        ]
        appendMessage(
            ChatMessage(kind: .toolResponse, role: .tool, text: jsonString(payload), toolCallId: intent.id.uuidString),
            to: conversationID
        )
        let summary = unshieldCardSummary(
            id: id, amount: amount, to: to, status: .submitted,
            userOpHash: nil, delivered: nil, createdAt: Date()
        )
        appendMessage(.onchainTransaction(summary), to: conversationID)
        reloadWalletHistory()
        return conversationID
    }

    /// The wallet stopped waiting for an exit that is probably still running. Deliberately an
    /// assistant note rather than an error: nothing failed, and the user must not be nudged
    /// into retrying and exiting twice.
    private func appendUnshieldStillInFlightNotice(for intent: ToolIntent, in conversationID: UUID?) {
        guard let conversationID else { return }
        appendMessage(
            ChatMessage(
                kind: .toolResponse,
                role: .tool,
                text: jsonString([
                    "status": "in_flight",
                    "intent_id": intent.id.uuidString,
                    "operation": "unshield",
                ]),
                toolCallId: intent.id.uuidString
            ),
            to: conversationID
        )
        appendMessage(
            ChatMessage(
                // `.assistantText`, not `.assistantError`: nothing failed here.
                kind: .assistantText,
                role: .assistant,
                text: RailgunExitCopy.exitStillInFlightMessage
            ),
            to: conversationID
        )
    }

    /// Fold an exit outcome into the card. Called TWICE with the same `id` — once when the
    /// bundler accepts the op (`included: false`) and once when it lands — which is exactly
    /// what `updateOnchainCard` is for, so the status comes from the `included` flag rather
    /// than from which call site produced it.
    ///
    /// There is no forward transaction: the unwrap and the forward ride inside the same
    /// sponsored UserOperation, so the identifying hash is the UserOperation hash.
    private func confirmUnshieldCard(
        id: String, result: JSONValue, amount: String, to: String, in conversationID: UUID?
    ) {
        let userOpHash = result["userOpHash"]?.stringValue
        let included = result["included"]?.boolValue ?? false
        // `deliveredWei` is a 0x-hex STRING on the wire and must stay one all the way into
        // WeiFormatter: 2^53 wei is 0.009 ETH, so any trip through Double would silently
        // corrupt nearly every real amount.
        let delivered = result["deliveredWei"]?.stringValue.map(WeiFormatter.ethDisplayString(fromHexWei:))
        updateOnchainCard(userOpHash: id, in: conversationID) { [self] old in
            // Fall back to what the card already shows: this runs twice, and the second call
            // must never erase a hash or amount the first one displayed just because the later
            // payload omitted the field.
            unshieldCardSummary(
                id: id, amount: amount, to: to,
                status: included ? .included : .submitted,
                userOpHash: userOpHash ?? old.transactionHash,
                delivered: delivered ?? old.amountOut,
                createdAt: old.createdAt
            )
        }
    }

    /// The exit failed: flip the card to "reverted" so it doesn't linger as submitted.
    ///
    /// Reachable ONLY when `RailgunExitCopy.shouldRevertCard(for:)` is true — i.e. the sidecar
    /// reported the job terminally failed. Never for a slow inclusion, a client deadline, an
    /// evicted job or a broken socket, all of which leave the card as it stands.
    /// The error's own message reaches the user via `appendExecutionError`.
    private func markUnshieldCardReverted(
        id: String, amount: String, to: String, in conversationID: UUID?
    ) {
        updateOnchainCard(userOpHash: id, in: conversationID) { [self] old in
            // Carry the existing hash and amount over: a failure AFTER submission is exactly
            // when the user needs them to look the op up or report it.
            unshieldCardSummary(
                id: id, amount: amount, to: to, status: .reverted,
                userOpHash: old.transactionHash, delivered: old.amountOut, createdAt: old.createdAt
            )
        }
    }

    /// Update an on-chain transaction card in place by its `userOpHash`, rewriting the most
    /// recent matching message. Used for cards the daemon doesn't reconcile (unshield).
    ///
    /// `conversationID` is required rather than resolved from the active conversation: the only
    /// callers update a card from a task that may finish long after the user has moved to a
    /// different chat, and the card lives where it was appended.
    private func updateOnchainCard(
        userOpHash: String,
        in conversationID: UUID?,
        _ transform: (OnchainTransactionSummary) -> OnchainTransactionSummary
    ) {
        guard let conversationID,
              let cIndex = conversations.firstIndex(where: { $0.id == conversationID })
        else { return }
        guard let mIndex = conversations[cIndex].messages.lastIndex(where: {
            $0.kind == .onchainTransaction
                && OnchainTransactionSummary.decode(from: $0)?.userOpHash == userOpHash
        }),
            let summary = OnchainTransactionSummary.decode(from: conversations[cIndex].messages[mIndex])
        else { return }
        conversations[cIndex].messages[mIndex].text = ChatMessage.onchainTransaction(transform(summary)).text
        conversations[cIndex].updatedAt = Date()
        try? chatStore.updateMessage(conversations[cIndex].messages[mIndex], in: conversationID)
        reloadWalletHistory()
    }

    private static func kernelExecution(from tx: RailgunHelperClient.ShieldTx) throws -> KernelExecutionRequest {
        KernelExecutionRequest(
            target: tx.to,
            value: try hexData(tx.value).leftPadded(to: 32),
            callData: try hexData(tx.data)
        )
    }

    private static func hexData(_ string: String) throws -> Data {
        var hex = string.hasPrefix("0x") ? String(string.dropFirst(2)) : string
        if hex.count % 2 != 0 { hex = "0" + hex }
        var out = Data()
        out.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { throw AppError.invalidAmount }
            out.append(byte)
            idx = next
        }
        return out
    }

    private func executeIfSupported(
        _ intent: ToolIntent,
        transferPreflightStatus: ChatTransferPreflightStatus? = nil,
        swapPreview: ChatSwapPreview? = nil,
        acknowledgedCallGasLimit: UInt64? = nil
    ) {
        guard intent.tool == .transfer || intent.tool == .swap
            || intent.tool == .shield || intent.tool == .unshield else {
            return
        }
        guard !executingIntentIDs.contains(intent.id) else {
            return
        }
        executingIntentIDs.insert(intent.id)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.executingIntentIDs.remove(intent.id)
            }

            do {
                switch intent.tool {
                case .transfer:
                    let request = try await self.transferRequest(
                        from: intent,
                        preflightStatus: transferPreflightStatus
                    )
                    let result: AppModel.UserOperationSendResult
                    let recipientLabel = request.recipientName.map {
                        "\($0) (\(request.recipient.walletDisplayShortAddress))"
                    } ?? request.recipient.walletDisplayShortAddress
                    switch request.token.kind {
                    case .native:
                        result = try await self.walletModel.executeNativeTransfer(
                            recipient: request.recipient,
                            amountETH: request.amount,
                            logContext: "chat-transfer",
                            signingReason: "Authorize \(request.amount) \(request.token.symbol) transfer to \(recipientLabel) on \(self.walletModel.activeChain.name)",
                            acknowledgedCallGasLimit: acknowledgedCallGasLimit
                        )
                    case .erc20:
                        result = try await self.walletModel.executeERC20Transfer(
                            token: request.token,
                            recipient: request.recipient,
                            amount: request.amount,
                            logContext: "chat-transfer",
                            signingReason: "Authorize \(request.amount) \(request.token.symbol) transfer to \(recipientLabel) on \(self.walletModel.activeChain.name)",
                            acknowledgedCallGasLimit: acknowledgedCallGasLimit
                        )
                    }
                    self.appendExecutionResult(result, for: intent, request: request)
                case .swap:
                    let request = try await self.swapRequest(
                        from: intent,
                        allowApprovalRequired: true,
                        preview: swapPreview
                    )
                    let signingAction = request.quote.requiresApproval && !request.fromToken.isNative
                        ? "Approve \(request.amount) \(request.fromToken.symbol) and authorize \(request.fromToken.symbol) to \(request.toToken.symbol) swap"
                        : "Authorize \(request.amount) \(request.fromToken.symbol) to \(request.toToken.symbol) swap"
                    let result = try await self.walletModel.executeExactInputSwap(
                        quote: request.quote,
                        from: request.fromToken,
                        to: request.toToken,
                        logContext: "chat-swap",
                        signingReason: "\(signingAction) on \(self.walletModel.activeChain.name)",
                        acknowledgedCallGasLimit: acknowledgedCallGasLimit
                    )
                    self.appendSwapExecutionResult(result, for: intent, request: request)
                case .shield:
                    try await self.executeShield(intent: intent, acknowledgedCallGasLimit: acknowledgedCallGasLimit)
                case .unshield:
                    // Intentionally drops acknowledgedCallGasLimit. The exit IS a 4337 UserOp
                    // now, but it is priced by the sidecar against a public bundler and never
                    // reaches the *daemon's* gas estimation, so it cannot produce
                    // .gasEstimationUnavailable and there is no acknowledgement to honour.
                    // Thread it through only if the exit ever moves onto the daemon's path.
                    try await self.executeUnshield(intent: intent)
                }
            } catch {
                self.appendExecutionError(error, for: intent)
            }
        }
    }

    private func transferRequest(
        from intent: ToolIntent,
        preflightStatus: ChatTransferPreflightStatus? = nil
    ) async throws -> ChatTransferRequest {
        guard !WalletTokenRegistry.tokens(on: walletModel.activeChain.id).isEmpty else {
            throw ChatIntentExecutionError.unsupportedChain
        }

        guard let token = WalletTokenRegistry.token(
            matching: intent.args["token"],
            on: walletModel.activeChain.id
        ) else {
            throw ChatIntentExecutionError.unsupportedTransferToken
        }

        guard let rawAmount = intent.args["amount"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawAmount.isEmpty,
              rawAmount.lowercased() != "all"
        else {
            throw ChatIntentExecutionError.unsupportedTransferAmount
        }

        guard let rawRecipient = intent.args["to"]?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ChatIntentExecutionError.invalidTransferRecipient
        }

        _ = try EtherAmountParser.units(fromDecimalString: rawAmount, decimals: token.decimals)

        if let recipientBytes = try? Data(hexString: rawRecipient), recipientBytes.count == 20 {
            return ChatTransferRequest(
                recipient: "0x" + recipientBytes.hexEncodedString,
                recipientName: nil,
                resolvedName: nil,
                amount: rawAmount,
                token: token
            )
        }

        guard rawRecipient.contains(".") else {
            throw ChatIntentExecutionError.invalidTransferRecipient
        }

        if case .resolved(let resolvedName) = preflightStatus {
            let recipientBytes = try Data(hexString: resolvedName.address)
            guard recipientBytes.count == 20 else {
                throw ChatIntentExecutionError.unsupportedENSRecipient
            }
            return ChatTransferRequest(
                recipient: "0x" + recipientBytes.hexEncodedString,
                recipientName: resolvedName.normalizedName,
                resolvedName: resolvedName,
                amount: rawAmount,
                token: token
            )
        }

        do {
            let resolvedName = try await walletModel.resolveName(rawRecipient)
            let recipientBytes = try Data(hexString: resolvedName.address)
            guard recipientBytes.count == 20 else {
                throw ChatIntentExecutionError.unsupportedENSRecipient
            }
            return ChatTransferRequest(
                recipient: "0x" + recipientBytes.hexEncodedString,
                recipientName: resolvedName.normalizedName,
                resolvedName: resolvedName,
                amount: rawAmount,
                token: token
            )
        } catch {
            if error is ChatIntentExecutionError {
                throw error
            }
            throw error
        }
    }

    private func swapRequest(
        from intent: ToolIntent,
        allowApprovalRequired: Bool = false,
        preview: ChatSwapPreview? = nil
    ) async throws -> ChatSwapRequest {
        guard !WalletTokenRegistry.tokens(on: walletModel.activeChain.id).isEmpty else {
            throw ChatIntentExecutionError.unsupportedChain
        }
        guard (intent.args["amount_side"] ?? "input").caseInsensitiveCompare("input") == .orderedSame else {
            throw ChatIntentExecutionError.unsupportedSwapAmountSide
        }
        guard let fromToken = WalletTokenRegistry.token(
            matching: intent.args["from_token"],
            on: walletModel.activeChain.id
        ),
              let toToken = WalletTokenRegistry.token(
                matching: intent.args["to_token"],
                on: walletModel.activeChain.id
              )
        else {
            throw ChatIntentExecutionError.unsupportedSwapToken
        }
        guard fromToken.id != toToken.id else {
            throw ChatIntentExecutionError.sameSwapToken
        }
        guard let rawAmount = intent.args["amount"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawAmount.isEmpty,
              rawAmount.lowercased() != "all"
        else {
            throw ChatIntentExecutionError.unsupportedSwapAmount
        }
        _ = try EtherAmountParser.units(fromDecimalString: rawAmount, decimals: fromToken.decimals)
        let quote: SwapQuote
        if let preview,
           ChatPreflightReusePolicy.canReuseSwapQuote(
            preview: preview,
            fromToken: fromToken,
            toToken: toToken,
            amount: rawAmount
           ) {
            quote = preview.quote
        } else {
            quote = try await walletModel.quoteExactInputSwap(
                from: fromToken,
                to: toToken,
                amount: rawAmount
            )
        }
        if quote.requiresApproval && !allowApprovalRequired {
            throw AppError.swapApprovalRequired(fromToken.symbol)
        }
        return ChatSwapRequest(
            fromToken: fromToken,
            toToken: toToken,
            amount: rawAmount,
            quote: quote
        )
    }

    private func appendExecutionResult(
        _ result: AppModel.UserOperationSendResult,
        for intent: ToolIntent,
        request: ChatTransferRequest
    ) {
        guard let conversationID = activeConversationIDIfPresent else {
            return
        }

        var responsePayload: [String: Any] = [
            "status": "submitted",
            "intent_id": intent.id.uuidString,
            "user_op_hash": result.userOpHash,
            "signed_by": result.signedBySession ? "session_key" : "passkey",
        ]
        if let transactionHash = result.transactionHash {
            responsePayload["transaction_hash"] = transactionHash
        }
        if let success = result.success {
            responsePayload["success"] = success
        }
        responsePayload["recipient"] = request.recipient
        if let recipientName = request.recipientName {
            responsePayload["recipient_name"] = recipientName
        }
        appendMessage(
            ChatMessage(
                kind: .toolResponse,
                role: .tool,
                text: jsonString(responsePayload),
                toolCallId: intent.id.uuidString
            ),
            to: conversationID
        )

        let status: OnchainTransactionSummary.Status
        if result.success == true {
            status = .included
        } else if result.success == false {
            status = .reverted
        } else if result.transactionHash != nil {
            status = .submitted
        } else {
            status = .pending
        }

        let summary = OnchainTransactionSummary(
            chainName: walletModel.activeChain.name,
            chainID: walletModel.activeChain.id,
            amount: intent.args["amount"] ?? "—",
            token: resolvedTokenSymbol(for: intent),
            recipient: request.recipient,
            recipientName: request.recipientName,
            resolvedRecipient: request.resolvedName?.address,
            resolutionChainName: request.resolvedName?.resolutionChainName,
            resolutionChainID: request.resolvedName.map { UInt64($0.resolutionChainId) },
            ccipReadUsed: request.resolvedName?.ccipReadUsed,
            operation: .transfer,
            signingMode: result.signedBySession ? "session" : "passkey",
            amountOut: nil,
            minimumReceived: nil,
            route: nil,
            userOpHash: result.userOpHash,
            transactionHash: result.transactionHash,
            status: status,
            createdAt: Date()
        )
        appendMessage(.onchainTransaction(summary), to: conversationID)
        reloadWalletHistory()
    }

    private func appendSwapExecutionResult(
        _ result: AppModel.UserOperationSendResult,
        for intent: ToolIntent,
        request: ChatSwapRequest
    ) {
        guard let conversationID = activeConversationIDIfPresent else {
            return
        }

        var responsePayload: [String: Any] = [
            "status": "submitted",
            "intent_id": intent.id.uuidString,
            "user_op_hash": result.userOpHash,
            "token_in": request.fromToken.symbol,
            "token_out": request.toToken.symbol,
            "amount_in": request.amount,
            "quote_amount_out": "0x" + request.quote.quoteAmountOut.hexEncodedString,
            "amount_out_minimum": "0x" + request.quote.amountOutMinimum.hexEncodedString,
            "approval_batched": request.quote.requiresApproval && !request.fromToken.isNative,
            "signed_by": result.signedBySession ? "session_key" : "passkey",
        ]
        if let transactionHash = result.transactionHash {
            responsePayload["transaction_hash"] = transactionHash
        }
        if let success = result.success {
            responsePayload["success"] = success
        }
        appendMessage(
            ChatMessage(
                kind: .toolResponse,
                role: .tool,
                text: jsonString(responsePayload),
                toolCallId: intent.id.uuidString
            ),
            to: conversationID
        )

        let status: OnchainTransactionSummary.Status
        if result.success == true {
            status = .included
        } else if result.success == false {
            status = .reverted
        } else if result.transactionHash != nil {
            status = .submitted
        } else {
            status = .pending
        }

        let summary = OnchainTransactionSummary(
            chainName: walletModel.activeChain.name,
            chainID: walletModel.activeChain.id,
            amount: request.amount,
            token: "\(request.fromToken.symbol) -> \(request.toToken.symbol)",
            recipient: request.quote.router,
            recipientName: "Uniswap SwapRouter02",
            resolvedRecipient: nil,
            resolutionChainName: nil,
            resolutionChainID: nil,
            ccipReadUsed: nil,
            operation: .swap,
            signingMode: result.signedBySession ? "session" : "passkey",
            amountOut: TokenAmountFormatter.displayString(
                rawUnits: request.quote.quoteAmountOut,
                decimals: request.toToken.decimals,
                symbol: request.toToken.symbol
            ),
            minimumReceived: TokenAmountFormatter.displayString(
                rawUnits: request.quote.amountOutMinimum,
                decimals: request.toToken.decimals,
                symbol: request.toToken.symbol
            ),
            route: swapRouteLabel(for: request),
            userOpHash: result.userOpHash,
            transactionHash: result.transactionHash,
            status: status,
            createdAt: Date()
        )
        appendMessage(.onchainTransaction(summary), to: conversationID)
        reloadWalletHistory()
    }

    private func swapRouteLabel(for request: ChatSwapRequest) -> String {
        guard !request.quote.hops.isEmpty else {
            return "\(request.fromToken.symbol) -> \(request.toToken.symbol)"
        }
        var symbols = [request.fromToken.symbol]
        for hop in request.quote.hops {
            symbols.append(
                WalletTokenRegistry.token(
                    matching: hop.tokenOut,
                    on: request.fromToken.chainID
                )?.symbol ?? hop.tokenOut.walletDisplayShortAddress
            )
        }
        return symbols.joined(separator: " -> ")
    }

    private func resolvedTokenSymbol(for intent: ToolIntent) -> String {
        WalletTokenRegistry.token(
            matching: intent.args["token"],
            on: walletModel.activeChain.id
        )?.symbol ?? intent.args["token"] ?? "ETH"
    }

    /// - Parameter conversationID: the conversation to report into. Defaults to the active one;
    ///   the unshield paths pass an explicit id because their detached inclusion task can finish
    ///   after the user has switched chats, and an error must not surface in a conversation that
    ///   never ran the intent.
    private func appendExecutionError(
        _ error: Error, for intent: ToolIntent, in conversationID: UUID? = nil
    ) {
        guard let conversationID = conversationID ?? activeConversationIDIfPresent else {
            return
        }

        if case let .gasEstimationUnavailable(detail, suggested)? =
            ChatIntentExecutionStatus.gasEstimationUnavailable(from: error) {
            appendMessage(
                ChatMessage(
                    kind: .toolResponse,
                    role: .tool,
                    text: jsonString([
                        "status": "gas_estimation_unavailable",
                        "intent_id": intent.id.uuidString,
                        "detail": detail,
                        "suggested_call_gas_limit": suggested,
                    ]),
                    toolCallId: intent.id.uuidString
                ),
                to: conversationID
            )
            return
        }

        // Backstop for a relayer status too stale to pre-flight against: the daemon refused
        // after all, so replace its raw `-32002 … bundler_eoa_needs_topup` with the same
        // sentence the intent card would have shown. A failed RAILGUN exit is checked first
        // because it carries its own stable code and must not reach the chat as raw Rust text.
        let message = RailgunExitCopy.failureCopy(for: error)
            ?? BundlerGasStatus.friendlyMessage(for: error, status: accountIdentity.bundlerGas)
            ?? error.localizedDescription

        appendMessage(
            ChatMessage(
                kind: .toolResponse,
                role: .tool,
                text: jsonString([
                    "status": "failed",
                    "intent_id": intent.id.uuidString,
                    "error": message,
                ]),
                toolCallId: intent.id.uuidString
            ),
            to: conversationID
        )
        appendMessage(
            ChatMessage(
                kind: .assistantError,
                role: .assistant,
                text: message
            ),
            to: conversationID
        )
    }

    private var activeConversationIDIfPresent: UUID? {
        conversations.contains { $0.id == activeConversationID } ? activeConversationID : nil
    }

    private func jsonString(_ payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            return #"{"status":"failed","error":"invalid execution response"}"#
        }
        return json
    }

    private func editedIntentResponseText(for intent: ToolIntent) -> String {
        let payload: [String: Any] = [
            "status": "acknowledged",
            "intent_id": intent.id.uuidString,
            "edited": "true",
            "args": intent.args
        ]

        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return #"{"status":"acknowledged","intent_id":"\#(intent.id.uuidString)","edited":"true","args":{}}"#
        }

        return json
    }

    private func promptBeforeToolIntent(at messageIndex: Int, in messages: [ChatMessage]) -> String {
        var index = messageIndex - 1
        while index >= 0 {
            let message = messages[index]
            if message.kind == .userText, message.role == .user {
                return message.text ?? ""
            }
            index -= 1
        }
        return ""
    }

    private static func exportDateStamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    private func updateTitleIfNeeded(for conversationID: UUID, prompt: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }
        guard conversations[index].title == "New chat" else {
            return
        }

        let title = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[index].title = String(title.prefix(44))
        try? chatStore.updateConversationMetadata(conversations[index])
    }

    private func sortConversationsKeepingActive() {
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }
}

/// Tracks whether the chat transcript is scrolled to (near) the bottom, so new messages can
/// follow the tail without yanking a user who has scrolled up.
///
/// This deliberately observes the scroll view's own geometry instead of measuring a sentinel
/// view during layout. The previous implementation published a `.global`-frame distance from a
/// `GeometryReader` inside the `ScrollView` as a preference on every layout pass; that preference
/// mutated `@State`, which drove an animated `scrollTo`, which moved the sentinel, which
/// republished the preference. Layout never reached a fixed point and the main thread spun at
/// 100% CPU. Mapping to a plain `Bool` here means at most one state mutation per threshold
/// crossing, so the follow-scroll cannot re-trigger itself.
private struct ChatBottomTracker: ViewModifier {
    @Binding var isAtBottom: Bool

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: Bool.self) { geometry in
            // `contentInsets` is deliberately ignored: the fully general maximum offset is
            // `contentSize.height + contentInsets.bottom - containerSize.height`, but this
            // scroll view has no `.contentMargins`/`.safeAreaInset` and its 28pt padding
            // lives inside the content, so the two agree today and the 80pt threshold
            // absorbs the difference. Adding content margins later would make the flag
            // sticky-false — fold `contentInsets.bottom` in here if that happens.
            ChatScrollAnchor.isNearBottom(
                contentOffsetY: geometry.contentOffset.y,
                contentHeight: geometry.contentSize.height,
                containerHeight: geometry.containerSize.height
            )
        } action: { _, nearBottom in
            // Kept even though `onScrollGeometryChange` only fires on change: `isAtBottom` is
            // also written imperatively by the streaming handler and the jump-to-latest
            // button, so the transform's notion of "changed" can diverge from the state.
            if nearBottom != isAtBottom {
                isAtBottom = nearBottom
            }
        }
    }
}

/// The near-bottom decision, hoisted out of the `ViewModifier` closure so it can be tested.
enum ChatScrollAnchor {
    /// Treat "within this many points of the end" as at-bottom, so a settling scroll animation
    /// or a one-pixel rounding difference doesn't flip the flag.
    ///
    /// Note this is a scroll-offset delta, whereas the value it replaced was a `.global`-frame
    /// distance between two views. They coincide in practice, but the `80` is not literally
    /// "unchanged behaviour".
    static let nearBottomThreshold: CGFloat = 80

    static func isNearBottom(
        contentOffsetY: CGFloat,
        contentHeight: CGFloat,
        containerHeight: CGFloat
    ) -> Bool {
        // Content shorter than the container can't scroll, so it is always at the bottom.
        let maxOffset = max(0, contentHeight - containerHeight)
        return contentOffsetY >= maxOffset - nearBottomThreshold
    }
}

private enum DashboardSection {
    case chat
    case history
    case settings
}

private enum WalletHistoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case done = "Done"
    case pending = "Pending"
    case reverted = "Reverted"

    var id: String { rawValue }

    var tint: Color {
        switch self {
        case .all:
            return ChatPalette.secondaryText
        case .done:
            return ChatPalette.success
        case .pending:
            return ChatPalette.accent
        case .reverted:
            return ChatPalette.warning
        }
    }

    func count(in records: [WalletTransactionRecord]) -> Int {
        records.filter(includes).count
    }

    func includes(_ record: WalletTransactionRecord) -> Bool {
        switch self {
        case .all:
            return true
        case .done:
            return record.status == .included
        case .pending:
            return record.status.requiresReceiptRefresh
        case .reverted:
            return record.status == .reverted || record.status == .failed
        }
    }
}

struct LocalWalletChatDashboardView: View {
    @StateObject private var model = ChatDashboardModel()
    @State private var conversationPendingDeletion: ChatConversation?
    @State private var isToolsPopoverPresented = false
    @State private var isGasPopoverPresented = false
    @State private var isSessionPopoverPresented = false
    @State private var isSessionActionInProgress = false
    @State private var sessionPopoverMessage: String?
    @State private var isAtBottomOfChat = true
    // Account cards start hidden; clicking the chain bar reveals them. Persisted so the
    // choice sticks across launches.
    @AppStorage("localwallet.accountHeaderExpanded") private var isAccountHeaderExpanded = false
    // Privacy on → show the RAILGUN pieces (the shielded balance row). Off → hide them and the
    // wallet reads as a plain account. Persisted across launches.
    @AppStorage("localwallet.privacyEnabled") private var privacyEnabled = true
    @State private var selectedSection: DashboardSection = .chat
    @State private var settingsInitialTab: LocalWalletSettingsTab = .info
    @State private var historyFilter: WalletHistoryFilter = .all

    private var filteredHistoryRecords: [WalletTransactionRecord] {
        model.walletHistoryRecords.filter(historyFilter.includes)
    }

    private var visibleHistorySelection: WalletTransactionRecord? {
        guard let selected = model.selectedHistoryRecord,
              historyFilter.includes(selected) else {
            return filteredHistoryRecords.first
        }
        return selected
    }

    var body: some View {
        ZStack {
            ChatPalette.background.ignoresSafeArea()
            HStack(spacing: 0) {
                if model.isSidebarVisible {
                    chatSidebar
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                VStack(spacing: 0) {
                    toolbar
                    if selectedSection == .settings {
                        settingsBody
                    } else {
                        accountHeader
                        if selectedSection == .chat,
                           let level = model.contextUsageLevel,
                           let snapshot = model.contextUsageSnapshot {
                            ContextUsageBanner(
                                level: level,
                                used: snapshot.used,
                                total: snapshot.total,
                                onNewChat: { model.createNewChat() }
                            )
                            .padding(.bottom, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if selectedSection == .chat {
                            chatBody
                            footerControls
                            composer
                        } else {
                            historyBody
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: model.contextUsageLevel)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
        }
        .frame(minWidth: 980, minHeight: 720)
        .background(keyboardShortcutLayer)
        .alert(
            "Delete chat?",
            isPresented: deletionAlertBinding,
            presenting: conversationPendingDeletion
        ) { conversation in
            Button("Delete", role: .destructive) {
                model.deleteConversation(conversation.id)
            }
            Button("Cancel", role: .cancel) { }
        } message: { conversation in
            Text("“\(conversation.title)” will be removed from this device. This cannot be undone.")
        }
        .alert(
            "Rankings export",
            isPresented: feedbackExportAlertBinding
        ) {
            Button("OK") {
                model.feedbackExportMessage = nil
            }
        } message: {
            Text(model.feedbackExportMessage ?? "")
        }
        .onAppear {
            model.startSessionActivityTracking()
        }
        .onDisappear {
            model.stopSessionActivityTracking()
        }
    }

    @ViewBuilder
    private var keyboardShortcutLayer: some View {
        ZStack {
            Button("New chat") {
                model.createNewChat()
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("Focus composer") {
                NotificationCenter.default.post(name: .chatComposerFocusRequested, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
            Button("Delete current chat") {
                if let active = model.activeConversation {
                    conversationPendingDeletion = active
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var deletionAlertBinding: Binding<Bool> {
        Binding(
            get: { conversationPendingDeletion != nil },
            set: { newValue in
                if !newValue {
                    conversationPendingDeletion = nil
                }
            }
        )
    }

    private var feedbackExportAlertBinding: Binding<Bool> {
        Binding(
            get: { model.feedbackExportMessage != nil },
            set: { newValue in
                if !newValue {
                    model.feedbackExportMessage = nil
                }
            }
        )
    }

    private var chatSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Chats")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(ChatPalette.primaryText)
                Spacer()
                Button {
                    model.createNewChat()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(ChatPalette.primaryText)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(ChatPalette.buttonCircle))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 18)
            .padding(.horizontal, 16)

            ScrollView {
                LazyVStack(spacing: 8, pinnedViews: []) {
                    ForEach(groupedConversations, id: \.0) { bucket, conversations in
                        sidebarBucketHeader(bucket)
                        ForEach(conversations) { conversation in
                            ChatConversationRow(
                                conversation: conversation,
                                isSelected: conversation.id == model.activeConversationID,
                                onSelect: { model.selectConversation(conversation) },
                                onDelete: { conversationPendingDeletion = conversation },
                                onRename: { newTitle in
                                    model.renameConversation(conversation.id, to: newTitle)
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 270)
        .background(ChatPalette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(ChatPalette.border.opacity(0.75))
                .frame(width: 1)
        }
    }

    private var groupedConversations: [(ChatSidebarBucket, [ChatConversation])] {
        var groups: [ChatSidebarBucket: [ChatConversation]] = [:]
        for conversation in model.conversations {
            let bucket = ChatSidebarBucket.bucket(for: conversation.updatedAt)
            groups[bucket, default: []].append(conversation)
        }
        return ChatSidebarBucket.allCases.compactMap { bucket in
            guard let conversations = groups[bucket], !conversations.isEmpty else {
                return nil
            }
            return (bucket, conversations)
        }
    }

    private func sidebarBucketHeader(_ bucket: ChatSidebarBucket) -> some View {
        HStack {
            Text(bucket.rawValue)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(ChatPalette.mutedText)
                .textCase(.uppercase)
                .tracking(0.6)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var toolbar: some View {
        HStack {
            HStack(spacing: 10) {
                Button {
                    model.toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(ChatPalette.secondaryText)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(ChatPalette.buttonCircle.opacity(model.isSidebarVisible ? 0.75 : 1)))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .frame(width: 180)

            Spacer()

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    DashboardSectionButton(
                        title: "Chat",
                        systemImage: "bubble.left.and.bubble.right.fill",
                        isSelected: selectedSection == .chat,
                        action: { selectedSection = .chat }
                    )
                    DashboardSectionButton(
                        title: "History",
                        systemImage: "clock.arrow.circlepath",
                        isSelected: selectedSection == .history,
                        action: {
                            showHistory()
                        }
                    )
                    DashboardSectionButton(
                        title: "Settings",
                        systemImage: "gearshape.fill",
                        isSelected: selectedSection == .settings,
                        action: {
                            settingsInitialTab = .info
                            selectedSection = .settings
                        }
                    )
                }
                .padding(3)
                .background(Capsule().fill(ChatPalette.panel).overlay(Capsule().stroke(ChatPalette.border, lineWidth: 1)))

            }

            Spacer()

            Color.clear
                .frame(width: 180, height: 1)
        }
        .frame(height: 42)
    }

    private var settingsBody: some View {
        LocalWalletSettingsView(
            snapshot: model.settingsSnapshot,
            thinkingEnabled: $model.thinkingEnabled,
            initialTab: settingsInitialTab,
            onExportRankings: {
                model.exportFeedbackRankings()
            },
            onExportDatabase: {
                try model.exportChatDatabase()
            },
            onRevealDatabase: {
                model.revealChatDatabase()
            },
            onClearChatHistory: {
                try model.clearChatHistory()
            },
            onClearRankings: {
                try model.clearFeedbackRankings()
            },
            onRevealModelFile: {
                try model.revealModelFile()
            },
            onSaveNetworkSettings: { settings in
                try model.saveNetworkSettings(settings)
            },
            onTestNetworkSettings: { settings in
                try await model.testNetworkSettings(settings)
            },
            onRunDiagnostics: { settings in
                await model.runSettingsDiagnostics(settings)
            },
            onMonitorHeliosCheckpoint: { settings in
                try await model.monitorHeliosCheckpointFromSettings(settings)
            },
            onRefreshRelayer: {
                model.refreshLocalRelayerFromSettings()
            },
            onRotateRelayer: {
                try await model.rotateLocalRelayerFromSettings()
            },
            onExportRelayerKey: {
                try await model.exportLocalRelayerKeyFromSettings()
            },
            onDeleteRelayerKey: { unsafe in
                try await model.deleteLocalRelayerKeyFromSettings(unsafe: unsafe)
            },
            onResetWallet: {
                try model.resetWalletFromSettings()
            },
            onEnableSessionKeys: {
                try await model.enableSessionKeysFromSettings()
            },
            onRevokeSessionKeys: {
                try await model.revokeSessionKeysFromSettings()
            },
            onUpdateSessionPolicy: { policy in
                try model.updateSessionPolicyFromSettings(policy)
            },
            onCopyDebugReport: {
                await model.debugSessionReportFromSettings()
            },
            onClearDebugLog: {
                model.clearDebugLogFromSettings()
            },
            onSetUnlockRelayerOnLaunch: { isEnabled in
                model.setUnlockRelayerOnLaunch(isEnabled)
            },
            onSetSwapSlippageBps: { bps in
                model.setSwapSlippageBps(bps)
            },
            onSetContextWindowTokens: { tokens in
                model.setContextWindowTokens(tokens)
            },
            onClose: {
                selectedSection = .chat
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 10)
    }

    /// Toggles the RAILGUN surface (the shielded balance row) on/off.
    private var privacyToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { privacyEnabled.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: privacyEnabled ? "lock.shield.fill" : "lock.open")
                    .font(.system(size: 12, weight: .black))
                Text("Privacy")
                    .font(.system(size: 12, weight: .heavy))
                Text(privacyEnabled ? "On" : "Off")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(privacyEnabled ? Color.white.opacity(0.85) : ChatPalette.mutedText)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(privacyEnabled ? Color.white.opacity(0.18) : ChatPalette.buttonCircle))
            }
            .foregroundStyle(privacyEnabled ? Color.white : ChatPalette.secondaryText)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(privacyEnabled ? ChatPalette.accent : ChatPalette.panel.opacity(0.75))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(privacyEnabled ? ChatPalette.accent : ChatPalette.border.opacity(0.75), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(privacyEnabled
            ? "Privacy on — RAILGUN shielding is available. Click to hide it."
            : "Privacy off — shielded balances are hidden. Click to show.")
    }

    private var accountHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ChainStatusStrip(
                    identity: model.accountIdentity,
                    isExpanded: isAccountHeaderExpanded,
                    onToggle: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isAccountHeaderExpanded.toggle()
                        }
                        // Opening the cards is the clearest signal that the user wants to see a
                        // current balance, and it's the only place the balance is actually shown.
                        // Collapsing them is not, so this is deliberately one-directional.
                        if isAccountHeaderExpanded {
                            model.refreshAccountBalanceOnDemand()
                        }
                    }
                )
                .frame(maxWidth: .infinity)

                privacyToggle

                Button {
                    model.refreshOnchainAccountStatus()
                } label: {
                    Group {
                        if model.isRefreshingAccountIdentity {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .black))
                                .foregroundStyle(ChatPalette.secondaryText)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(ChatPalette.panel.opacity(0.75))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ChatPalette.border.opacity(0.75), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                .disabled(model.isRefreshingAccountIdentity)
                .help("Refresh balances")
            }
            if isAccountHeaderExpanded {
                HStack(alignment: .top, spacing: 12) {
                    // The Kernel account is where funds are received, so its address stays
                    // front and centre.
                    AddressPill(
                        icon: "lock.shield.fill",
                        title: "Kernel smart account",
                        address: model.accountIdentity.kernelAddress,
                        balance: model.accountIdentity.kernelBalance,
                        state: model.accountIdentity.kernelState,
                        tokenBalances: model.kernelTokenBalances,
                        isRefreshingTokenBalances: model.isRefreshingTokenBalances,
                        onRefreshTokenBalances: { model.refreshTokenBalances(force: true) },
                        explorerURL: explorerAddressURL(model.accountIdentity.kernelAddress)
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    // The bundler is the wallet's one gas-paying helper EOA: lead with a Fund
                    // action, not the address.
                    FundableAccountCard(
                        icon: "key.fill",
                        title: "Bundler",
                        subtitle: "Relays your account's transactions",
                        address: model.accountIdentity.bundlerAddress,
                        balance: model.accountIdentity.bundlerBalance,
                        state: model.accountIdentity.bundlerState,
                        isFunding: model.fundingHelperAddress == model.accountIdentity.bundlerAddress,
                        fundError: model.helperFundErrorAddress == model.accountIdentity.bundlerAddress ? model.helperFundError : nil,
                        tokenBalances: model.bundlerTokenBalances,
                        isRefreshingTokenBalances: model.isRefreshingTokenBalances,
                        onRefreshTokenBalances: { model.refreshTokenBalances(force: true) },
                        explorerURL: explorerAddressURL(model.accountIdentity.bundlerAddress),
                        gasWarning: model.accountIdentity.bundlerGas,
                        onFund: { amount in
                            model.fundHelper(
                                address: model.accountIdentity.bundlerAddress,
                                amountETH: amount,
                                label: "bundler"
                            )
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                if privacyEnabled {
                    shieldedBalanceRow
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.18), value: isAccountHeaderExpanded)
        .animation(.easeInOut(duration: 0.18), value: privacyEnabled)
    }

    /// Shielded (RAILGUN) balance row: confirmed = cleared/spendable, pending = deposited
    /// but awaiting the pool's approval set. Refreshed after shield/unshield or manually.
    private var shieldedBalanceRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.secondary)
            Text("Shielded (RAILGUN)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let confirmed = model.shieldedConfirmed {
                Text("Confirmed \(confirmed) · Pending \(model.shieldedPending ?? "0 ETH")")
                    .font(.caption.monospacedDigit())
                    .help("Confirmed = cleared and spendable. Pending = deposited but not yet included by the pool's approval set.")
            } else if model.isRefreshingShieldedBalance {
                Text("Loading… (syncing the pool)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.shieldedBalanceError != nil {
                Text("unavailable")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(model.shieldedBalanceError ?? "")
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                model.refreshShieldedBalance()
            } label: {
                Image(systemName: model.isRefreshingShieldedBalance ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(model.isRefreshingShieldedBalance)
            .help("Refresh shielded balance")
        }
        .padding(.top, 2)
        .task {
            // Auto-load once when the account header first shows this row, so the balance
            // is visible without hunting for the refresh button. (Starts the sidecar.)
            if model.shieldedConfirmed == nil && model.shieldedBalanceError == nil {
                model.refreshShieldedBalance()
            }
        }
    }

    private func explorerAddressURL(_ address: String) -> URL? {
        guard address.hasPrefix("0x"), address.count == 42 else {
            return nil
        }
        return explorerBaseURL.appending(path: "address").appending(path: address)
    }

    private var explorerBaseURL: URL {
        if model.accountIdentity.chainID == 11_155_111 {
            return URL(string: "https://sepolia.etherscan.io")!
        }
        return URL(string: "https://etherscan.io")!
    }

    @ViewBuilder
    private var chatBody: some View {
        if model.messages.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(model.messages) { message in
                            switch message.kind {
                            case .userText, .assistantText:
                                ChatBubble(
                                    message: message,
                                    canRegenerate: message.role == .assistant && !model.isGenerating,
                                    onRegenerate: { model.regenerate(from: message) },
                                    canEdit: message.kind == .userText && !model.isGenerating,
                                    onEdit: { newText in
                                        model.editAndResend(message, newText: newText)
                                    }
                                )
                                .id(message.id)
                            case .assistantError:
                                AssistantErrorBubble(
                                    message: message,
                                    canRetry: !model.isGenerating,
                                    onRetry: { model.regenerate(from: message) }
                                )
                                .id(message.id)
                            case .toolIntent:
                                if let intent = message.toolIntent {
                                    let transferPreflightStatus = model.transferPreflightStatus(for: intent)
                                    let swapPreflightStatus = model.swapPreflightStatus(for: intent)
                                    HStack {
                                        ToolIntentCardView(
                                            intent: intent,
                                            feedback: message.toolFeedback,
                                            executionStatus: model.executionStatus(for: intent),
                                            transferPreflightStatus: transferPreflightStatus,
                                            swapPreflightStatus: swapPreflightStatus,
                                            bundlerGasStatus: model.bundlerGasStatus(for: intent),
                                            signingPreview: model.signingPreview(
                                                for: intent,
                                                transferPreflightStatus: transferPreflightStatus,
                                                swapPreflightStatus: swapPreflightStatus
                                            ),
                                            onConfirm: { model.confirmIntent(message) },
                                            onReject: { model.rejectIntent(message) },
                                            onEdit: { editedIntent in
                                                model.editIntent(message, with: editedIntent)
                                            },
                                            onFeedback: { rating, note in
                                                model.submitIntentFeedback(for: message, rating: rating, note: note)
                                            },
                                            onSubmitWithGasHeadroom: { suggested in
                                                model.retryIntentWithGasHeadroom(intent, callGasLimit: suggested)
                                            }
                                        )
                                        Spacer(minLength: 0)
                                    }
                                    .onAppear {
                                        model.prepareIntentPreview(message)
                                    }
                                    .padding(.horizontal)
                                    .id(message.id)
                                }
                            case .onchainTransaction:
                                if let summary = OnchainTransactionCard.summary(from: message) {
                                    let replacement = model.replacementStatus(for: summary)
                                    HStack {
                                        OnchainTransactionCard(
                                            summary: summary,
                                            replacementBlocked: replacement?.blocked ?? false,
                                            replacementBlockedReason: replacement?.blockedReason,
                                            replacementActionState: model.replacementActionState(for: summary.userOpHash),
                                            onOpenHistory: { userOpHash in
                                                model.selectHistoryRecord(userOpHash: userOpHash)
                                                selectedSection = .history
                                            },
                                            onSpeedUp: { model.speedUpPendingOperation($0) },
                                            onCancel: { model.cancelPendingOperation($0) }
                                        )
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal)
                                    .id(message.id)
                                }
                            case .toolResponse:
                                EmptyView()
                            }
                        }
                        if let streamingID = model.streamingMessageID {
                            StreamingAssistantBubble(
                                text: model.streamingText,
                                onStop: { model.stop() }
                            )
                            .id(streamingID)
                        }
                    }
                    .padding(.vertical, 28)
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                }
                .modifier(ChatBottomTracker(isAtBottom: $isAtBottomOfChat))
                .onChange(of: model.messages) { _, messages in
                    guard isAtBottomOfChat, let last = messages.last else { return }
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: model.streamingMessageID) { _, newID in
                    guard let newID else { return }
                    isAtBottomOfChat = true
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo(newID, anchor: .bottom)
                    }
                }
                .onChange(of: model.streamingText) { _, _ in
                    guard isAtBottomOfChat, let id = model.streamingMessageID else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
                .overlay(alignment: .bottomTrailing) {
                    // The implicit animation is scoped to this overlay. Applied to the ScrollView
                    // itself it animated the whole transcript — re-measuring every selectable
                    // text run — each time the near-bottom flag flipped.
                    ZStack {
                        if !isAtBottomOfChat {
                            Button {
                                let targetID: AnyHashable
                                if let id = model.streamingMessageID {
                                    targetID = id
                                } else if let last = model.messages.last {
                                    targetID = last.id
                                } else {
                                    return
                                }
                                withAnimation(.easeOut(duration: 0.22)) {
                                    proxy.scrollTo(targetID, anchor: .bottom)
                                }
                                isAtBottomOfChat = true
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(ChatPalette.primaryText)
                                    .frame(width: 34, height: 34)
                                    .background(
                                        Circle()
                                            .fill(ChatPalette.buttonCircle)
                                            .overlay(Circle().stroke(ChatPalette.border, lineWidth: 1))
                                    )
                            }
                            .buttonStyle(.plain)
                            .help("Jump to latest")
                            .padding(.bottom, 12)
                            .padding(.trailing, 12)
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.15), value: isAtBottomOfChat)
                }
            }
        }
    }

    private var historyBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    selectedSection = .chat
                } label: {
                    Label("Chat", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(ChatPalette.primaryText)
                        .lineLimit(1)
                        .frame(width: 86, height: 34)
                        .background(
                            Capsule()
                                .fill(ChatPalette.buttonCircle)
                                .overlay(Capsule().stroke(ChatPalette.border, lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
                .help("Back to chat")

                VStack(alignment: .leading, spacing: 4) {
                    Text("History")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(ChatPalette.primaryText)
                    Text("App-submitted UserOperations. Done means the receipt confirmed success.")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ChatPalette.secondaryText)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    model.exportWalletHistory()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(ChatPalette.primaryText)
                        .lineLimit(1)
                        .labelStyle(.iconOnly)
                        .frame(width: 36, height: 34)
                        .background(
                            Capsule()
                                .fill(ChatPalette.buttonCircle)
                                .overlay(Capsule().stroke(ChatPalette.border, lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
                .help("Export history")
                Button {
                    model.refreshWalletHistory()
                } label: {
                    HStack(spacing: 8) {
                        if model.isRefreshingWalletHistory {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .black))
                        }
                        Text("Refresh")
                            .font(.system(size: 12, weight: .heavy))
                            .lineLimit(1)
                    }
                    .foregroundStyle(ChatPalette.primaryText)
                    .frame(width: 94, height: 34)
                    .background(
                        Capsule()
                            .fill(ChatPalette.buttonCircle)
                            .overlay(Capsule().stroke(ChatPalette.border, lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                .disabled(model.isRefreshingWalletHistory)
            }

            HistoryStatusSummary(
                records: model.walletHistoryRecords,
                selection: historyFilter,
                onSelect: selectHistoryFilter
            )

            if let message = model.walletHistoryMessage {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text(message)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(ChatPalette.secondaryText)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .frame(maxWidth: 520)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(ChatPalette.panel)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(ChatPalette.border, lineWidth: 1))
                )
            }

            if model.walletHistoryRecords.isEmpty {
                WalletHistoryEmptyState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredHistoryRecords.isEmpty {
                WalletHistoryEmptyState(
                    title: "No \(historyFilter.rawValue.lowercased()) records",
                    message: "Choose another status filter or refresh history."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { proxy in
                    let isCompact = proxy.size.width < 860
                    if isCompact,
                       model.selectedHistoryUserOpHash != nil,
                       let selected = model.selectedHistoryRecord,
                       historyFilter.includes(selected) {
                        WalletHistoryDetailView(
                            record: selected,
                            showsBackButton: true,
                            onBack: { model.clearSelectedHistoryRecord() }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        HStack(spacing: 12) {
                            WalletHistoryListView(
                                records: filteredHistoryRecords,
                                selectedRecord: visibleHistorySelection,
                                onSelect: { model.selectHistoryRecord($0) }
                            )
                            .frame(minWidth: isCompact ? proxy.size.width : 320, idealWidth: 380, maxWidth: isCompact ? .infinity : 420)

                            if !isCompact {
                                if let selected = visibleHistorySelection {
                                    WalletHistoryDetailView(record: selected)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                } else {
                                    WalletHistoryEmptyState()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func showHistory() {
        model.reloadWalletHistory()
        model.clearSelectedHistoryRecord()
        selectedSection = .history
    }

    private func selectHistoryFilter(_ filter: WalletHistoryFilter) {
        historyFilter = filter
        guard let selected = model.selectedHistoryRecord,
              filter.includes(selected) else {
            model.clearSelectedHistoryRecord()
            return
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(ChatPalette.avatar)
                    .frame(width: 132, height: 132)
                Image(systemName: "person.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(ChatPalette.secondaryText)
            }
            VStack(spacing: 6) {
                Text(greeting)
                    .font(.system(size: 32, weight: .heavy))
                    .foregroundStyle(ChatPalette.primaryText)
                Text("Pick a starter below or just message Gemma directly.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ChatPalette.secondaryText)
                    .multilineTextAlignment(.center)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(welcomeStarters, id: \.title) { starter in
                    WelcomeStarterChip(starter: starter) {
                        model.inputText = starter.prompt
                        NotificationCenter.default.post(name: .chatComposerFocusRequested, object: nil)
                    }
                }
            }
            .frame(maxWidth: 620)
            .padding(.top, 6)

            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private var welcomeStarters: [WelcomeStarter] {
        [
            WelcomeStarter(
                icon: "arrow.up.right.circle.fill",
                title: "Transfer",
                prompt: "Send 0.1 ETH to vitalik.eth"
            ),
            WelcomeStarter(
                icon: "arrow.triangle.swap",
                title: "Swap",
                prompt: "Swap 100 USDC for ETH"
            ),
            WelcomeStarter(
                icon: "slash.circle.fill",
                title: "Try a slash command",
                prompt: "/transfer 0.05 ETH to <recipient>"
            ),
            WelcomeStarter(
                icon: "lock.shield.fill",
                title: "How keys stay safe",
                prompt: "How does this wallet keep my private keys safe?"
            )
        ]
    }

    private var sessionPillText: String {
        switch model.settingsSnapshot.session.statusTitle {
        case "Active":
            return "Session key active"
        case "Pending install":
            return "Session key pending"
        case "Inactive":
            return "Session key locked"
        case "Duration expired", "Expired":
            return "Session key expired"
        case "Stored":
            return "Session key stored"
        default:
            return "Session key off"
        }
    }

    private var sessionPillIcon: String {
        switch model.settingsSnapshot.session.statusTitle {
        case "Active":
            return "bolt.fill"
        case "Pending install":
            return "hourglass"
        case "Inactive", "Duration expired", "Expired":
            return "lock.fill"
        case "Stored":
            return "key.fill"
        default:
            return "touchid"
        }
    }

    private var sessionPillTint: Color {
        switch model.settingsSnapshot.session.statusTitle {
        case "Active":
            return ChatPalette.success
        case "Pending install", "Stored":
            return ChatPalette.warning
        case "Inactive", "Duration expired", "Expired":
            return ChatPalette.warning
        default:
            return ChatPalette.secondaryText
        }
    }

    private func runSessionPopoverAction(_ action: @escaping () async throws -> String) {
        guard !isSessionActionInProgress else {
            return
        }
        isSessionActionInProgress = true
        sessionPopoverMessage = nil
        Task { @MainActor in
            do {
                sessionPopoverMessage = try await action()
            } catch {
                sessionPopoverMessage = error.localizedDescription
            }
            isSessionActionInProgress = false
        }
    }

    private var footerControls: some View {
        HStack(spacing: 8) {
            StatusPill(icon: "circle.fill", text: "Gemma 4 E4B", tint: ChatPalette.success)
            Button {
                model.toggleThinking()
            } label: {
                StatusPill(icon: model.thinkingEnabled ? "brain" : "brain.head.profile", text: model.thinkingEnabled ? "Thinking on" : "Thinking off")
            }
            .buttonStyle(.plain)
            StatusPill(
                icon: model.hasExecutingIntent ? "arrow.triangle.2.circlepath" : "slider.horizontal.3",
                text: model.executionStatusText,
                tint: model.hasExecutingIntent ? ChatPalette.accent : ChatPalette.secondaryText
            )
            Button {
                isSessionPopoverPresented.toggle()
                sessionPopoverMessage = nil
            } label: {
                StatusPill(
                    icon: sessionPillIcon,
                    text: sessionPillText,
                    tint: sessionPillTint
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isSessionPopoverPresented, arrowEdge: .top) {
                SessionStatusPopover(
                    snapshot: model.settingsSnapshot.session,
                    isWorking: isSessionActionInProgress,
                    message: sessionPopoverMessage,
                    onEnable: {
                        runSessionPopoverAction {
                            try await model.enableSessionKeysFromSettings()
                        }
                    },
                    onRevoke: {
                        runSessionPopoverAction {
                            try await model.revokeSessionKeysFromSettings()
                        }
                    },
                    onOpenSettings: {
                        settingsInitialTab = .sessionKeys
                        selectedSection = .settings
                        isSessionPopoverPresented = false
                    }
                )
            }
            .help("Assistant session key status")
            Button {
                isGasPopoverPresented.toggle()
                model.refreshGasPricesNow()
            } label: {
                StatusPill(icon: "fuelpump.fill", text: model.gasPillText, tint: ChatPalette.secondaryText)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isGasPopoverPresented, arrowEdge: .top) {
                GasBreakdownPopover(display: model.gasBreakdown)
            }
            .help("Current network gas price")
            Button {
                isToolsPopoverPresented.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slash.circle.fill")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(ChatPalette.accent)
                    Text("Tools")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ChatPalette.secondaryText)
                }
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(Capsule().fill(ChatPalette.panel).overlay(Capsule().stroke(ChatPalette.border, lineWidth: 0.8)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isToolsPopoverPresented, arrowEdge: .top) {
                SlashCommandPalette { command in
                    model.insertSlashCommand(command)
                    isToolsPopoverPresented = false
                }
                .frame(width: 420)
            }
            .help("Browse slash commands")
            Spacer()
            Text(model.contextStatsText)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ChatPalette.mutedText)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 8)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !model.slashSuggestions.isEmpty {
                SlashSuggestionPanel(commands: model.slashSuggestions) { command in
                    model.insertSlashCommand(command)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            composerInputBox
        }
        .animation(.easeOut(duration: 0.12), value: model.slashSuggestions)
    }

    private var composerInputBox: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                PromptTextEditor(text: $model.inputText) {
                    model.send()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .disabled(model.isGenerating)
                    .frame(minHeight: 78, maxHeight: 96)
                if model.inputText.isEmpty {
                    Text("Message Gemma — describe what you want, or type / for tools")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(ChatPalette.mutedText)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Text("↩ to send · ⌘K to focus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ChatPalette.mutedText)
                Button {
                    model.send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .black))
                        .frame(width: 42, height: 42)
                        .foregroundStyle(model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isGenerating ? ChatPalette.mutedText : .white)
                        .background(Circle().fill(ChatPalette.accent.opacity(model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isGenerating ? 0.35 : 0.95)))
                }
                .buttonStyle(.plain)
                .disabled(model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isGenerating)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(ChatPalette.input)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(ChatPalette.accent.opacity(0.78), lineWidth: 1.4)
                )
        )
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:
            return "Good morning"
        case 12..<18:
            return "Good afternoon"
        default:
            return "Good evening"
        }
    }
}

private struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 16, weight: .medium)
        textView.textColor = NSColor(ChatPalette.primaryText)
        textView.insertionPointColor = NSColor(ChatPalette.primaryText)
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        context.coordinator.attach(textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit

        if textView.string != text {
            textView.string = text
        }

        textView.isEditable = isEnabled
        textView.textColor = NSColor(ChatPalette.primaryText)
        textView.font = .systemFont(ofSize: 16, weight: .medium)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        private weak var textView: NSTextView?

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleFocusRequest),
                name: .chatComposerFocusRequested,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attach(textView: NSTextView) {
            self.textView = textView
        }

        @objc private func handleFocusRequest() {
            textView?.window?.makeFirstResponder(textView)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            text.wrappedValue = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }

            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                return false
            }

            onSubmit()
            return true
        }
    }
}

private struct ChatConversationRow: View {
    let conversation: ChatConversation
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void
    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var editingTitle = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: { if !isRenaming { onSelect() } }) {
                rowContent
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isSelected ? ChatPalette.selectedPanel : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(isSelected ? ChatPalette.accent.opacity(0.65) : ChatPalette.border.opacity(0.45), lineWidth: 1)
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { startRenaming() }
            )
            .contextMenu {
                Button {
                    startRenaming()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete chat", systemImage: "trash")
                }
            }

            if isHovered, !isRenaming {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(ChatPalette.secondaryText)
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(ChatPalette.buttonCircle)
                                .overlay(Circle().stroke(ChatPalette.border, lineWidth: 0.8))
                        )
                }
                .buttonStyle(.plain)
                .help("Delete chat")
                .padding(6)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isRenaming {
                TextField("Conversation title", text: $editingTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ChatPalette.primaryText)
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelRename() }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused && isRenaming {
                            commitRename()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(conversation.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ChatPalette.primaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                Text("\(conversation.messages.count) messages")
                Text("·")
                Text(conversation.updatedAt, style: .relative)
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(ChatPalette.mutedText)
        }
    }

    private func startRenaming() {
        editingTitle = conversation.title
        isRenaming = true
        DispatchQueue.main.async {
            renameFocused = true
        }
    }

    private func commitRename() {
        let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        isRenaming = false
        guard !trimmed.isEmpty, trimmed != conversation.title else {
            return
        }
        onRename(trimmed)
    }

    private func cancelRename() {
        isRenaming = false
    }
}

private struct ChainStatusStrip: View {
    let identity: ChatAccountIdentity
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: identity.isTestnet ? "testtube.2" : "network")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(identity.isTestnet ? ChatPalette.warning : ChatPalette.success)
                Text(identity.chainName)
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(ChatPalette.primaryText)
                Text("Chain \(identity.chainID)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(ChatPalette.secondaryText)
                Text(identity.isTestnet ? "Testnet" : "Mainnet")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(identity.isTestnet ? ChatPalette.warning : ChatPalette.success)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill((identity.isTestnet ? ChatPalette.warning : ChatPalette.success).opacity(0.12)))

                Spacer(minLength: 0)

                Text(isExpanded ? "Hide accounts" : "Show accounts")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(ChatPalette.mutedText)

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(ChatPalette.secondaryText)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(ChatPalette.buttonCircle.opacity(0.85)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide account details" : "Show account details")
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ChatPalette.panel.opacity(0.75))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ChatPalette.border.opacity(0.75), lineWidth: 1))
        )
    }

}

private struct AddressPill: View {
    let icon: String
    let title: String
    let address: String
    let balance: String
    let state: String
    let tokenBalances: [ChatTokenBalance]
    let isRefreshingTokenBalances: Bool
    let onRefreshTokenBalances: () -> Void
    let explorerURL: URL?
    @State private var copied = false
    @State private var isTokenListPresented = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(ChatPalette.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(ChatPalette.buttonCircle))

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(ChatPalette.mutedText)
                    .textCase(.uppercase)
                Text(shortAddress(address))
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .foregroundStyle(ChatPalette.primaryText)
                    .lineLimit(1)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(balance)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ChatPalette.secondaryText)
                        .lineLimit(1)
                    Text(state)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(state.lowercased().contains("ready") || state.lowercased().contains("deployed") ? ChatPalette.success : ChatPalette.mutedText)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Capsule().fill(ChatPalette.buttonCircle.opacity(0.75)))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button {
                    if tokenBalances.isEmpty {
                        onRefreshTokenBalances()
                    }
                    isTokenListPresented.toggle()
                } label: {
                    Group {
                        if isRefreshingTokenBalances {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "list.bullet.rectangle.portrait")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(ChatPalette.secondaryText)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(ChatPalette.buttonCircle))
                }
                .buttonStyle(.plain)
                .disabled(!address.hasPrefix("0x"))
                .help("Show token balances")
                .popover(isPresented: $isTokenListPresented, arrowEdge: .bottom) {
                    TokenBalancePopover(
                        title: title,
                        address: address,
                        balances: tokenBalances,
                        isRefreshing: isRefreshingTokenBalances,
                        onRefresh: onRefreshTokenBalances
                    )
                }

                Button {
                    copy(address)
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(copied ? ChatPalette.success : ChatPalette.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(ChatPalette.buttonCircle))
                }
                .buttonStyle(.plain)
                .disabled(!address.hasPrefix("0x"))
                .help(copied ? "Copied" : "Copy address")

                if let explorerURL {
                    Link(destination: explorerURL) {
                        Image(systemName: "safari")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(ChatPalette.secondaryText)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(ChatPalette.buttonCircle))
                    }
                    .buttonStyle(.plain)
                    .help("Open in explorer")
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 78)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(ChatPalette.panel)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ChatPalette.border, lineWidth: 1))
        )
    }

    private func shortAddress(_ value: String) -> String {
        guard value.hasPrefix("0x"), value.count > 18 else {
            return value
        }

        let prefix = value.prefix(10)
        let suffix = value.suffix(8)
        return "\(prefix)...\(suffix)"
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation(.easeInOut(duration: 0.12)) {
            copied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            copied = false
        }
    }
}

/// Account card for a gas-paying helper EOA — in practice the bundler, the only one the wallet
/// has. Unlike `AddressPill`, it leads with the gas balance and a **Fund** action — the raw
/// address is demoted to a copy button (the external-funding fallback the bundler needs when
/// empty). "Send" moves ETH from the Kernel account as a passkey UserOp; see `fundHelper`.
///
/// When `gasWarning` says the bundler is under the daemon's threshold, the Fund control is
/// replaced by the only route that can work — its address, a Copy button and (on testnets) a
/// faucet link — because the empty bundler would have to relay its own top-up. `gasWarning`
/// stays optional so a future helper without that self-funding trap can reuse the card.
private struct FundableAccountCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let address: String
    let balance: String
    let state: String
    let isFunding: Bool
    let fundError: String?
    let tokenBalances: [ChatTokenBalance]
    let isRefreshingTokenBalances: Bool
    let onRefreshTokenBalances: () -> Void
    let explorerURL: URL?
    var gasWarning: BundlerGasStatus?
    let onFund: (String) -> Void

    @State private var fundAmount = "0.02"
    @State private var copied = false
    @State private var isTokenListPresented = false

    private var hasAddress: Bool { address.hasPrefix("0x") && address.count == 42 }
    /// Out of gas by the daemon's own threshold — the in-app Fund control cannot work.
    private var isOutOfGas: Bool { gasWarning?.needsGas == true }
    private var needsFunding: Bool {
        if isOutOfGas {
            return true
        }
        let s = state.lowercased()
        return s.contains("need") || s.contains("top")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(isOutOfGas ? ChatPalette.warning : ChatPalette.accent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(ChatPalette.buttonCircle))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(ChatPalette.mutedText)
                        .textCase(.uppercase)
                        .lineLimit(1)
                    Text(balance)
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(isOutOfGas ? ChatPalette.warning : ChatPalette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }

                Spacer(minLength: 4)

                trailingIcons
            }

            stateBadge

            if let gasWarning, isOutOfGas {
                externalFundingControl(gasWarning)
            } else {
                fundControl
            }

            if let fundError {
                Text(fundError)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(ChatPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isOutOfGas == false {
                Text("Send from your Kernel account (passkey), or copy the address to fund externally.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(ChatPalette.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(ChatPalette.panel)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ChatPalette.border, lineWidth: 1))
        )
    }

    private var trailingIcons: some View {
        HStack(spacing: 5) {
            // Out of gas, the external-funding block below carries a full Copy button; a
            // second copy icon up here would just be the same action twice.
            if isOutOfGas == false {
                iconButton(systemName: copied ? "checkmark" : "doc.on.doc",
                           tint: copied ? ChatPalette.success : ChatPalette.secondaryText,
                           help: copied ? "Copied" : "Copy address to fund externally",
                           disabled: !hasAddress) {
                    copy(address)
                }
            }
            if tokenBalances.isEmpty == false || isRefreshingTokenBalances {
                tokenListButton
            }
            if let explorerURL {
                Link(destination: explorerURL) {
                    iconLabel(systemName: "safari", tint: ChatPalette.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Open in explorer")
            }
        }
    }

    private var stateBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(needsFunding ? ChatPalette.warning : ChatPalette.success)
                .frame(width: 6, height: 6)
            Text(state)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(needsFunding ? ChatPalette.warning : ChatPalette.success)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 20)
        .background(
            Capsule().fill((needsFunding ? ChatPalette.warning : ChatPalette.success).opacity(0.14))
        )
        .overlay(
            Capsule().stroke((needsFunding ? ChatPalette.warning : ChatPalette.success).opacity(0.35), lineWidth: 1)
        )
    }

    /// Shown instead of `fundControl` while the bundler is under the daemon's threshold: the
    /// reason it can't be funded from inside the app, then the address and a faucet link.
    private func externalFundingControl(_ gas: BundlerGasStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(ChatPalette.warning)
                Text(gas.cardDetail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ChatPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ChatPalette.warning.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(ChatPalette.warning.opacity(0.30), lineWidth: 1)
                    )
            )

            HStack(spacing: 8) {
                Text(hasAddress ? address : "Address not available yet")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ChatPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button {
                    copy(address)
                } label: {
                    Text(copied ? "Copied" : "Copy")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(hasAddress ? Color.black.opacity(0.85) : ChatPalette.mutedText)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(hasAddress ? ChatPalette.warning : ChatPalette.buttonCircle)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!hasAddress)
                .help("Copy the bundler address to fund it from another wallet")
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(ChatPalette.input)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(ChatPalette.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    )
            )

            if let faucetURL = gas.faucetURL {
                Link(destination: faucetURL) {
                    Text("Open \(gas.networkLabel) faucet")
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundStyle(ChatPalette.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var fundControl: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Text("Fund")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ChatPalette.mutedText)
                TextField("0.02", text: $fundAmount)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .foregroundStyle(ChatPalette.primaryText)
                    .frame(maxWidth: .infinity)
                    .disabled(isFunding)
                Text("ETH")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ChatPalette.mutedText)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(ChatPalette.input)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(ChatPalette.border, lineWidth: 1))
            )

            Button {
                onFund(fundAmount)
            } label: {
                HStack(spacing: 5) {
                    if isFunding {
                        ProgressView().controlSize(.small)
                    }
                    Text(isFunding ? "Sending" : "Send")
                        .font(.system(size: 12, weight: .heavy))
                    if !isFunding {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .black))
                    }
                }
                .foregroundStyle(hasAddress ? Color.white : ChatPalette.mutedText)
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(hasAddress ? ChatPalette.accent : ChatPalette.buttonCircle)
                )
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(!hasAddress || isFunding)
            .help(hasAddress ? "Send ETH from your Kernel account for gas" : "Address not available yet")
        }
    }

    private var tokenListButton: some View {
        Button {
            if tokenBalances.isEmpty { onRefreshTokenBalances() }
            isTokenListPresented.toggle()
        } label: {
            if isRefreshingTokenBalances {
                ProgressView().controlSize(.small).frame(width: 26, height: 26)
                    .background(Circle().fill(ChatPalette.buttonCircle))
            } else {
                iconLabel(systemName: "list.bullet.rectangle.portrait", tint: ChatPalette.secondaryText)
            }
        }
        .buttonStyle(.plain)
        .disabled(!hasAddress)
        .help("Show token balances")
        .popover(isPresented: $isTokenListPresented, arrowEdge: .bottom) {
            TokenBalancePopover(
                title: title,
                address: address,
                balances: tokenBalances,
                isRefreshing: isRefreshingTokenBalances,
                onRefresh: onRefreshTokenBalances
            )
        }
    }

    private func iconButton(
        systemName: String,
        tint: Color,
        help: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            iconLabel(systemName: systemName, tint: tint)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    private func iconLabel(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .black))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(Circle().fill(ChatPalette.buttonCircle))
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation(.easeInOut(duration: 0.12)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { copied = false }
    }
}

private struct TokenBalancePopover: View {
    let title: String
    let address: String
    let balances: [ChatTokenBalance]
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(ChatPalette.primaryText)
                    Text(shortAddress(address))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(ChatPalette.secondaryText)
                }
                Spacer()
                Button {
                    onRefresh()
                } label: {
                    Group {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(ChatPalette.secondaryText)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(ChatPalette.buttonCircle))
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
            }

            Divider()
                .overlay(ChatPalette.border)

            if balances.isEmpty {
                HStack(spacing: 8) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isRefreshing ? "Loading balances" : "No balances loaded")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ChatPalette.secondaryText)
                    Spacer()
                }
                .frame(height: 32)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(balances) { balance in
                            TokenBalanceRow(balance: balance)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(14)
        .frame(width: 330)
        .background(ChatPalette.panel)
    }

    private func shortAddress(_ value: String) -> String {
        guard value.hasPrefix("0x"), value.count > 18 else {
            return value
        }
        return "\(value.prefix(10))...\(value.suffix(8))"
    }
}

private struct TokenBalanceRow: View {
    let balance: ChatTokenBalance

    var body: some View {
        HStack(spacing: 10) {
            Text(String(balance.token.symbol.prefix(1)))
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(ChatPalette.primaryText)
                .frame(width: 28, height: 28)
                .background(Circle().fill(ChatPalette.buttonCircle))

            VStack(alignment: .leading, spacing: 2) {
                Text(balance.token.symbol)
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(ChatPalette.primaryText)
                Text(balance.token.name)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ChatPalette.mutedText)
                    .lineLimit(1)
            }

            Spacer()

            Text(balance.displayBalance)
                .font(.system(size: 12, weight: .bold, design: balance.rawBalanceHex == nil ? .default : .monospaced))
                .foregroundStyle(balance.rawBalanceHex == nil ? ChatPalette.warning : ChatPalette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 9)
        .frame(height: 42)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(ChatPalette.buttonCircle.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(ChatPalette.border.opacity(0.5), lineWidth: 1))
        )
    }
}

private struct DashboardSectionButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(isSelected ? ChatPalette.primaryText : ChatPalette.secondaryText)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(Capsule().fill(isSelected ? ChatPalette.selectedPanel : Color.clear))
        }
        .buttonStyle(.plain)
    }
}

private struct HistoryStatusSummary: View {
    let records: [WalletTransactionRecord]
    let selection: WalletHistoryFilter
    let onSelect: (WalletHistoryFilter) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(WalletHistoryFilter.allCases) { filter in
                Button {
                    onSelect(filter)
                } label: {
                    summaryPill(filter)
                }
                .buttonStyle(.plain)
                .help("Show \(filter.rawValue.lowercased()) records")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func summaryPill(_ filter: WalletHistoryFilter) -> some View {
        let isSelected = selection == filter
        return HStack(spacing: 6) {
            Circle()
                .fill(filter.tint)
                .frame(width: 7, height: 7)
            Text("\(filter.count(in: records))")
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundStyle(ChatPalette.primaryText)
                .frame(minWidth: 12, alignment: .trailing)
            Text(filter.rawValue)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isSelected ? ChatPalette.primaryText : ChatPalette.secondaryText)
                .lineLimit(1)
        }
        .frame(width: 94, height: 30)
        .background(
            Capsule()
                .fill(isSelected ? ChatPalette.selectedPanel : ChatPalette.panel)
                .overlay(Capsule().stroke(isSelected ? filter.tint.opacity(0.8) : ChatPalette.border, lineWidth: 1))
        )
    }
}

private struct WalletHistoryEmptyState: View {
    var title = "No wallet history yet"
    var message = "Transfers, swaps, and future batches submitted from this app will appear here."

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(ChatPalette.secondaryText)
                .frame(width: 84, height: 84)
                .background(Circle().fill(ChatPalette.avatar))
            Text(title)
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(ChatPalette.primaryText)
            Text(message)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ChatPalette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
    }
}

private struct WalletHistoryListView: View {
    let records: [WalletTransactionRecord]
    let selectedRecord: WalletTransactionRecord?
    let onSelect: (WalletTransactionRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transactions")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(ChatPalette.mutedText)
                    .textCase(.uppercase)
                Spacer()
                Text("\(records.count)")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(ChatPalette.secondaryText)
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(records) { record in
                        WalletHistoryRow(
                            record: record,
                            isSelected: selectedRecord?.id == record.id,
                            onSelect: { onSelect(record) }
                        )
                    }
                }
                .padding(2)
            }
        }
    }
}

private struct WalletHistoryRow: View {
    let record: WalletTransactionRecord
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: record.operationIcon)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(record.statusTint)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(record.statusTint.opacity(0.14)))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(record.title)
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(ChatPalette.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(record.statusTitle)
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(record.statusTint)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(Capsule().fill(record.statusTint.opacity(0.14)))
                    }
                    Text(record.subtitle)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ChatPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(record.updatedAt, style: .relative)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(ChatPalette.mutedText)
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(isSelected ? ChatPalette.secondaryText : ChatPalette.mutedText.opacity(0.7))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? ChatPalette.selectedPanel : ChatPalette.panel.opacity(0.74))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isSelected ? ChatPalette.accent.opacity(0.7) : ChatPalette.border.opacity(0.55), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct WalletHistoryDetailView: View {
    let record: WalletTransactionRecord
    var showsBackButton = false
    var onBack: (() -> Void)? = nil
    @State private var copiedValue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                if showsBackButton {
                    Button {
                        onBack?()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(ChatPalette.secondaryText)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(ChatPalette.buttonCircle))
                    }
                    .buttonStyle(.plain)
                    .help("Back to transactions")
                }
                Image(systemName: record.statusIcon)
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(record.statusTint)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(record.statusTint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.title)
                        .font(.system(size: 21, weight: .heavy))
                        .foregroundStyle(ChatPalette.primaryText)
                        .lineLimit(1)
                    Text(record.statusExplanation)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(ChatPalette.secondaryText)
                        .lineLimit(2)
                }
                Spacer()
                Text(record.chainName)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(ChatPalette.secondaryText)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Capsule().fill(ChatPalette.buttonCircle))
            }

            ScrollView {
                VStack(spacing: 8) {
                    WalletHistoryFieldRow(title: "Status", value: record.statusTitle, copiedValue: $copiedValue, monospaced: false)
                    WalletHistoryFieldRow(title: "Operation", value: record.operation.rawValue.capitalized, copiedValue: $copiedValue, monospaced: false)
                    if let amountLabel = record.amountLabel {
                        WalletHistoryFieldRow(title: "Amount", value: amountLabel, copiedValue: $copiedValue, monospaced: false)
                    }
                    if let amountOut = record.amountOut {
                        WalletHistoryFieldRow(title: "Estimated out", value: amountOut, copiedValue: $copiedValue, monospaced: false)
                    }
                    if let minimumReceived = record.minimumReceived {
                        WalletHistoryFieldRow(title: "Minimum out", value: minimumReceived, copiedValue: $copiedValue, monospaced: false)
                    }
                    if let route = record.route {
                        WalletHistoryFieldRow(title: "Route", value: route, copiedValue: $copiedValue, monospaced: false)
                    }
                    if let counterparty = record.counterparty {
                        WalletHistoryFieldRow(
                            title: record.operation == .swap ? "Router" : "Recipient",
                            value: record.counterpartyName ?? counterparty,
                            copiedValue: $copiedValue,
                            monospaced: record.counterpartyName == nil
                        )
                        if record.counterpartyName != nil {
                            WalletHistoryFieldRow(title: "Address", value: counterparty, copiedValue: $copiedValue)
                        }
                    }
                    WalletHistoryFieldRow(title: "UserOperation", value: record.userOpHash, copiedValue: $copiedValue)
                    if let signingModeTitle = record.signingModeTitle {
                        WalletHistoryFieldRow(title: "Signed by", value: signingModeTitle, copiedValue: $copiedValue, monospaced: false)
                    }
                    if let transactionHash = record.transactionHash {
                        WalletHistoryFieldRow(
                            title: "Transaction",
                            value: transactionHash,
                            copiedValue: $copiedValue,
                            explorerURL: record.transactionExplorerURL
                        )
                    } else {
                        WalletHistoryFieldRow(title: "Transaction", value: record.pendingTransactionStatusText, copiedValue: $copiedValue, monospaced: false)
                    }
                    if let actualGasUsed = record.actualGasUsed {
                        WalletHistoryFieldRow(title: "Gas used", value: actualGasUsed, copiedValue: $copiedValue)
                    }
                    if let actualGasCost = record.actualGasCost {
                        WalletHistoryFieldRow(title: "Gas cost", value: actualGasCost, copiedValue: $copiedValue)
                    }
                    if let revertReason = record.revertReason, !revertReason.isEmpty {
                        WalletHistoryFieldRow(title: "Revert reason", value: revertReason, copiedValue: $copiedValue, monospaced: false)
                    }
                }
            }

            Spacer()

            HStack {
                Label("Created \(record.createdAt, style: .date) \(record.createdAt, style: .time)", systemImage: "calendar")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ChatPalette.mutedText)
                Spacer()
                Label("Updated \(record.updatedAt, style: .relative)", systemImage: "clock")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ChatPalette.mutedText)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(ChatPalette.panel)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ChatPalette.border, lineWidth: 1))
        )
    }
}

private struct WalletHistoryFieldRow: View {
    let title: String
    let value: String
    @Binding var copiedValue: String?
    var explorerURL: URL? = nil
    var monospaced = true

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(ChatPalette.mutedText)
                .frame(width: 116, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: monospaced ? .monospaced : .default))
                .foregroundStyle(ChatPalette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copiedValue = value
            } label: {
                Image(systemName: copiedValue == value ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(copiedValue == value ? ChatPalette.success : ChatPalette.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(ChatPalette.buttonCircle))
            }
            .buttonStyle(.plain)
            .help(copiedValue == value ? "Copied" : "Copy")

            if let explorerURL {
                Link(destination: explorerURL) {
                    Image(systemName: "safari")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(ChatPalette.secondaryText)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(ChatPalette.buttonCircle))
                }
                .buttonStyle(.plain)
                .help("Open in explorer")
            }
        }
        .frame(height: 31)
    }
}

private extension WalletTransactionRecord {
    var title: String {
        switch operation {
        case .transfer:
            return "Transfer"
        case .swap:
            return "Swap"
        case .approval:
            return "Approval"
        case .batch:
            return "Batch"
        case .deploy:
            return "Deploy account"
        case .shield:
            return "Shield"
        case .unshield:
            return "Unshield"
        case .unknown:
            return "Transaction"
        }
    }

    var pendingTransactionStatusText: String {
        switch status {
        case .created:
            return "Prepared locally"
        case .submitted:
            return "Waiting for receipt"
        case .pending:
            return "No transaction hash yet"
        case .looksIncluded:
            return "Looks included; verifying"
        case .included:
            return "Receipt missing"
        case .reverted:
            return "Reverted before receipt"
        case .failed:
            return "Submission failed"
        case .cancelled:
            return "Cancelled"
        case .dropped:
            return "Dropped"
        case .unknown:
            return "Status unknown"
        }
    }

    var subtitle: String {
        if let amountLabel {
            return amountLabel
        }
        if let counterpartyName {
            return counterpartyName
        }
        if let counterparty {
            return counterparty.walletDisplayShortAddress
        }
        return userOpHash.walletDisplayShortAddress
    }

    var amountLabel: String? {
        guard let amount, !amount.isEmpty else {
            return token
        }
        guard let token, !token.isEmpty else {
            return amount
        }
        if token.contains("->") {
            return "\(amount) · \(token)"
        }
        if amount.localizedCaseInsensitiveContains(token) {
            return amount
        }
        return "\(amount) \(token)"
    }

    var operationIcon: String {
        switch operation {
        case .transfer:
            return "arrow.up.right"
        case .swap:
            return "arrow.triangle.swap"
        case .approval:
            return "checkmark.seal.fill"
        case .batch:
            return "square.stack.3d.up.fill"
        case .deploy:
            return "shippingbox.fill"
        case .shield:
            return "lock.shield.fill"
        case .unshield:
            return "lock.open.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    var statusIcon: String {
        switch status {
        case .included:
            return "checkmark.circle.fill"
        case .reverted:
            return "xmark.octagon.fill"
        case .failed:
            return "exclamationmark.octagon.fill"
        case .created:
            return "circle.dotted"
        case .submitted:
            return "paperplane.circle.fill"
        case .pending:
            return "clock.fill"
        case .looksIncluded:
            return "hourglass.circle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        case .cancelled:
            return "xmark.circle.fill"
        case .dropped:
            return "arrow.down.circle.fill"
        }
    }

    var statusTitle: String {
        switch status {
        case .created:
            return "Created"
        case .submitted:
            return "Submitted"
        case .pending:
            return "Pending"
        case .looksIncluded:
            return "Verifying"
        case .included:
            return "Done"
        case .reverted:
            return "Reverted"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        case .dropped:
            return "Dropped"
        case .unknown:
            return "Unknown"
        }
    }

    var signingModeTitle: String? {
        switch signingModeFromDetailsJSON(detailsJSON) {
        case "session":
            return "Session key"
        case "passkey":
            return "Passkey"
        default:
            return nil
        }
    }

    var statusExplanation: String {
        switch status {
        case .included:
            return "Receipt found and execution succeeded."
        case .reverted:
            return "Receipt found, but execution reverted on-chain."
        case .failed:
            return "The app recorded a failed local submission."
        case .created:
            return "Created locally, not submitted yet."
        case .submitted:
            return "wallet-node accepted the UserOperation; receipt is not confirmed yet."
        case .pending:
            return "Receipt is still unavailable. This is not marked done."
        case .looksIncluded:
            return "A tentative receipt was found; wallet-node is still verifying it."
        case .cancelled:
            return "The operation was cancelled before a UserOperation receipt appeared."
        case .dropped:
            return "wallet-node marked the operation dropped after it left the pending path."
        case .unknown:
            return "The app cannot currently reconcile this record."
        }
    }

    private func detailsField(_ key: String) -> String? {
        guard let detailsJSON,
              let data = detailsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key]
        else {
            return nil
        }
        return "\(value)"
    }

    var statusTint: Color {
        switch status {
        case .included:
            return ChatPalette.success
        case .reverted, .failed, .cancelled, .dropped:
            return ChatPalette.warning
        case .created, .submitted, .pending, .looksIncluded, .unknown:
            return ChatPalette.accent
        }
    }

    var transactionExplorerURL: URL? {
        guard let transactionHash, transactionHash.hasPrefix("0x") else {
            return nil
        }
        let host = chainID == 11_155_111 ? "https://sepolia.etherscan.io" : "https://etherscan.io"
        return URL(string: "\(host)/tx/\(transactionHash)")
    }
}

private struct OnchainTransactionCard: View {
    let summary: OnchainTransactionSummary
    var replacementBlocked = false
    var replacementBlockedReason: String? = nil
    var replacementActionState: ReplacementActionState? = nil
    var onOpenHistory: ((String) -> Void)? = nil
    var onSpeedUp: ((String) -> Void)? = nil
    var onCancel: ((String) -> Void)? = nil
    @State private var copiedValue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: summary.status.icon)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(statusTint)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(statusTint.opacity(0.14)))

                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(ChatPalette.primaryText)
                    Text(subtitle)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(ChatPalette.secondaryText)
                }

                Spacer()

                Text("Chain \(summary.chainID)")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(ChatPalette.secondaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(ChatPalette.buttonCircle))
            }

            VStack(spacing: 8) {
                if isSwap {
                    if let amountOut = summary.amountOut {
                        TransactionHashRow(
                            title: "Estimated out",
                            value: amountOut,
                            copiedValue: $copiedValue,
                            usesMonospacedValue: false
                        )
                    }
                    if let minimumReceived = summary.minimumReceived {
                        TransactionHashRow(
                            title: "Minimum out",
                            value: minimumReceived,
                            copiedValue: $copiedValue,
                            usesMonospacedValue: false
                        )
                    }
                    if let route = summary.route {
                        TransactionHashRow(
                            title: "Route",
                            value: route,
                            copiedValue: $copiedValue,
                            usesMonospacedValue: false
                        )
                    }
                    TransactionHashRow(
                        title: "Router",
                        value: summary.recipientName ?? "Uniswap SwapRouter02",
                        copiedValue: $copiedValue,
                        usesMonospacedValue: false
                    )
                    TransactionHashRow(
                        title: "Router address",
                        value: summary.recipient,
                        copiedValue: $copiedValue
                    )
                } else {
                    if let recipientName = summary.recipientName {
                        TransactionHashRow(
                            title: "ENS name",
                            value: recipientName,
                            copiedValue: $copiedValue
                        )
                    }
                    TransactionHashRow(
                        title: summary.recipientName == nil ? "Recipient" : "Resolved to",
                        value: summary.recipient,
                        copiedValue: $copiedValue
                    )
                    if let resolutionChainName = summary.resolutionChainName {
                        HStack {
                            Text("Resolved on")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(ChatPalette.mutedText)
                                .frame(width: 116, alignment: .leading)
                            Text(summary.ccipReadUsed == true ? "\(resolutionChainName) · CCIP Read" : resolutionChainName)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ChatPalette.secondaryText)
                            Spacer()
                        }
                        .frame(height: 30)
                    }
                }
                TransactionHashRow(
                    title: "UserOperation",
                    value: summary.userOpHash,
                    copiedValue: $copiedValue
                )
                if let signingModeTitle {
                    HStack {
                        Text("Signed by")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(ChatPalette.mutedText)
                            .frame(width: 108, alignment: .leading)
                        Label(signingModeTitle, systemImage: signingModeIcon)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(signingModeTint)
                        Spacer()
                    }
                    .frame(height: 30)
                }
                if let transactionHash = summary.transactionHash {
                    TransactionHashRow(
                        title: "Transaction",
                        value: transactionHash,
                        copiedValue: $copiedValue,
                        explorerURL: explorerTransactionURL(transactionHash)
                    )
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Transaction")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(ChatPalette.mutedText)
                                .frame(width: 108, alignment: .leading)
                            HStack(spacing: 7) {
                                if summary.status == .submitted {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(pendingTransactionText)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(ChatPalette.secondaryText)
                            }
                            Spacer()
                        }
                        if let detail = pendingTransactionDetail {
                            Text(detail)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(ChatPalette.mutedText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let replacementActionState {
                ReplacementActionStatusPill(state: replacementActionState)
            }

            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ChatPalette.mutedText)
                Text("Recorded \(summary.createdAt, style: .time)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ChatPalette.mutedText)
                Spacer()
                if let transactionHash = summary.transactionHash,
                   let url = explorerTransactionURL(transactionHash) {
                    Link(destination: url) {
                        Label("Open in Etherscan", systemImage: "safari")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(ChatPalette.primaryText)
                            .padding(.horizontal, 11)
                            .frame(height: 30)
                            .background(Capsule().fill(ChatPalette.accent.opacity(0.88)))
                    }
                    .buttonStyle(.plain)
                }
                if let onOpenHistory {
                    Button {
                        onOpenHistory(summary.userOpHash)
                    } label: {
                        Label("View history", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(ChatPalette.primaryText)
                            .padding(.horizontal, 11)
                            .frame(height: 30)
                            .background(Capsule().fill(ChatPalette.buttonCircle))
                    }
                    .buttonStyle(.plain)
                }
                if OnchainTransactionActions.canEscape(status: summary.status, blocked: replacementBlocked) {
                    if let onSpeedUp, !replacementBlocked {
                        Button {
                            onSpeedUp(summary.userOpHash)
                        } label: {
                            Label("Speed up", systemImage: "bolt.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ChatPalette.primaryText)
                                .padding(.horizontal, 11)
                                .frame(height: 30)
                                .background(Capsule().fill(ChatPalette.buttonCircle))
                        }
                        .buttonStyle(.plain)
                        .disabled(replacementActionState != nil)
                        .opacity(replacementActionState == nil ? 1 : 0.55)
                    } else if let reason = OnchainTransactionActions.displayBlockedReason(
                        blocked: replacementBlocked,
                        reason: replacementBlockedReason
                    ) {
                        Text(reason)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ChatPalette.warning)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let onCancel {
                        Button {
                            onCancel(summary.userOpHash)
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ChatPalette.primaryText)
                                .padding(.horizontal, 11)
                                .frame(height: 30)
                                .background(Capsule().fill(ChatPalette.buttonCircle))
                        }
                        .buttonStyle(.plain)
                        .disabled(replacementActionState != nil)
                        .opacity(replacementActionState == nil ? 1 : 0.55)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(ChatPalette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(statusTint.opacity(0.55), lineWidth: 1)
                )
        )
    }

    static func summary(from message: ChatMessage) -> OnchainTransactionSummary? {
        OnchainTransactionSummary.decode(from: message)
    }

    private var isSwap: Bool {
        summary.operation == .swap
    }

    private var signingModeTitle: String? {
        switch summary.signingMode {
        case "session":
            return "Session key"
        case "passkey":
            return "Passkey"
        default:
            return nil
        }
    }

    private var signingModeIcon: String {
        summary.signingMode == "session" ? "bolt.fill" : "touchid"
    }

    private var signingModeTint: Color {
        summary.signingMode == "session" ? ChatPalette.success : ChatPalette.secondaryText
    }

    private var statusTitle: String {
        if summary.status == .pending, summary.transactionHash == nil {
            return isSwap ? "Swap UserOperation pending" : "UserOperation pending"
        }
        guard isSwap else {
            return summary.status.title
        }
        switch summary.status {
        case .included:
            return "Swap included"
        case .submitted:
            return "Swap submitted"
        case .reverted:
            return "Swap reverted"
        case .pending:
            return "Swap pending"
        case .cancelled:
            return "Swap cancelled"
        }
    }

    private var subtitle: String {
        if summary.status == .pending, summary.transactionHash == nil {
            return "\(summary.amount) \(summary.token.uppercased()) accepted by wallet-node. No transaction hash yet."
        }
        if isSwap {
            return "\(summary.amount) \(summary.token.uppercased()) on \(summary.chainName)"
        }
        return "\(summary.amount) \(summary.token.uppercased()) on \(summary.chainName)"
    }

    private var pendingTransactionText: String {
        switch summary.status {
        case .pending:
            return "No transaction hash yet"
        case .submitted:
            return "Waiting for receipt"
        case .reverted:
            return "Reverted before receipt"
        case .included:
            return "Receipt missing"
        case .cancelled:
            return "Cancelled"
        }
    }

    private var pendingTransactionDetail: String? {
        guard summary.status == .pending else {
            return nil
        }
        return "The UserOperation was accepted locally, but no network transaction was found yet. wallet-node may retry, or the first broadcast may have been rejected by the RPC."
    }

    private var statusTint: Color {
        switch summary.status {
        case .included:
            return ChatPalette.success
        case .submitted, .pending:
            return ChatPalette.accent
        case .reverted, .cancelled:
            return ChatPalette.warning
        }
    }

    private func explorerTransactionURL(_ hash: String) -> URL? {
        guard hash.hasPrefix("0x") else {
            return nil
        }
        let host = summary.chainID == 11_155_111 ? "https://sepolia.etherscan.io" : "https://etherscan.io"
        return URL(string: "\(host)/tx/\(hash)")
    }
}

private struct ReplacementActionStatusPill: View {
    let state: ReplacementActionState

    var body: some View {
        HStack(spacing: 7) {
            if state.showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(ChatPalette.accent)
            } else {
                Image(systemName: state.iconName)
                    .font(.system(size: 11, weight: .black))
            }
            Text(state.title)
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(ChatPalette.primaryText)
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(Capsule().fill(ChatPalette.accent.opacity(0.24)))
    }
}

private struct TransactionHashRow: View {
    let title: String
    let value: String
    @Binding var copiedValue: String?
    var explorerURL: URL? = nil
    var usesMonospacedValue = true

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(ChatPalette.mutedText)
                .frame(width: 116, alignment: .leading)
            Text(value)
                .font(valueFont)
                .foregroundStyle(ChatPalette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button {
                copy(value)
            } label: {
                Image(systemName: copiedValue == value ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(copiedValue == value ? ChatPalette.success : ChatPalette.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(ChatPalette.buttonCircle))
            }
            .buttonStyle(.plain)
            .help(copiedValue == value ? "Copied" : "Copy")

            if let explorerURL {
                Link(destination: explorerURL) {
                    Image(systemName: "safari")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(ChatPalette.secondaryText)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(ChatPalette.buttonCircle))
                }
                .buttonStyle(.plain)
                .help("Open in explorer")
            }
        }
        .frame(height: 30)
    }

    private var valueFont: Font {
        usesMonospacedValue
            ? .system(size: 12, weight: .bold, design: .monospaced)
            : .system(size: 12, weight: .bold)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation(.easeInOut(duration: 0.12)) {
            copiedValue = value
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedValue == value {
                copiedValue = nil
            }
        }
    }
}

private extension String {
    var removingHexPrefix: String {
        hasPrefix("0x") ? String(dropFirst(2)) : self
    }

    var walletDisplayShortAddress: String {
        guard hasPrefix("0x"), count > 18 else {
            return self
        }
        return "\(prefix(10))...\(suffix(8))"
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    var canRegenerate: Bool = false
    var onRegenerate: (() -> Void)? = nil
    var canEdit: Bool = false
    var onEdit: ((String) -> Void)? = nil
    @State private var isThinkingExpanded = false
    @State private var isHovered = false
    @State private var justCopied = false
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 90)
            }
            ZStack(alignment: .topTrailing) {
                bubbleContent
                if isHovered, !isEditing {
                    hoverActions
                        .padding(8)
                        .transition(.opacity)
                }
            }
            .contextMenu {
                if !isEditing {
                    Button {
                        copyPlainText()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    if message.stats != nil, message.role == .assistant {
                        Button {
                            copyWithStats()
                        } label: {
                            Label("Copy with stats", systemImage: "doc.on.doc.fill")
                        }
                    }
                    if canEdit, onEdit != nil {
                        Divider()
                        Button {
                            beginEditing()
                        } label: {
                            Label("Edit message", systemImage: "pencil")
                        }
                    }
                    if canRegenerate, let onRegenerate {
                        Divider()
                        Button {
                            onRegenerate()
                        } label: {
                            Label("Regenerate response", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
            if message.role == .assistant {
                Spacer(minLength: 90)
            }
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 6) {
            if canEdit, onEdit != nil {
                bubbleActionButton(systemImage: "pencil", help: "Edit and resend", action: beginEditing)
            }
            if canRegenerate, let onRegenerate {
                bubbleActionButton(systemImage: "arrow.clockwise", help: "Regenerate response", action: onRegenerate)
            }
            copyButton
        }
    }

    private func beginEditing() {
        editText = message.text ?? ""
        isEditing = true
        DispatchQueue.main.async {
            editorFocused = true
        }
    }

    private func submitEdit() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        isEditing = false
        onEdit?(trimmed)
    }

    private func cancelEdit() {
        editText = message.text ?? ""
        isEditing = false
    }

    private func bubbleActionButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(ChatPalette.secondaryText)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(ChatPalette.buttonCircle)
                        .overlay(Circle().stroke(ChatPalette.border, lineWidth: 0.8))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let thinking = message.thinking, message.role == .assistant {
                DisclosureGroup(isExpanded: $isThinkingExpanded) {
                    MarkdownMessageText(markdown: thinking, fontSize: 14, color: ChatPalette.secondaryText)
                        .padding(.top, 6)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "brain")
                            .font(.system(size: 12, weight: .bold))
                        Text("Thinking")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(ChatPalette.secondaryText)
                }
                .tint(ChatPalette.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(ChatPalette.input)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ChatPalette.border, lineWidth: 0.8))
                )
            }

            if message.role == .assistant {
                MarkdownMessageText(markdown: message.text ?? "", fontSize: 16, color: ChatPalette.primaryText)
            } else if isEditing {
                editingView
            } else {
                Text(message.text ?? "")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(ChatPalette.primaryText)
                    .textSelection(.enabled)
            }

            if let stats = message.stats, message.role == .assistant {
                Text(stats.formattedSummary)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ChatPalette.mutedText)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(message.role == .user ? ChatPalette.userBubble : ChatPalette.assistantBubble)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(ChatPalette.border, lineWidth: 1)
                )
        )
    }

    private var editingView: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $editText)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(ChatPalette.primaryText)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .focused($editorFocused)
                .frame(minHeight: 60, maxHeight: 220)
                .onExitCommand {
                    cancelEdit()
                }

            HStack(spacing: 8) {
                Button(action: cancelEdit) {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(ChatPalette.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(ChatPalette.buttonCircle)
                                .overlay(Capsule().stroke(ChatPalette.border, lineWidth: 0.8))
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button(action: submitEdit) {
                    HStack(spacing: 5) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 10, weight: .black))
                        Text("Save & send")
                            .font(.system(size: 12, weight: .heavy))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(ChatPalette.accent.opacity(canSubmitEdit ? 0.95 : 0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmitEdit)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(minWidth: 280, alignment: .trailing)
    }

    private var canSubmitEdit: Bool {
        !editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var copyButton: some View {
        Button(action: copyPlainText) {
            Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(justCopied ? ChatPalette.success : ChatPalette.secondaryText)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(ChatPalette.buttonCircle)
                        .overlay(Circle().stroke(ChatPalette.border, lineWidth: 0.8))
                )
        }
        .buttonStyle(.plain)
        .help(justCopied ? "Copied" : "Copy message")
    }

    private func copyPlainText() {
        ChatClipboard.copy(message.text ?? "")
        flashCopied()
    }

    private func copyWithStats() {
        var pieces: [String] = [message.text ?? ""]
        if let stats = message.stats {
            pieces.append("")
            pieces.append("— \(stats.formattedSummary)")
        }
        ChatClipboard.copy(pieces.joined(separator: "\n"))
        flashCopied()
    }

    private func flashCopied() {
        withAnimation(.easeInOut(duration: 0.12)) {
            justCopied = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                justCopied = false
            }
        }
    }
}

private struct WelcomeStarter: Equatable {
    let icon: String
    let title: String
    let prompt: String
}

private struct WelcomeStarterChip: View {
    let starter: WelcomeStarter
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: starter.icon)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(ChatPalette.accent)
                    Text(starter.title)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(ChatPalette.mutedText)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }
                Text(starter.prompt)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ChatPalette.primaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isHovered ? ChatPalette.selectedPanel.opacity(0.8) : ChatPalette.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isHovered ? ChatPalette.accent.opacity(0.6) : ChatPalette.border, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

private struct SlashSuggestionPanel: View {
    let commands: [SlashCommand]
    let onSelect: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                Button {
                    onSelect(command)
                } label: {
                    HStack(spacing: 10) {
                        Text(command.displayName)
                            .font(.system(size: 13, weight: .heavy, design: .monospaced))
                            .foregroundStyle(ChatPalette.accent)
                            .frame(width: 84, alignment: .leading)
                        Text(command.summary)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ChatPalette.secondaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(command.signature)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(ChatPalette.mutedText)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SlashSuggestionRowStyle())
                if index < commands.count - 1 {
                    Rectangle()
                        .fill(ChatPalette.border.opacity(0.5))
                        .frame(height: 0.5)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(ChatPalette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(ChatPalette.border, lineWidth: 1)
                )
        )
    }
}

private struct SlashSuggestionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? ChatPalette.selectedPanel.opacity(0.8)
                    : Color.clear
            )
    }
}

private struct SlashCommandPalette: View {
    let onSelect: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "slash.circle.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(ChatPalette.accent)
                Text("Slash commands")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(ChatPalette.primaryText)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Text("Click a command to insert a ready-to-edit scaffold into the composer. Replace the placeholders (in <angle brackets>) with your values.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ChatPalette.mutedText)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            Rectangle()
                .fill(ChatPalette.border.opacity(0.4))
                .frame(height: 0.5)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(SlashCatalog.all.enumerated()), id: \.element.id) { index, command in
                    Button {
                        onSelect(command)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(command.displayName)
                                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                                    .foregroundStyle(ChatPalette.accent)
                                Text(command.signature)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(ChatPalette.mutedText)
                                Spacer(minLength: 0)
                            }
                            Text(command.summary)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(ChatPalette.secondaryText)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SlashSuggestionRowStyle())

                    if index < SlashCatalog.all.count - 1 {
                        Rectangle()
                            .fill(ChatPalette.border.opacity(0.4))
                            .frame(height: 0.5)
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }
}

private enum ChatClipboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private struct MarkdownMessageText: View {
    let markdown: String
    let fontSize: CGFloat
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ChatMarkdownParser.segments(in: markdown).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let text):
                    Text(attributed(text))
                        .font(.system(size: fontSize, weight: .medium))
                        .foregroundStyle(color)
                        .textSelection(.enabled)
                case .codeBlock(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
    }

    private func attributed(_ text: String) -> AttributedString {
        do {
            return try AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        } catch {
            return AttributedString(text)
        }
    }
}

private enum ChatMarkdownSegment: Equatable {
    case prose(String)
    case codeBlock(language: String?, code: String)
}

private enum ChatMarkdownParser {
    static func segments(in markdown: String) -> [ChatMarkdownSegment] {
        var segments: [ChatMarkdownSegment] = []
        var prose: [String] = []
        var iterator = markdown.components(separatedBy: "\n").makeIterator()
        while let line = iterator.next() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if !prose.isEmpty {
                    segments.append(.prose(prose.joined(separator: "\n")))
                    prose.removeAll()
                }
                let fence = line.trimmingCharacters(in: .whitespaces)
                let language = String(fence.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                var closed = false
                while let codeLine = iterator.next() {
                    if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        closed = true
                        break
                    }
                    codeLines.append(codeLine)
                }
                let code = codeLines.joined(separator: "\n")
                if closed || !code.isEmpty {
                    segments.append(.codeBlock(language: language.isEmpty ? nil : language, code: code))
                }
            } else {
                prose.append(line)
            }
        }
        if !prose.isEmpty {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                segments.append(.prose(joined))
            }
        }
        return segments
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text((language ?? "code").uppercased())
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(ChatPalette.mutedText)
                    .tracking(0.6)
                Spacer()
                Button {
                    ChatClipboard.copy(code)
                    flashCopied()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .black))
                        Text(justCopied ? "Copied" : "Copy")
                            .font(.system(size: 10, weight: .heavy))
                    }
                    .foregroundStyle(justCopied ? ChatPalette.success : ChatPalette.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(ChatPalette.background.opacity(0.5))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(ChatPalette.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .textSelection(.enabled)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ChatPalette.input)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(ChatPalette.border, lineWidth: 0.8)
                )
        )
    }

    private func flashCopied() {
        withAnimation(.easeInOut(duration: 0.12)) {
            justCopied = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                justCopied = false
            }
        }
    }
}

private extension ChatGenerationStats {
    var formattedSummary: String {
        let seconds = duration.formatted(.number.precision(.fractionLength(1)))
        return "\(seconds)s · \(generatedTokens) generated tokens · context \(usedContextTokens)/\(contextSize) · \(contextTokensLeft) left"
    }
}

private struct AssistantErrorBubble: View {
    let message: ChatMessage
    let canRetry: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Color.orange)
                    Text("Generation failed")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(ChatPalette.primaryText)
                }
                Text(message.text ?? "Unknown error")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ChatPalette.secondaryText)
                    .textSelection(.enabled)
                if canRetry {
                    Button(action: onRetry) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .black))
                            Text("Retry")
                                .font(.system(size: 12, weight: .heavy))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(ChatPalette.accent.opacity(0.9)))
                    }
                    .buttonStyle(.plain)
                    .help("Re-run the last prompt")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.orange.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.orange.opacity(0.45), lineWidth: 1)
                    )
            )
            Spacer(minLength: 90)
        }
    }
}

private struct StreamingAssistantBubble: View {
    let text: String
    let onStop: () -> Void
    @State private var isThinkingExpanded = false

    private var split: GemmaStreamingSplit {
        GemmaChannelFallback.streamingSplit(of: text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if text.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                            .scaleEffect(0.75)
                        Text("Thinking with Gemma 4 E4B…")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(ChatPalette.secondaryText)
                    }
                } else {
                    let parts = split
                    if let reasoning = parts.reasoning {
                        DisclosureGroup(isExpanded: $isThinkingExpanded) {
                            MarkdownMessageText(
                                markdown: reasoning,
                                fontSize: 14,
                                color: ChatPalette.secondaryText
                            )
                            .padding(.top, 6)
                        } label: {
                            HStack(spacing: 8) {
                                if parts.content.isEmpty {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                } else {
                                    Image(systemName: "brain")
                                        .font(.system(size: 12, weight: .bold))
                                }
                                Text(parts.content.isEmpty ? "Thinking…" : "Thinking")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundStyle(ChatPalette.secondaryText)
                        }
                        .tint(ChatPalette.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(ChatPalette.input)
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ChatPalette.border, lineWidth: 0.8))
                        )
                    }
                    if !parts.content.isEmpty {
                        MarkdownMessageText(
                            markdown: parts.content,
                            fontSize: 16,
                            color: ChatPalette.primaryText
                        )
                    }
                }
                HStack {
                    Spacer()
                    Button(action: onStop) {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .black))
                            Text("Stop")
                                .font(.system(size: 11, weight: .heavy))
                        }
                        .foregroundStyle(ChatPalette.primaryText)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(ChatPalette.buttonCircle)
                                .overlay(Capsule().stroke(ChatPalette.border, lineWidth: 0.8))
                        )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Stop generation")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(ChatPalette.assistantBubble)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(ChatPalette.border, lineWidth: 1)
                    )
            )
            Spacer(minLength: 90)
        }
    }
}

private struct ContextUsageBanner: View {
    let level: ContextUsageLevel
    let used: Int
    let total: Int
    let onNewChat: () -> Void

    private var tint: Color {
        switch level {
        case .warning: return Color.yellow
        case .critical: return Color.orange
        }
    }

    private var icon: String {
        switch level {
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    private var title: String {
        switch level {
        case .warning: return "Context running low"
        case .critical: return "Context almost full"
        }
    }

    private var detail: String {
        let percent = Int((Double(used) / Double(max(total, 1))) * 100)
        switch level {
        case .warning:
            return "Used \(used) of \(total) tokens (\(percent)%). A fresh chat keeps responses crisp."
        case .critical:
            return "Used \(used) of \(total) tokens (\(percent)%). Gemma may start truncating earlier turns — start a new chat."
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(ChatPalette.primaryText)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ChatPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: onNewChat) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .black))
                    Text("New chat")
                        .font(.system(size: 12, weight: .heavy))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(tint.opacity(0.85)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(tint.opacity(0.45), lineWidth: 1)
                )
        )
    }
}

private struct StatusPill: View {
    let icon: String
    let text: String
    var tint: Color = ChatPalette.secondaryText

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ChatPalette.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(Capsule().fill(ChatPalette.panel).overlay(Capsule().stroke(ChatPalette.border, lineWidth: 0.8)))
    }
}

private struct SessionStatusPopover: View {
    let snapshot: LocalWalletSessionSettingsSnapshot
    let isWorking: Bool
    let message: String?
    let onEnable: () -> Void
    let onRevoke: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(statusTint)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(statusTint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(ChatPalette.primaryText)
                    Text(sessionKeyDescription)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ChatPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SessionPopoverRow(title: "Max per action", value: Self.ethLabel(wei: snapshot.activePolicy.perTxValueLimitWei))
                SessionPopoverRow(
                    title: "Action pace",
                    value: "\(snapshot.activePolicy.rateLimitCount) / \(Self.friendlyDurationLabel(seconds: snapshot.activePolicy.rateLimitIntervalSec))"
                )
                SessionPopoverRow(title: "Duration", value: Self.friendlyDurationLabel(seconds: snapshot.activePolicy.ttlSeconds))
                SessionPopoverRow(
                    title: "Actions",
                    value: actionScope
                )
                SessionPopoverRow(title: "Token scope", value: "Known ERC-20s")
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ChatPalette.input)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(ChatPalette.border.opacity(0.8), lineWidth: 1)
                    )
            )

            if let message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ChatPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(ChatPalette.selectedPanel.opacity(0.7))
                    )
            }

            HStack(spacing: 10) {
                Button {
                    snapshot.isEnabled ? onRevoke() : onEnable()
                } label: {
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(actionTitle, systemImage: snapshot.isEnabled ? "xmark.circle.fill" : "bolt.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)

                Button("Settings", action: onOpenSettings)
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(ChatPalette.panel)
    }

    private var title: String {
        "Session key \(statusLabel)"
    }

    private var actionTitle: String {
        snapshot.isEnabled ? "End session key" : "Enable session key"
    }

    private var statusLabel: String {
        switch snapshot.statusTitle {
        case "Active":
            return "active"
        case "Pending install":
            return "pending"
        case "Inactive":
            return "locked"
        case "Duration expired", "Expired":
            return "expired"
        case "Stored":
            return "stored"
        default:
            return "off"
        }
    }

    private var sessionKeyDescription: String {
        if snapshot.isExpired {
            return "This session key is no longer active. Enable a new one to sign approved \"Transfer\" and \"Swap\" actions without Touch ID."
        }
        if snapshot.isEnabled, snapshot.record?.installedOnChain == true {
            return "This session key can sign approved \"Transfer\" and \"Swap\" actions without Touch ID while staying inside your wallet limits."
        }
        if snapshot.isEnabled {
            return "The first approved \"Transfer\" or \"Swap\" action will install this session key onchain."
        }
        return "A session key lets the assistant sign approved \"Transfer\" and \"Swap\" actions without Touch ID while staying inside your wallet limits."
    }

    private var statusIcon: String {
        if snapshot.isExpired {
            return "lock.fill"
        }
        if snapshot.isEnabled {
            return snapshot.record?.installedOnChain == true ? "bolt.fill" : "hourglass"
        }
        return snapshot.hasRecord ? "key.fill" : "touchid"
    }

    private var statusTint: Color {
        if snapshot.isEnabled, !snapshot.isExpired, snapshot.record?.installedOnChain == true {
            return ChatPalette.success
        }
        if snapshot.hasRecord || snapshot.isExpired {
            return ChatPalette.warning
        }
        return ChatPalette.secondaryText
    }

    private var actionScope: String {
        var actions: [String] = []
        if snapshot.activePolicy.allowlist.nativeTransfers {
            actions.append("\"Transfer\"")
        }
        if snapshot.activePolicy.allowlist.swapRouter {
            actions.append("\"Swap\"")
        }
        return actions.isEmpty ? "None" : actions.joined(separator: ", ")
    }

    private static func friendlyDurationLabel(seconds: Int) -> String {
        if seconds % 86_400 == 0 {
            let days = seconds / 86_400
            return "\(days) \(days == 1 ? "day" : "days")"
        }
        if seconds % 3_600 == 0 {
            let hours = seconds / 3_600
            return "\(hours) \(hours == 1 ? "hour" : "hours")"
        }
        if seconds % 60 == 0 {
            let minutes = seconds / 60
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        }
        return "\(seconds) seconds"
    }

    private static func ethLabel(wei: String) -> String {
        let trimmed = wei.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let weiValue = Decimal(string: trimmed) else {
            return trimmed.isEmpty ? "Not set" : "\(trimmed) wei"
        }
        let ethValue = weiValue / Decimal(1_000_000_000) / Decimal(1_000_000_000)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        return "\(formatter.string(from: ethValue as NSDecimalNumber) ?? "\(ethValue)") ETH"
    }
}

private struct SessionPopoverRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(ChatPalette.mutedText)
            Spacer(minLength: 16)
            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ChatPalette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private enum ChatPalette {
    static let background = Color(red: 0.045, green: 0.055, blue: 0.115)
    static let sidebar = Color(red: 0.038, green: 0.047, blue: 0.100)
    static let panel = Color(red: 0.063, green: 0.075, blue: 0.135)
    static let selectedPanel = Color(red: 0.095, green: 0.118, blue: 0.215)
    static let input = Color(red: 0.048, green: 0.060, blue: 0.125)
    static let avatar = Color(red: 0.150, green: 0.165, blue: 0.250)
    static let border = Color(red: 0.170, green: 0.205, blue: 0.355)
    static let accent = Color(red: 0.300, green: 0.440, blue: 0.890)
    static let success = Color(red: 0.360, green: 0.900, blue: 0.340)
    static let warning = Color(red: 1.000, green: 0.620, blue: 0.230)
    static let primaryText = Color(red: 1.000, green: 0.990, blue: 0.880)
    static let secondaryText = Color(red: 0.720, green: 0.770, blue: 0.930)
    static let mutedText = Color(red: 0.460, green: 0.520, blue: 0.710)
    static let userBubble = Color(red: 0.115, green: 0.145, blue: 0.260)
    static let assistantBubble = Color(red: 0.070, green: 0.085, blue: 0.150)
    static let buttonCircle = Color(red: 0.115, green: 0.135, blue: 0.230)
}
