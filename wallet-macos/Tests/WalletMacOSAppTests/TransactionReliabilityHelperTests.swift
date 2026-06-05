import Foundation
import Testing
@testable import WalletMacOSApp
@testable import WalletToolLayer

private func record(_ hash: String, status: WalletTransactionStatus = .submitted) -> WalletTransactionRecord {
    WalletTransactionRecord(
        chainID: 1,
        chainName: "Ethereum Mainnet",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        operation: .transfer,
        status: status,
        userOpHash: hash
    )
}

private func receipt(_ hash: String, success: Bool, tentative: Bool) -> WalletNodeClient.UserOperationReceipt {
    WalletNodeClient.UserOperationReceipt(
        userOpHash: hash,
        txHash: "0xtx",
        success: success,
        actualGasCost: nil,
        actualGasUsed: nil,
        revertReason: nil,
        tentative: tentative,
        invalidated: false
    )
}

private func userOpStatus(
    _ hash: String,
    status: String,
    lastError: String? = nil
) -> WalletNodeClient.UserOperationStatus {
    WalletNodeClient.UserOperationStatus(
        userOpHash: hash,
        status: status,
        lastError: lastError,
        createdAt: 1,
        updatedAt: 2
    )
}

@Test func gateAllowsChangesWhenNoOperationInFlight() {
    #expect(NetworkSettingsGate.allowed(
        isBootstrapping: false,
        isRunningDemo: false,
        isRefreshingBalance: false,
        isBuildingUserOperation: false,
        isSendingUserOperation: false
    ))
}

@Test func gateBlocksOnlyDuringSubmission() {
    #expect(NetworkSettingsGate.allowed(
        isBootstrapping: false,
        isRunningDemo: false,
        isRefreshingBalance: false,
        isBuildingUserOperation: false,
        isSendingUserOperation: true
    ) == false)
}

@Test func gateBlocksWhileBuildingOrBootstrapping() {
    #expect(NetworkSettingsGate.allowed(
        isBootstrapping: true,
        isRunningDemo: false,
        isRefreshingBalance: false,
        isBuildingUserOperation: false,
        isSendingUserOperation: false
    ) == false)
    #expect(NetworkSettingsGate.allowed(
        isBootstrapping: false,
        isRunningDemo: false,
        isRefreshingBalance: false,
        isBuildingUserOperation: true,
        isSendingUserOperation: false
    ) == false)
}

@Test func decisionAppliesVerifiedReceipt() {
    let outcome = ReconcileDecision.next(
        for: record("0xrec1"),
        receipt: receipt("0xrec1", success: true, tentative: false)
    )
    guard case .applyReceipt(let applied) = outcome else {
        Issue.record("expected applyReceipt")
        return
    }
    #expect(applied.userOpHash == "0xrec1")
}

@Test func decisionMarksPendingWhenNoReceipt() {
    #expect(ReconcileDecision.next(for: record("0xrec2"), receipt: nil) == .markPending)
}

@Test func decisionMarksDroppedWhenDaemonFailedWithDroppedDiagnostic() {
    #expect(ReconcileDecision.next(
        for: record("0xrec2"),
        receipt: nil,
        status: userOpStatus("0xrec2", status: "failed", lastError: "auto_dropped_aged_no_receipt")
    ) == .markTerminal(.dropped, reason: "auto_dropped_aged_no_receipt"))
}

@Test func decisionMarksFailedWhenDaemonFailedWithoutDroppedDiagnostic() {
    #expect(ReconcileDecision.next(
        for: record("0xrec2"),
        receipt: nil,
        status: userOpStatus("0xrec2", status: "failed", lastError: "raw_transaction_first_submit_failed")
    ) == .markTerminal(.failed, reason: "raw_transaction_first_submit_failed"))
}

@Test func decisionKeepsPendingWhenDaemonStatusIsNonTerminal() {
    #expect(ReconcileDecision.next(
        for: record("0xrec2"),
        receipt: nil,
        status: userOpStatus("0xrec2", status: "submitted", lastError: "raw_transaction_first_submit_failed")
    ) == .markPending)
}

@Test func decisionKeepsTerminalRowWhenNoReceipt() {
    #expect(ReconcileDecision.next(for: record("0xrec2", status: .cancelled), receipt: nil) == .keep)
}

