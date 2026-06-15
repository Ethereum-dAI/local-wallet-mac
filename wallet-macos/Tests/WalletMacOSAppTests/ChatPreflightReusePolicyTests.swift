import Foundation
import Testing
@testable import WalletMacOSApp

@Test func freshMatchingSwapPreviewCanBeReused() throws {
    let from = try #require(WalletTokenRegistry.token(matching: "USDC", on: 11_155_111))
    let to = try #require(WalletTokenRegistry.token(matching: "ETH", on: 11_155_111))
    let now = Date(timeIntervalSince1970: 1_000)
    let preview = ChatSwapPreview(
        fromToken: from,
        toToken: to,
        amount: "10",
        quote: previewQuote(from: from, to: to),
        quotedAt: now
    )

    #expect(ChatPreflightReusePolicy.canReuseSwapQuote(
        preview: preview,
        fromToken: from,
        toToken: to,
        amount: "10",
        now: now.addingTimeInterval(10),
        ttl: 30
    ))
}

@Test func staleOrChangedSwapPreviewIsNotReused() throws {
    let from = try #require(WalletTokenRegistry.token(matching: "USDC", on: 11_155_111))
    let to = try #require(WalletTokenRegistry.token(matching: "ETH", on: 11_155_111))
    let now = Date(timeIntervalSince1970: 1_000)
    let preview = ChatSwapPreview(
        fromToken: from,
        toToken: to,
        amount: "10",
        quote: previewQuote(from: from, to: to),
        quotedAt: now
    )

    #expect(ChatPreflightReusePolicy.canReuseSwapQuote(
        preview: preview,
        fromToken: from,
        toToken: to,
        amount: "10",
        now: now.addingTimeInterval(31),
        ttl: 30
    ) == false)
    #expect(ChatPreflightReusePolicy.canReuseSwapQuote(
        preview: preview,
        fromToken: from,
        toToken: to,
        amount: "11",
        now: now.addingTimeInterval(10),
        ttl: 30
    ) == false)
}

private func previewQuote(from: WalletToken, to: WalletToken) -> SwapQuote {
    SwapQuote(
        chainID: from.chainID,
        factory: "0x0000000000000000000000000000000000000001",
        router: "0x0000000000000000000000000000000000000002",
        quoter: "0x0000000000000000000000000000000000000003",
        tokenIn: from.contractAddress ?? "0x0000000000000000000000000000000000000004",
        tokenOut: to.contractAddress ?? "0x0000000000000000000000000000000000000005",
        amountIn: Data([1]),
        quoteAmountOut: Data([2]),
        amountOutMinimum: Data([1]),
        slippageBps: 100,
        path: Data([1, 2, 3]),
        hops: [],
        gasEstimate: "0x1",
        allowance: nil,
        requiresApproval: false
    )
}
