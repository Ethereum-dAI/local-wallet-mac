import SwiftUI
import WalletToolLayer

struct ToolIntentCardView: View {
    let intent: ToolIntent
    let onConfirm: () -> Void
    let onReject: () -> Void
    let onEdit: ([String: String]) -> Void

    @State private var showingEditSheet = false

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

            Text("Phase 1 demo: this intent is recognized but no transaction is signed or broadcast.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .italic()

            switch intent.disposition {
            case .pending:
                HStack(spacing: 8) {
                    Button("Edit") { showingEditSheet = true }
                        .buttonStyle(.bordered)
                    Button("Reject", role: .destructive, action: onReject)
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Looks good", action: onConfirm)
                        .buttonStyle(.borderedProminent)
                }
            case .confirmed:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Confirmed at \(intent.updatedAt, style: .time)").foregroundStyle(.secondary)
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
    }
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
