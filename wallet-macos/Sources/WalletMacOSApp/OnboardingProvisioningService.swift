import Foundation
import LocalAuthentication
import WalletSignature

struct OnboardingProvisioningResult {
    let kernelAccountAddress: String
    let bundlerIdentity: VerifiedRelayerIdentity
    let bundlerSecretRecord: BundlerSecretRecord
}

enum OnboardingRelayerProvisioningError: Error, Equatable, LocalizedError {
    case journalHeadMismatch(expected: String, active: String?, pending: String?)
    case finalJournalReadbackMissing(UInt64)
    case finalAuthorityMismatch(String)

    var errorDescription: String? {
        switch self {
        case let .journalHeadMismatch(expected, active, pending):
            let activeDescription = active ?? "none"
            let pendingDescription = pending ?? "none"
            return "The relayer selection record does not match the registered key. Expected \(expected), active \(activeDescription), pending \(pendingDescription)."
        case .finalJournalReadbackMissing(let chainID):
            return "The relayer selection record could not be read back for chain \(chainID)."
        case .finalAuthorityMismatch(let keyRef):
            return "The registered relayer identity could not be verified for \(keyRef)."
        }
    }
}

struct OnboardingProvisioningService {
    private let keyStore: KeyStore
    private let walletKeyValidator: WalletKeyValidator
    private let metadataStore: WalletMetadataStore
    private let settingsStore: OnboardingSettingsStore
    private let addressPredictor: KernelAccountAddressPredictor
    private let chain: ChainConfiguration
    private let bundlerKeyStore: BundlerKeyStore
    private let relayerPublicIdentityStore: RelayerPublicIdentityStore
    private let relayerChainStateJournalStore: RelayerChainStateJournalStore
    private let generateBundlerSecret: @Sendable () throws -> Data

    init(
        keyStore: KeyStore = KeyStore(),
        metadataStore: WalletMetadataStore = WalletMetadataStore(),
        walletKeyValidator: WalletKeyValidator? = nil,
        settingsStore: OnboardingSettingsStore = OnboardingSettingsStore(),
        addressPredictor: KernelAccountAddressPredictor = KernelAccountAddressPredictor(),
        chain: ChainConfiguration = ChainConfiguration.ethereumSepolia,
        bundlerKeyStore: BundlerKeyStore = .shared,
        relayerPublicIdentityStore: RelayerPublicIdentityStore = .shared,
        relayerChainStateJournalStore: RelayerChainStateJournalStore = .shared,
        generateBundlerSecret: @escaping @Sendable () throws -> Data = {
            try WalletSignature.generateBundlerSecret().secret
        }
    ) {
        self.keyStore = keyStore
        self.walletKeyValidator = walletKeyValidator ?? WalletKeyValidator(keyStore: keyStore)
        self.metadataStore = metadataStore
        self.settingsStore = settingsStore
        self.addressPredictor = addressPredictor
        self.chain = chain
        self.bundlerKeyStore = bundlerKeyStore
        self.relayerPublicIdentityStore = relayerPublicIdentityStore
        self.relayerChainStateJournalStore = relayerChainStateJournalStore
        self.generateBundlerSecret = generateBundlerSecret
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

    /// Commits the daemon-verified identity to app-owned authority, then proves
    /// that the final journal head and immutable public record resolve back to
    /// that exact identity. This path is entirely passive and never reads the
    /// protected relayer secret.
    func finalizeRegisteredBundlerIdentity(
        _ expected: VerifiedRelayerIdentity
    ) throws -> VerifiedRelayerIdentity {
        let snapshot = try relayerChainStateJournalStore.snapshot(chainID: expected.chainID)
        if let snapshot {
            try requireExactHead(snapshot.head, expected: expected)
        } else {
            let genesis = try RelayerChainStateTransition.genesis(
                chainID: expected.chainID,
                activeKeyRef: expected.keyRef
            )
            let appended = try relayerChainStateJournalStore.append(genesis)
            guard appended == genesis else {
                throw OnboardingRelayerProvisioningError.finalAuthorityMismatch(expected.keyRef)
            }
        }

        guard let finalSnapshot = try relayerChainStateJournalStore.snapshot(
            chainID: expected.chainID
        ) else {
            throw OnboardingRelayerProvisioningError.finalJournalReadbackMissing(expected.chainID)
        }
        try requireExactHead(finalSnapshot.head, expected: expected)

        let authority = try RelayerIdentityAuthority.resolve(head: finalSnapshot.head) { keyRef in
            try relayerPublicIdentityStore.identity(forKeyRef: keyRef)
        }
        guard authority.active == expected, authority.pending == nil else {
            throw OnboardingRelayerProvisioningError.finalAuthorityMismatch(expected.keyRef)
        }
        return expected
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

    func createOrLoadBundlerIdentity(
        authenticationContext: LAContext?
    ) throws -> (
        identity: VerifiedRelayerIdentity,
        record: BundlerSecretRecord
    ) {
        let keyRef = settingsStore.bundlerKeyRef(chainId: chain.id) ?? "bundler-eoa:default:\(chain.id):1"
        settingsStore.setBundlerKeyRef(keyRef, chainId: chain.id)

        let generatedSecret = try generateBundlerSecret()
        switch try bundlerKeyStore.addIfAbsent(
            keyRef: keyRef,
            secret: generatedSecret
        ) {
        case .existing:
            // Another app instance won the atomic Keychain insert, or this is
            // a legacy item without public metadata. The explicit Create/Retry
            // action may authenticate to read that canonical secret.
            let record = try bundlerKeyStore.read(
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
            let record = BundlerSecretRecord(keyRef: keyRef, secret: generatedSecret)
            let identity = try VerifiedRelayerIdentity.derive(
                keyRef: keyRef,
                secret: generatedSecret
            )
            settingsStore.setBundlerAddress(identity.address, chainId: chain.id)
            return (identity, record)
        }
    }

    private func requireExactHead(
        _ head: RelayerChainState,
        expected: VerifiedRelayerIdentity
    ) throws {
        guard head.chainID == expected.chainID,
              head.activeKeyRef == expected.keyRef,
              head.pendingKeyRef == nil else {
            throw OnboardingRelayerProvisioningError.journalHeadMismatch(
                expected: expected.keyRef,
                active: head.activeKeyRef,
                pending: head.pendingKeyRef
            )
        }
    }

}
