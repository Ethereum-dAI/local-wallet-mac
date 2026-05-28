import Foundation

enum ChainReadCallData {
    static func entryPointGetNonce(
        accountAddress: String,
        nonceKey: UInt64
    ) throws -> String {
        let selector = "35567e1a"
        let account = try Data(hexString: accountAddress)
        guard account.count == 20 else {
            throw AppError.invalidExecutionAddress
        }

        let nonceKeyData = Data.fromBigEndian(nonceKey).leftPadded(to: 32)
        let encoded = account.leftPadded(to: 32) + nonceKeyData
        return "0x" + selector + encoded.hexEncodedString
    }

    static func erc20BalanceOf(ownerAddress: String) throws -> String {
        let selector = "70a08231"
        let owner = try Data(hexString: ownerAddress)
        guard owner.count == 20 else {
            throw AppError.invalidExecutionAddress
        }

        return "0x" + selector + owner.leftPadded(to: 32).hexEncodedString
    }
}
