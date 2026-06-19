import Foundation
import Testing
@testable import WalletMacOSApp

@Test func entryPointGetNonceEncodesFullPermissionNonceKey() throws {
    let nonceKey = try Data(hexString: "010244366fcb000000000000000000000000000000000000")
    let calldata = try ChainReadCallData.entryPointGetNonce(
        accountAddress: "0x000000000000000000000000000000000000dEaD",
        nonceKey192: nonceKey
    )

    #expect(calldata == "0x35567e1a000000000000000000000000000000000000000000000000000000000000dead0000000000000000010244366fcb000000000000000000000000000000000000")
}

@Test func entryPointGetNonceAcceptsPaddedThirtyTwoBytePermissionNonceKey() throws {
    let nonceKey = try Data(hexString: "0000000000000000010244366fcb000000000000000000000000000000000000")
    let calldata = try ChainReadCallData.entryPointGetNonce(
        accountAddress: "0x000000000000000000000000000000000000dEaD",
        nonceKey192: nonceKey
    )

    #expect(calldata == "0x35567e1a000000000000000000000000000000000000000000000000000000000000dead0000000000000000010244366fcb000000000000000000000000000000000000")
}

@Test func entryPointGetNonceRejectsOverflowingPermissionNonceKey() {
    #expect(throws: AppError.self) {
        _ = try ChainReadCallData.entryPointGetNonce(
            accountAddress: "0x000000000000000000000000000000000000dEaD",
            nonceKey192: Data(repeating: 0x01, count: 25)
        )
    }
    #expect(throws: AppError.self) {
        _ = try ChainReadCallData.entryPointGetNonce(
            accountAddress: "0x000000000000000000000000000000000000dEaD",
            nonceKey192: Data(repeating: 0x01, count: 32)
        )
    }
}
