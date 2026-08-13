import Foundation
import Testing
import WalletSignature
@testable import WalletMacOSApp

@Test func signForSendUsesSessionWrapperWithoutPasskeySigner() throws {
    let draft = try makeSigningDraft()
    let operation = try makeAuthorizedSigningOperation(draft: draft, signatureLength: 2)
    let record = makeSigningSessionRecord(installedOnChain: false)
    let plan = try #require(SessionUserOperationPlan(record: record))
    let expectedHash = try operation.draft.userOpHash()
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
        operation: operation,
        currentBlockNumber: signingBlockNumber,
        now: signingDate,
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
    #expect(result.operation == operation)
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
    let operation = try makeAuthorizedSigningOperation(draft: draft, signatureLength: 1)
    let expectedHash = try operation.draft.userOpHash()
    let expectedPreimage = try WalletSignature.computeSigningPreimage(userOpHash: expectedHash)
    var capturedPreimage: Data?
    var sessionSecretRead = false
    var capturedWrapperHash: Data?
    var capturedWrapperSignature: SignatureComponents?

    let result = try UserOperationSigning.signForSend(
        operation: operation,
        currentBlockNumber: signingBlockNumber,
        now: signingDate,
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
    #expect(result.operation == operation)
    #expect(result.signature == Data([0x70]))
    #expect(!result.usedSession)
    #expect(capturedPreimage == expectedPreimage)
    #expect(capturedWrapperHash == expectedHash)
    #expect(capturedWrapperSignature?.r == fakePasskeySignature().r)
    #expect(!sessionSecretRead)
}

@Test func authorizedUserOperationRejectsNonPositiveSignatureLength() throws {
    let draft = try makeSigningDraft()

    #expect(throws: UserOperationBoundaryError.invalidExpectedSignatureLength(0)) {
        _ = try makeAuthorizedSigningOperation(draft: draft, signatureLength: 0)
    }
}

@Test func authorizationRejectsFeeQuoteFromAnotherChain() throws {
    let draft = try makeSigningDraft()
    let baseFee = signingWord(1_000_000_000)
    let priorityFee = signingWord(1_000_000_000)
    let maxFee = try GasPricing.checkedAddWei(
        GasPricing.sixBlockBaseFeeCeiling(nextBlockBaseFeePerGas: baseFee),
        priorityFee
    )

    #expect(
        throws: UserOperationBoundaryError.feeQuoteChainMismatch(
            expected: draft.chainId,
            actual: 1
        )
    ) {
        _ = try UserOperationGasAuthorizer.authorize(
            draft: draft,
            callGasLimit: signingWord(125_000),
            verificationGasLimit: signingWord(250_000),
            maxPriorityFeePerGas: priorityFee,
            maxFeePerGas: maxFee,
            expectedSignatureLength: 2,
            authorizationScope: .owner,
            feeQuote: ExecutionFeeQuote(
                chainID: 1,
                blockNumber: signingBlockNumber,
                issuedAt: signingDate,
                nextBlockBaseFeePerGas: baseFee,
                medianPriorityFeePerGas: priorityFee,
                sixBlockMaxFeePerGas: maxFee
            )
        )
    }
}

@Test func authorizationRejectsPaymasterDataInsteadOfSilentlyStrippingIt() throws {
    let base = try makeSigningDraft()
    let draft = base.updatingGasPlan(
        UserOperationGasPlan(
            accountGasLimits: base.gasPlan.accountGasLimits,
            preVerificationGas: base.gasPlan.preVerificationGas,
            gasFees: base.gasPlan.gasFees,
            paymasterAndData: Data([0x01])
        )
    )

    #expect(throws: WalletGasAuthorizationError.paymasterNotSupported) {
        _ = try makeAuthorizedSigningOperation(draft: draft, signatureLength: 2)
    }
}

