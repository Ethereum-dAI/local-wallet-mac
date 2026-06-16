import Foundation
import Testing
@testable import WalletMacOSApp

@Test func kernelCallEncoderEncodesErc7579BatchExecution() throws {
    let calls = [
        KernelExecutionRequest(
            target: "0x1111111111111111111111111111111111111111",
            value: try Data(hexString: "07").leftPadded(to: 32),
            callData: try Data(hexString: "1234")
        ),
        KernelExecutionRequest.zeroValueCall(
            target: "0x2222222222222222222222222222222222222222",
            callData: try Data(hexString: "abcdef")
        ),
    ]

    let encoded = try KernelCallEncoder().encodeExecute(calls)

    #expect("0x" + encoded.hexEncodedString == """
    0xe9ae5c530100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000001c000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000111111111111111111111111111111111111111100000000000000000000000000000000000000000000000000000000000000070000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000212340000000000000000000000000000000000000000000000000000000000000000000000000000000000002222222222222222222222222222222222222222000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000003abcdef0000000000000000000000000000000000000000000000000000000000
    """.trimmingCharacters(in: .whitespacesAndNewlines))
}

@Test func erc20SwapWithMissingAllowancePrependsApprovalExecution() throws {
    let builder = UserOperationBuilder()
    let quote = try makeSwapQuote(
        allowance: Data(repeating: 0, count: 32),
        requiresApproval: true
    )
    let request = SwapExecutionRequest(
        quote: quote,
        recipient: "0x3333333333333333333333333333333333333333",
        tokenInIsNative: false,
        tokenOutIsNative: false
    )

    let executions = try builder.buildExecutionRequests(for: .exactInputSwap(request))
    let expectedApproval = try ERC20ApprovalCallEncoder().encodeApprove(
        spender: quote.router,
        amount: quote.amountIn
    )

    #expect(executions.count == 2)
    #expect(executions[0].target == quote.tokenIn.lowercasedAddress)
    #expect(executions[0].value == Data(repeating: 0, count: 32))
    #expect(executions[0].callData == expectedApproval)
    #expect(executions[1].target == quote.router.lowercasedAddress)
}

@Test func erc20SwapWithNonZeroInsufficientAllowanceResetsApprovalFirst() throws {
    let builder = UserOperationBuilder()
    let quote = try makeSwapQuote(
        allowance: try Data(hexString: "01").leftPadded(to: 32),
        requiresApproval: true
    )
    let request = SwapExecutionRequest(
        quote: quote,
        recipient: "0x3333333333333333333333333333333333333333",
        tokenInIsNative: false,
        tokenOutIsNative: false
    )

    let executions = try builder.buildExecutionRequests(for: .exactInputSwap(request))
    let expectedResetApproval = try ERC20ApprovalCallEncoder().encodeApprove(
        spender: quote.router,
        amount: Data(repeating: 0, count: 32)
    )
    let expectedApproval = try ERC20ApprovalCallEncoder().encodeApprove(
        spender: quote.router,
        amount: quote.amountIn
    )

    #expect(executions.count == 3)
    #expect(executions[0].callData == expectedResetApproval)
    #expect(executions[1].callData == expectedApproval)
    #expect(executions[2].target == quote.router.lowercasedAddress)
}

@Test func erc20SwapWithSufficientAllowanceUsesRouterOnly() throws {
    let builder = UserOperationBuilder()
    let quote = try makeSwapQuote(
        allowance: try Data(hexString: "64").leftPadded(to: 32),
        requiresApproval: false
    )
    let request = SwapExecutionRequest(
        quote: quote,
        recipient: "0x3333333333333333333333333333333333333333",
        tokenInIsNative: false,
        tokenOutIsNative: false
    )

    let executions = try builder.buildExecutionRequests(for: .exactInputSwap(request))

    #expect(executions.count == 1)
    #expect(executions[0].target == quote.router.lowercasedAddress)
}

@Test func nativeOutSwapUsesRouterMulticallOutsideSessionMode() throws {
    let builder = UserOperationBuilder()
    let quote = try makeSwapQuote(
        allowance: try Data(hexString: "64").leftPadded(to: 32),
        requiresApproval: false
    )
    let request = SwapExecutionRequest(
        quote: quote,
        recipient: "0x3333333333333333333333333333333333333333",
        tokenInIsNative: false,
        tokenOutIsNative: true
    )
    let swapCallData = try SwapRouterCallEncoder().encodeExactInput(
        path: quote.path,
        recipient: quote.router,
        amountIn: quote.amountIn,
        amountOutMinimum: quote.amountOutMinimum
    )
    let unwrapCallData = try SwapRouterCallEncoder().encodeUnwrapWETH9(
        amountMinimum: quote.amountOutMinimum,
        recipient: request.recipient
    )

    let executions = try builder.buildExecutionRequests(for: .exactInputSwap(request))

    #expect(executions.count == 1)
    #expect(executions[0].target == quote.router.lowercasedAddress)
    #expect(executions[0].callData == SwapRouterCallEncoder().encodeMulticall([swapCallData, unwrapCallData]))
}

@Test func nativeOutSwapInSessionModeUsesTopLevelRouterCalls() throws {
    let builder = UserOperationBuilder()
    let quote = try makeSwapQuote(
        allowance: Data(repeating: 0, count: 32),
        requiresApproval: true
    )
    let request = SwapExecutionRequest(
        quote: quote,
        recipient: "0x3333333333333333333333333333333333333333",
        tokenInIsNative: false,
        tokenOutIsNative: true
    )
    let expectedApproval = try ERC20ApprovalCallEncoder().encodeApprove(
        spender: quote.router,
        amount: quote.amountIn
    )
    let expectedSwap = try SwapRouterCallEncoder().encodeExactInput(
        path: quote.path,
        recipient: quote.router,
        amountIn: quote.amountIn,
        amountOutMinimum: quote.amountOutMinimum
    )
    let expectedUnwrap = try SwapRouterCallEncoder().encodeUnwrapWETH9(
        amountMinimum: quote.amountOutMinimum,
        recipient: request.recipient
    )

    let executions = try builder.buildExecutionRequests(for: .exactInputSwap(request), sessionMode: true)

    #expect(executions.count == 3)
    #expect(executions[0].target == quote.tokenIn.lowercasedAddress)
    #expect(executions[0].callData == expectedApproval)
    #expect(executions[1].target == quote.router.lowercasedAddress)
    #expect(executions[1].callData == expectedSwap)
    #expect(executions[2].target == quote.router.lowercasedAddress)
    #expect(executions[2].callData == expectedUnwrap)
}

@Test func swapExactInputCallPolicyOffsetsMatchEncodedCalldataWords() throws {
    let quote = try makeSwapQuote(
        allowance: try Data(hexString: "64").leftPadded(to: 32),
        requiresApproval: false
    )
    let recipient = "0x3333333333333333333333333333333333333333"
    let callData = try SwapRouterCallEncoder().encodeExactInput(
        path: quote.path,
        recipient: recipient,
        amountIn: quote.amountIn,
        amountOutMinimum: quote.amountOutMinimum
    )
    let tupleOffset = try Data(hexString: "20").leftPadded(to: 32)
    let pathOffset = try Data(hexString: "80").leftPadded(to: 32)
    let encodedRecipient = try Data(hexString: recipient).leftPadded(to: 32)

    #expect(callPolicyWord(callData, offset: 0) == tupleOffset)
    #expect(callPolicyWord(callData, offset: 32) == pathOffset)
    #expect(callPolicyWord(callData, offset: 64) == encodedRecipient)
    #expect(callPolicyWord(callData, offset: 96) == quote.amountIn)
    #expect(callPolicyWord(callData, offset: 128) == quote.amountOutMinimum)
}

private func makeSwapQuote(allowance: Data?, requiresApproval: Bool) throws -> SwapQuote {
    let tokenIn = "0x1111111111111111111111111111111111111111"
    let tokenOut = "0x2222222222222222222222222222222222222222"

    return SwapQuote(
        chainID: 1,
        factory: "0x4444444444444444444444444444444444444444",
        router: "0x5555555555555555555555555555555555555555",
        quoter: "0x6666666666666666666666666666666666666666",
        tokenIn: tokenIn,
        tokenOut: tokenOut,
        amountIn: try Data(hexString: "64").leftPadded(to: 32),
        quoteAmountOut: try Data(hexString: "5f").leftPadded(to: 32),
        amountOutMinimum: try Data(hexString: "5e").leftPadded(to: 32),
        slippageBps: 100,
        path: try Data(hexString: "\(String(tokenIn.dropFirst(2)))000bb8\(String(tokenOut.dropFirst(2)))"),
        hops: [],
        gasEstimate: "0x0",
        allowance: allowance,
        requiresApproval: requiresApproval
    )
}

private func callPolicyWord(_ callData: Data, offset: Int) -> Data {
    let start = 4 + offset
    return callData.subdata(in: start..<(start + 32))
}

private extension String {
    var lowercasedAddress: String {
        "0x" + String(dropFirst(2)).lowercased()
    }
}
