import Foundation
import WalletSignature

// KernelAccountAddressPredictor is a narrow app-side adapter around the shared
// bridge logic for deterministic Kernel account address derivation.
struct KernelAccountAddressPredictor {
    static let defaultAuthenticatorIdHash = Data(repeating: 0, count: 32)
    static let defaultSalt = Data(repeating: 0, count: 32)

    func predictedAddress(
        chain: ChainConfiguration,
        publicKey: PublicKeyCoordinates,
        authenticatorIdHash: Data = defaultAuthenticatorIdHash,
        salt: Data = defaultSalt
    ) throws -> String {
        let predicted = try WalletSignature.predictKernelAccountAddress(
            factoryAddress: try Data(hexString: chain.kernel.factory),
            implementation: try Data(hexString: chain.kernel.implementation),
            webauthnValidator: try Data(hexString: chain.kernel.webAuthnValidator),
            pubKeyX: publicKey.x,
            pubKeyY: publicKey.y,
            authenticatorIdHash: authenticatorIdHash,
            salt: salt
        )

        guard predicted.count == 20 else {
            throw AppError.invalidCounterfactualAddress
        }

        return "0x" + predicted.hexEncodedString
    }
}
