import AppKit
import SwiftUI
import WalletToolLayer

struct ChatSigningPreview: Equatable {
    enum Mode: Equatable {
        case session
        case passkey
        case pending
    }

    let mode: Mode
    let title: String
    let detail: String

    var systemImage: String {
        switch mode {
        case .session:
            return "bolt.fill"
        case .passkey:
            return "touchid"
        case .pending:
            return "hourglass"
        }
    }

    var tint: Color {
        switch mode {
        case .session:
            return .green
        case .passkey:
            return .secondary
        case .pending:
            return .secondary
        }
    }
}

struct ToolIntentCardView: View {
    let intent: ToolIntent
    let feedback: ToolIntentFeedback?
    let executionStatus: ChatIntentExecutionStatus
    let transferPreflightStatus: ChatTransferPreflightStatus?
    let swapPreflightStatus: ChatSwapPreflightStatus?
    /// Non-nil when the bundler is out of gas and would refuse to relay this intent. The card
    /// declines before the Secure Enclave prompt instead of letting the daemon reject a
    /// UserOperation the user already signed.
    let bundlerGasStatus: BundlerGasStatus?
    let signingPreview: ChatSigningPreview?
    let onConfirm: () -> Void
    let onReject: () -> Void
    let onEdit: ([String: String]) -> Void
    let onFeedback: (ToolIntentFeedback.Rating, String?) -> Void
    let onSubmitWithGasHeadroom: (UInt64) -> Void

