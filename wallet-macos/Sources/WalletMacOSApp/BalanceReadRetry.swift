import Foundation

// Bounded retry for chain *reads* only (balances shown in the dashboard).
//
// A balance refresh issues one read per registry token per address — 14 calls on Sepolia, 20
// on mainnet — back to back. Against a keyless public endpoint some of those come back 429 or
// simply time out, and with no retry anywhere in WalletNodeClient a single such blip left that
// row reading "Unavailable" until the next refresh.
//
// Deliberately scoped to reads: the send path must never silently re-issue anything.
enum BalanceReadRetryPolicy {
    static let maxAttempts = 3

    // 150ms, then 450ms. Long enough for a rate-limit window to move, short enough that a
    // genuinely dead endpoint still resolves the popover quickly.
    static func backoffNanoseconds(beforeAttempt attempt: Int) -> UInt64 {
        let base: UInt64 = 150_000_000
        let exponent = max(0, attempt - 2)
        return base * UInt64(pow(3.0, Double(exponent)))
    }

    // Retry only what a retry can fix. A rejected or malformed request must fail on the first
    // attempt rather than being sent three times.
    static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .notConnectedToInternet, .dnsLookupFailed, .resourceUnavailable,
                 .badServerResponse:
                return true
            default:
                return false
            }
        }

        guard let clientError = error as? WalletNodeClient.ClientError else {
            return false
        }

        switch clientError {
        case let .transport(message):
            return containsTransientSignal(message)
                || WalletNodeClient.isRecoverableUnixSocketFailure(clientError)
        case let .rpcError(_, code, message, _, _):
            // -32005 is EIP-1474 "limit exceeded". Providers also report throttling as a
            // generic internal error with the detail only in the message.
            if code == -32005 {
                return true
            }
            return containsTransientSignal(message)
        case .invalidResponse:
            // An unparseable body is not known to be transient; surface it instead of hiding
            // it behind retries.
            return false
        }
    }

    private static func containsTransientSignal(_ message: String) -> Bool {
        let haystack = message.lowercased()
        return [
            "http 429", "http 500", "http 502", "http 503", "http 504",
            "too many requests", "rate limit", "ratelimit", "limit exceeded",
            "timeout", "timed out", "capacity", "try again",
        ].contains { haystack.contains($0) }
    }
}

// Inherits the caller's isolation (`#isolation`) so the read closure stays on the actor that
// owns the model it touches, instead of being sent across isolation domains.
//
// `sleep` is injectable so tests exercise the attempt/backoff sequence without real delays.
func withBalanceReadRetry<T>(
    isolation: isolated (any Actor)? = #isolation,
    sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
    operation: () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        do {
            return try await operation()
        } catch {
            guard attempt < BalanceReadRetryPolicy.maxAttempts,
                  BalanceReadRetryPolicy.isTransient(error)
            else {
                throw error
            }
            attempt += 1
            try await sleep(BalanceReadRetryPolicy.backoffNanoseconds(beforeAttempt: attempt))
        }
    }
}