@Test func authorizationIgnoresEveryUntrustedRawGasField() throws {
    let base = try makeSigningDraft()
    let forged = base.updatingGasPlan(
        UserOperationGasPlan(
            accountGasLimits: Data(repeating: 0xff, count: 32),
            preVerificationGas: Data(repeating: 0xff, count: 32),
            gasFees: Data(repeating: 0xff, count: 32),
            paymasterAndData: Data()
        )
    )

    let cleanAuthorization = try makeAuthorizedSigningOperation(
        draft: base,
        signatureLength: 2
    )
    let forgedAuthorization = try makeAuthorizedSigningOperation(
        draft: forged,
        signatureLength: 2
    )

    #expect(forgedAuthorization == cleanAuthorization)
    #expect(forgedAuthorization.draft.gasPlan.preVerificationGas
        != Data(repeating: 0xff, count: 32))
}

@Test func maliciousDaemonLimitHintsRejectBeforeOwnerOrSessionSigningAndSubmission() throws {
    let allOnes = "0x" + String(repeating: "ff", count: 32)
    let cases: [(response: [String: Any], expected: WalletGasAuthorizationError)] = [
        (
            adversarialEstimateResponse(callGasLimit: signingQuantity(10_000_001)),
            .capExceeded(field: "callGasLimit")
        ),
        (
            adversarialEstimateResponse(verificationGasLimit: signingQuantity(5_000_001)),
            .capExceeded(field: "verificationGasLimit")
        ),
        (
            adversarialEstimateResponse(callGasLimit: allOnes),
            .entryPointWidth(field: "callGasLimit")
        ),
        (
            adversarialEstimateResponse(verificationGasLimit: allOnes),
            .entryPointWidth(field: "verificationGasLimit")
        ),
    ]

    for testCase in cases {
        for usesSession in [false, true] {
            let probe = SigningBoundaryProbe()
            do {
                _ = try signDecodedDaemonEstimate(
                    testCase.response,
                    usesSession: usesSession,
                    probe: probe
                )
                Issue.record("Hostile daemon gas hint crossed the signing boundary")
            } catch {
                #expect(error as? WalletGasAuthorizationError == testCase.expected)
            }
            #expect(probe.signingCallbackCalls == 0)
            #expect(probe.ownerSignerCalls == 0)
            #expect(probe.sessionKeyReads == 0)
            #expect(probe.submissionCalls == 0)
        }
    }
}

@Test func daemonPreVerificationGasAndPrefundNeverAlterTheSignedOperation() throws {
    let allOnes = "0x" + String(repeating: "ff", count: 32)
    let baseline = adversarialEstimateResponse(
        preVerificationGas: "0x0",
        requiredPrefund: "0x0"
    )
    let hostileResponses: [[String: Any]] = [
        adversarialEstimateResponse(
            preVerificationGas: signingQuantity(1_000_001),
            requiredPrefund: signingQuantity(UInt64.max)
        ),
        adversarialEstimateResponse(
            preVerificationGas: allOnes,
            requiredPrefund: allOnes
        ),
        adversarialEstimateResponse(
            preVerificationGas: allOnes,
            requiredPrefund: false
        ),
    ]

    for usesSession in [false, true] {
        let baselineProbe = SigningBoundaryProbe()
        let expected = try signDecodedDaemonEstimate(
            baseline,
            usesSession: usesSession,
            probe: baselineProbe
        )
        #expect(baselineProbe.submissionCalls == 1)

        for response in hostileResponses {
            let probe = SigningBoundaryProbe()
            let actual = try signDecodedDaemonEstimate(
                response,
                usesSession: usesSession,
                probe: probe
            )

            #expect(actual == expected)
            #expect(probe.submissionCalls == 1)
            #expect(probe.ownerSignerCalls == (usesSession ? 0 : 1))
            #expect(probe.sessionKeyReads == (usesSession ? 1 : 0))
        }
    }
}

