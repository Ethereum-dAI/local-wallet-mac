import Foundation
import WalletSignature

struct OnboardingProvisioningResult {
    let kernelAccountAddress: String
    let bundlerAddress: String
}

struct OnboardingProvisioningService {
    private let keyStore: KeyStore
    private let metadataStore: WalletMetadataStore
    private let settingsStore: OnboardingSettingsStore
    private let addressPredictor: KernelAccountAddressPredictor
    private let chain: ChainConfiguration

    init(
        keyStore: KeyStore = KeyStore(),
        metadataStore: WalletMetadataStore = WalletMetadataStore(),
        settingsStore: OnboardingSettingsStore = OnboardingSettingsStore(),
        addressPredictor: KernelAccountAddressPredictor = KernelAccountAddressPredictor(),
        chain: ChainConfiguration = ChainConfiguration.ethereumSepolia
    ) {
        self.keyStore = keyStore
        self.metadataStore = metadataStore
        self.settingsStore = settingsStore
        self.addressPredictor = addressPredictor
        self.chain = chain
    }

    func createOrLoadIdentity() throws -> OnboardingProvisioningResult {
        let wallet = try createOrLoadWalletRecord()
        let bundlerAddress = try createOrLoadBundlerAddress()

        return OnboardingProvisioningResult(
            kernelAccountAddress: wallet.kernelAccountAddress ?? "Unavailable",
            bundlerAddress: bundlerAddress
        )
    }

    private func createOrLoadWalletRecord() throws -> WalletRecord {
        let now = Date()

        if let existing = try metadataStore.load(), existing.keyTag == keyStore.keyTag {
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

        let coordinates = try keyStore.publicKeyCoordinates()
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

    private func createOrLoadBundlerAddress() throws -> String {
        let keyRef = settingsStore.bundlerKeyRef ?? "bundler-eoa:default:\(chain.id):1"
        settingsStore.bundlerKeyRef = keyRef

        if try BundlerKeyStore.shared.hasKey(forKeyRef: keyRef), let cachedAddress = settingsStore.bundlerAddress {
            return cachedAddress
        }

        if try BundlerKeyStore.shared.hasKey(forKeyRef: keyRef) {
            let record = try BundlerKeyStore.shared.read(
                keyRef: keyRef,
                reason: "Show the local bundler address"
            )
            let addressData = try WalletSignature.bundlerAddress(fromSecret: record.secret)
            let address = "0x" + addressData.hexEncodedString
            settingsStore.bundlerAddress = address
            return address
        }

        let generated = try WalletSignature.generateBundlerSecret()
        try BundlerKeyStore.shared.add(keyRef: keyRef, secret: generated.secret)
        let address = "0x" + generated.address.hexEncodedString
        settingsStore.bundlerAddress = address
        return address
    }

}
