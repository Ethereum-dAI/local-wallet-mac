import Foundation
import WalletSignature

// UserOperationBuilder assembles local ERC-4337 drafts for the current demo
// intents. Deterministic protocol encoding stays in the shared Rust/Swift
// bridge; chain orchestration and app intent mapping live here.
struct KernelCallEncoder {
    private static let executeSelector = Data(hex: "e9ae5c53")
    private static let execModeSingleDefault = Data(repeating: 0, count: 32)
    private static let execModeBatchDefault = Data([0x01]) + Data(repeating: 0, count: 31)

    func encodeExecute(_ requests: [KernelExecutionRequest]) throws -> Data {
        guard !requests.isEmpty else {
            throw AppError.invalidExecutionBatch
        }
        if requests.count == 1, let request = requests.first {
            return try encodeExecuteSingle(request)
        }
        return try encodeExecuteBatch(requests)
    }

    func encodeExecuteSingle(_ request: KernelExecutionRequest) throws -> Data {
        let executionCalldata = try abiEncodePackedExecution(request)

        return encodeExecute(
            mode: Self.execModeSingleDefault,
            executionCalldata: executionCalldata
        )
    }

    func encodeExecuteBatch(_ requests: [KernelExecutionRequest]) throws -> Data {
        guard !requests.isEmpty else {
            throw AppError.invalidExecutionBatch
        }

        return encodeExecute(
            mode: Self.execModeBatchDefault,
            executionCalldata: try abiEncodeExecutionArray(requests)
        )
    }

    private func encodeExecute(mode: Data, executionCalldata: Data) -> Data {
        Self.executeSelector
            + mode
            + Data.fromBigEndian(UInt64(64)).leftPadded(to: 32)
            + abiEncodeDynamicBytes(executionCalldata)
    }

    private func abiEncodePackedExecution(_ request: KernelExecutionRequest) throws -> Data {
        try executionTargetData(request.target)
            + request.value.leftPadded(to: 32)
            + request.callData
    }

    private func abiEncodeExecutionArray(_ requests: [KernelExecutionRequest]) throws -> Data {
        var encodedExecutions = Data()
        var offsets = Data()
        var nextOffset = requests.count * 32

        for request in requests {
            offsets += Data.fromBigEndian(UInt64(nextOffset)).leftPadded(to: 32)
            let encoded = try abiEncodeExecutionTuple(request)
            encodedExecutions += encoded
            nextOffset += encoded.count
        }

        return Data.fromBigEndian(UInt64(32)).leftPadded(to: 32)
            + Data.fromBigEndian(UInt64(requests.count)).leftPadded(to: 32)
            + offsets
            + encodedExecutions
    }

    private func abiEncodeExecutionTuple(_ request: KernelExecutionRequest) throws -> Data {
        try executionTargetData(request.target).leftPadded(to: 32)
            + request.value.leftPadded(to: 32)
            + Data.fromBigEndian(UInt64(96)).leftPadded(to: 32)
            + abiEncodeDynamicBytes(request.callData)
    }

    private func executionTargetData(_ target: String) throws -> Data {
        let target = try Data(hexString: target)
        guard target.count == 20 else {
            throw AppError.invalidExecutionAddress
        }
        return target
    }

    private func abiEncodeDynamicBytes(_ value: Data) -> Data {
        let length = Data.fromBigEndian(UInt64(value.count)).leftPadded(to: 32)
        let remainder = value.count % 32
        let padding = remainder == 0 ? 0 : 32 - remainder
        return length + value + Data(repeating: 0, count: padding)
    }
}

struct ERC20TransferCallEncoder {
    private static let transferSelector = Data(hex: "a9059cbb")

    func encodeTransfer(recipient: String, amount: Data) throws -> Data {
        let recipientData = try Data(hexString: recipient)
        guard recipientData.count == 20 else {
            throw AppError.invalidExecutionAddress
        }

        return Self.transferSelector
            + recipientData.leftPadded(to: 32)
            + amount.leftPadded(to: 32)
    }
}