    @State private var showingEditSheet = false
    @State private var showingFeedbackSheet = false
    @State private var feedbackNote = ""
    @State private var copiedBundlerAddress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.tint)
                Text("Intent recognized: \(intent.tool.rawValue)")
                    .font(.headline)
                Spacer()
                Text(intent.source.rawValue)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(intent.args.keys.sorted(), id: \.self) { key in
                    HStack(alignment: .firstTextBaseline) {
                        Text(key)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .leading)
                        Text(intent.args[key] ?? "—")
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.vertical, 4)

            transferPreflightRow

            swapPreflightRow

            bundlerGasRow

            signingPreviewRow

            executionStatusRow

            feedbackControls

            switch intent.disposition {
            case .pending:
                HStack(spacing: 8) {
                    // Edit is disabled alongside confirm while the bundler is out of gas:
                    // "Save & confirm" executes, so leaving it live would just no-op.
                    Button("Edit") { showingEditSheet = true }
                        .buttonStyle(.bordered)
                        .disabled(isExecutionRunning || isBlockedByBundlerGas)
                    Button("Reject", role: .destructive, action: onReject)
                        .buttonStyle(.bordered)
                        .disabled(isExecutionRunning)
                    Spacer()
                    Button(isBlockedByBundlerGas ? "Can't send" : "Looks good", action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .disabled(isExecutionRunning || !canConfirm)
                        .help(isBlockedByBundlerGas
                              ? "\(BundlerGasStatus.warningTitle) — top it up to enable this."
                              : "Sign and submit this intent")
                }
            case .confirmed:
                HStack(spacing: 6) {
                    Image(systemName: confirmedIcon).foregroundStyle(confirmedTint)
                    Text(confirmedText).foregroundStyle(.secondary)
                }
            case .edited:
                HStack(spacing: 6) {
                    Image(systemName: "pencil.circle.fill").foregroundStyle(.orange)
                    Text("Edited & confirmed at \(intent.updatedAt, style: .time)").foregroundStyle(.secondary)
                }
            case .rejected:
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text("Rejected").foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        )
        .sheet(isPresented: $showingEditSheet) {
            ToolIntentEditSheet(intent: intent) { editedArgs in
                onEdit(editedArgs)
                showingEditSheet = false
            } onCancel: {
                showingEditSheet = false
            }
        }
        .sheet(isPresented: $showingFeedbackSheet) {
            ToolIntentFeedbackSheet(
                note: $feedbackNote,
                onSave: {
                    onFeedback(.thumbsDown, feedbackNote)
                    showingFeedbackSheet = false
                },
                onCancel: {
                    showingFeedbackSheet = false
                }
            )
        }
    }

    private var isExecutionRunning: Bool {
        if case .running = executionStatus {
            return true
        }
        return false
    }

    private var shouldShowSigningPreview: Bool {
        // Suppress while blocked: the signing preview promises a Secure Enclave prompt that
        // the bundler-gas row has just ruled out.
        guard isBlockedByBundlerGas == false else {
            return false
        }
        if case .idle = executionStatus {
            return true
        }
        return false
    }

    private var isBlockedByBundlerGas: Bool { bundlerGasStatus?.needsGas == true }

    private var canConfirm: Bool {
        if isBlockedByBundlerGas {
            return false
        }
        switch transferPreflightStatus {
        case .resolving, .failed:
            return false
        case .resolved, nil:
            break
        }
        switch swapPreflightStatus {
        case .quoting, .failed:
            return false
        case .quoted:
            return true
        case nil:
            return true
        }
    }

    private var confirmedIcon: String {
        switch executionStatus {
        case .running:
            return "arrow.triangle.2.circlepath"
        case .submitted(_, _, let success):
            if success == true {
                return "checkmark.circle.fill"
            }
            if success == false {
                return "xmark.octagon.fill"
            }
            return "paperplane.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .gasEstimationUnavailable, .prefundShortfall:
            return "exclamationmark.triangle.fill"
        case .idle:
            return "checkmark.circle.fill"
        }
    }

    private var confirmedTint: Color {
        switch executionStatus {
        case .running:
            return .blue
        case .submitted(_, _, let success):
            return success == false ? .red : .green
        case .failed:
            return .orange
        case .gasEstimationUnavailable, .prefundShortfall:
            return .orange
        case .idle:
            return .green
        }
    }

    private var confirmedText: String {
        switch executionStatus {
        case .running(let message):
            return runningExecutionMessage(from: message)
        case .submitted(_, let txHash, let success):
            if success == true {
                return "Included onchain at \(Self.timeFormatter.string(from: intent.updatedAt))"
            }
            if success == false {
                return "Submitted but reverted"
            }
            return txHash == nil ? "Submitted; receipt pending" : "Submitted onchain"
        case .failed(let message):
            return message
        case .gasEstimationUnavailable:
            return "Gas estimation unavailable — action required above."
        case .prefundShortfall:
            return "Not enough ETH for the gas headroom — action required above."
        case .idle:
            return "Confirmed at \(Self.timeFormatter.string(from: intent.updatedAt))"
        }
    }

    @ViewBuilder
    private var transferPreflightRow: some View {
        if intent.tool == .transfer, let transferPreflightStatus {
            switch transferPreflightStatus {
            case .resolving:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Resolving recipient before signing...")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            case .resolved(let resolvedName):
                VStack(alignment: .leading, spacing: 5) {
                    Label("ENS resolved", systemImage: resolvedName.ccipReadUsed ? "network" : "checkmark.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                    intentDetailRow("name", resolvedName.normalizedName)
                    intentDetailRow("resolved to", resolvedName.address.walletDisplayShortAddress)
                    intentDetailRow(
                        "resolved on",
                        resolvedName.ccipReadUsed
                        ? "\(resolvedName.resolutionChainName) · CCIP Read"
                        : resolvedName.resolutionChainName
                    )
                }
                .padding(.vertical, 4)
            case .failed(let message):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var swapPreflightRow: some View {
        if intent.tool == .swap, let swapPreflightStatus {
            switch swapPreflightStatus {
            case .quoting:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Quoting Uniswap v3 routes through local wallet-node...")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            case .quoted(let preview):
                VStack(alignment: .leading, spacing: 5) {
                    Label(
                        preview.quote.requiresApproval ? "Approve + swap batch" : "Route quoted",
                        systemImage: preview.quote.requiresApproval ? "checkmark.shield.fill" : "arrow.triangle.swap"
                    )
                    .font(.caption.bold())
                    .foregroundStyle(.green)
                    intentDetailRow(
                        "estimated out",
                        TokenAmountFormatter.displayString(
                            rawUnits: preview.quote.quoteAmountOut,
                            decimals: preview.toToken.decimals,
                            symbol: preview.toToken.symbol
                        )
                    )
                    intentDetailRow(
                        "minimum out",
                        TokenAmountFormatter.displayString(
                            rawUnits: preview.quote.amountOutMinimum,
                            decimals: preview.toToken.decimals,
                            symbol: preview.toToken.symbol
                        )
                    )
                    intentDetailRow("route", swapRouteLabel(preview))
                    intentDetailRow("slippage", "\(preview.quote.slippageBps) bps")
                    if preview.quote.requiresApproval {
                        intentDetailRow("approval", "included before swap")
                    }
                }
                .padding(.vertical, 4)
            case .failed(let message):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// The pre-flight decline: the bundler cannot pay for this transaction, so nothing is
    /// signed or submitted. Offers the address to top up from another wallet.
    @ViewBuilder
    private var bundlerGasRow: some View {
        if let bundlerGasStatus, isBlockedByBundlerGas {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(BundlerGasStatus.warningTitle)
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
                Text(bundlerGasStatus.declineDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let address = bundlerGasStatus.address {
                        Button(copiedBundlerAddress ? "Copied" : "Copy bundler address") {
                            copyBundlerAddress(address)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if let faucetURL = bundlerGasStatus.faucetURL {
                        Link("Open \(bundlerGasStatus.networkLabel) faucet", destination: faucetURL)
                            .font(.caption2.bold())
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func copyBundlerAddress(_ address: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        copiedBundlerAddress = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            copiedBundlerAddress = false
        }
    }

    @ViewBuilder
    private var signingPreviewRow: some View {
        if shouldShowSigningPreview, let signingPreview {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: signingPreview.systemImage)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(signingPreview.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(signingPreview.title)
                        .font(.caption.bold())
                        .foregroundStyle(signingPreview.tint)
                    Text(signingPreview.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var executionStatusRow: some View {
        switch executionStatus {
        case .running(let message):
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(runningExecutionTitle(from: message))
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                if let detail = runningExecutionDetail(from: message) {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        case .submitted(let userOpHash, let transactionHash, let success):
            VStack(alignment: .leading, spacing: 4) {
                Text(success == false ? "Execution reverted after submission." : "Onchain submission recorded.")
                    .font(.caption.bold())
                    .foregroundStyle(success == false ? .red : .green)
                Text(transactionHash ?? userOpHash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
        case .failed(let message):
            Text(message)
                .font(.caption.bold())
                .foregroundStyle(.orange)
                .padding(.vertical, 4)
        case let .gasEstimationUnavailable(detail, suggestedCallGasLimit):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Gas estimation unavailable — check your RPC.")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("""
                You can submit with a \(suggestedCallGasLimit.formatted()) gas headroom instead. \
                Your account must hold enough ETH to cover that limit up front, and EntryPoint \
                charges a 10% penalty on whatever the transaction does not use.
                """)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Submit with gas headroom") {
                    onSubmitWithGasHeadroom(suggestedCallGasLimit)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        case let .prefundShortfall(report):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Not enough ETH to cover the gas headroom up front.")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
                Text("""
                EntryPoint requires \(WeiFormatter.ethDisplayString(fromHexWei: report.requiredPrefundWeiHex)) \
                held up front to cover \(report.effectiveCallGasLimit.formatted()) call gas, whatever \
                the transaction actually spends. This account has \
                \(WeiFormatter.ethDisplayString(fromHexWei: report.availableWeiHex)) available, counting its \
                EntryPoint deposit.
                """)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Top up at least \(WeiFormatter.ethDisplayString(fromHexWei: report.deficitWeiHex)), then try again.")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") {
                    onSubmitWithGasHeadroom(report.effectiveCallGasLimit)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Re-reads the account balance and re-estimates before asking for a signature.")
            }
            .padding(.vertical, 4)
        case .idle:
            // Nothing to promise while blocked — the bundler-gas row above already says the
            // send is refused, and this line would contradict it.
            if isBlockedByBundlerGas == false {
                Text(intent.tool == .transfer
                     ? "Review before signing. Confirmation will request Secure Enclave approval and submit onchain."
                     : "Review before confirming this tool intent.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
    }

    private func runningExecutionTitle(from message: String) -> String {
        if message.localizedCaseInsensitiveContains("accepted")
            || message.localizedCaseInsensitiveContains("waiting for inclusion")
            || message.localizedCaseInsensitiveContains("receipt") {
            return "Submitted to wallet-node. Waiting for onchain receipt."
        }
        if message.localizedCaseInsensitiveContains("submitting") {
            return "Relaying through local wallet-node."
        }
        if message.localizedCaseInsensitiveContains("gas") {
            return "Preparing gas estimate with local wallet-node."
        }
        return "Preparing, signing, and submitting onchain."
    }

    private func runningExecutionDetail(from message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    private func runningExecutionMessage(from message: String) -> String {
        runningExecutionTitle(from: message)
    }

    private func intentDetailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func swapRouteLabel(_ preview: ChatSwapPreview) -> String {
        guard !preview.quote.hops.isEmpty else {
            return "\(preview.fromToken.symbol) -> \(preview.toToken.symbol)"
        }
        var symbols = [preview.fromToken.symbol]
        for hop in preview.quote.hops {
            symbols.append(symbol(for: hop.tokenOut, in: preview))
        }
        return symbols.joined(separator: " -> ")
    }

    private func symbol(for address: String, in preview: ChatSwapPreview) -> String {
        if address.caseInsensitiveCompare(preview.quote.tokenIn) == .orderedSame {
            return preview.fromToken.symbol
        }
        if address.caseInsensitiveCompare(preview.quote.tokenOut) == .orderedSame {
            return preview.toToken.symbol
        }
        if let token = WalletTokenRegistry.tokens(on: preview.quote.chainID).first(where: {
            $0.contractAddress?.caseInsensitiveCompare(address) == .orderedSame
        }) {
            return token.symbol
        }
        return address.walletDisplayShortAddress
    }

    private var feedbackControls: some View {
        HStack(spacing: 8) {
            Text("Extraction feedback")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Button {
                onFeedback(.thumbsUp, nil)
            } label: {
                Image(systemName: feedback?.rating == .thumbsUp ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Good extraction")

            Button {
                feedbackNote = feedback?.note ?? ""
                showingFeedbackSheet = true
            } label: {
                Image(systemName: feedback?.rating == .thumbsDown ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Bad extraction")

            if let feedback {
                Text(feedback.rating == .thumbsUp ? "Rated up" : "Rated down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let note = feedback.note, !note.isEmpty {
                    Text("Note saved")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

private struct ToolIntentEditSheet: View {
    let intent: ToolIntent
    let onSave: ([String: String]) -> Void
    let onCancel: () -> Void

    @State private var editedArgs: [String: String]
    @State private var originalArgs: [String: String]

    init(intent: ToolIntent,
         onSave: @escaping ([String: String]) -> Void,
         onCancel: @escaping () -> Void) {
        self.intent = intent
        self.onSave = onSave
        self.onCancel = onCancel
        _editedArgs = State(initialValue: intent.args)
        _originalArgs = State(initialValue: intent.args)
    }

    private var keysSorted: [String] { intent.args.keys.sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Edit \(intent.tool.rawValue) intent")
                    .font(.title3.bold())
                Spacer()
                Button("Reset") {
                    editedArgs = originalArgs
                }
                .disabled(editedArgs == originalArgs)
            }

            Form {
                ForEach(keysSorted, id: \.self) { key in
                    LabeledContent(key) {
                        TextField(key, text: Binding(
                            get: { editedArgs[key] ?? "" },
                            set: { editedArgs[key] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 240)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save & confirm") {
                    onSave(editedArgs)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(editedArgs.values.contains { $0.isEmpty })
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 300)
    }
}

private struct ToolIntentFeedbackSheet: View {
    @Binding var note: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What was wrong?")
                .font(.title3.bold())

            TextEditor(text: $note)
                .font(.body)
                .frame(minWidth: 360, minHeight: 130)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 240)
    }
}

private extension String {
    var walletDisplayShortAddress: String {
        guard hasPrefix("0x"), count > 18 else {
            return self
        }
        return "\(prefix(10))...\(suffix(8))"
    }
}
