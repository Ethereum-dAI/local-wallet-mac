import AppKit
import SwiftUI

/// The two no-backend recovery actions for funding the local relayer.
/// Opening the faucet intentionally has no clipboard side effect.
struct BundlerExternalFundingActions: View {
    let address: String
    let faucetURL: URL
    let accent: Color
    let secondaryText: Color
    let inputBackground: Color
    let border: Color
    var compact = false

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            Text(address)
                .font(.system(
                    size: compact ? 11 : 14,
                    weight: .semibold,
                    design: .monospaced
                ))
                .foregroundStyle(secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .frame(
                    maxWidth: .infinity,
                    minHeight: compact ? 34 : 44,
                    alignment: .leading
                )
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(border)
                        )
                )

            HStack(spacing: 10) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                        copied = false
                    }
                } label: {
                    Label(
                        copied ? "Copied" : "Copy address",
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(compact ? .small : .large)
                .accessibilityHint(
                    "Copies the bundler address for funding from another wallet"
                )

                Link(destination: faucetURL) {
                    Label("Open Sepolia faucet", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(accent)
                .controlSize(compact ? .small : .large)
                .accessibilityHint("Opens the faucet without changing the clipboard")
            }
        }
    }
}
