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
    static let minimumBalanceDisplay = "0.005 ETH"
    static let recommendedBalanceDisplay = "0.01 ETH"
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

enum BundlerTopUpUIRoute: Equatable {
    case prefillComposer
    case externalFunding
    case retryOnly
}

/// The primary action shown on the bundler account card.
///
/// Legacy verification intentionally outranks every funding route. Until the
/// protected secret is explicitly verified and app-owned authority is established,
/// the daemon address is not a trusted top-up destination.
enum BundlerAccountActionRoute: Equatable {
    case verifyLegacyRelayer(LegacyRelayerMigrationCandidate)
    case prefillTopUp
    case externalFunding
    case retryStatus
}

/// App-owned authority available to the bundler account card.
///
/// A missing migration candidate does not prove that relayer authority exists.
/// Keeping unavailable, legacy, and verified states distinct makes it impossible
/// for a malformed or corrupt passive state to inherit a funding route.
enum BundlerAccountAuthorityState: Equatable {
    case unavailable
    case legacyVerification(LegacyRelayerMigrationCandidate)
    case verified(BundlerFundingState)
}

enum BundlerAccountActionPolicy {
    static func route(
        authority: BundlerAccountAuthorityState,
        forceExternalFunding: Bool
    ) -> BundlerAccountActionRoute {
        switch authority {
        case .unavailable:
            return .retryStatus
        case .legacyVerification(let migrationCandidate):
            return .verifyLegacyRelayer(migrationCandidate)
        case .verified(let fundingState):
            switch BundlerTopUpUI.route(
                fundingState: fundingState,
                forceExternalFunding: forceExternalFunding
            ) {
            case .prefillComposer:
                return .prefillTopUp
            case .externalFunding:
                return .externalFunding
            case .retryOnly:
                return .retryStatus
            }
        }
    }
}

enum BundlerTopUpUI {
    static let defaultPrompt = "Top up the bundler with 0.01 ETH"

    static func route(
        fundingState: BundlerFundingState,
        forceExternalFunding: Bool
    ) -> BundlerTopUpUIRoute {
        if forceExternalFunding {
            return .externalFunding
        }
        switch fundingState {
        case .kernelTopUpCandidate, .healthy:
            return .prefillComposer
        case .externalRequired:
            return .externalFunding
        case .checking, .unavailable:
            return .retryOnly
        }
    }

    static func draft(existing: String) -> String {
        defaultPrompt
    }
}

/// A live exact-cost preflight can require more than the coarse 0.005 ETH
/// readiness floor. Keep that requirement until a later verified balance read
/// proves the same relayer can afford it; a generic refresh must not send the
/// user back into an impossible Kernel-funded retry loop.
struct BundlerExternalFundingRequirement: Equatable {
    let identity: VerifiedRelayerIdentity
    let requiredBalanceWeiHex: String
    let balanceAtFailureWeiHex: String?
}

enum BundlerExternalFundingRequirementPolicy {
    static func shouldClear(
        _ requirement: BundlerExternalFundingRequirement,
        verifiedIdentity: VerifiedRelayerIdentity?,
        observedBalanceWeiHex: String?
    ) -> Bool {
        guard let verifiedIdentity else { return false }
        // A requirement for a retired relayer must never constrain its verified
        // replacement. An unverified mismatch reaches this method as nil and is
        // deliberately retained until verification succeeds.
        guard verifiedIdentity == requirement.identity else { return true }
        guard let observedBalanceWeiHex,
              let observed = BundlerFundingPolicy.quantity(observedBalanceWeiHex),
              let required = BundlerFundingPolicy.quantity(
                  requirement.requiredBalanceWeiHex
              ) else {
            return false
        }
        if !GasPricing.isWeiLessThan(observed, required) {
            return true
        }
        guard let balanceAtFailureWeiHex = requirement.balanceAtFailureWeiHex,
              let balanceAtFailure = BundlerFundingPolicy.quantity(
                  balanceAtFailureWeiHex
              ) else {
            return false
        }
        // Any confirmed increase means the user's external funding action moved
        // the balance. Re-run the exact live-cost check instead of pinning them
        // forever to a gas quote that may already have fallen.
        return GasPricing.isWeiLessThan(balanceAtFailure, observed)
    }
}
