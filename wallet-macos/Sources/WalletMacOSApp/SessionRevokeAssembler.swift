import Foundation
import WalletToolLayer

enum SessionRevokeAssembler {
    static func executionRequest(
        accountAddress: String,
        permissionId: Data,
        deinitData: Data,
        calldataBuilder: (Data, Data) throws -> Data
    ) throws -> KernelExecutionRequest {
        let account = try Data(hexString: accountAddress)
        guard account.count == 20 else {
            throw AppError.invalidExecutionAddress
        }
        return KernelExecutionRequest.zeroValueCall(
            target: "0x" + account.hexEncodedString,
            callData: try calldataBuilder(permissionId, deinitData)
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
