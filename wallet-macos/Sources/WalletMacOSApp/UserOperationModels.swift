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
        WalletToken(chainID: 1, symbol: "ETH", name: "Ether", decimals: 18, kind: .native),
        WalletToken(chainID: 1, symbol: "WETH", name: "Wrapped Ether", decimals: 18, kind: .erc20(address: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")),
        WalletToken(chainID: 1, symbol: "USDC", name: "USD Coin", decimals: 6, kind: .erc20(address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")),
        WalletToken(chainID: 1, symbol: "USDT", name: "Tether USD", decimals: 6, kind: .erc20(address: "0xdAC17F958D2ee523a2206206994597C13D831ec7")),
        WalletToken(chainID: 1, symbol: "DAI", name: "Dai Stablecoin", decimals: 18, kind: .erc20(address: "0x6B175474E89094C44Da98b954EedeAC495271d0F")),
        WalletToken(chainID: 1, symbol: "WBTC", name: "Wrapped BTC", decimals: 8, kind: .erc20(address: "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599")),
        WalletToken(chainID: 1, symbol: "LINK", name: "ChainLink Token", decimals: 18, kind: .erc20(address: "0x514910771AF9Ca656af840dff83E8264EcF986CA")),
        WalletToken(chainID: 1, symbol: "UNI", name: "Uniswap", decimals: 18, kind: .erc20(address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984")),
        WalletToken(chainID: 1, symbol: "AAVE", name: "Aave", decimals: 18, kind: .erc20(address: "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9")),
        WalletToken(chainID: 1, symbol: "LDO", name: "Lido DAO", decimals: 18, kind: .erc20(address: "0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32")),

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