struct ERC20ApprovalCallEncoder {
    private static let approveSelector = Data(hex: "095ea7b3")

    func encodeApprove(spender: String, amount: Data) throws -> Data {
        let spenderData = try Data(hexString: spender)
        guard spenderData.count == 20 else {
            throw AppError.invalidExecutionAddress
        }

        return Self.approveSelector
            + spenderData.leftPadded(to: 32)
            + amount.leftPadded(to: 32)
    }
}

struct SwapRouterCallEncoder {
    private static let exactInputSelector = Data(hex: "b858183f")
    private static let multicallSelector = Data(hex: "ac9650d8")
    private static let unwrapWETH9Selector = Data(hex: "49404b7c")

    func encodeExactInput(path: Data, recipient: String, amountIn: Data, amountOutMinimum: Data) throws -> Data {
        let recipientData = try Data(hexString: recipient)
        guard recipientData.count == 20 else {
            throw AppError.invalidExecutionAddress
        }

        return Self.exactInputSelector
            + Data.fromBigEndian(UInt64(32)).leftPadded(to: 32)
            + Data.fromBigEndian(UInt64(128)).leftPadded(to: 32)
            + recipientData.leftPadded(to: 32)
            + amountIn.leftPadded(to: 32)
            + amountOutMinimum.leftPadded(to: 32)
            + abiEncodeDynamicBytes(path)
    }

    func encodeUnwrapWETH9(amountMinimum: Data, recipient: String) throws -> Data {
        let recipientData = try Data(hexString: recipient)
        guard recipientData.count == 20 else {
            throw AppError.invalidExecutionAddress
        }

        return Self.unwrapWETH9Selector
            + amountMinimum.leftPadded(to: 32)
            + recipientData.leftPadded(to: 32)
    }

    func encodeMulticall(_ calls: [Data]) -> Data {
        var encodedCalls = Data()
        var offsets = Data()
        var nextOffset = calls.count * 32
        for call in calls {
            offsets += Data.fromBigEndian(UInt64(nextOffset)).leftPadded(to: 32)
            let encoded = abiEncodeDynamicBytes(call)
            encodedCalls += encoded
            nextOffset += encoded.count
        }

        return Self.multicallSelector
            + Data.fromBigEndian(UInt64(32)).leftPadded(to: 32)
            + Data.fromBigEndian(UInt64(calls.count)).leftPadded(to: 32)
            + offsets
            + encodedCalls
    }

    private func abiEncodeDynamicBytes(_ value: Data) -> Data {
        let length = Data.fromBigEndian(UInt64(value.count)).leftPadded(to: 32)
        let remainder = value.count % 32
        let padding = remainder == 0 ? 0 : 32 - remainder
        return length + value + Data(repeating: 0, count: padding)
    }
}

struct KernelDeploymentEncoder {
    private static let createAccountSelector = Data(hex: "ea6d13ac")

    func makeInitCode(
        chain: ChainConfiguration,
        publicKey: PublicKeyCoordinates,
        authenticatorIdHash: Data,
        salt: Data
    ) throws -> Data {
        let factory = try Data(hexString: chain.kernel.factory)
        guard factory.count == 20 else {
            throw AppError.invalidCounterfactualAddress
        }

        let initializeCall = try WalletSignature.encodeKernelInitializeCall(
            webauthnValidator: try Data(hexString: chain.kernel.webAuthnValidator),
            pubKeyX: publicKey.x,
            pubKeyY: publicKey.y,
            authenticatorIdHash: authenticatorIdHash
        )

        let calldata = try encodeCreateAccountCall(
            initializeCall: initializeCall,
            salt: salt
        )

        return factory + calldata
    }

    private func encodeCreateAccountCall(
        initializeCall: Data,
        salt: Data
    ) throws -> Data {
        guard salt.count == 32 else {
            throw AppError.invalidHexString
        }

        return Self.createAccountSelector
            + Data.fromBigEndian(UInt64(64)).leftPadded(to: 32)
            + salt
            + abiEncodeDynamicBytes(initializeCall)
    }

