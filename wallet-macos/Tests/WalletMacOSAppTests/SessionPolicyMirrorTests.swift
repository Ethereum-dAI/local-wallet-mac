import Foundation
import Testing
@testable import WalletMacOSApp

@Test func sessionPolicyMirrorAllowsNativeTransferAtCapAndRejectsOverCap() {
    let context = sessionPolicyContext()
    let recipient = "0x1111111111111111111111111111111111111111"

    #expect(SessionPolicyMirror.isWithinPolicy(
        intent: .nativeTransfer(recipient: recipient, amountETH: "0.1"),
        config: .default,
        context: context
    ))
    #expect(!SessionPolicyMirror.isWithinPolicy(
        intent: .nativeTransfer(recipient: recipient, amountETH: "0.100000000000000001"),
        config: .default,
        context: context
    ))
    #expect(SessionPolicyMirror.rejectionReason(
        intent: .nativeTransfer(recipient: recipient, amountETH: "0.100000000000000001"),
        config: .default,
        context: context
    ) == .overValueLimit)
}

@Test func sessionPolicyMirrorAllowsKnownERC20TransferAndRejectsUnknownOrOverCap() throws {
    let context = sessionPolicyContext()
    let recipient = "0x2222222222222222222222222222222222222222"
    let usdc = try #require(WalletTokenRegistry.token(matching: "USDC", on: 11_155_111))
    let unknown = WalletToken(
        chainID: 11_155_111,
        symbol: "FAKE",
        name: "Fake",
        decimals: 18,
        kind: .erc20(address: "0x9999999999999999999999999999999999999999")
    )

    #expect(SessionPolicyMirror.isWithinPolicy(
        intent: .erc20Transfer(token: usdc, recipient: recipient, amount: "100"),
        config: .default,
        context: context
    ))
    #expect(!SessionPolicyMirror.isWithinPolicy(
        intent: .erc20Transfer(token: unknown, recipient: recipient, amount: "1"),
        config: .default,
        context: context
    ))
    #expect(SessionPolicyMirror.rejectionReason(
        intent: .erc20Transfer(token: unknown, recipient: recipient, amount: "1"),
        config: .default,
        context: context
    ) == .unsupportedToken)
    #expect(!SessionPolicyMirror.isWithinPolicy(
        intent: .erc20Transfer(token: usdc, recipient: recipient, amount: "1000000000000"),
        config: .default,
        context: context
    ))
}

@Test func sessionPolicyMirrorRejectsDisabledERC20TransfersAndTokens() throws {
    let context = sessionPolicyContext()
    let recipient = "0x2222222222222222222222222222222222222222"
    let usdc = try #require(WalletTokenRegistry.token(matching: "USDC", on: 11_155_111))
    var transfersDisabled = SessionPolicyConfig.default
    transfersDisabled.allowlist.erc20Transfers = false

    #expect(SessionPolicyMirror.rejectionReason(
        intent: .erc20Transfer(token: usdc, recipient: recipient, amount: "1"),
        config: transfersDisabled,
        context: context
    ) == .erc20TransfersDisabled)

    var tokenDisabled = SessionPolicyConfig.default
    tokenDisabled.erc20TokenLimits = [
        SessionERC20TokenLimit(
            chainID: 11_155_111,
            tokenAddress: try #require(usdc.contractAddress),
            isEnabled: false,
            maxAmount: "100000000"
        ),
    ]

    #expect(SessionPolicyMirror.rejectionReason(
        intent: .erc20Transfer(token: usdc, recipient: recipient, amount: "1"),
        config: tokenDisabled,
        context: context
    ) == .erc20TokenDisabled)
}

@Test func sessionPolicyMirrorAllowsKnownRouterSwapAndRejectsUnknownRouter() throws {
    let context = sessionPolicyContext()
    let quote = try makeSessionPolicyMirrorSwapQuote(
        router: "0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E"
    )
    let request = SwapExecutionRequest(
        quote: quote,
        recipient: "0x3333333333333333333333333333333333333333",
        tokenInIsNative: false,
        tokenOutIsNative: false
    )
    let unknownRouterQuote = try makeSessionPolicyMirrorSwapQuote(
        router: "0x5555555555555555555555555555555555555555"
    )
    let unknownRouterRequest = SwapExecutionRequest(
        quote: unknownRouterQuote,
        recipient: request.recipient,
        tokenInIsNative: false,
        tokenOutIsNative: false
    )

    #expect(SessionPolicyMirror.isWithinPolicy(
        intent: .exactInputSwap(request),
        config: .default,
        context: context
    ))
    #expect(!SessionPolicyMirror.isWithinPolicy(
        intent: .exactInputSwap(unknownRouterRequest),
        config: .default,
        context: context
    ))
    #expect(SessionPolicyMirror.rejectionReason(
        intent: .exactInputSwap(unknownRouterRequest),
        config: .default,
        context: context
    ) == .unsupportedSwapRouter)
}

@Test func sessionPolicyMirrorRejectsSwapThatNeedsDisabledERC20Approval() throws {
    let context = sessionPolicyContext()
    let quote = try makeSessionPolicyMirrorSwapQuote(
        router: "0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E",
        requiresApproval: true
    )
    let request = SwapExecutionRequest(
        quote: quote,
        recipient: "0x3333333333333333333333333333333333333333",
        tokenInIsNative: false,
        tokenOutIsNative: false
    )
    var approvalsDisabled = SessionPolicyConfig.default
    approvalsDisabled.allowlist.erc20Approvals = .disabled

    #expect(SessionPolicyMirror.rejectionReason(
        intent: .exactInputSwap(request),
        config: approvalsDisabled,
        context: context
    ) == .erc20ApprovalsDisabled)
}

