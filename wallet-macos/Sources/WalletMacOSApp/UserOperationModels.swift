import Foundation
import WalletSignature

struct KernelExecutionRequest: Equatable {
    let target: String
    let value: Data
    let callData: Data
}

extension KernelExecutionRequest {
    static func zeroValueCall(target: String, callData: Data) -> KernelExecutionRequest {
        KernelExecutionRequest(
            target: target,
            value: Data(repeating: 0, count: 32),
            callData: callData
        )
    }
}

struct WalletToken: Equatable, Identifiable {
    enum Kind: Equatable {
        case native
        case erc20(address: String)
    }

    let chainID: UInt64
    let symbol: String
    let name: String
    let decimals: Int
    let kind: Kind

    var id: String {
        "\(chainID):\(symbol.uppercased())"
    }

    var contractAddress: String? {
        if case let .erc20(address) = kind {
            return address
        }
        return nil
    }

    var isNative: Bool {
        kind == .native
    }
}

enum WalletTokenRegistry {
    static func tokens(on chainID: UInt64) -> [WalletToken] {
        allTokens.filter { $0.chainID == chainID }
    }

    static func erc20PolicyCatalog() -> [WalletToken] {
        var seenSymbols = Set<String>()
        return allTokens.compactMap { token in
            guard token.contractAddress != nil else {
                return nil
            }
            let symbol = token.symbol.uppercased()
            guard seenSymbols.insert(symbol).inserted else {
                return nil
            }
            return token
        }
    }

    static func token(matching rawValue: String?, on chainID: UInt64) -> WalletToken? {
        let normalized = (rawValue ?? "ETH")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lookup = normalized.isEmpty ? "ETH" : normalized

        if lookup.hasPrefix("0x") || lookup.hasPrefix("0X") {
            return tokens(on: chainID).first {
                $0.contractAddress?.caseInsensitiveCompare(lookup) == .orderedSame
            }
        }

        return tokens(on: chainID).first {
            $0.symbol.caseInsensitiveCompare(lookup) == .orderedSame
        }
    }

    static func wrappedNativeToken(on chainID: UInt64) -> WalletToken? {
        token(matching: "WETH", on: chainID)
    }

    static func swapIntermediates(on chainID: UInt64) -> [WalletToken] {
        ["WETH", "USDC", "USDT", "DAI"].compactMap { token(matching: $0, on: chainID) }
    }