@Test func decisionAppliesTentativeReceiptToStore() {
    let outcome = ReconcileDecision.next(
        for: record("0xrec3"),
        receipt: receipt("0xrec3", success: true, tentative: true)
    )
    guard case .applyReceipt = outcome else {
        Issue.record("expected applyReceipt for tentative")
        return
    }
}

@MainActor
@Test func reconcilerBackoffDelaysAreMonotonicAndCapped() {
    let delays = (0..<8).map { AppModel.reconcilerDelay(forAttempt: $0) }
    for i in 1..<delays.count {
        #expect(delays[i] >= delays[i - 1])
    }
    #expect(delays.first == 2_000_000_000)
    #expect(delays.last == 30_000_000_000)
    #expect(AppModel.reconcilerDelay(forAttempt: 999) == 30_000_000_000)
}

@Test func loopStopsWhenNoPendingRows() {
    #expect(ReconcilerLoopStep.shouldContinue(pendingCount: 0) == false)
    #expect(ReconcilerLoopStep.shouldContinue(pendingCount: 3) == true)
}

@Test func loopAttemptResetsWhenDrained() {
    #expect(ReconcilerLoopStep.nextAttempt(current: 4, stillPending: false) == 0)
}

@Test func loopAttemptIncrementsWhileStillPending() {
    #expect(ReconcilerLoopStep.nextAttempt(current: 0, stillPending: true) == 1)
    #expect(ReconcilerLoopStep.nextAttempt(current: 4, stillPending: true) == 5)
}

@Test func automaticReconcilerSkipsOldUnfinalizedRecords() {
    let now = Date(timeIntervalSince1970: 10_000)
    var fresh = record("0xfresh", status: .pending)
    fresh.updatedAt = now.addingTimeInterval(-60)
    var old = record("0xold", status: .pending)
    old.updatedAt = now.addingTimeInterval(-3_600)
    var terminal = record("0xterminal", status: .included)
    terminal.updatedAt = now

    #expect(ReconcilerEligibility.shouldPoll(fresh, now: now, maxAge: 15 * 60))
    #expect(ReconcilerEligibility.shouldPoll(old, now: now, maxAge: 15 * 60) == false)
    #expect(ReconcilerEligibility.shouldPoll(terminal, now: now, maxAge: 15 * 60) == false)
}

@Test func warmupPolicyRetriesVerifiedReadStartupErrors() {
    #expect(WalletNodeWarmupRetryPolicy.isWarmupError(
        WalletNodeClient.ClientError.rpcError(
            method: "test",
            code: -32002,
            message: "Not ready: verified_reads_not_ready",
            reason: "verified_reads_not_ready"
        )
    ))
    #expect(WalletNodeWarmupRetryPolicy.isWarmupError(
        WalletNodeClient.ClientError.rpcError(
            method: "test",
            code: -32010,
            message: "Verified reads are stale",
            reason: "verified_reads_stale"
        )
    ))
    #expect(WalletNodeWarmupRetryPolicy.isWarmupError(
        WalletNodeClient.ClientError.rpcError(
            method: "test",
            code: -32002,
            message: "Not ready: state_override_smoke_pending",
            reason: "state_override_smoke_pending"
        )
    ))
}

@Test func warmupPolicyDoesNotRetryOperationalFailures() {
    #expect(WalletNodeWarmupRetryPolicy.isWarmupError(
        WalletNodeClient.ClientError.rpcError(
            method: "test",
            code: -32002,
            message: "Not ready: bundler_eoa_needs_topup",
            reason: "bundler_eoa_needs_topup"
        )
    ) == false)
    #expect(WalletNodeWarmupRetryPolicy.isWarmupError(
        WalletNodeClient.ClientError.rpcError(
            method: "test",
            code: -32009,
            message: "Insufficient smart account balance",
            reason: "gas_shortfall"
        )
    ) == false)
    #expect(WalletNodeWarmupRetryPolicy.isWarmupError(
        WalletNodeClient.ClientError.rpcError(
            method: "test",
            code: -32603,
            message: "Internal error",
            reason: nil
        )
    ) == false)
}

