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

/// The only UserOperation representation accepted by submission transports.
/// Its fileprivate initializer makes the signing boundary the only production
/// code that can mint one.
struct SignedUserOperation: Equatable {
    let operation: AuthorizedUserOperation
    let userOpHash: Data
    let signature: Data
    let usedSession: Bool

    var draft: UserOperationDraft {
        operation.draft
    }

    var userOpHashHex: String {
        "0x" + userOpHash.hexEncodedString
    }

    func validatingReturnedHash(_ returnedHash: String) throws -> String {
        guard returnedHash.caseInsensitiveCompare(userOpHashHex) == .orderedSame else {
            throw UserOperationBoundaryError.returnedHashMismatch(
                expected: userOpHashHex,
                actual: returnedHash
            )
        }
        return userOpHashHex
    }

    fileprivate init(
        operation: AuthorizedUserOperation,
        signature: Data,
        usedSession: Bool
    ) throws {
        guard signature.count == operation.expectedSignatureLength else {
            throw UserOperationBoundaryError.signatureLengthMismatch(
                expected: operation.expectedSignatureLength,
                actual: signature.count
            )
        }
        self.operation = operation
        self.userOpHash = try operation.draft.userOpHash()
        self.signature = signature
        self.usedSession = usedSession
    }
}

/// The final boundary between a signed UserOperation and any submission
/// transport. Authentication can outlive the fee quote that was checked before
/// signing, so every transport attempt must re-read the independent execution
/// head and validate wall-clock freshness after that read completes.
enum UserOperationSubmission {
    @MainActor
    static func submit(
        operation: SignedUserOperation,
        rpcURL: URL,
        expectedChainID: UInt64,
        oracle: ExecutionFeeOracle = ExecutionFeeOracle(),
        now: () -> Date = Date.init,
        transport: (SignedUserOperation) async throws -> String
    ) async throws -> String {
        let quote = operation.operation.feeQuote
        guard quote.chainID == expectedChainID else {
            throw ExecutionFeeOracleError.wrongChain(
                expected: expectedChainID,
                actual: quote.chainID
            )
        }

        let currentBlockNumber = try await oracle.currentBlockNumber(
            rpcURL: rpcURL,
            expectedChainID: expectedChainID
        )
        try quote.validateFreshness(
            now: now(),
            currentBlockNumber: currentBlockNumber
        )
        return try await transport(operation)
    }
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
        operation: AuthorizedUserOperation,
        currentBlockNumber: UInt64,
        now: Date = Date(),
        session: SessionContext?,
        passkeySigner: PasskeySigner,
        passkeyWrapper: PasskeyWrapper,
        sessionSecretReader: SessionSecretReader,
        sessionWrapper: SessionWrapper
    ) throws -> SignedUserOperation {
        // This check is deliberately before hashing, key reads, and every signer
        // callback. A quote that aged while the relayer was unlocking or Touch ID
        // was on screen must be rebuilt, never signed optimistically.
        try operation.feeQuote.validateFreshness(
            now: now,
            currentBlockNumber: currentBlockNumber
        )
        let userOpHash = try operation.draft.userOpHash()

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
            return try SignedUserOperation(
                operation: operation,
                signature: signature,
                usedSession: true
            )
        }

        let preimage = try WalletSignature.computeSigningPreimage(userOpHash: userOpHash)
        let passkeySignature = try passkeySigner(preimage)
        return try SignedUserOperation(
            operation: operation,
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
