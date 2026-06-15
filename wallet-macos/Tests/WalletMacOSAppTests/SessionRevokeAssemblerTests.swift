import Foundation
import Testing
import WalletToolLayer
@testable import WalletMacOSApp

@Test func sessionRevokeExecutionTargetsAccountAndUsesPermissionId() throws {
    var capturedPermissionId: Data?
    let calldata = try Data(hexString: "deadbeef")
    let permissionId = Data([0xaa, 0xbb, 0xcc, 0xdd])

    let execution = try SessionRevokeAssembler.executionRequest(
        accountAddress: "0x000000000000000000000000000000000000dEaD",
        permissionId: permissionId,
        calldataBuilder: { permissionId in
            capturedPermissionId = permissionId
            return calldata
        }
    )

    #expect(capturedPermissionId == permissionId)
    #expect(execution.target == "0x000000000000000000000000000000000000dead")
    #expect(execution.value == Data(repeating: 0, count: 32))
    #expect(execution.callData == calldata)
}

@Test func sessionRevokeHistoryDraftIdentifiesRevoke() {
    let draft = SessionRevokeAssembler.historyDraft(
        accountAddress: "0x000000000000000000000000000000000000dEaD",
        validationNonce: 7
    )

    #expect(draft.operation == .batch)
    #expect(draft.amount == "1")
    #expect(draft.token == "session revoke")
    #expect(draft.counterparty == "0x000000000000000000000000000000000000dEaD")
    #expect(draft.detailsJSON == #"{"kind":"session_key_revoke","validationNonce":"7"}"#)
}

@Test func removingSessionRecordClearsOnlyTheMatchingChain() {
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let updatedAt = now.addingTimeInterval(100)
    let sepoliaRecord = makeRevokeSessionRecord(chainID: 11_155_111, keyRef: "session:sepolia")
    let mainnetRecord = makeRevokeSessionRecord(chainID: 1, keyRef: "session:mainnet")
    let record = WalletRecord(
        walletId: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        keyTag: "wallet-key",
        pubkeyX: Data(repeating: 0x01, count: 32),
        pubkeyY: Data(repeating: 0x02, count: 32),
        chainId: 11_155_111,
        kernelAccountAddress: "0x000000000000000000000000000000000000dEaD",
        authenticatorIdHash: Data(repeating: 0x03, count: 32),
        kernelSalt: Data(repeating: 0x04, count: 32),
        sessionRecords: [sepoliaRecord, mainnetRecord],
        isDeployed: true,
        createdAt: now,
        updatedAt: now
    )

    let refreshed = record.removingSessionRecord(
        chainID: 11_155_111,
        isDeployed: true,
        updatedAt: updatedAt
    )

    #expect(refreshed.sessionRecords == [mainnetRecord])
    #expect(refreshed.isDeployed)
    #expect(refreshed.createdAt == now)
    #expect(refreshed.updatedAt == updatedAt)
}

private func makeRevokeSessionRecord(chainID: UInt64, keyRef: String) -> SessionRecord {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return SessionRecord(
        chainId: chainID,
        sessionKeyRef: keyRef,
        permissionId: Data([0x44, 0x36, 0x6f, 0xcb]),
        enableSig: Data(repeating: 0xee, count: 65),
        enabledAt: now,
        expiresAt: now.addingTimeInterval(604_800),
        installedOnChain: true,
        validationNonce: 7,
        enableData: Data([0x01, 0x02]),
        selectorData: Data([0xe9, 0xae, 0x5c, 0x53]),
        nonceKeyDefault: Data(repeating: 0, count: 8) + Data(repeating: 0x11, count: 24),
        nonceKeyEnable: Data(repeating: 0, count: 8) + Data(repeating: 0x22, count: 24),
        policyConfigSnapshot: .default
    )
}