@Test func hostileFeeValuesRejectBeforeOwnerOrSessionSigningAndSubmission() throws {
    let allOnes = Data(repeating: 0xff, count: 32)
    let cases: [(
        maxPriorityFeePerGas: Data,
        maxFeePerGas: Data,
        expected: WalletGasAuthorizationError
    )] = [
        (
            signingWord(1_000_000_000),
            signingWord(50_000_000_001),
            .capExceeded(field: "maxFeePerGas")
        ),
        (
            signingWord(5_000_000_001),
            signingWord(50_000_000_000),
            .capExceeded(field: "maxPriorityFeePerGas")
        ),
        (
            signingWord(1),
            allOnes,
            .entryPointWidth(field: "maxFeePerGas")
        ),
        (
            allOnes,
            signingWord(50_000_000_000),
            // This value is both over-width and above maxFee. The policy's
            // semantic ordering check intentionally rejects it first.
            .priorityFeeAboveMaxFee
        ),
        (
            signingWord(2),
            signingWord(1),
            .priorityFeeAboveMaxFee
        ),
    ]

    for testCase in cases {
        for usesSession in [false, true] {
            let probe = SigningBoundaryProbe()
            do {
                _ = try signDecodedDaemonEstimate(
                    adversarialEstimateResponse(),
                    usesSession: usesSession,
                    maxPriorityFeePerGas: testCase.maxPriorityFeePerGas,
                    maxFeePerGas: testCase.maxFeePerGas,
                    probe: probe
                )
                Issue.record("Hostile fee value crossed the signing boundary")
            } catch {
                #expect(error as? WalletGasAuthorizationError == testCase.expected)
            }
            #expect(probe.signingCallbackCalls == 0)
            #expect(probe.ownerSignerCalls == 0)
            #expect(probe.sessionKeyReads == 0)
            #expect(probe.submissionCalls == 0)
        }
    }
}

@Test func sessionBudgetOneWeiBelowLiabilityRejectsBeforeAnySigningAndSubmission() throws {
    let authorized = try authorizeDecodedDaemonEstimate(adversarialEstimateResponse())
    let oneWeiBelow = try GasPricing.checkedSubtractWei(
        authorized.maxLiability,
        signingWord(1)
    )

    for usesSession in [false, true] {
        let probe = SigningBoundaryProbe()
        do {
            _ = try signDecodedDaemonEstimate(
                adversarialEstimateResponse(),
                usesSession: usesSession,
                authorizationScope: .session(gasBudget: oneWeiBelow),
                probe: probe
            )
            Issue.record("A liability one wei above the local ceiling crossed the signing boundary")
        } catch {
            #expect(
                error as? WalletGasAuthorizationError
                    == .capExceeded(field: "maximum gas liability")
            )
        }
        #expect(probe.signingCallbackCalls == 0)
        #expect(probe.ownerSignerCalls == 0)
        #expect(probe.sessionKeyReads == 0)
        #expect(probe.submissionCalls == 0)
    }
}

@Test func signForSendRejectsPasskeySignatureLengthChangedAfterAuthorization() throws {
    let draft = try makeSigningDraft()
    let operation = try makeAuthorizedSigningOperation(draft: draft, signatureLength: 2)

    #expect(throws: UserOperationBoundaryError.signatureLengthMismatch(expected: 2, actual: 1)) {
        _ = try UserOperationSigning.signForSend(
            operation: operation,
            currentBlockNumber: signingBlockNumber,
            now: signingDate,
            session: nil,
            passkeySigner: { _ in fakePasskeySignature() },
            passkeyWrapper: { _, _ in Data([0x70]) },
            sessionSecretReader: { _ in Data(repeating: 0x11, count: 32) },
            sessionWrapper: { _, _, _, _, _, _ in Data([0xff]) }
        )
    }
}

@Test func signForSendRejectsSessionSignatureLengthChangedAfterAuthorization() throws {
    let draft = try makeSigningDraft()
    let operation = try makeAuthorizedSigningOperation(draft: draft, signatureLength: 66)
    let record = makeSigningSessionRecord(installedOnChain: true)
    let plan = try #require(SessionUserOperationPlan(record: record))

    #expect(throws: UserOperationBoundaryError.signatureLengthMismatch(expected: 66, actual: 65)) {
        _ = try UserOperationSigning.signForSend(
            operation: operation,
            currentBlockNumber: signingBlockNumber,
            now: signingDate,
            session: plan.signingContext,
            passkeySigner: { _ in fakePasskeySignature() },
            passkeyWrapper: { _, _ in Data(repeating: 0xaa, count: 66) },
            sessionSecretReader: { _ in Data(repeating: 0x11, count: 32) },
            sessionWrapper: { _, _, _, _, _, _ in Data(repeating: 0xbb, count: 65) }
        )
    }
}

