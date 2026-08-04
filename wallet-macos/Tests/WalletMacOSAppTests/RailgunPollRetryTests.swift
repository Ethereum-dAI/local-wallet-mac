import XCTest
@testable import WalletMacOSApp

/// Pins the retry policy of `RailgunHelperClient.poll`, the loop behind both
/// `awaitUnshieldSubmitted` and `awaitUnshieldIncluded`.
///
/// The failure this guards is not hypothetical, and not an edge case. The sidecar's RPC server
/// serves ONE connection to completion (`local-wallet-railgun/src/rpc.rs`) and holds the helper
/// mutex for the whole of phase-1 proving (`railgun-helper.rs`), which `balance` also needs. So the
/// ordinary sequence — `/shield` schedules a repeating balance refresh, then `/unshield` starts
/// proving — parks a `balance` request in the sole connection slot, blocked on that mutex, and
/// every `unshieldStatus` poll queues behind it until it hits the client's socket timeout. If one
/// such poll ended the wait, the deadline would bound only the happy path: the exit proves,
/// submits, lands and delivers while the card sits permanently on "Submitted".
///
/// Drives the loop with an injected `fetch` rather than a socket, because the retry policy is the
/// load-bearing behaviour here, not the transport under it.
final class RailgunPollRetryTests: XCTestCase {
    /// A scripted sequence of poll results. `final class` so the async `fetch` closure can advance
    /// it across iterations.
    private final class Script: @unchecked Sendable {
        private var steps: [Result<RailgunHelperClient.UnshieldStatus, Error>]
        private(set) var calls = 0
        init(_ steps: [Result<RailgunHelperClient.UnshieldStatus, Error>]) { self.steps = steps }
        func next() throws -> RailgunHelperClient.UnshieldStatus {
            calls += 1
            guard !steps.isEmpty else { throw XCTSkip("script exhausted") }
            return try steps.removeFirst().get()
        }
    }

    private static func status(
        _ status: String, code: String? = nil, submitted: Bool? = nil, included: Bool = false
    ) -> RailgunHelperClient.UnshieldStatus {
        let codeField = code.map { "\"code\":\"\($0)\"," } ?? ""
        let submittedField = submitted.map { "\"submitted\":\($0)," } ?? ""
        let json = """
        {"status":"\(status)",\(codeField)\(submittedField)"deliveredAsset":"ETH","error":"scripted",\
        "result":{"userOpHash":"0xabc","sender":"0xdef","deliveredWei":"0x230F","exitIndex":3,"included":\(included)}}
        """
        // Force-try: the fixture is a literal in this file, so a decode failure is a test bug.
        return try! JSONDecoder().decode(
            RailgunHelperClient.UnshieldStatus.self, from: Data(json.utf8)
        )
    }

    /// The core fix: transient poll failures are swallowed and polling continues, so the deadline
    /// stays the single bound. Mirrors what `exit::await_exit` does on the Rust side, where EVERY
    /// receipt-poll error is retryable.
    func testTransientPollFailuresDoNotEndTheWait() async throws {
        let script = Script([
            .failure(RailgunHelperClient.ClientError.ioFailed("read: errno 60")),
            .failure(RailgunHelperClient.ClientError.connectFailed("ENOENT")),
            .failure(RailgunHelperClient.ClientError.decodeFailed("UnshieldStatus")),
            .failure(RailgunHelperClient.ClientError.httpError("HTTP/1.1 401")),
            .failure(RailgunHelperClient.ClientError.rpcError(code: "unknownJobId", message: "gone")),
            .success(Self.status("submitted")),
        ])
        let result = try await RailgunHelperClient.poll(
            until: ["submitted", "done"],
            deadline: Date().addingTimeInterval(30),
            every: 0.001,
            fetch: { try script.next() }
        )
        XCTAssertNotNil(result, "the wait must survive five failed polls and see the sixth")
        XCTAssertEqual(script.calls, 6, "every failure must be retried, not aborted on")
        XCTAssertEqual(result?["userOpHash"]?.stringValue, "0xabc")
    }

    /// `pending` is not a failure either — it is the normal state while proving runs.
    func testPendingKeepsWaitingUntilATerminalStatus() async throws {
        let script = Script([
            .success(Self.status("pending")),
            .success(Self.status("pending")),
            .success(Self.status("done", included: true)),
        ])
        let result = try await RailgunHelperClient.poll(
            until: ["done"],
            deadline: Date().addingTimeInterval(30),
            every: 0.001,
            fetch: { try script.next() }
        )
        XCTAssertEqual(result?["included"]?.boolValue, true)
        XCTAssertEqual(script.calls, 3)
    }

    /// The ONE thing that ends the wait early: the sidecar's own report that the job failed. It
    /// must surface immediately, with its code and `submitted` bit intact, since those are what the
    /// view layer switches card state on.
    func testOnlyASidecarReportedFailureEndsTheWaitEarly() async throws {
        let script = Script([
            .failure(RailgunHelperClient.ClientError.ioFailed("read: errno 60")),
            .success(Self.status("error", code: "bundlerRejected", submitted: true)),
            .success(Self.status("done", included: true)),
        ])
        do {
            _ = try await RailgunHelperClient.poll(
                until: ["done"],
                deadline: Date().addingTimeInterval(30),
                every: 0.001,
                fetch: { try script.next() }
            )
            XCTFail("a sidecar-reported failure must throw")
        } catch let RailgunHelperClient.ClientError.exitFailed(code, message, submitted) {
            XCTAssertEqual(code, "bundlerRejected")
            XCTAssertEqual(submitted, true, "the submitted bit must reach the view layer")
            XCTAssertEqual(message, "scripted")
        }
        XCTAssertEqual(script.calls, 2, "must stop at the failure, not poll on")
    }

    /// A deadline that passes with nothing terminal returns nil — "we don't know yet", never a
    /// failure. `awaitUnshieldSubmitted` turns that into `ioFailed` (which does NOT revert the
    /// card); `awaitUnshieldIncluded` returns it as-is.
    func testAnExhaustedDeadlineReturnsNilRatherThanThrowing() async throws {
        let script = Script([.failure(RailgunHelperClient.ClientError.ioFailed("wedged"))])
        let result = try await RailgunHelperClient.poll(
            until: ["done"],
            // Already elapsed: the loop must not fetch at all, and must not throw.
            deadline: Date().addingTimeInterval(-1),
            every: 0.001,
            fetch: { try script.next() }
        )
        XCTAssertNil(result)
        XCTAssertEqual(script.calls, 0)
    }
}
