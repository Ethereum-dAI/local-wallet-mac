import Foundation
import Testing
@testable import WalletMacOSApp

@Test func sessionRecordRoundTripsThroughWalletMetadataStore() throws {
    let fileURL = temporaryWalletRecordURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let sessionRecord = SessionRecord(
        chainId: 11_155_111,
        sessionKeyRef: "session:11155111:0xabc",
        permissionId: Data([0x44, 0x36, 0x6f, 0xcb]),
        enableSig: Data(repeating: 0xab, count: 65),
        enabledAt: now,
        expiresAt: now.addingTimeInterval(604_800),
        installedOnChain: false,
        policyConfigSnapshot: .default
    )
    let record = WalletRecord(
        walletId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        keyTag: "wallet-key",
        pubkeyX: Data(repeating: 0x01, count: 32),
        pubkeyY: Data(repeating: 0x02, count: 32),
        chainId: 11_155_111,
        kernelAccountAddress: "0x000000000000000000000000000000000000dEaD",
        authenticatorIdHash: Data(repeating: 0x03, count: 32),
        kernelSalt: Data(repeating: 0x04, count: 32),
        sessionRecords: [sessionRecord],
        isDeployed: true,
        createdAt: now,
        updatedAt: now
    )
    let store = WalletMetadataStore(fileURL: fileURL)

    try store.save(record)

    let loaded = try #require(try store.load())
    #expect(loaded == record)
}

@Test func walletRecordDecodesLegacyMetadataWithoutSessionRecords() throws {
    let fileURL = temporaryWalletRecordURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let pubkeyX = Data(repeating: 0x01, count: 32).base64EncodedString()
    let pubkeyY = Data(repeating: 0x02, count: 32).base64EncodedString()
    let authenticatorIdHash = Data(repeating: 0x03, count: 32).base64EncodedString()
    let kernelSalt = Data(repeating: 0x04, count: 32).base64EncodedString()
    let json = """
    {
      "walletId": "00000000-0000-0000-0000-000000000002",
      "keyTag": "wallet-key",
      "pubkeyX": "\(pubkeyX)",
      "pubkeyY": "\(pubkeyY)",
      "chainId": 11155111,
      "kernelAccountAddress": "0x000000000000000000000000000000000000dEaD",
      "authenticatorIdHash": "\(authenticatorIdHash)",
      "kernelSalt": "\(kernelSalt)",
      "isDeployed": false,
      "createdAt": "2026-06-10T18:00:00Z",
      "updatedAt": "2026-06-10T18:00:00Z"
    }
    """
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(json.utf8).write(to: fileURL)

    let record = try #require(try WalletMetadataStore(fileURL: fileURL).load())
    #expect(record.sessionRecords == [])
}

private func temporaryWalletRecordURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("wallet-metadata-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("wallet-record.json", isDirectory: false)
}
