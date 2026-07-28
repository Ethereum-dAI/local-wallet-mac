import Foundation
import Testing
@testable import WalletMacOSApp

// Coverage for the token popover's intermittent "Unavailable" rows.
//
// Balance reads had no retry anywhere in WalletNodeClient, so a single transient 429 or
// timeout from the configured RPC stranded that row on "Unavailable" until the next
// refresh. Retry only what is actually transient — a bad address or a rejected request must
// still fail on the first attempt rather than being hammered.

private struct StubError: Error {}

@Test func timeoutsAndDroppedConnectionsAreTransient() {
    #expect(BalanceReadRetryPolicy.isTransient(URLError(.timedOut)))
    #expect(BalanceReadRetryPolicy.isTransient(URLError(.networkConnectionLost)))
    #expect(BalanceReadRetryPolicy.isTransient(URLError(.cannotConnectToHost)))
}

@Test func rateLimitingIsTransient() {
    // Keyless public endpoints answer a burst of reads with 429 / 503.
    #expect(BalanceReadRetryPolicy.isTransient(
        WalletNodeClient.ClientError.transport("wallet-node returned HTTP 429 without a response body")
    ))
    #expect(BalanceReadRetryPolicy.isTransient(
        WalletNodeClient.ClientError.transport("wallet-node returned HTTP 503 without a response body")
    ))
    // EIP-1474 "limit exceeded", and providers that describe it in the message instead.
    #expect(BalanceReadRetryPolicy.isTransient(
        WalletNodeClient.ClientError.rpcError(method: "eth_call", code: -32005, message: "limit exceeded", reason: nil)
    ))
    #expect(BalanceReadRetryPolicy.isTransient(
        WalletNodeClient.ClientError.rpcError(method: "eth_call", code: -32603, message: "Too Many Requests", reason: nil)
    ))
}

@Test func requestErrorsAreNotTransient() {
    // Retrying these can never help, and would triple the load for nothing.
    #expect(!BalanceReadRetryPolicy.isTransient(
        WalletNodeClient.ClientError.rpcError(method: "eth_call", code: -32602, message: "invalid params", reason: nil)
    ))
    #expect(!BalanceReadRetryPolicy.isTransient(
        WalletNodeClient.ClientError.rpcError(method: "eth_call", code: -32000, message: "execution reverted", reason: nil)
    ))
    #expect(!BalanceReadRetryPolicy.isTransient(WalletNodeClient.ClientError.invalidResponse))
    #expect(!BalanceReadRetryPolicy.isTransient(AppError.invalidExecutionAddress))
    #expect(!BalanceReadRetryPolicy.isTransient(StubError()))
}

@Test func backoffGrowsBetweenAttempts() {
    let first = BalanceReadRetryPolicy.backoffNanoseconds(beforeAttempt: 2)
    let second = BalanceReadRetryPolicy.backoffNanoseconds(beforeAttempt: 3)
    #expect(first > 0)
    #expect(second > first)
}

@Test func transientFailureThenSuccessReturnsTheBalance() async throws {
    var attempts = 0
    let value = try await withBalanceReadRetry(sleep: { _ in }) {
        attempts += 1
        if attempts < 3 {
            throw URLError(.timedOut)
        }
        return "0x16345785d8a0000"
    }
    #expect(value == "0x16345785d8a0000")
    #expect(attempts == 3)
}

@Test func nonTransientFailureIsNotRetried() async {
    var attempts = 0
    await #expect(throws: (any Error).self) {
        _ = try await withBalanceReadRetry(sleep: { _ in }) {
            attempts += 1
            throw WalletNodeClient.ClientError.rpcError(
                method: "eth_call",
                code: -32602,
                message: "invalid params",
                reason: nil
            )
        }
    }
    #expect(attempts == 1)
}

@Test func persistentTransientFailureGivesUpAndRethrows() async {
    var attempts = 0
    await #expect(throws: (any Error).self) {
        _ = try await withBalanceReadRetry(sleep: { _ in }) {
            attempts += 1
            throw URLError(.timedOut)
        }
    }
    // Bounded: the popover must not retry forever behind a spinner.
    #expect(attempts == BalanceReadRetryPolicy.maxAttempts)
}

@Test func sleepsOnlyBetweenAttemptsNotAfterTheLast() async {
    var sleeps: [UInt64] = []
    _ = try? await withBalanceReadRetry(sleep: { sleeps.append($0) }) {
        throw URLError(.timedOut)
    }
    // 3 attempts means 2 waits.
    #expect(sleeps.count == BalanceReadRetryPolicy.maxAttempts - 1)
    #expect(sleeps == sleeps.sorted())
}
