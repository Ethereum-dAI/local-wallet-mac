import Foundation
import WalletToolLayer

enum SessionRevokeAssembler {
    static func executionRequest(
        accountAddress: String,
        validationNonce: UInt32,
        calldataBuilder: (UInt32) throws -> Data
    ) throws -> KernelExecutionRequest {
        let account = try Data(hexString: accountAddress)
        guard account.count == 20 else {
            throw AppError.invalidExecutionAddress
        }
        return KernelExecutionRequest.zeroValueCall(
            target: "0x" + account.hexEncodedString,
            callData: try calldataBuilder(validationNonce)
        )
    }

    static func historyDraft(accountAddress: String, validationNonce: UInt32) -> WalletTransactionDraft {
        WalletTransactionDraft(
            operation: .batch,
            amount: "1",
            token: "session revoke",
            counterparty: accountAddress,
            counterpartyName: "Kernel account",
            detailsJSON: #"{"kind":"session_key_revoke","validationNonce":"\#(validationNonce)"}"#
        )
    }
}