@Test func signForSendRejectsStaleQuoteBeforeReadingAnySigningKey() throws {
    let draft = try makeSigningDraft()
    let operation = try makeAuthorizedSigningOperation(
        draft: draft,
        signatureLength: 2,
        issuedAt: signingDate.addingTimeInterval(-ExecutionFeeQuote.maximumAge - 1)
    )
    var signingCallbackCalled = false

    #expect(throws: ExecutionFeeOracleError.staleQuote(age: ExecutionFeeQuote.maximumAge + 1)) {
        _ = try UserOperationSigning.signForSend(
            operation: operation,
            currentBlockNumber: signingBlockNumber,
            now: signingDate,
            session: nil,
            passkeySigner: { _ in
                signingCallbackCalled = true
                return fakePasskeySignature()
            },
            passkeyWrapper: { _, _ in
                signingCallbackCalled = true
                return Data([0xaa, 0xbb])
            },
            sessionSecretReader: { _ in
                signingCallbackCalled = true
                return Data()
            },
            sessionWrapper: { _, _, _, _, _, _ in
                signingCallbackCalled = true
                return Data()
            }
        )
    }
    #expect(!signingCallbackCalled)
}

@Test func signForSendRejectsQuoteAfterThreeBlocksBeforeReadingAnySigningKey() throws {
    let draft = try makeSigningDraft()
    let operation = try makeAuthorizedSigningOperation(draft: draft, signatureLength: 2)
    var signingCallbackCalled = false

    #expect(
        throws: ExecutionFeeOracleError.headAdvancedTooFar(
            quoteBlock: signingBlockNumber,
            currentBlock: signingBlockNumber + 3
        )
    ) {
        _ = try UserOperationSigning.signForSend(
            operation: operation,
            currentBlockNumber: signingBlockNumber + 3,
            now: signingDate,
            session: nil,
            passkeySigner: { _ in
                signingCallbackCalled = true
                return fakePasskeySignature()
            },
            passkeyWrapper: { _, _ in
                signingCallbackCalled = true
                return Data([0xaa, 0xbb])
            },
            sessionSecretReader: { _ in
                signingCallbackCalled = true
                return Data()
            },
            sessionWrapper: { _, _, _, _, _, _ in
                signingCallbackCalled = true
                return Data()
            }
        )
    }
    #expect(!signingCallbackCalled)
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

@Test func sessionLiabilityCapRejectionRequiresFreshOwnerDraft() {
    #expect(SessionGasAuthorizationFallback.requiresFreshOwnerDraft(
        after: WalletGasAuthorizationError.capExceeded(field: "maximum gas liability"),
        hadSessionPlan: true
    ))
    #expect(!SessionGasAuthorizationFallback.requiresFreshOwnerDraft(
        after: WalletGasAuthorizationError.capExceeded(field: "callGasLimit"),
        hadSessionPlan: true
    ))
    #expect(!SessionGasAuthorizationFallback.requiresFreshOwnerDraft(
        after: WalletGasAuthorizationError.capExceeded(field: "maximum gas liability"),
        hadSessionPlan: false
    ))
}

