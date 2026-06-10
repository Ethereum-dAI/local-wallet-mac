import Foundation
import Testing
import WalletSignature
@testable import WalletMacOSApp

@Test func signForSendUsesSessionWrapperWithoutPasskeySigner() throws {
    let draft = try makeSigningDraft()
    let record = makeSigningSessionRecord(installedOnChain: false)
    let plan = try #require(SessionUserOperationPlan(record: record))
    let expectedHash = try draft.userOpHash()
    var passkeyCalled = false
    var capturedKeyRef: String?
    var capturedSessionArgs: (
        secret: Data,
        hash: Data,
        mode: WalletSignature.SessionSignatureMode,
        enableData: Data,
        selectorData: Data,
        enableSig: Data
    )?

    let result = try UserOperationSigning.signForSend(
        draft: draft,
        session: plan.signingContext,
        passkeySigner: { _ in
            passkeyCalled = true
            return fakePasskeySignature()
        },
        passkeyWrapper: { _, _ in
            passkeyCalled = true
            return Data([0xff])
        },
        sessionSecretReader: { keyRef in
            capturedKeyRef = keyRef
            return Data(repeating: 0x44, count: 32)
        },
        sessionWrapper: { secret, hash, mode, enableData, selectorData, enableSig in
            capturedSessionArgs = (secret, hash, mode, enableData, selectorData, enableSig)
            return Data([0x51, 0x52])
        }
    )

    #expect(result.userOpHash == expectedHash)
    #expect(result.signature == Data([0x51, 0x52]))
    #expect(result.usedSession)
    #expect(!passkeyCalled)
    #expect(capturedKeyRef == record.sessionKeyRef)
    #expect(capturedSessionArgs?.secret == Data(repeating: 0x44, count: 32))
    #expect(capturedSessionArgs?.hash == expectedHash)
    #expect(capturedSessionArgs?.mode == .enable)
    #expect(capturedSessionArgs?.enableData == record.enableData)
    #expect(capturedSessionArgs?.selectorData == record.selectorData)
    #expect(capturedSessionArgs?.enableSig == record.enableSig)
}

@Test func signForSendFallsBackToPasskeyWhenSessionContextIsNil() throws {
    let draft = try makeSigningDraft()
    let expectedHash = try draft.userOpHash()
    let expectedPreimage = try WalletSignature.computeSigningPreimage(userOpHash: expectedHash)
    var capturedPreimage: Data?
    var sessionSecretRead = false
    var capturedWrapperHash: Data?
    var capturedWrapperSignature: SignatureComponents?

    let result = try UserOperationSigning.signForSend(
        draft: draft,
        session: nil,
        passkeySigner: { preimage in
            capturedPreimage = preimage
            return fakePasskeySignature()
        },
        passkeyWrapper: { userOpHash, signature in
            capturedWrapperHash = userOpHash
            capturedWrapperSignature = signature
            return Data([0x70])
        },
        sessionSecretReader: { _ in
            sessionSecretRead = true
            return Data(repeating: 0x11, count: 32)
        },
        sessionWrapper: { _, _, _, _, _, _ in
            sessionSecretRead = true
            return Data([0xff])
        }
    )

    #expect(result.userOpHash == expectedHash)
    #expect(result.signature == Data([0x70]))
    #expect(!result.usedSession)
    #expect(capturedPreimage == expectedPreimage)
    #expect(capturedWrapperHash == expectedHash)
    #expect(capturedWrapperSignature?.r == fakePasskeySignature().r)
    #expect(!sessionSecretRead)
}

@Test func sessionUserOperationPlanSelectsInstalledAndEnableArtifacts() throws {
    let enableRecord = makeSigningSessionRecord(installedOnChain: false)
    let installedRecord = makeSigningSessionRecord(installedOnChain: true)
    let enablePlan = try #require(SessionUserOperationPlan(record: enableRecord))
    let installedPlan = try #require(SessionUserOperationPlan(record: installedRecord))

    #expect(enablePlan.signatureMode == .enable)
    #expect(enablePlan.nonceKey192 == enableRecord.nonceKeyEnable)
    #expect(enablePlan.signingContext.enableData == enableRecord.enableData)
    #expect(installedPlan.signatureMode == .installed)
    #expect(installedPlan.nonceKey192 == installedRecord.nonceKeyDefault)
    #expect(installedPlan.signingContext.enableData.isEmpty)
}

private func makeSigningDraft() throws -> UserOperationDraft {
    UserOperationDraft(
        sender: "0x000000000000000000000000000000000000dEaD",
        nonce: Data(repeating: 0, count: 32),
        initCode: Data(),
        callData: try Data(hexString: "e9ae5c53"),
        gasPlan: UserOperationGasPlan.placeholder,
        entryPoint: "0x0000000000000000000000000000000000000001",
        chainId: 11_155_111
    )
}

private func makeSigningSessionRecord(installedOnChain: Bool) -> SessionRecord {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return SessionRecord(
        chainId: 11_155_111,
        sessionKeyRef: "session-key:11155111:0xdead",
        permissionId: Data([0x44, 0x36, 0x6f, 0xcb]),
        enableSig: Data(repeating: 0xee, count: 65),
        enabledAt: now,
        expiresAt: now.addingTimeInterval(604_800),
        installedOnChain: installedOnChain,
        validationNonce: 7,
        enableData: Data([0x01, 0x02]),
        selectorData: Data([0xe9, 0xae, 0x5c, 0x53]),
        nonceKeyDefault: Data(repeating: 0, count: 8) + Data(repeating: 0x11, count: 24),
        nonceKeyEnable: Data(repeating: 0, count: 8) + Data(repeating: 0x22, count: 24),
        policyConfigSnapshot: .default
    )
}

private func fakePasskeySignature() -> SignatureComponents {
    SignatureComponents(
        rawRepresentation: Data(repeating: 0xaa, count: 64),
        r: Data(repeating: 0xbb, count: 32),
        s: Data(repeating: 0x01, count: 32)
    )
}
