import SwiftUI

struct WalletLaunchGateView: View {
    @ObservedObject var walletModel: AppModel
    let onRecoveryCompleted: () -> Void

    var body: some View {
        if let reason = walletModel.walletRecoveryReason {
            WalletRecoveryView(
                reason: reason,
                walletModel: walletModel,
                onRecoveryCompleted: onRecoveryCompleted
            )
        } else {
            LocalWalletChatDashboardView(walletModel: walletModel)
        }
    }
}

struct WalletRecoveryView: View {
    let reason: WalletKeyRecoveryReason
    @ObservedObject var walletModel: AppModel
    let onRecoveryCompleted: () -> Void
    @State private var resetError: String?
    @State private var isResetConfirmationPresented = false

    var body: some View {
        ZStack {
            Color(red: 0.045, green: 0.055, blue: 0.100)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "key.slash.fill")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.orange)

                Text("Wallet key unavailable")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color(red: 1.000, green: 0.990, blue: 0.900))

                Text(explanation)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(red: 0.730, green: 0.790, blue: 0.900))
                    .frame(maxWidth: 560)

                Text("Resetting removes this local wallet identity and its local wallet data. The inaccessible private key cannot be recovered by this app.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 560)

                if let resetError {
                    Text(resetError)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                        .textSelection(.enabled)
                }

                Button(walletModel.isResettingWallet ? "Resetting…" : "Reset local wallet") {
                    isResetConfirmationPresented = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(walletModel.isResettingWallet)
                .accessibilityHint("Deletes this local wallet identity and returns to onboarding")
            }
            .padding(48)
        }
        .frame(minWidth: 980, minHeight: 720)
        .alert("Reset local wallet?", isPresented: $isResetConfirmationPresented) {
            Button("Reset local wallet", role: .destructive) {
                resetWallet()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the local wallet identity and local wallet data. The inaccessible private key cannot be recovered by this app.")
        }
    }

    private var explanation: String {
        switch reason {
        case .missing:
            return "The saved wallet belongs to a Secure Enclave key that is no longer available to this signed app. This can happen after the development team, bundle identifier, or Keychain state changes."
        case .mismatch:
            return "The accessible Secure Enclave key does not match this wallet's saved public identity, so the app will not use either one."
        }
    }

    private func resetWallet() {
        Task {
            do {
                try await walletModel.resetWalletForRecoveryAuthorized()
                onRecoveryCompleted()
            } catch {
                resetError = error.localizedDescription
            }
        }
    }
}