@Test func sessionLiabilityAtCapSucceedsAndOneWeiOverUsesFreshOwnerShape() throws {
    let sessionPlan = try #require(
        SessionUserOperationPlan(record: makeSigningSessionRecord(installedOnChain: true))
    )
    let sessionNonce = Data(sessionPlan.nonceKey192.suffix(24))
        + Data.fromBigEndian(UInt64(7))
    let sessionDraft = try makeSigningDraft(nonce: sessionNonce)
    let ownerDraft = try makeSigningDraft()
    let baseline = try authorizeDecodedDaemonEstimate(
        adversarialEstimateResponse(),
        draft: sessionDraft
    )
    let exactSessionCap = baseline.maxLiability
    let oneWeiBelowLiability = try GasPricing.checkedSubtractWei(
        exactSessionCap,
        signingWord(1)
    )

    let exactProbe = SigningBoundaryProbe()
    let exactSigned = try signDecodedDaemonEstimate(
        adversarialEstimateResponse(),
        draft: sessionDraft,
        usesSession: true,
        authorizationScope: .session(gasBudget: exactSessionCap),
        probe: exactProbe
    )

    #expect(exactSigned.usedSession)
    #expect(exactSigned.draft.nonce == sessionNonce)
    #expect(exactSigned.operation.maxLiability == exactSessionCap)
    #expect(exactProbe.ownerSignerCalls == 0)
    #expect(exactProbe.sessionKeyReads == 1)
    #expect(exactProbe.submissionCalls == 1)

    let rejectedProbe = SigningBoundaryProbe()
    var rejection: Error?
    do {
        _ = try signDecodedDaemonEstimate(
            adversarialEstimateResponse(),
            draft: sessionDraft,
            usesSession: true,
            authorizationScope: .session(gasBudget: oneWeiBelowLiability),
            probe: rejectedProbe
        )
        Issue.record("A session liability one wei over its cap reached the signing boundary")
    } catch {
        rejection = error
    }

    #expect(
        rejection as? WalletGasAuthorizationError
            == .capExceeded(field: "maximum gas liability")
    )
    #expect(SessionGasAuthorizationFallback.requiresFreshOwnerDraft(
        after: try #require(rejection),
        hadSessionPlan: true
    ))
    #expect(rejectedProbe.signingCallbackCalls == 0)
    #expect(rejectedProbe.sessionKeyReads == 0)
    #expect(rejectedProbe.submissionCalls == 0)

    let ownerProbe = SigningBoundaryProbe()
    let ownerSigned = try signDecodedDaemonEstimate(
        adversarialEstimateResponse(),
        draft: ownerDraft,
        usesSession: false,
        authorizationScope: .owner,
        probe: ownerProbe
    )

    #expect(!ownerSigned.usedSession)
    #expect(ownerSigned.draft.nonce == Data(repeating: 0, count: 32))
    #expect(ownerSigned.draft.nonce != exactSigned.draft.nonce)
    #expect(ownerSigned.userOpHash != exactSigned.userOpHash)
    #expect(ownerProbe.ownerSignerCalls == 1)
    #expect(ownerProbe.sessionKeyReads == 0)
    #expect(ownerProbe.submissionCalls == 1)
}

@Test func feeAuthorizationRefreshesOnlyForNormalQuoteAging() {
    #expect(FeeAuthorizationRefreshPolicy.shouldRefresh(
        after: ExecutionFeeOracleError.staleQuote(age: 31)
    ))
    #expect(FeeAuthorizationRefreshPolicy.shouldRefresh(
        after: ExecutionFeeOracleError.headAdvancedTooFar(quoteBlock: 100, currentBlock: 103)
    ))
    #expect(!FeeAuthorizationRefreshPolicy.shouldRefresh(
        after: ExecutionFeeOracleError.wrongChain(expected: 1, actual: 2)
    ))
    #expect(!FeeAuthorizationRefreshPolicy.shouldRefresh(
        after: ExecutionFeeOracleError.quoteIssuedInFuture
    ))
}

@Test func ownerSigningReasonIncludesTheExactAuthorizedLiability() {
    let liability = Data([0x0a, 0xa8, 0x7b, 0xee, 0x53, 0x80, 0x00])
        .leftPadded(to: 32)
    #expect(
        GasAuthorizationPresentation.ownerSigningReason(
            action: "Send 1 ETH",
            maximumLiability: liability
        ) == "Maximum network fee: 0.003 ETH. Send 1 ETH."
    )
}

@Test func ownerSigningReasonNeverRoundsTheMaximumLiabilityDown() {
    let oneWei = Data.fromBigEndian(UInt64(1)).leftPadded(to: 32)
    #expect(
        GasAuthorizationPresentation.ownerSigningReason(
            action: "Send",
            maximumLiability: oneWei
        ) == "Maximum network fee: 0.000001 ETH. Send."
    )

    let justOverDisplayedBoundary = Data.fromBigEndian(UInt64(999_999_000_000_000_001))
        .leftPadded(to: 32)
    #expect(
        GasAuthorizationPresentation.ownerSigningReason(
            action: "Send",
            maximumLiability: justOverDisplayedBoundary
        ) == "Maximum network fee: 1 ETH. Send."
    )
}

