import XCTest
@testable import WalletToolLayer

final class ShieldIntentTests: XCTestCase {
    func testShieldToolDecodes() {
        XCTAssertEqual(
            ToolIntent(tool: .shield, args: ["amount": "0.01"], source: .slash).tool,
            .shield
        )
    }

    func testShieldInPhase1() {
        XCTAssertTrue(ToolDefinitions.phase1.contains { $0.name == "shield" })
    }

    func testShieldRawValue() {
        XCTAssertEqual(ToolIntent.Tool.shield.rawValue, "shield")
    }
}