@Test func replacementFailurePolicyMarksRetiredRelayerFailuresTerminal() {
    let error = WalletNodeClient.ClientError.rpcError(
        method: "wallet_cancelPendingOperation",
        code: -32011,
        message: "Replacement not possible",
        reason: "bundler_account_lifecycle_not_signable"
    )

    #expect(ReplacementActionFailurePolicy.shouldMarkLocalHistoryFailed(error))
    #expect(ReplacementActionFailurePolicy.displayMessage(action: "Cancellation", error: error)
        == "Cancellation unavailable: the relayer key for that transaction is retired.")
}

@Test func replacementFailurePolicyDoesNotFinalizeMissingPendingTxFailures() {
    let error = WalletNodeClient.ClientError.rpcError(
        method: "wallet_cancelPendingOperation",
        code: -32011,
        message: "Replacement not possible",
        reason: "no_pending_bundler_transaction"
    )

    #expect(ReplacementActionFailurePolicy.shouldMarkLocalHistoryFailed(error) == false)
    #expect(ReplacementActionFailurePolicy.displayMessage(action: "Cancellation", error: error)
        == "Cancellation unavailable: wallet-node has no pending transaction to replace.")
}

@Test func relayerAddressCacheKeepsCaseOnlyMatches() {
    #expect(RelayerAddressCachePolicy.shouldUpdate(
        cached: "0xFEFB27836352D522404FC529327325D7E380B980",
        unlocked: "0xfefb27836352d522404fc529327325d7e380b980"
    ) == false)
}

@Test func relayerAddressCacheUpdatesStaleAddress() {
    #expect(RelayerAddressCachePolicy.shouldUpdate(
        cached: "0x122cbfd6b318e468625fa9f2264dc77d887b8393",
        unlocked: "0xfefb27836352d522404fc529327325d7e380b980"
    ))
}

@Test func relayerAddressCacheUpdatesMissingOrInvalidAddress() {
    #expect(RelayerAddressCachePolicy.shouldUpdate(
        cached: nil,
        unlocked: "0xfefb27836352d522404fc529327325d7e380b980"
    ))
    #expect(RelayerAddressCachePolicy.shouldUpdate(
        cached: "Not available",
        unlocked: "0xfefb27836352d522404fc529327325d7e380b980"
    ))
}

@Test func launchFailureGateBlocksOnlyUntilRetryAfter() {
    let now = Date(timeIntervalSince1970: 100)
    let retryAfter = Date(timeIntervalSince1970: 104)

    #expect(WalletNodeLaunchFailureGate.shouldBlockRetry(now: now, retryAfter: retryAfter))
    #expect(WalletNodeLaunchFailureGate.shouldBlockRetry(
        now: Date(timeIntervalSince1970: 104),
        retryAfter: retryAfter
    ) == false)
    #expect(WalletNodeLaunchFailureGate.retryAfter(now: now, cooldown: 4) == retryAfter)
}

@Test func bundlerSecretPromptReusePolicyUsesShortWindows() {
    let now = Date(timeIntervalSince1970: 200)
    let expiresAt = BundlerSecretPromptReusePolicy.expiry(now: now, ttl: 10)
    let retryAfter = BundlerSecretPromptReusePolicy.retryAfter(now: now, cooldown: 4)

    #expect(BundlerSecretPromptReusePolicy.shouldUseCached(
        now: Date(timeIntervalSince1970: 209),
        expiresAt: expiresAt
    ))
    #expect(BundlerSecretPromptReusePolicy.shouldUseCached(
        now: Date(timeIntervalSince1970: 210),
        expiresAt: expiresAt
    ) == false)
    #expect(retryAfter == Date(timeIntervalSince1970: 204))
}

@Test func clampPrefersHigherOptimisticNonce() {
    #expect(NonceClamp.effective(onChain: 5, optimistic: 7) == 7)
}

@Test func clampPrefersOnChainWhenItCaughtUp() {
    #expect(NonceClamp.effective(onChain: 8, optimistic: 7) == 8)
}

@Test func clampHandlesNilOptimistic() {
    #expect(NonceClamp.effective(onChain: 3, optimistic: nil) == 3)
}

@Test func nextOptimisticIsUsedPlusOne() {
    #expect(NonceClamp.next(after: 7) == 8)
}