@Test func ownerSigningReasonKeepsFeeVisibleBeforeBoundedUntrustedText() {
    let oneWei = Data.fromBigEndian(UInt64(1)).leftPadded(to: 32)
    let action = "  Send\n\tto " + String(repeating: "x", count: 500)
    let reason = GasAuthorizationPresentation.ownerSigningReason(
        action: action,
        maximumLiability: oneWei
    )

    #expect(reason.hasPrefix("Maximum network fee: 0.000001 ETH. Send to "))
    #expect(reason.count <= "Maximum network fee: 0.000001 ETH. ".count + 121)
    #expect(!reason.contains("\n"))
    #expect(!reason.contains("\t"))
}

private func makeSigningDraft(
    nonce: Data = Data(repeating: 0, count: 32)
) throws -> UserOperationDraft {
    UserOperationDraft(
        sender: "0x000000000000000000000000000000000000dEaD",
        nonce: nonce,
        initCode: Data(),
        callData: try Data(hexString: "e9ae5c53"),
        gasPlan: UserOperationGasPlan.placeholder,
        entryPoint: "0x0000000000000000000000000000000000000001",
        chainId: 11_155_111
    )
}

private let signingDate = Date(timeIntervalSince1970: 1_700_000_000)
private let signingBlockNumber: UInt64 = 100

private func makeAuthorizedSigningOperation(
    draft: UserOperationDraft,
    signatureLength: Int,
    issuedAt: Date = signingDate
) throws -> AuthorizedUserOperation {
    let baseFee = signingWord(1_000_000_000)
    let priorityFee = signingWord(1_000_000_000)
    let grownBaseFee = try GasPricing.sixBlockBaseFeeCeiling(
        nextBlockBaseFeePerGas: baseFee
    )
    let maxFee = try GasPricing.checkedAddWei(grownBaseFee, priorityFee)
    return try authorizeSigningOperation(
        draft: draft,
        callGasLimit: signingWord(125_000),
        verificationGasLimit: signingWord(250_000),
        maxPriorityFeePerGas: priorityFee,
        maxFeePerGas: maxFee,
        signatureLength: signatureLength,
        authorizationScope: .owner,
        issuedAt: issuedAt
    )
}

private func authorizeSigningOperation(
    draft: UserOperationDraft,
    callGasLimit: Data,
    verificationGasLimit: Data,
    maxPriorityFeePerGas: Data,
    maxFeePerGas: Data,
    signatureLength: Int,
    authorizationScope: WalletSignature.GasAuthorizationScope,
    issuedAt: Date = signingDate
) throws -> AuthorizedUserOperation {
    let quoteBaseFee = signingWord(1_000_000_000)
    let quotePriorityFee = signingWord(1_000_000_000)
    let quoteMaxFee = try GasPricing.checkedAddWei(
        GasPricing.sixBlockBaseFeeCeiling(nextBlockBaseFeePerGas: quoteBaseFee),
        quotePriorityFee
    )
    let quote = ExecutionFeeQuote(
        chainID: draft.chainId,
        blockNumber: signingBlockNumber,
        issuedAt: issuedAt,
        nextBlockBaseFeePerGas: quoteBaseFee,
        medianPriorityFeePerGas: quotePriorityFee,
        sixBlockMaxFeePerGas: quoteMaxFee
    )
    return try UserOperationGasAuthorizer.authorize(
        draft: draft,
        callGasLimit: callGasLimit,
        verificationGasLimit: verificationGasLimit,
        maxPriorityFeePerGas: maxPriorityFeePerGas,
        maxFeePerGas: maxFeePerGas,
        expectedSignatureLength: signatureLength,
        authorizationScope: authorizationScope,
        feeQuote: quote
    )
}

private final class SigningBoundaryProbe {
    var signingCallbackCalls = 0
    var ownerSignerCalls = 0
    var sessionKeyReads = 0
    var submissionCalls = 0
}

