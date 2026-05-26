import Foundation
import WalletSignature

// UserOperationBuilder assembles local ERC-4337 drafts for the current demo
// intents. Deterministic protocol encoding stays in the shared Rust/Swift
// bridge; chain orchestration and app intent mapping live here.
struct KernelCallEncoder {
    private static let executeSelector = Data(hex: "e9ae5c53")
    private static let execModeSingleDefault = Data(repeating: 0, count: 32)

    func encodeExecuteSingle(_ request: KernelExecutionRequest) throws -> Data {
        let target = try Data(hexString: request.target)
        guard target.count == 20 else {
            throw AppError.invalidExecutionAddress
        }

        let executionCalldata = target
            + request.value.leftPadded(to: 32)
            + request.callData

        return Self.executeSelector
            + Self.execModeSingleDefault
            + Data.fromBigEndian(UInt64(64)).leftPadded(to: 32)
            + abiEncodeDynamicBytes(executionCalldata)
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
    private let rpcClient: DemoRPCClient
    private let kernelCallEncoder: KernelCallEncoder
    private let erc20TransferCallEncoder: ERC20TransferCallEncoder
    private let deploymentEncoder: KernelDeploymentEncoder

    init(
        rpcClient: DemoRPCClient = DemoRPCClient(),
        kernelCallEncoder: KernelCallEncoder = KernelCallEncoder(),
        erc20TransferCallEncoder: ERC20TransferCallEncoder = ERC20TransferCallEncoder(),
        deploymentEncoder: KernelDeploymentEncoder = KernelDeploymentEncoder()
    ) {
        self.rpcClient = rpcClient
        self.kernelCallEncoder = kernelCallEncoder
        self.erc20TransferCallEncoder = erc20TransferCallEncoder
        self.deploymentEncoder = deploymentEncoder
    }

    func buildDraft(
        walletRecord: WalletRecord,
        publicKey: PublicKeyCoordinates,
        chain: ChainConfiguration,
        isDeployed: Bool,
        intent: TransactionIntent
    ) async throws -> UserOperationDraft {
        try await buildDraft(
            walletRecord: walletRecord,
            publicKey: publicKey,
            chain: chain,
            isDeployed: isDeployed,
            execution: buildExecutionRequest(for: intent)
        )
    }

    func buildDraft(
        walletRecord: WalletRecord,
        publicKey: PublicKeyCoordinates,
        chain: ChainConfiguration,
        isDeployed: Bool,
        execution: KernelExecutionRequest
    ) async throws -> UserOperationDraft {
        guard let sender = walletRecord.kernelAccountAddress else {
            throw AppError.invalidCounterfactualAddress
        }

        let callData = try kernelCallEncoder.encodeExecuteSingle(execution)
        let nonceHex = try await rpcClient.entryPointNonce(
            chain: chain,
            accountAddress: sender,
            nonceKey: 0
        )
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

    private func buildExecutionRequest(for intent: TransactionIntent) throws -> KernelExecutionRequest {
        switch intent {
        case .nativeTransfer(let recipient, let amountETH):
            let addressData = try Data(hexString: recipient)
            guard addressData.count == 20 else {
                throw AppError.invalidExecutionAddress
            }

            return KernelExecutionRequest(
                target: "0x" + addressData.hexEncodedString,
                value: try EtherAmountParser.wei(fromETHString: amountETH),
                callData: Data()
            )
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
            return KernelExecutionRequest(
                target: "0x" + tokenAddressData.hexEncodedString,
                value: Data(repeating: 0, count: 32),
                callData: try erc20TransferCallEncoder.encodeTransfer(
                    recipient: recipient,
                    amount: transferAmount
                )
            )
        }
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
