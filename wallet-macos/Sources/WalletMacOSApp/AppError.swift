import Foundation

enum AppError: LocalizedError {
    case bundlerNotConfigured
    case unsupportedBundlerEntryPoint
    case invalidCounterfactualAddress
    case invalidExecutionAddress
    case invalidHexString
    case invalidAmount
    case invalidPublicKeyFormat
    case invalidSignatureFormat
    case missingKeyReference
    case walletKeyRecoveryRequired(WalletKeyRecoveryReason)
    case missingEntitlement
    case localDaemonNotConfigured
    case localDaemonLaunchFailed(String)
    case localRelayerKeyMissing
    case localRelayerKeyAuthorizationFailed
    case modelNotInstalled
    case corruptedMetadataStore
    case unsupportedSigningAlgorithm
    case walletOperationInProgress
    case swapApprovalRequired(String)
    case invalidExecutionBatch
    case sessionKeysRequireDeployedAccount
    case sessionKeysNotEnabled
    case userOperationTerminal(String)
    case userOperationReceiptReverted(String)
    case userAuthorizationCancelled
    /// The app could not prove that the local relayer can afford this exact
    /// top-up operation. Thrown before authentication or signing.
    case bundlerRelayPreflightUnavailable(String)
    /// The live relayer balance is below the maximum outer-transaction cost
    /// for this finalized top-up. Thrown before authentication or signing.
    case bundlerRelayShortfall(BundlerRelayPrecheck.Report)
    /// The account cannot cover the locally authorized maximum UserOperation
    /// liability. Thrown before any owner or session signing key is accessed;
    /// `ChatIntentExecutionStatus.prefundShortfall(from:)` turns it into a
    /// recoverable card rather than a terminal failure.
    case prefundShortfall(PrefundPrecheck.Report)
    /// A native-value operation cannot be funded by the smart account after
    /// reserving the gas liability not covered by its EntryPoint deposit.
    /// Thrown before any signing key is accessed.
    case accountBalanceShortfall(PrefundPrecheck.AccountBalanceReport)

    var errorDescription: String? {
        switch self {
        case .bundlerNotConfigured:
            return "No hosted bundler is configured for the active chain."
        case .unsupportedBundlerEntryPoint:
            return "The configured bundler does not report support for the active EntryPoint."
        case .invalidCounterfactualAddress:
            return "The predicted Kernel account address is not a valid Ethereum address."
        case .invalidExecutionAddress:
            return "The provided transaction address is not a valid Ethereum address."
        case .invalidHexString:
            return "A configured hex string is invalid."
        case .invalidAmount:
            return "The provided ETH amount is not valid."
        case .invalidPublicKeyFormat:
            return "The loaded public key is not a valid P-256 x9.63 key."
        case .invalidSignatureFormat:
            return "The generated signature is not a valid P-256 signature."
        case .missingKeyReference:
            return "The Secure Enclave key reference is missing from Keychain."
        case let .walletKeyRecoveryRequired(reason):
            switch reason {
            case .missing:
                return "The wallet's Secure Enclave key is unavailable to this app. Reset local wallet to create a new identity and continue."
            case .mismatch:
                return "The Secure Enclave key does not match this wallet's saved identity. Reset local wallet to create a new identity and continue."
            }
        case .missingEntitlement:
            return "This Secure Enclave flow needs a signed macOS app bundle with an application identifier entitlement. Do not ad-hoc re-sign the app; use a properly signed packaged build, or open `LocalWallet.xcodeproj`, select a development team for `LocalWalletApp`, and run it from Xcode."
        case .localDaemonNotConfigured:
            return "The local wallet-node daemon endpoint is not configured."
        case let .localDaemonLaunchFailed(message):
            return message
        case .localRelayerKeyMissing:
            return "The active local relayer private key is missing from Keychain. The app will not generate a replacement during daemon launch."
        case .localRelayerKeyAuthorizationFailed:
            return "Authorization for the local relayer key failed, so it could not be created or unlocked. Retry and approve the Touch ID prompt, or use your login password when offered. A relayer key created before this Mac's Touch ID enrollment changed may need to be replaced from Settings."
        case .modelNotInstalled:
            return "The selected local model file is not installed."
        case .corruptedMetadataStore:
            return "The wallet metadata file could not be decoded."
        case .unsupportedSigningAlgorithm:
            return "The Secure Enclave key does not support the expected signing algorithm."
        case .walletOperationInProgress:
            return "Another wallet operation is already in progress."
        case .swapApprovalRequired(let token):
            return "\(token) approval is required before this swap can be submitted."
        case .invalidExecutionBatch:
            return "Batch execution needs at least one transaction."
        case .sessionKeysRequireDeployedAccount:
            return "Session keys can be enabled after the smart account is deployed. Send one passkey-authorized transaction first, then enable session keys."
        case .sessionKeysNotEnabled:
            return "Session keys are not enabled for the active account."
        case .userOperationTerminal(let message):
            return message
        case .userOperationReceiptReverted(let reason):
            return reason
        case .userAuthorizationCancelled:
            return "Local authorization was cancelled or failed, so the action was not performed."
        case .bundlerRelayPreflightUnavailable(let detail):
            return "\(detail) No transaction was signed. Retry after checking wallet-node and the active network. Funding actions stay hidden until the app verifies the relayer identity."
        case .bundlerRelayShortfall(let report):
            return """
            The local relayer holds \(WeiFormatter.ethDisplayString(fromHexWei: report.balanceWeiHex)), but this top-up can require up to \(WeiFormatter.ethDisplayString(fromHexWei: report.requiredBalanceWeiHex)) to relay. No transaction was signed. Add at least \(WeiFormatter.ethDisplayString(fromHexWei: report.deficitWeiHex)) from another wallet or the Sepolia faucet, then retry.
            """
        case let .prefundShortfall(report):
            // States the exact deficit rather than the daemon's
            // displayed_topup_minimum x1.2 figure (funding.rs:15): only one of the
            // two surfaces can be showing at a time, and duplicating that rule
            // here would be a second place to drift.
            return """
            This send needs \(WeiFormatter.ethDisplayString(fromHexWei: report.requiredPrefundWeiHex)) \
            held up front to cover \(report.effectiveCallGasLimit.formatted()) gas, and the account has \
            \(WeiFormatter.ethDisplayString(fromHexWei: report.availableWeiHex)) available. \
            Top up at least \(WeiFormatter.ethDisplayString(fromHexWei: report.deficitWeiHex)) and try again.
            """
        case let .accountBalanceShortfall(report):
            let callValue = WeiFormatter.ethDisplayString(fromHexWei: report.callValueWeiHex)
            let gasBalanceRequired = WeiFormatter.ethDisplayString(
                fromHexWei: report.gasBalanceRequiredWeiHex
            )
            let minimum = WeiFormatter.ethDisplayString(
                fromHexWei: report.minimumAccountBalanceWeiHex
            )
            let balance = WeiFormatter.ethDisplayString(fromHexWei: report.accountBalanceWeiHex)
            let deficit = WeiFormatter.ethDisplayString(fromHexWei: report.deficitWeiHex)
            if report.gasBalanceRequiredWeiHex == "0x" + String(repeating: "00", count: 32) {
                return "This send transfers \(callValue), but the smart account holds \(balance). Top up at least \(deficit) and try again. No transaction was signed."
            }
            return "This send needs \(minimum) in the smart account: \(callValue) to transfer plus \(gasBalanceRequired) for gas not covered by its EntryPoint deposit. The account holds \(balance). Top up at least \(deficit) and try again. No transaction was signed."
        }
    }
}