private func adversarialEstimateResponse(
    callGasLimit: String = signingQuantity(125_000),
    verificationGasLimit: String = signingQuantity(250_000),
    preVerificationGas: String = "0x0",
    requiredPrefund: Any? = "0x0"
) -> [String: Any] {
    var response: [String: Any] = [
        "callGasLimit": callGasLimit,
        "verificationGasLimit": verificationGasLimit,
        "preVerificationGas": preVerificationGas,
    ]
    if let requiredPrefund {
        response["requiredPrefund"] = requiredPrefund
    }
    return response
}

private func authorizeDecodedDaemonEstimate(
    _ response: [String: Any],
    draft: UserOperationDraft? = nil,
    maxPriorityFeePerGas: Data = signingWord(1_000_000_000),
    maxFeePerGas: Data = signingWord(10_000_000_000),
    authorizationScope: WalletSignature.GasAuthorizationScope = .owner
) throws -> AuthorizedUserOperation {
    let estimate = try WalletNodeClient.decodeGasEstimate(response)
    return try authorizeSigningOperation(
        draft: draft ?? makeSigningDraft(),
        callGasLimit: estimate.callGasLimit,
        verificationGasLimit: estimate.verificationGasLimit,
        maxPriorityFeePerGas: maxPriorityFeePerGas,
        maxFeePerGas: maxFeePerGas,
        signatureLength: 2,
        authorizationScope: authorizationScope
    )
}

private func signDecodedDaemonEstimate(
    _ response: [String: Any],
    draft: UserOperationDraft? = nil,
    usesSession: Bool,
    maxPriorityFeePerGas: Data = signingWord(1_000_000_000),
    maxFeePerGas: Data = signingWord(10_000_000_000),
    authorizationScope: WalletSignature.GasAuthorizationScope? = nil,
    probe: SigningBoundaryProbe
) throws -> SignedUserOperation {
    let effectiveAuthorizationScope = authorizationScope ?? (usesSession
        ? .session(gasBudget: signingWord(50_000_000_000_000_000))
        : .owner)
    let operation = try authorizeDecodedDaemonEstimate(
        response,
        draft: draft,
        maxPriorityFeePerGas: maxPriorityFeePerGas,
        maxFeePerGas: maxFeePerGas,
        authorizationScope: effectiveAuthorizationScope
    )
    let signed = try UserOperationSigning.signForSend(
        operation: operation,
        currentBlockNumber: signingBlockNumber,
        now: signingDate,
        session: usesSession
            ? UserOperationSigning.SessionContext(
                keyRef: "session-key:test",
                mode: .installed,
                enableData: Data(),
                selectorData: Data(),
                enableSig: Data()
            )
            : nil,
        passkeySigner: { _ in
            probe.signingCallbackCalls += 1
            probe.ownerSignerCalls += 1
            return fakePasskeySignature()
        },
        passkeyWrapper: { _, _ in
            probe.signingCallbackCalls += 1
            return Data([0x70, 0x71])
        },
        sessionSecretReader: { _ in
            probe.signingCallbackCalls += 1
            probe.sessionKeyReads += 1
            return Data(repeating: 0x11, count: 32)
        },
        sessionWrapper: { _, _, _, _, _, _ in
            probe.signingCallbackCalls += 1
            return Data([0x51, 0x52])
        }
    )
    probe.submissionCalls += 1
    return signed
}

private func signingQuantity(_ value: UInt64) -> String {
    "0x" + String(value, radix: 16)
}

private func signingWord(_ value: UInt64) -> Data {
    Data.fromBigEndian(value).leftPadded(to: 32)
}

private func makeSigningSessionRecord(installedOnChain: Bool) -> SessionRecord {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return SessionRecord(
        chainId: 11_155_111,
        sessionKeyRef: "session-key:11155111:0xdead",
        permissionId: Data([0x44, 0x36, 0x6f, 0xcb]),
        enableSig: Data(repeating: 0xee, count: 65),
        enabledAt: now,
        expiresAt: now.addingTimeInterval(TimeInterval(SessionPolicyConfig.defaultTTLSeconds)),
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
