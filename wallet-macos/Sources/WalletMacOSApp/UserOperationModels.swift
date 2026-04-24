import Foundation
import WalletSignature

struct KernelExecutionRequest: Equatable {
    let target: String
    let value: Data
    let callData: Data
}

enum TransactionIntent: Equatable {
    case nativeTransfer(recipient: String, amountETH: String)
}

struct UserOperationGasPlan: Equatable {
    let accountGasLimits: Data
    let preVerificationGas: Data
    let gasFees: Data
    let paymasterAndData: Data

    var verificationGasLimit: Data {
        Data(accountGasLimits.prefix(16)).leftPadded(to: 32)
    }

    var callGasLimit: Data {
        Data(accountGasLimits.suffix(16)).leftPadded(to: 32)
    }

    var maxPriorityFeePerGas: Data {
        Data(gasFees.prefix(16)).leftPadded(to: 32)
    }

    var maxFeePerGas: Data {
        Data(gasFees.suffix(16)).leftPadded(to: 32)
    }

    static let placeholder = UserOperationGasPlan(
        accountGasLimits: Data(repeating: 0, count: 32),
        preVerificationGas: Data(repeating: 0, count: 32),
        gasFees: Data(repeating: 0, count: 32),
        paymasterAndData: Data()
    )
}

struct UserOperationDraft: Equatable {
    let sender: String
    let nonce: Data
    let initCode: Data
    let callData: Data
    let gasPlan: UserOperationGasPlan
    let entryPoint: String
    let chainId: UInt64

    func updatingGasPlan(_ gasPlan: UserOperationGasPlan) -> UserOperationDraft {
        UserOperationDraft(
            sender: sender,
            nonce: nonce,
            initCode: initCode,
            callData: callData,
            gasPlan: gasPlan,
            entryPoint: entryPoint,
            chainId: chainId
        )
    }

    func userOpHash() throws -> Data {
        try WalletSignature.computeUserOpHash(
            sender: try Data(hexString: sender),
            nonce: nonce,
            initCode: initCode,
            callData: callData,
            accountGasLimits: gasPlan.accountGasLimits,
            preVerificationGas: gasPlan.preVerificationGas,
            gasFees: gasPlan.gasFees,
            paymasterAndData: gasPlan.paymasterAndData,
            entryPoint: try Data(hexString: entryPoint),
            chainId: chainId
        )
    }
}