    private static let allTokens: [WalletToken] = [
        WalletToken(chainID: 11_155_111, symbol: "ETH", name: "Sepolia Ether", decimals: 18, kind: .native),
        WalletToken(chainID: 11_155_111, symbol: "WETH", name: "Wrapped Ether", decimals: 18, kind: .erc20(address: "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14")),
        WalletToken(chainID: 11_155_111, symbol: "USDC", name: "USD Coin", decimals: 6, kind: .erc20(address: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238")),
        WalletToken(chainID: 11_155_111, symbol: "USDT", name: "Tether USD", decimals: 6, kind: .erc20(address: "0xaa8E23Fb1079EA71e0a56F48a2aA51851D8433D0")),
        WalletToken(chainID: 11_155_111, symbol: "DAI", name: "Dai Stablecoin", decimals: 18, kind: .erc20(address: "0x776b6FC2eD15d6bB5fC32e0c89DE68683118c62a")),
        WalletToken(chainID: 11_155_111, symbol: "AAVE", name: "Aave", decimals: 18, kind: .erc20(address: "0x5Bb220aFc6e2E008cB2302A83536A019ed245Aa2")),
        WalletToken(chainID: 11_155_111, symbol: "UNI", name: "Uniswap", decimals: 18, kind: .erc20(address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984")),
    ]
}

enum TransactionIntent: Equatable {
    case nativeTransfer(recipient: String, amountETH: String)
    case erc20Transfer(token: WalletToken, recipient: String, amount: String)
    case exactInputSwap(SwapExecutionRequest)
}

struct SwapQuoteHop: Equatable, Codable {
    let tokenIn: String
    let tokenOut: String
    let fee: Int
    let pool: String
    let liquidity: String
}

struct SwapQuote: Equatable, Codable {
    let chainID: UInt64
    let factory: String
    let router: String
    let quoter: String
    let tokenIn: String
    let tokenOut: String
    let amountIn: Data
    let quoteAmountOut: Data
    let amountOutMinimum: Data
    let slippageBps: UInt64
    let path: Data
    let hops: [SwapQuoteHop]
    let gasEstimate: String
    let allowance: Data?
    let requiresApproval: Bool
}

struct SwapExecutionRequest: Equatable {
    let quote: SwapQuote
    let recipient: String
    let tokenInIsNative: Bool
    let tokenOutIsNative: Bool
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

/// A UserOperation whose gas plan has crossed the local Rust policy boundary.
/// The maximum liability and fee quote are meaningful only for this exact draft.
struct EnrichedUserOperation: Equatable {
    let operation: AuthorizedUserOperation

    var draft: UserOperationDraft { operation.draft }
    var requiredPrefund: Data { operation.maxLiability }
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

enum UserOperationBoundaryError: LocalizedError, Equatable {
    case invalidExpectedSignatureLength(Int)
    case feeQuoteChainMismatch(expected: UInt64, actual: UInt64)
    case signatureLengthMismatch(expected: Int, actual: Int)
    case returnedHashMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case let .invalidExpectedSignatureLength(length):
            return "The authorized UserOperation signature length must be positive (got \(length))."
        case let .feeQuoteChainMismatch(expected, actual):
            return "The fee quote is for chain \(actual), but the UserOperation is for chain \(expected)."
        case let .signatureLengthMismatch(expected, actual):
            return "The final UserOperation signature length changed after authorization (expected \(expected) bytes, got \(actual))."
        case let .returnedHashMismatch(expected, actual):
            return "The RPC returned UserOperation hash \(actual), but the signed operation hash is \(expected)."
        }
    }
}

/// A fully finalized UserOperation that has crossed the app's local policy
/// boundary. The expected signature length is part of that authorization
/// because changing the encoded signature size changes pre-verification gas.
struct AuthorizedUserOperation: Equatable {
    let draft: UserOperationDraft
    let expectedSignatureLength: Int
    let maxLiability: Data
    let gasPolicyVersion: UInt32
    let feeQuote: ExecutionFeeQuote

    fileprivate init(
        draft: UserOperationDraft,
        expectedSignatureLength: Int,
        maxLiability: Data,
        gasPolicyVersion: UInt32,
        feeQuote: ExecutionFeeQuote
    ) throws {
        guard expectedSignatureLength > 0 else {
            throw UserOperationBoundaryError.invalidExpectedSignatureLength(expectedSignatureLength)
        }
        guard maxLiability.count == 32 else {
            throw WalletGasAuthorizationError.invalidInput
        }
        self.draft = draft
        self.expectedSignatureLength = expectedSignatureLength
        self.maxLiability = maxLiability
        self.gasPolicyVersion = gasPolicyVersion
        self.feeQuote = feeQuote
    }
}

/// The only production constructor for `AuthorizedUserOperation`. Daemon gas
/// values remain hints until this checked Rust boundary accepts and repacks them.
enum UserOperationGasAuthorizer {
    static func checkedPackedGasFees(
        maxPriorityFeePerGas: Data,
        maxFeePerGas: Data
    ) throws -> Data {
        try checkedPackedPair(
            high: maxPriorityFeePerGas,
            low: maxFeePerGas,
            highField: "maxPriorityFeePerGas",
            lowField: "maxFeePerGas"
        )
    }

    static func authorize(
        draft: UserOperationDraft,
        callGasLimit: Data,
        verificationGasLimit: Data,
        maxPriorityFeePerGas: Data,
        maxFeePerGas: Data,
        expectedSignatureLength: Int,
        authorizationScope: WalletSignature.GasAuthorizationScope,
        feeQuote: ExecutionFeeQuote
    ) throws -> AuthorizedUserOperation {
        guard feeQuote.chainID == draft.chainId else {
            throw UserOperationBoundaryError.feeQuoteChainMismatch(
                expected: draft.chainId,
                actual: feeQuote.chainID
            )
        }
        let sender = try Data(hexString: draft.sender)
        let entryPoint = try Data(hexString: draft.entryPoint)
        guard sender.count == 20,
              entryPoint.count == 20,
              draft.nonce.count == 32,
              callGasLimit.count == 32,
              verificationGasLimit.count == 32,
              maxPriorityFeePerGas.count == 32,
              maxFeePerGas.count == 32
        else {
            throw WalletGasAuthorizationError.invalidInput
        }
        guard draft.gasPlan.paymasterAndData.isEmpty else {
            throw WalletGasAuthorizationError.paymasterNotSupported
        }

        let plan = try WalletSignature.authorizeUserOperationGasV1(
            sender: sender,
            nonce: draft.nonce,
            initCode: draft.initCode,
            callData: draft.callData,
            callGasLimit: callGasLimit,
            verificationGasLimit: verificationGasLimit,
            maxFeePerGas: maxFeePerGas,
            maxPriorityFeePerGas: maxPriorityFeePerGas,
            paymasterAndData: Data(),
            signatureLength: expectedSignatureLength,
            scope: authorizationScope
        )
        let authorizedDraft = draft.updatingGasPlan(
            UserOperationGasPlan(
                accountGasLimits: plan.accountGasLimits,
                preVerificationGas: plan.preVerificationGas,
                gasFees: plan.gasFees,
                paymasterAndData: Data()
            )
        )
        return try AuthorizedUserOperation(
            draft: authorizedDraft,
            expectedSignatureLength: plan.signatureLength,
            maxLiability: plan.maxLiability,
            gasPolicyVersion: plan.policyVersion,
            feeQuote: feeQuote
        )
    }

    private static func checkedPackedPair(
        high: Data,
        low: Data,
        highField: String,
        lowField: String
    ) throws -> Data {
        guard high.count == 32, low.count == 32 else {
            throw WalletGasAuthorizationError.invalidInput
        }
        guard high.prefix(16).allSatisfy({ $0 == 0 }) else {
            throw WalletGasAuthorizationError.entryPointWidth(field: highField)
        }
        guard low.prefix(16).allSatisfy({ $0 == 0 }) else {
            throw WalletGasAuthorizationError.entryPointWidth(field: lowField)
        }
        return Data(high.suffix(16)) + Data(low.suffix(16))
    }
}

/// A session-shaped operation may be discarded and rebuilt as an owner
/// operation only when the aggregate liability exceeds the session budget.
/// Field caps are identical for owner and session paths, so retrying those with
/// the owner would merely turn a hard policy rejection into biometric churn.
enum SessionGasAuthorizationFallback {
    static func requiresFreshOwnerDraft(
        after error: Error,
        hadSessionPlan: Bool
    ) -> Bool {
        guard hadSessionPlan,
              let gasError = error as? WalletGasAuthorizationError,
              case let .capExceeded(field) = gasError
        else {
            return false
        }
        return field == "maximum gas liability"
    }
}

enum FeeAuthorizationRefreshPolicy {
    static func shouldRefresh(after error: Error) -> Bool {
        guard let feeError = error as? ExecutionFeeOracleError else {
            return false
        }
        switch feeError {
        case .staleQuote, .headAdvancedTooFar:
            return true
        default:
            return false
        }
    }
}

enum GasAuthorizationPresentation {
    private static let maximumActionCharacters = 120

    static func ownerSigningReason(
        action: String,
        maximumLiability: Data
    ) -> String {
        let amount = WeiFormatter.ethUpperBoundDisplayString(
            fromHexWei: "0x" + maximumLiability.hexEncodedString
        )
        let normalizedAction = action
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let boundedAction = String(normalizedAction.prefix(maximumActionCharacters))
        let actionSuffix = boundedAction.isEmpty ? "" : " \(boundedAction)."
        // Put the security-sensitive ceiling first. macOS may visually truncate a
        // long authentication reason, so an untrusted recipient label must never
        // be able to push the maximum fee out of view.
        return "Maximum network fee: \(amount).\(actionSuffix)"
    }
}
