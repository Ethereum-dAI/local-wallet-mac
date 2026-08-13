import Foundation

enum BundlerFundingState: Equatable {
    case checking
    case unavailable
    case externalRequired(balanceWeiHex: String?)
    case kernelTopUpCandidate(balanceWeiHex: String)
    case healthy(balanceWeiHex: String)

    var needsExternalFunding: Bool {
        if case .externalRequired = self { return true }
        return false
    }

    var isOperational: Bool {
        switch self {
        case .kernelTopUpCandidate, .healthy:
            return true
        case .checking, .unavailable, .externalRequired:
            return false
        }
    }

    var shouldOfferKernelTopUp: Bool {
        if case .kernelTopUpCandidate = self { return true }
        return false
    }
}

enum BundlerFundingPolicy {
    static let minimumBalanceWeiHex = "0x11c37937e08000"       // 0.005 ETH
    static let recommendedBalanceWeiHex = "0x2386f26fc10000"   // 0.01 ETH
    static let recommendedBalanceDisplay = "0.01 Sepolia ETH"
    static let sepoliaFaucetURL = URL(
        string: "https://cloud.google.com/application/web3/faucet/ethereum/sepolia"
    )!

    private static let minimum = quantity(minimumBalanceWeiHex)!
    private static let recommended = quantity(recommendedBalanceWeiHex)!

    static func fromObservedBalance(_ balanceWeiHex: String?) -> BundlerFundingState {
        guard let balanceWeiHex, let balance = quantity(balanceWeiHex) else {
            return .unavailable
        }
        if GasPricing.isWeiLessThan(balance, minimum) {
            return .externalRequired(balanceWeiHex: balanceWeiHex)
        }
        if GasPricing.isWeiLessThan(balance, recommended) {
            return .kernelTopUpCandidate(balanceWeiHex: balanceWeiHex)
        }
        return .healthy(balanceWeiHex: balanceWeiHex)
    }

    static func fromDaemonStatus(
        _ status: WalletNodeClient.RelayerStatus?
    ) -> BundlerFundingState {
        guard let status else { return .checking }
        if status.needsTopup {
            return .externalRequired(
                balanceWeiHex: quantity(status.balance) == nil ? nil : status.balance
            )
        }
        return fromObservedBalance(status.balance)
    }

    static func quantity(_ value: String) -> Data? {
        guard value.hasPrefix("0x") else { return nil }
        let body = value.dropFirst(2)
        guard body.isEmpty == false,
              body.count <= 64,
              body.allSatisfy(\.isHexDigit),
              body == "0" || body.first != "0",
              let parsed = try? Data.quantityString(value),
              parsed.count <= 32 else {
            return nil
        }
        return parsed.leftPadded(to: 32)
    }
}
