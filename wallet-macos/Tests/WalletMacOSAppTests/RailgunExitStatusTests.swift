import XCTest
@testable import WalletMacOSApp

/// Pins the wire shapes `railgun-helper` actually emits (see
/// `local-wallet-railgun/src/bin/railgun-helper.rs`, `submitted_and_done_share_one_schema_with_hex_wei_amounts`
/// and `error_status_carries_the_stable_code`), so the decoders here match reality and not a
/// stale draft of it.
final class RailgunExitStatusTests: XCTestCase {
    func testDecodesSubmittedStatusWithDeliveredAsset() throws {
        // `deliveredWei` on the wire is ALWAYS a 0x-hex string, never a JSON number (see
        // below) — this fixture uses a real hex string rather than a bare number so the test
        // cannot pass against a Double/Int-backed decode by accident.
        let json = """
        {"status":"submitted","deliveredAsset":"ETH","result":{"userOpHash":"0xabc","sender":"0xdef","deliveredWei":"0x2317","exitIndex":3,"included":false}}
        """.data(using: .utf8)!
        let st = try JSONDecoder().decode(RailgunHelperClient.UnshieldStatus.self, from: json)
        XCTAssertEqual(st.status, "submitted")
        XCTAssertEqual(st.deliveredAsset, "ETH")
        XCTAssertNil(st.code)
    }

    func testDecodesErrorStatusWithStableCode() throws {
        let json = """
        {"status":"error","code":"feeDidNotConverge","error":"gas is moving too fast"}
        """.data(using: .utf8)!
        let st = try JSONDecoder().decode(RailgunHelperClient.UnshieldStatus.self, from: json)
        XCTAssertEqual(st.code, "feeDidNotConverge")
    }