@Test func sessionPolicyMirrorRejectsDisabledNativeTransfersAndSwaps() throws {
    let context = sessionPolicyContext()
    let recipient = "0x3333333333333333333333333333333333333333"
    var nativeDisabled = SessionPolicyConfig.default
    nativeDisabled.allowlist.nativeTransfers = false

    #expect(!SessionPolicyMirror.isWithinPolicy(
        intent: .nativeTransfer(recipient: recipient, amountETH: "0.01"),
        config: nativeDisabled,
        context: context
    ))
    #expect(SessionPolicyMirror.rejectionReason(
        intent: .nativeTransfer(recipient: recipient, amountETH: "0.01"),
        config: nativeDisabled,
        context: context
    ) == .nativeTransfersDisabled)

    let quote = try makeSessionPolicyMirrorSwapQuote(
        router: "0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E"
    )
    let request = SwapExecutionRequest(
        quote: quote,
        recipient: recipient,
        tokenInIsNative: false,
        tokenOutIsNative: false
    )
    var swapsDisabled = SessionPolicyConfig.default
    swapsDisabled.allowlist.swapRouter = false

    #expect(!SessionPolicyMirror.isWithinPolicy(
        intent: .exactInputSwap(request),
        config: swapsDisabled,
        context: context
    ))
    #expect(SessionPolicyMirror.rejectionReason(
        intent: .exactInputSwap(request),
        config: swapsDisabled,
        context: context
    ) == .swapsDisabled)
}

@Test func sessionPolicyMirrorRejectsExpiredSessionAndExhaustedRateLimit() {
    let recipient = "0x4444444444444444444444444444444444444444"
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let intent = TransactionIntent.nativeTransfer(recipient: recipient, amountETH: "0.01")
    let exhaustedDates = (0..<SessionPolicyConfig.default.rateLimitCount).map {
        now.addingTimeInterval(-Double($0 + 1))
    }

    #expect(!SessionPolicyMirror.isWithinPolicy(
        intent: intent,
        config: .default,
        context: SessionPolicyContext(
            chainID: 11_155_111,
            now: now,
            expiresAt: now.addingTimeInterval(-1)
        )
    ))
    #expect(!SessionPolicyMirror.isWithinPolicy(
        intent: intent,
        config: .default,
        context: SessionPolicyContext(
            chainID: 11_155_111,
            now: now,
            expiresAt: now.addingTimeInterval(TimeInterval(SessionPolicyConfig.defaultTTLSeconds)),
            recentSessionTransactionDates: exhaustedDates
        )
    ))
    #expect(SessionPolicyMirror.rejectionReason(
        intent: intent,
        config: .default,
        context: SessionPolicyContext(
            chainID: 11_155_111,
            now: now,
            expiresAt: now.addingTimeInterval(TimeInterval(SessionPolicyConfig.defaultTTLSeconds)),
            recentSessionTransactionDates: exhaustedDates
        )
    ) == .rateLimited)
}

@Test func sessionPolicyMirrorRejectsInactiveSessionBeforeOnchainDurationExpires() {
    let recipient = "0x4444444444444444444444444444444444444444"
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let intent = TransactionIntent.nativeTransfer(recipient: recipient, amountETH: "0.01")

    #expect(!SessionPolicyMirror.isWithinPolicy(
        intent: intent,
        config: .default,
        context: SessionPolicyContext(
            chainID: 11_155_111,
            now: now,
            expiresAt: now.addingTimeInterval(TimeInterval(SessionPolicyConfig.defaultTTLSeconds)),
            lastActivityAt: now.addingTimeInterval(-TimeInterval(SessionPolicyConfig.defaultInactivityTimeoutSeconds))
        )
    ))

    #expect(SessionPolicyMirror.isWithinPolicy(
        intent: intent,
        config: .default,
        context: SessionPolicyContext(
            chainID: 11_155_111,
            now: now,
            expiresAt: now.addingTimeInterval(TimeInterval(SessionPolicyConfig.defaultTTLSeconds)),
            lastActivityAt: now.addingTimeInterval(-TimeInterval(SessionPolicyConfig.defaultInactivityTimeoutSeconds) + 1)
        )
    ))
}

private func sessionPolicyContext() -> SessionPolicyContext {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return SessionPolicyContext(
        chainID: 11_155_111,
        now: now,
        expiresAt: now.addingTimeInterval(TimeInterval(SessionPolicyConfig.defaultTTLSeconds))
    )
}

private func makeSessionPolicyMirrorSwapQuote(
    router: String,
    requiresApproval: Bool = false
) throws -> SwapQuote {
    let usdc = try #require(WalletTokenRegistry.token(matching: "USDC", on: 11_155_111))
    let weth = try #require(WalletTokenRegistry.token(matching: "WETH", on: 11_155_111))
    let tokenIn = try #require(usdc.contractAddress)
    let tokenOut = try #require(weth.contractAddress)

    return SwapQuote(
        chainID: 11_155_111,
        factory: "0x0000000000000000000000000000000000000001",
        router: router,
        quoter: "0x0000000000000000000000000000000000000002",
        tokenIn: tokenIn,
        tokenOut: tokenOut,
        amountIn: try Data(hexString: "64").leftPadded(to: 32),
        quoteAmountOut: try Data(hexString: "5f").leftPadded(to: 32),
        amountOutMinimum: try Data(hexString: "5e").leftPadded(to: 32),
        slippageBps: 100,
        path: try Data(hexString: "\(String(tokenIn.dropFirst(2)))000bb8\(String(tokenOut.dropFirst(2)))"),
        hops: [],
        gasEstimate: "0x0",
        allowance: requiresApproval ? Data(repeating: 0, count: 32) : nil,
        requiresApproval: requiresApproval
    )
}
