import Foundation

enum ChainReadCallData {
    static func kernelCurrentNonce() -> String {
        "0xadb610a3"
    }

    static func entryPointGetNonce(
        accountAddress: String,
        nonceKey: UInt64
    ) throws -> String {
        let account = try Data(hexString: accountAddress)
        guard account.count == 20 else {
            throw AppError.invalidExecutionAddress
        }

        let nonceKeyData = Data.fromBigEndian(nonceKey).leftPadded(to: 32)
        return entryPointGetNonce(account: account, nonceKeyData: nonceKeyData)
    }

    static func entryPointGetNonce(
        accountAddress: String,
        nonceKey192: Data
    ) throws -> String {
        let account = try Data(hexString: accountAddress)
        guard account.count == 20 else {
            throw AppError.invalidExecutionAddress
        }

        return try entryPointGetNonce(
            account: account,
            nonceKeyData: normalizedNonceKey192(nonceKey192)
        )
    }

    private static func entryPointGetNonce(account: Data, nonceKeyData: Data) -> String {
        let selector = "35567e1a"
        let encoded = account.leftPadded(to: 32) + nonceKeyData
        return "0x" + selector + encoded.hexEncodedString
    }

    private static func normalizedNonceKey192(_ nonceKey: Data) throws -> Data {
        if nonceKey.count == 24 {
            return nonceKey.leftPadded(to: 32)
        }
        guard nonceKey.count == 32, nonceKey.prefix(8).allSatisfy({ $0 == 0 }) else {
            throw AppError.invalidHexString
        }
        return nonceKey
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
