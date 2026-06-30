import XCTest
@testable import WalletMacOSApp

final class ShieldedBalanceTests: XCTestCase {
    func testFormatsHexWeiViaSharedFormatter() {
        XCTAssertEqual(WeiFormatter.ethDisplayString(fromHexWei: "0x2386f26fc10000"), "0.01 ETH") // 1e16 wei
    }
}
