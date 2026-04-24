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
    case metadataKeyMismatch
    case corruptedMetadataStore
    case unsupportedSigningAlgorithm

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
            return "This Secure Enclave flow needs a signed macOS app bundle with Keychain access entitlements. Use the packaged app release, or open `LocalWallet.xcodeproj`, select a development team for `LocalWalletApp`, and run it from Xcode instead of `swift run`."
        case .metadataKeyMismatch:
            return "Stored wallet metadata does not match the loaded Secure Enclave key."
        case .corruptedMetadataStore:
            return "The wallet metadata file could not be decoded."
        case .unsupportedSigningAlgorithm:
            return "The Secure Enclave key does not support the expected signing algorithm."
        }
    }
}
