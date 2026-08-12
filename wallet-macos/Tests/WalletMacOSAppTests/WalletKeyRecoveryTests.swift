import Foundation
import Testing
@testable import WalletMacOSApp

private func recoveryRecord(
    keyTag: String = "wallet-key",
    coordinates: PublicKeyCoordinates = PublicKeyCoordinates(
        x: Data(repeating: 0x11, count: 32),
        y: Data(repeating: 0x22, count: 32)
    )
) -> WalletRecord {
    WalletRecord(
        walletId: UUID(),
        keyTag: keyTag,
        pubkeyX: coordinates.x,
        pubkeyY: coordinates.y,
        chainId: ChainConfiguration.ethereumSepolia.id,
        kernelAccountAddress: "0x1111111111111111111111111111111111111111",
        isDeployed: false,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Test func validatorAcceptsTheMatchingAccessibleKey() throws {
    let coordinates = PublicKeyCoordinates(
        x: Data(repeating: 0x11, count: 32),
        y: Data(repeating: 0x22, count: 32)
    )
    let validator = WalletKeyValidator(currentKeyTag: "wallet-key") { coordinates }

    #expect(try validator.validate(recoveryRecord(coordinates: coordinates)) == .available)
}

@Test func validatorReportsMissingWithoutCreatingAKey() throws {
    var loadCount = 0
    let validator = WalletKeyValidator(currentKeyTag: "wallet-key") {
        loadCount += 1
        return nil
    }

    #expect(try validator.validate(recoveryRecord()) == .recoveryRequired(.missing))
    #expect(loadCount == 1)
}

@Test func validatorRejectsAStoredTagFromAnotherSigningIdentity() throws {
    var loadedCoordinates = false
    let validator = WalletKeyValidator(currentKeyTag: "current-key") {
        loadedCoordinates = true
        return PublicKeyCoordinates(x: Data(), y: Data())
    }

    #expect(try validator.validate(recoveryRecord(keyTag: "old-key")) == .recoveryRequired(.mismatch))
    #expect(!loadedCoordinates)
}

@Test func validatorRejectsDifferentPublicKeyCoordinates() throws {
    let other = PublicKeyCoordinates(
        x: Data(repeating: 0x33, count: 32),
        y: Data(repeating: 0x44, count: 32)
    )
    let validator = WalletKeyValidator(currentKeyTag: "wallet-key") { other }

    #expect(try validator.validate(recoveryRecord()) == .recoveryRequired(.mismatch))
}

private func recoveryMetadataStore(record: WalletRecord) throws -> (WalletMetadataStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("wallet-key-recovery-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("wallet-record.json")
    let store = WalletMetadataStore(fileURL: url)
    try store.save(record)
    return (store, directory)
}

@Test @MainActor func bootstrapStopsBeforePresentingWalletWhenKeyIsMissing() throws {
    let record = recoveryRecord()
    let (metadataStore, directory) = try recoveryMetadataStore(record: record)
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaultsName = "WalletKeyRecoveryTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let validator = WalletKeyValidator(currentKeyTag: record.keyTag) { nil }
    let model = AppModel(
        metadataStore: metadataStore,
        settingsStore: DemoSettingsStore(defaults: defaults),
        onboardingSettingsStore: OnboardingSettingsStore(defaults: defaults),
        walletKeyValidator: validator,
        walletNodeClient: nil
    )

    model.bootstrap()

    #expect(model.walletRecoveryReason == .missing)
    #expect(model.walletRecord == nil)
    #expect(model.accountInspection == nil)
    #expect(try metadataStore.load() == record)
}

@Test func onboardingRefusesExistingMetadataWhenItsKeyIsMissing() throws {
    let record = recoveryRecord()
    let (metadataStore, directory) = try recoveryMetadataStore(record: record)
    defer { try? FileManager.default.removeItem(at: directory) }
    let validator = WalletKeyValidator(currentKeyTag: record.keyTag) { nil }
    let service = OnboardingProvisioningService(
        metadataStore: metadataStore,
        walletKeyValidator: validator
    )

    #expect(throws: AppError.self) {
        try service.createOrLoadIdentity()
    }
    #expect(try metadataStore.load() == record)
}

@Test func walletKeyRecoveryCopyIsActionableAndHonest() {
    let missing = AppError.walletKeyRecoveryRequired(.missing).localizedDescription
    let mismatch = AppError.walletKeyRecoveryRequired(.mismatch).localizedDescription

    #expect(missing.contains("Reset local wallet"))
    #expect(mismatch.contains("Reset local wallet"))
    #expect(!missing.lowercased().contains("recover the key"))
    #expect(!mismatch.lowercased().contains("recover the key"))
}

@Test func recoveryResetDestinationReturnsToOnboardingWithoutReplacementKeys() {
    #expect(WalletResetDestination.onboarding.recreatesRelayer == false)
    #expect(WalletResetDestination.onboarding.rebootstrapsWallet == false)
    #expect(WalletResetDestination.onboarding.marksOnboardingIncomplete)
}

@Test func dashboardResetDestinationKeepsExistingBehavior() {
    #expect(WalletResetDestination.dashboard.recreatesRelayer)
    #expect(WalletResetDestination.dashboard.rebootstrapsWallet)
    #expect(WalletResetDestination.dashboard.marksOnboardingIncomplete == false)
}