    private func abiEncodeDynamicBytes(_ value: Data) -> Data {
        let length = Data.fromBigEndian(UInt64(value.count)).leftPadded(to: 32)
        let remainder = value.count % 32
        let padding = remainder == 0 ? 0 : 32 - remainder
        return length + value + Data(repeating: 0, count: padding)
    }
}

struct UserOperationBuilder {
    private let kernelCallEncoder: KernelCallEncoder
    private let erc20TransferCallEncoder: ERC20TransferCallEncoder
    private let erc20ApprovalCallEncoder: ERC20ApprovalCallEncoder
    private let swapRouterCallEncoder: SwapRouterCallEncoder
    private let deploymentEncoder: KernelDeploymentEncoder

    init(
        kernelCallEncoder: KernelCallEncoder = KernelCallEncoder(),
        erc20TransferCallEncoder: ERC20TransferCallEncoder = ERC20TransferCallEncoder(),
        erc20ApprovalCallEncoder: ERC20ApprovalCallEncoder = ERC20ApprovalCallEncoder(),
        swapRouterCallEncoder: SwapRouterCallEncoder = SwapRouterCallEncoder(),
        deploymentEncoder: KernelDeploymentEncoder = KernelDeploymentEncoder()
    ) {
        self.kernelCallEncoder = kernelCallEncoder
        self.erc20TransferCallEncoder = erc20TransferCallEncoder
        self.erc20ApprovalCallEncoder = erc20ApprovalCallEncoder
        self.swapRouterCallEncoder = swapRouterCallEncoder
        self.deploymentEncoder = deploymentEncoder
    }

    func buildDraft(
        walletRecord: WalletRecord,
        publicKey: PublicKeyCoordinates,
        chain: ChainConfiguration,
        isDeployed: Bool,
        nonceHex: String,
        intent: TransactionIntent
    ) throws -> UserOperationDraft {
        try buildDraft(
            walletRecord: walletRecord,
            publicKey: publicKey,
            chain: chain,
            isDeployed: isDeployed,
            nonceHex: nonceHex,
            executions: buildExecutionRequests(for: intent)
        )
    }

    func buildDraft(
        walletRecord: WalletRecord,
        publicKey: PublicKeyCoordinates,
        chain: ChainConfiguration,
        isDeployed: Bool,
        nonceHex: String,
        execution: KernelExecutionRequest
    ) throws -> UserOperationDraft {
        try buildDraft(
            walletRecord: walletRecord,
            publicKey: publicKey,
            chain: chain,
            isDeployed: isDeployed,
            nonceHex: nonceHex,
            executions: [execution]
        )
    }

    func buildDraft(
        walletRecord: WalletRecord,
        publicKey: PublicKeyCoordinates,
        chain: ChainConfiguration,
        isDeployed: Bool,
        nonceHex: String,
        executions: [KernelExecutionRequest]
    ) throws -> UserOperationDraft {
        guard let sender = walletRecord.kernelAccountAddress else {
            throw AppError.invalidCounterfactualAddress
        }

        let callData = try kernelCallEncoder.encodeExecute(executions)
        let nonce = try Data(hexString: nonceHex).leftPadded(to: 32)

        let initCode: Data
        if isDeployed {
            initCode = Data()
        } else {
            initCode = try deploymentEncoder.makeInitCode(
                chain: chain,
                publicKey: publicKey,
                authenticatorIdHash: walletRecord.authenticatorIdHash,
                salt: walletRecord.kernelSalt
            )
        }

        return UserOperationDraft(
            sender: sender,
            nonce: nonce,
            initCode: initCode,
            callData: callData,
            gasPlan: .placeholder,
            entryPoint: chain.entryPoint,
            chainId: chain.id
        )
    }

