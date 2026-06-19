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
        expiresAt: now.addingTimeInterval(TimeInterval(SessionPolicyConfig.defaultTTLSeconds)),
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

@Test func legacySessionRecordDecodesLastActivityFromEnabledAt() throws {
    let enabledAt = Date(timeIntervalSince1970: 1_780_000_000)
    let expiresAt = enabledAt.addingTimeInterval(TimeInterval(SessionPolicyConfig.defaultTTLSeconds))
    let json = """
    {
      "chainId": 11155111,
      "sessionKeyRef": "session:11155111:0xabc",
      "permissionId": "\(Data([0x44, 0x36, 0x6f, 0xcb]).base64EncodedString())",
      "enableSig": "\(Data(repeating: 0xab, count: 65).base64EncodedString())",
      "enabledAt": "\(ISO8601DateFormatter().string(from: enabledAt))",
      "expiresAt": "\(ISO8601DateFormatter().string(from: expiresAt))",
      "installedOnChain": false
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let sessionRecord = try decoder.decode(SessionRecord.self, from: Data(json.utf8))

    #expect(sessionRecord.lastActivityAt == enabledAt)
}

@Test func sessionLifecycleReportsFirstExpiredTimer() {
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    var record = testSessionRecord(now: now)

    #expect(SessionLifecycle.expiryReason(
        record: record,
        now: now.addingTimeInterval(TimeInterval(SessionPolicyConfig.defaultInactivityTimeoutSeconds) - 1)
    ) == nil)
    #expect(SessionLifecycle.expiryReason(
        record: record,
        now: now.addingTimeInterval(TimeInterval(SessionPolicyConfig.defaultInactivityTimeoutSeconds))
    ) == .inactivity)

    record.expiresAt = now.addingTimeInterval(600)
    #expect(SessionLifecycle.expiryReason(
        record: record,
        now: now.addingTimeInterval(600)
    ) == .duration)
}

@Test func walletRecordUpdatesSessionActivityTimestamp() {
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let activityAt = now.addingTimeInterval(120)
    let sessionRecord = testSessionRecord(now: now)
    let record = WalletRecord(
        walletId: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        keyTag: "wallet-key",
        pubkeyX: Data(repeating: 0x01, count: 32),
        pubkeyY: Data(repeating: 0x02, count: 32),
        chainId: 11_155_111,
        kernelAccountAddress: "0x000000000000000000000000000000000000dEaD",
        sessionRecords: [sessionRecord],
        isDeployed: true,
        createdAt: now,
        updatedAt: now
    )

    let refreshed = record.updatingSessionActivity(
        chainID: 11_155_111,
        activityAt: activityAt,
        isDeployed: true,
        updatedAt: activityAt
    )

    #expect(refreshed.sessionRecords.first?.lastActivityAt == activityAt)
    #expect(refreshed.updatedAt == activityAt)
}

private func temporaryWalletRecordURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("wallet-metadata-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("wallet-record.json", isDirectory: false)
}

private func testSessionRecord(now: Date) -> SessionRecord {
    SessionRecord(
        chainId: 11_155_111,
        sessionKeyRef: "session:11155111:0xabc",
        permissionId: Data([0x44, 0x36, 0x6f, 0xcb]),
        enableSig: Data(repeating: 0xab, count: 65),
        enabledAt: now,
        expiresAt: now.addingTimeInterval(TimeInterval(SessionPolicyConfig.defaultTTLSeconds)),
        lastActivityAt: now,
        installedOnChain: false,
        policyConfigSnapshot: .default
    )
}
