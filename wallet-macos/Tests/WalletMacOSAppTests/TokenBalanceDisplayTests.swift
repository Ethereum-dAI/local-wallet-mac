import Foundation
import Testing
@testable import WalletMacOSApp

// Regression coverage for the token popover reading real balances as 0.
//
// `eth_getBalance` returns a minimally-encoded quantity, so an odd nibble count is
// normal: 0.1 ETH is `0x16345785d8a0000`, 15 digits after the prefix. The popover used
// to parse it with `Data(hexString:)`, which rejects odd-length input, and swallowed the
// throw into `?? Data()` — rendering a funded account as `0 ETH`.

@Test func oddLengthQuantityFormatsInsteadOfReadingAsZero() throws {
    // 0.1 ETH — the exact value from the bug report.
    let display = try TokenBalanceDisplay.displayString(
        balanceHex: "0x16345785d8a0000",
        decimals: 18,
        symbol: "ETH"
    )
    #expect(display == "0.1 ETH")
}

@Test func oddLengthHexIsRejectedByTheStrictParser() {
    // Pins the reason the helper exists: the strict byte parser cannot take a quantity.
    #expect(throws: (any Error).self) {
        try Data(hexString: "0x16345785d8a0000")
    }
}

@Test func evenLengthQuantityStillFormats() throws {
    // 1 ETH = 0xde0b6b3a7640000 is also odd; 16 ETH = 0x0de0b6b3a76400000 is even.
    let display = try TokenBalanceDisplay.displayString(
        balanceHex: "0x0de0b6b3a7640000",
        decimals: 18,
        symbol: "ETH"
    )
    #expect(display == "1 ETH")
}

@Test func zeroQuantityFormatsAsZero() throws {
    let display = try TokenBalanceDisplay.displayString(
        balanceHex: "0x0",
        decimals: 18,
        symbol: "ETH"
    )
    #expect(display == "0 ETH")
}

@Test func erc20WordSizedReturnFormats() throws {
    // eth_call returns a full 32-byte word: 1500000 USDC at 6 decimals.
    let display = try TokenBalanceDisplay.displayString(
        balanceHex: "0x00000000000000000000000000000000000000000000000000000000000f4240",
        decimals: 6,
        symbol: "USDC"
    )
    #expect(display == "1 USDC")
}

@Test func emptyCallResultFormatsAsZeroNotUnavailable() throws {
    // eth_call against a token with no contract on this chain returns `0x`. That is a
    // successful read of "no balance" and must show 0 — only a *failed* read is Unavailable.
    let display = try TokenBalanceDisplay.displayString(
        balanceHex: "0x",
        decimals: 18,
        symbol: "DAI"
    )
    #expect(display == "0 DAI")
}

@Test func malformedHexThrowsRatherThanReportingZero() {
    // A read that cannot be parsed must surface as unavailable, never as a 0 balance.
    #expect(throws: (any Error).self) {
        try TokenBalanceDisplay.displayString(balanceHex: "0xzz", decimals: 18, symbol: "ETH")
    }
    #expect(throws: (any Error).self) {
        try TokenBalanceDisplay.displayString(balanceHex: "", decimals: 18, symbol: "ETH")
    }
}
