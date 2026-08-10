import Foundation
import Testing
@testable import WalletMacOSApp

// The daemon writes structured JSON logs; these fixtures are copied from a real
// `wallet-node.log` so the parser is pinned to the format it actually meets.
private let chainIDFailure = """
{"timestamp":"2026-08-10T19:48:57.751405Z","level":"ERROR","fields":{"message":"execution RPC chain id validation failed","error":"rpc error: eth_chainId HTTP status 400 Bad Request","expected_chain_id":11155111},"target":"wallet_node"}
"""

private let heliosWarning = """
{"timestamp":"2026-08-10T19:48:57.475071Z","level":"WARN","fields":{"message":"helios read verification disabled; serving reads directly from execution RPC"},"target":"wallet_node"}
"""

private func date(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: iso)!
}

@Test func parsesMicrosecondPrecisionLogTimestamps() throws {
    // tracing emits six fractional digits; ISO8601DateFormatter accepts three.
    let parsed = try #require(WalletNodeDaemon.parseDaemonLogTimestamp("2026-08-10T19:48:57.751405Z"))

    #expect(abs(parsed.timeIntervalSince(date("2026-08-10T19:48:57.751Z"))) < 0.001)
}

@Test func parsesLogTimestampWithoutFractionalSeconds() throws {
    let parsed = try #require(WalletNodeDaemon.parseDaemonLogTimestamp("2026-08-10T19:48:57Z"))

    #expect(abs(parsed.timeIntervalSince(date("2026-08-10T19:48:57.000Z"))) < 0.001)
}

@Test func reportsTheLastErrorWithItsDetail() throws {
    let reason = WalletNodeDaemon.lastLoggedDaemonError(
        since: date("2026-08-10T19:48:00.000Z"),
        tail: "\(heliosWarning)\n\(chainIDFailure)"
    )

    #expect(reason == "execution RPC chain id validation failed: rpc error: eth_chainId HTTP status 400 Bad Request")
}

/// The log is appended across launches. An error from a previous run must never
/// be reported as the reason this launch failed.
@Test func ignoresErrorsLoggedBeforeThisLaunch() {
    let reason = WalletNodeDaemon.lastLoggedDaemonError(
        since: date("2026-08-10T19:49:00.000Z"),
        tail: chainIDFailure
    )

    #expect(reason == nil)
}

@Test func ignoresNonErrorLevels() {
    let reason = WalletNodeDaemon.lastLoggedDaemonError(
        since: date("2026-08-10T19:48:00.000Z"),
        tail: heliosWarning
    )

    #expect(reason == nil)
}

@Test func returnsTheMostRecentErrorWhenSeveralAreLogged() throws {
    let earlier = """
    {"timestamp":"2026-08-10T19:48:10.000000Z","level":"ERROR","fields":{"message":"first"},"target":"wallet_node"}
    """

    let reason = WalletNodeDaemon.lastLoggedDaemonError(
        since: date("2026-08-10T19:48:00.000Z"),
        tail: "\(earlier)\n\(chainIDFailure)"
    )

    #expect(reason?.hasPrefix("execution RPC chain id validation failed") == true)
}

@Test func toleratesNonJSONLinesInTheTail() throws {
    let reason = WalletNodeDaemon.lastLoggedDaemonError(
        since: date("2026-08-10T19:48:00.000Z"),
        tail: "<tail truncated to last 16384 bytes>\nnot json at all\n\(chainIDFailure)"
    )

    #expect(reason?.hasPrefix("execution RPC chain id validation failed") == true)
}
