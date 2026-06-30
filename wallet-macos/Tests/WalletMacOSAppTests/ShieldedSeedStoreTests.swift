// Tests/WalletMacOSAppTests/ShieldedSeedStoreTests.swift
import XCTest
@testable import WalletMacOSApp

final class ShieldedSeedStoreTests: XCTestCase {
    func testAccessControlIsBiometricAndThisDeviceOnly() throws {
        var err: Unmanaged<CFError>?
        XCTAssertNotNil(ShieldedSeedStore.makeAccessControl(&err))
        XCTAssertNil(err)
    }
    func testEntropyHexShapeFromBytes() {
        let hex = ShieldedSeedStore.hexString(from: Data(repeating: 0xab, count: 32))
        XCTAssertEqual(hex, "0x" + String(repeating: "ab", count: 32))
    }
}