    func testDecodesMaxUnshieldable() throws {
        let json = """
        {"maxValueWei":"0x2710","receivableAtMaxWei":"0x2317","reserveWei":"0x64"}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(RailgunHelperClient.MaxUnshieldable.self, from: json)
        XCTAssertEqual(m.maxValueWei, "0x2710")
        XCTAssertEqual(m.receivableAtMaxWei, "0x2317")
        XCTAssertEqual(m.reserveWei, "0x64")
    }

    /// Guards the load-bearing detail from the wire contract: `deliveredWei` MUST decode as a
    /// string, never a number. 2^53 wei is only 0.009 ETH, so a Double-backed decode would
    /// silently corrupt essentially every real delivered amount. This value (1 ETH in wei) is
    /// chosen specifically because it is already past 2^53.
    func testDeliveredWeiSurvivesAsHexStringPastDoublePrecision() throws {
        let json = """
        {"status":"done","deliveredAsset":"ETH","result":{"userOpHash":"0x1c3fa5b0e2d47c8916aa0b3d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081","sender":"0x4b39f7b0624b9db86ad293686bc38b903142dbbc","deliveredWei":"0xde0b6b3a7640000","exitIndex":3,"included":true}}
        """.data(using: .utf8)!
        let st = try JSONDecoder().decode(RailgunHelperClient.UnshieldStatus.self, from: json)
        guard case let .object(result)? = st.result,
              case let .string(deliveredWei)? = result["deliveredWei"] else {
            XCTFail("deliveredWei must decode as a JSON string, not a number")
            return
        }
        XCTAssertEqual(deliveredWei, "0xde0b6b3a7640000")
    }

    /// `submitted` and `done` are asserted to share one non-optional `result` schema (the
    /// sidecar's own test pins the same thing on the Rust side) — a client that required
    /// `included` to already be `true` would fail to decode the `submitted` phase.
    func testSubmittedAndDoneShareOneResultSchema() throws {
        func decode(_ status: String, included: Bool) throws -> RailgunHelperClient.UnshieldStatus {
            let json = """
            {"status":"\(status)","deliveredAsset":"ETH","result":{"userOpHash":"0xabc","sender":"0xdef","deliveredWei":"0x64","exitIndex":1,"included":\(included)}}
            """.data(using: .utf8)!
            return try JSONDecoder().decode(RailgunHelperClient.UnshieldStatus.self, from: json)
        }
        let submitted = try decode("submitted", included: false)
        let done = try decode("done", included: true)
        XCTAssertEqual(submitted.result?["exitIndex"], done.result?["exitIndex"])
        XCTAssertEqual(submitted.result?["userOpHash"], done.result?["userOpHash"])
    }

    func testExitFailureCopyIsActionablePerCode() {
        let converge = RailgunExitCopy.exitFailureMessage(
            code: "feeDidNotConverge", message: "raw rust error"
        )
        XCTAssertFalse(converge.contains("raw rust error"), "must not leak the raw error")
        XCTAssertTrue(converge.lowercased().contains("try again"), "must tell the user what to do")

        let rejected = RailgunExitCopy.exitFailureMessage(
            code: "bundlerRejected", message: "raw"
        )
        XCTAssertTrue(
            rejected.lowercased().contains("untouched"),
            "must reassure that shielded funds are safe: \(rejected)"
        )

        // deliveryReverted is the one case where the detail matters for a bug report.
        let reverted = RailgunExitCopy.exitFailureMessage(
            code: "deliveryReverted", message: "index 7"
        )
        XCTAssertTrue(reverted.contains("index 7"), "recovery detail must survive")

        // Unknown codes must fall through, never be swallowed into a generic string.
        XCTAssertEqual(
            RailgunExitCopy.exitFailureMessage(code: "somethingNew", message: "verbatim"),
            "verbatim"
        )
        // A missing code means the generic `error`, which is also a fall-through.
        XCTAssertEqual(
            RailgunExitCopy.exitFailureMessage(code: nil, message: "verbatim"),
            "verbatim"
        )
    }

    /// Both sidecar failure paths carry a code and must reach the same copy: a synchronous
    /// rejection (`error.data.code`) and an async job failure (`status: error` + `code`). A
    /// non-RAILGUN error must pass through untouched so its own handler keeps its message.
    func testFailureCopyIsSelectedByCodeFromBothErrorCases() {
        XCTAssertEqual(
            RailgunExitCopy.failureCopy(
                for: RailgunHelperClient.ClientError.exitFailed(code: "bundlerRejected", message: "raw")
            ),
            RailgunExitCopy.exitFailureMessage(code: "bundlerRejected", message: "raw")
        )
        XCTAssertEqual(
            RailgunExitCopy.failureCopy(
                for: RailgunHelperClient.ClientError.rpcError(code: "insufficientShieldedBalance", message: "5 wei exceeds 3 wei")
            ),
            RailgunExitCopy.exitFailureMessage(code: "insufficientShieldedBalance", message: "5 wei exceeds 3 wei")
        )
        XCTAssertNil(
            RailgunExitCopy.failureCopy(for: RailgunHelperClient.ClientError.ioFailed("socket")),
            "transport failures have no domain code and must keep their own description"
        )
        XCTAssertNil(RailgunExitCopy.failureCopy(for: URLError(.timedOut)))
    }

    /// The stable code travels in the JSON-RPC error's `data.code`, not its transport-level
    /// integer `code`. Dropping it would force the view layer back to substring-matching a
    /// message the sidecar deliberately stripped of its prefix.
    func testSyncRejectionCarriesTheStableCodeFromErrorData() throws {
        let body = """
        {"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"5 wei exceeds the spendable maximum 3 wei","data":{"code":"insufficientShieldedBalance"}}}
        """
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n\(body)".utf8)
        do {
            _ = try RailgunHelperClient.parseBody(raw)
            XCTFail("an error body must throw")
        } catch let RailgunHelperClient.ClientError.rpcError(code, message) {
            XCTAssertEqual(code, "insufficientShieldedBalance")
            XCTAssertEqual(message, "5 wei exceeds the spendable maximum 3 wei")
        }
    }

    /// A peer that sends no `data.code` (or a transport-level JSON-RPC error like an unknown
    /// method) has no domain code to recover, so it must read as "no code" rather than crash or
    /// invent one.
    func testSyncRejectionWithoutDataCodeHasNoCode() throws {
        let body = """
        {"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"unknown method: nope"}}
        """
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n\(body)".utf8)
        do {
            _ = try RailgunHelperClient.parseBody(raw)
            XCTFail("an error body must throw")
        } catch let RailgunHelperClient.ClientError.rpcError(code, message) {
            XCTAssertNil(code)
            XCTAssertEqual(message, "unknown method: nope")
        }
    }
}
