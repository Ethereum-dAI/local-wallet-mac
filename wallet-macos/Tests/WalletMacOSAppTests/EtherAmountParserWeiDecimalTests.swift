import XCTest
@testable import WalletMacOSApp

final class EtherAmountParserWeiDecimalTests: XCTestCase {
    // 0.01 ETH = 10_000_000_000_000_000 wei
    func testPointZeroOneETHToWeiDecimalString() throws {
        XCTAssertEqual(try EtherAmountParser.weiDecimalString(fromETHString: "0.01"), "10000000000000000")
    }

    // 1 ETH = 1_000_000_000_000_000_000 wei
    func testOneETHToWeiDecimalString() throws {
        XCTAssertEqual(try EtherAmountParser.weiDecimalString(fromETHString: "1"), "1000000000000000000")
    }

    // 0.001 ETH = 1_000_000_000_000_000 wei
    func testPointZeroZeroOneETHToWeiDecimalString() throws {
        XCTAssertEqual(try EtherAmountParser.weiDecimalString(fromETHString: "0.001"), "1000000000000000")
    }

    // 0 ETH = 0 wei
    func testZeroETHToWeiDecimalString() throws {
        XCTAssertEqual(try EtherAmountParser.weiDecimalString(fromETHString: "0"), "0")
    }

    // decimalString round-trips through units(fromDecimalString:decimals:0)
    func testDecimalStringFromBigEndianDataRoundTrip() throws {
        let weiData = try EtherAmountParser.units(fromDecimalString: "10000000000000000", decimals: 0)
        XCTAssertEqual(EtherAmountParser.decimalString(fromBigEndianData: weiData), "10000000000000000")
    }

    func testDecimalStringFromZeroData() {
        XCTAssertEqual(EtherAmountParser.decimalString(fromBigEndianData: Data(repeating: 0, count: 32)), "0")
    }
}
