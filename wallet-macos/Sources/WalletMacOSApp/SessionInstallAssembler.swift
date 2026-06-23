import Foundation
import WalletToolLayer

/// Builds the executions + history entry for installing a session permission via
/// a root(owner)-validated user op. The install runs in the execution phase (so
/// it is NOT charged against the permission's own GasPolicy), mirroring the
/// revoke flow in reverse. See `SessionRevokeAssembler`.
enum SessionInstallAssembler {
    /// Two batched self-calls: `installValidations` then `grantAccess` (granting
    /// the permission access to the `execute` selector that session user ops use).
    static func executions(
        accountAddress: String,
        installCalldata: Data,
        grantCalldata: Data
    ) throws -> [KernelExecutionRequest] {
        let account = try Data(hexString: accountAddress)
        guard account.count == 20 else {
            throw AppError.invalidExecutionAddress
        }
        let target = "0x" + account.hexEncodedString
        return [
            KernelExecutionRequest.zeroValueCall(target: target, callData: installCalldata),
            KernelExecutionRequest.zeroValueCall(target: target, callData: grantCalldata),
        ]
    }

    static func historyDraft(accountAddress: String, validationNonce: UInt32) -> WalletTransactionDraft {
        WalletTransactionDraft(
            operation: .batch,
            amount: "1",
            token: "session install",
            counterparty: accountAddress,
            counterpartyName: "Kernel account",
            detailsJSON: #"{"kind":"session_key_install","validationNonce":"\#(validationNonce)"}"#
        )
    }
}
