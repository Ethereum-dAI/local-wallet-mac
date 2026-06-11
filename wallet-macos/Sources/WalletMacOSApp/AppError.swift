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
    case missingEntitlement
    case localDaemonNotConfigured
    case localDaemonLaunchFailed(String)
    case localRelayerKeyMissing
    case modelNotInstalled
    case metadataKeyMismatch
    case corruptedMetadataStore
    case unsupportedSigningAlgorithm
    case walletOperationInProgress
    case swapApprovalRequired(String)
    case invalidExecutionBatch
    case sessionKeysRequireDeployedAccount
    case sessionKeysNotEnabled

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
        case .missingEntitlement:
            return "This Secure Enclave flow needs a signed macOS app bundle with an application identifier entitlement. Do not ad-hoc re-sign the app; use a properly signed packaged build, or open `LocalWallet.xcodeproj`, select a development team for `LocalWalletApp`, and run it from Xcode."
        case .localDaemonNotConfigured:
            return "The local wallet-node daemon endpoint is not configured."
        case let .localDaemonLaunchFailed(message):
            return message
        case .localRelayerKeyMissing:
            return "The active local relayer private key is missing from Keychain. The app will not generate a replacement during daemon launch."
        case .modelNotInstalled:
            return "The selected local model file is not installed."
        case .metadataKeyMismatch:
            return "Stored wallet metadata does not match the loaded Secure Enclave key."
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
        }
    }
}
