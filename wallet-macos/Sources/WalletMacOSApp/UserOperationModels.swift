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

/// A draft whose gas plan is complete, plus EntryPoint's prefund floor for it as
/// the daemon computed it. Kept together because the number is only meaningful
/// for the exact limits and fees in this draft.
struct EnrichedUserOperation: Equatable {
    let draft: UserOperationDraft
    let requiredPrefund: Data
    /// The fee baked into `draft` is the configured policy ceiling rather than a
    /// live spread (`GasPricing.isPolicyCeilingQuote`) — the live price is at or
    /// above the cap. A prefund floor derived from it is cap-driven, so surfaces
    /// should point at the cap before pointing at the balance.
    let feeQuoteAtPolicyCeiling: Bool
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