    func buildExecutionRequests(for intent: TransactionIntent) throws -> [KernelExecutionRequest] {
        switch intent {
        case .nativeTransfer(let recipient, let amountETH):
            let addressData = try Data(hexString: recipient)
            guard addressData.count == 20 else {
                throw AppError.invalidExecutionAddress
            }

            return [KernelExecutionRequest(
                target: "0x" + addressData.hexEncodedString,
                value: try EtherAmountParser.wei(fromETHString: amountETH),
                callData: Data()
            )]
        case .erc20Transfer(let token, let recipient, let amount):
            guard let tokenAddress = token.contractAddress else {
                throw AppError.invalidExecutionAddress
            }
            let tokenAddressData = try Data(hexString: tokenAddress)
            guard tokenAddressData.count == 20 else {
                throw AppError.invalidExecutionAddress
            }

            let transferAmount = try EtherAmountParser.units(
                fromDecimalString: amount,
                decimals: token.decimals
            )
            return [KernelExecutionRequest.zeroValueCall(
                target: "0x" + tokenAddressData.hexEncodedString,
                callData: try erc20TransferCallEncoder.encodeTransfer(
                    recipient: recipient,
                    amount: transferAmount
                )
            )]
        case .exactInputSwap(let request):
            let routerData = try Data(hexString: request.quote.router)
            guard routerData.count == 20 else {
                throw AppError.invalidExecutionAddress
            }

            let routerCallData: Data
            if request.tokenOutIsNative {
                let swapCallData = try swapRouterCallEncoder.encodeExactInput(
                    path: request.quote.path,
                    recipient: request.quote.router,
                    amountIn: request.quote.amountIn,
                    amountOutMinimum: request.quote.amountOutMinimum
                )
                let unwrapCallData = try swapRouterCallEncoder.encodeUnwrapWETH9(
                    amountMinimum: request.quote.amountOutMinimum,
                    recipient: request.recipient
                )
                routerCallData = swapRouterCallEncoder.encodeMulticall([swapCallData, unwrapCallData])
            } else {
                routerCallData = try swapRouterCallEncoder.encodeExactInput(
                    path: request.quote.path,
                    recipient: request.recipient,
                    amountIn: request.quote.amountIn,
                    amountOutMinimum: request.quote.amountOutMinimum
                )
            }

            let routerExecution = KernelExecutionRequest(
                target: "0x" + routerData.hexEncodedString,
                value: request.tokenInIsNative ? request.quote.amountIn : Data(repeating: 0, count: 32),
                callData: routerCallData
            )

            return try approvalExecutionRequests(for: request) + [routerExecution]
        }
    }

    private func approvalExecutionRequests(for request: SwapExecutionRequest) throws -> [KernelExecutionRequest] {
        guard request.quote.requiresApproval, !request.tokenInIsNative else {
            return []
        }

        let tokenInData = try Data(hexString: request.quote.tokenIn)
        guard tokenInData.count == 20 else {
            throw AppError.invalidExecutionAddress
        }

        var requests: [KernelExecutionRequest] = []
        if request.quote.allowance.hasNonZeroValue {
            requests.append(
                KernelExecutionRequest.zeroValueCall(
                    target: "0x" + tokenInData.hexEncodedString,
                    callData: try erc20ApprovalCallEncoder.encodeApprove(
                        spender: request.quote.router,
                        amount: Data(repeating: 0, count: 32)
                    )
                )
            )
        }
        requests.append(
            KernelExecutionRequest.zeroValueCall(
                target: "0x" + tokenInData.hexEncodedString,
                callData: try erc20ApprovalCallEncoder.encodeApprove(
                    spender: request.quote.router,
                    amount: request.quote.amountIn
                )
            )
        )
        return requests
    }
}

private extension Data {
    init(hex: String) {
        let normalized = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        self = stride(from: 0, to: normalized.count, by: 2).reduce(into: Data()) { data, index in
            let start = normalized.index(normalized.startIndex, offsetBy: index)
            let end = normalized.index(start, offsetBy: 2)
            let value = UInt8(normalized[start..<end], radix: 16) ?? 0
            data.append(value)
        }
    }
}

private extension Optional where Wrapped == Data {
    var hasNonZeroValue: Bool {
        guard let self else {
            return false
        }
        return self.contains { $0 != 0 }
    }
}
