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
}
