import Foundation
import WalletSignature

struct SessionUserOperationPlan: Equatable {
    let record: SessionRecord

    init?(record: SessionRecord) {
        guard record.hasUsableSessionSigningArtifacts,
              Self.isValidNonceKey192(record.installedOnChain ? record.nonceKeyDefault : record.nonceKeyEnable)
        else {
            return nil
        }
        self.record = record
    }

    var signatureMode: WalletSignature.SessionSignatureMode {
        record.installedOnChain ? .installed : .enable
    }

    var nonceKey192: Data {
        record.installedOnChain ? record.nonceKeyDefault : record.nonceKeyEnable
    }

    var signingContext: UserOperationSigning.SessionContext {
        UserOperationSigning.SessionContext(
            keyRef: record.sessionKeyRef,
            mode: signatureMode,
            enableData: record.installedOnChain ? Data() : record.enableData,
            selectorData: record.installedOnChain ? Data() : record.selectorData,
            enableSig: record.installedOnChain ? Data() : record.enableSig
        )
    }

    private static func isValidNonceKey192(_ nonceKey: Data) -> Bool {
        nonceKey.count == 24 || (nonceKey.count == 32 && nonceKey.prefix(8).allSatisfy { $0 == 0 })
    }
}

struct UserOperationBuildContext: Equatable {
    let isDeployed: Bool
    let sessionPlan: SessionUserOperationPlan?
}

enum SessionSigningAvailability {
    static func plan(
        settingsEnabled: Bool,
        sessionRecord: SessionRecord?,
        pendingRevokeRecords: [SessionRecord],
        intent: TransactionIntent,
        now: Date
    ) -> SessionUserOperationPlan? {
        guard settingsEnabled,
              let sessionRecord,
              !pendingRevokeRecords.contains(where: {
                  $0.chainId == sessionRecord.chainId && $0.permissionId == sessionRecord.permissionId
              }),
              let plan = SessionUserOperationPlan(record: sessionRecord)
        else {
            return nil
        }

        let context = SessionPolicyContext(
            sessionRecord: sessionRecord,
            now: now,
            recentSessionTransactionDates: []
        )
        guard SessionPolicyMirror.isWithinPolicy(
            intent: intent,
            config: sessionRecord.policyConfigSnapshot,
            context: context
        ) else {
            return nil
        }
        return plan
    }
}

struct UserOperationSignatureResult: Equatable {
    let userOpHash: Data
    let signature: Data
    let usedSession: Bool
}

enum UserOperationSigning {
    struct SessionContext: Equatable {
        let keyRef: String
        let mode: WalletSignature.SessionSignatureMode
        let enableData: Data
        let selectorData: Data
        let enableSig: Data
    }

    typealias PasskeySigner = (_ preimage: Data) throws -> SignatureComponents
    typealias PasskeyWrapper = (_ userOpHash: Data, _ signature: SignatureComponents) throws -> Data
    typealias SessionSecretReader = (_ keyRef: String) throws -> Data
    typealias SessionWrapper = (
        _ secret: Data,
        _ userOpHash: Data,
        _ mode: WalletSignature.SessionSignatureMode,
        _ enableData: Data,
        _ selectorData: Data,
        _ enableSig: Data
    ) throws -> Data

    static func signForSend(
        draft: UserOperationDraft,
        session: SessionContext?,
        passkeySigner: PasskeySigner,
        passkeyWrapper: PasskeyWrapper,
        sessionSecretReader: SessionSecretReader,
        sessionWrapper: SessionWrapper
    ) throws -> UserOperationSignatureResult {
        let userOpHash = try draft.userOpHash()

        if let session {
            let secret = try sessionSecretReader(session.keyRef)
            let signature = try sessionWrapper(
                secret,
                userOpHash,
                session.mode,
                session.enableData,
                session.selectorData,
                session.enableSig
            )
            return UserOperationSignatureResult(
                userOpHash: userOpHash,
                signature: signature,
                usedSession: true
            )
        }

        let preimage = try WalletSignature.computeSigningPreimage(userOpHash: userOpHash)
        let passkeySignature = try passkeySigner(preimage)
        return UserOperationSignatureResult(
            userOpHash: userOpHash,
            signature: try passkeyWrapper(userOpHash, passkeySignature),
            usedSession: false
        )
    }
}

private extension SessionRecord {
    var hasUsableSessionSigningArtifacts: Bool {
        guard !sessionKeyRef.isEmpty else {
            return false
        }
        if installedOnChain {
            return !nonceKeyDefault.isEmpty
        }
        return !nonceKeyEnable.isEmpty
            && !enableData.isEmpty
            && !selectorData.isEmpty
            && !enableSig.isEmpty
    }
}
