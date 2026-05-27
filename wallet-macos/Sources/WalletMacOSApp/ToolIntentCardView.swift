import SwiftUI
import WalletToolLayer

struct ToolIntentCardView: View {
    let intent: ToolIntent
    let feedback: ToolIntentFeedback?
    let executionStatus: ChatIntentExecutionStatus
    let transferPreflightStatus: ChatTransferPreflightStatus?
    let onConfirm: () -> Void
    let onReject: () -> Void
    let onEdit: ([String: String]) -> Void
    let onFeedback: (ToolIntentFeedback.Rating, String?) -> Void

    @State private var showingEditSheet = false
    @State private var showingFeedbackSheet = false
    @State private var feedbackNote = ""

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

            executionStatusRow

            feedbackControls

            switch intent.disposition {
            case .pending:
                HStack(spacing: 8) {
                    Button("Edit") { showingEditSheet = true }
                        .buttonStyle(.bordered)
                        .disabled(isExecutionRunning)
                    Button("Reject", role: .destructive, action: onReject)
                        .buttonStyle(.bordered)
                        .disabled(isExecutionRunning)
                    Spacer()
                    Button("Looks good", action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .disabled(isExecutionRunning || !canConfirm)
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

    private var canConfirm: Bool {
        switch transferPreflightStatus {
        case .resolving, .failed:
            return false
        case .resolved, nil:
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
        case .idle:
            return .green
        }
    }

    private var confirmedText: String {
        switch executionStatus {
        case .running:
            return "Signing and submitting onchain..."
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
    private var executionStatusRow: some View {
        switch executionStatus {
        case .running:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing gas, requesting signature, and relaying through local wallet-node.")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
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
        case .idle:
            Text(intent.tool == .transfer
                 ? "Review before signing. Confirmation will request Secure Enclave approval and submit onchain."
                 : "Review before confirming this tool intent.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .italic()
        }
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
