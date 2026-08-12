import Foundation

enum WalletKeyRecoveryReason: Equatable {
    case missing
    case mismatch
}

enum WalletKeyValidationResult: Equatable {
    case available
    case recoveryRequired(WalletKeyRecoveryReason)
}

struct WalletKeyValidator {
    private let currentKeyTag: String
    private let loadCoordinates: () throws -> PublicKeyCoordinates?

    init(keyStore: KeyStore = KeyStore()) {
        self.init(currentKeyTag: keyStore.keyTag) {
            try keyStore.loadPublicKeyCoordinates()
        }
    }

    init(
        currentKeyTag: String,
        loadCoordinates: @escaping () throws -> PublicKeyCoordinates?
    ) {
        self.currentKeyTag = currentKeyTag
        self.loadCoordinates = loadCoordinates
    }

    func validate(_ record: WalletRecord) throws -> WalletKeyValidationResult {
        guard record.keyTag == currentKeyTag else {
            return .recoveryRequired(.mismatch)
        }
        guard let coordinates = try loadCoordinates() else {
            return .recoveryRequired(.missing)
        }
        return record.matches(coordinates)
            ? .available
            : .recoveryRequired(.mismatch)
    }
}
