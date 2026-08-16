import Foundation
import LocalAuthentication
import WalletSignature

struct OnboardingProvisioningResult {
    let kernelAccountAddress: String
    let bundlerIdentity: VerifiedRelayerIdentity
    let bundlerSecretRecord: BundlerSecretRecord
}

struct OnboardingProvisioningService {
    private let keyStore: KeyStore
    private let walletKeyValidator: WalletKeyValidator
    private let metadataStore: WalletMetadataStore
    private let settingsStore: OnboardingSettingsStore
    private let addressPredictor: KernelAccountAddressPredictor
    private let chain: ChainConfiguration

    init(
        keyStore: KeyStore = KeyStore(),
        metadataStore: WalletMetadataStore = WalletMetadataStore(),
        walletKeyValidator: WalletKeyValidator? = nil,
        settingsStore: OnboardingSettingsStore = OnboardingSettingsStore(),
        addressPredictor: KernelAccountAddressPredictor = KernelAccountAddressPredictor(),
        chain: ChainConfiguration = ChainConfiguration.ethereumSepolia
    ) {
        self.keyStore = keyStore
        self.walletKeyValidator = walletKeyValidator ?? WalletKeyValidator(keyStore: keyStore)
        self.metadataStore = metadataStore
        self.settingsStore = settingsStore
        self.addressPredictor = addressPredictor
        self.chain = chain
    }

    func createOrLoadIdentity(
        authenticationContext: LAContext? = nil
    ) throws -> OnboardingProvisioningResult {
        let wallet = try createOrLoadWalletRecord()
        let bundler = try createOrLoadBundlerIdentity(
            authenticationContext: authenticationContext
        )

        return OnboardingProvisioningResult(
            kernelAccountAddress: wallet.kernelAccountAddress ?? "Unavailable",
            bundlerIdentity: bundler.identity,
            bundlerSecretRecord: bundler.record
        )
    }

    /// Confirms that registration still names the exact immutable Keychain
    /// item selected during provisioning. This reads public item attributes
    /// only and therefore never triggers device-owner authentication.
    func verifyPersistedBundlerIdentity(
        _ expected: VerifiedRelayerIdentity
    ) throws -> VerifiedRelayerIdentity {
        guard let persisted = try BundlerKeyStore.shared.verifiedIdentity(
            forKeyRef: expected.keyRef
        ) else {
            throw AppError.localRelayerKeyMissing
        }
        guard persisted == expected else {
            throw VerifiedRelayerIdentity.ValidationError.storedIdentityMismatch
        }
        return persisted
    }

    private func createOrLoadWalletRecord() throws -> WalletRecord {
        let now = Date()

        if let existing = try metadataStore.load() {
            switch try walletKeyValidator.validate(existing) {
            case .available:
                break
            case let .recoveryRequired(reason):
                throw AppError.walletKeyRecoveryRequired(reason)
            }

            let coordinates = PublicKeyCoordinates(x: existing.pubkeyX, y: existing.pubkeyY)
            let predictedAddress = try addressPredictor.predictedAddress(
                chain: chain,
                publicKey: coordinates,
                authenticatorIdHash: existing.authenticatorIdHash,
                salt: existing.kernelSalt
            )

            let refreshed = WalletRecord(
                walletId: existing.walletId,
                keyTag: existing.keyTag,
                pubkeyX: existing.pubkeyX,
                pubkeyY: existing.pubkeyY,
                chainId: chain.id,
                kernelAccountAddress: predictedAddress,
                authenticatorIdHash: existing.authenticatorIdHash,
                kernelSalt: existing.kernelSalt,
                sessionRecords: existing.sessionRecords,
                isDeployed: existing.isDeployed,
                createdAt: existing.createdAt,
                updatedAt: now
            )
            try metadataStore.save(refreshed)
            return refreshed
        }

        let coordinates = try keyStore.createOrLoadPublicKeyCoordinates()
        let authenticatorIdHash = KernelAccountAddressPredictor.defaultAuthenticatorIdHash
        let kernelSalt = KernelAccountAddressPredictor.defaultSalt
        let predictedAddress = try addressPredictor.predictedAddress(
            chain: chain,
            publicKey: coordinates,
            authenticatorIdHash: authenticatorIdHash,
            salt: kernelSalt
        )

        let created = WalletRecord(
            walletId: UUID(),
            keyTag: keyStore.keyTag,
            pubkeyX: coordinates.x,
            pubkeyY: coordinates.y,
            chainId: chain.id,
            kernelAccountAddress: predictedAddress,
            authenticatorIdHash: authenticatorIdHash,
            kernelSalt: kernelSalt,
            isDeployed: false,
            createdAt: now,
            updatedAt: now
        )
        try metadataStore.save(created)
        return created
    }

    private func createOrLoadBundlerIdentity(
        authenticationContext: LAContext?
    ) throws -> (
        identity: VerifiedRelayerIdentity,
        record: BundlerSecretRecord
    ) {
        let keyRef = settingsStore.bundlerKeyRef(chainId: chain.id) ?? "bundler-eoa:default:\(chain.id):1"
        settingsStore.setBundlerKeyRef(keyRef, chainId: chain.id)

        if try BundlerKeyStore.shared.verifiedIdentity(forKeyRef: keyRef) != nil {
            // This is reached only from the explicit Create Keys / Retry action.
            // Reading the protected value proves the stored public metadata still
            // matches the secret before wallet-node is allowed to register it.
            let record = try BundlerKeyStore.shared.read(
                keyRef: keyRef,
                reason: "Finish setting up the local relayer",
                authenticationContext: authenticationContext
            )
            let identity = try VerifiedRelayerIdentity.derive(
                keyRef: record.keyRef,
                secret: record.secret
            )
            settingsStore.setBundlerAddress(identity.address, chainId: chain.id)
            return (identity, record)
        }

        let generated = try WalletSignature.generateBundlerSecret()
        switch try BundlerKeyStore.shared.addIfAbsent(
            keyRef: keyRef,
            secret: generated.secret
        ) {
        case .existing:
            // Another app instance won the atomic Keychain insert, or this is
            // a legacy item without public metadata. The explicit Create/Retry
            // action may authenticate to read that canonical secret.
            let record = try BundlerKeyStore.shared.read(
                keyRef: keyRef,
                reason: "Finish setting up the local relayer",
                authenticationContext: authenticationContext
            )
            let identity = try VerifiedRelayerIdentity.derive(
                keyRef: record.keyRef,
                secret: record.secret
            )
            settingsStore.setBundlerAddress(identity.address, chainId: chain.id)
            return (identity, record)
        case .inserted:
            // The winning process already knows the exact bytes atomically
            // stored in Keychain. Avoid an unnecessary biometric prompt.
            let record = BundlerSecretRecord(keyRef: keyRef, secret: generated.secret)
            let identity = try VerifiedRelayerIdentity.derive(
                keyRef: keyRef,
                secret: generated.secret
            )
            settingsStore.setBundlerAddress(identity.address, chainId: chain.id)
            return (identity, record)
        }
    }

}
