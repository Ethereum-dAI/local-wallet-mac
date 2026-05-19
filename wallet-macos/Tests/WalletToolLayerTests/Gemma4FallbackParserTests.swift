import Foundation
import Testing
@testable import WalletToolLayer

@Test func parsesSingleTransferCall() {
    let raw = #"<|tool_call>call:transfer{to:<|"|>vitalik.eth<|"|>,amount:<|"|>0.1<|"|>,token:<|"|>ETH<|"|>}<tool_call|>"#
    let calls = Gemma4FallbackParser.parse(raw)
    #expect(calls.count == 1)
    let call = calls[0]
    #expect(call.name == "transfer")
    #expect(call.arguments["to"] == "vitalik.eth")
    #expect(call.arguments["amount"] == "0.1")
    #expect(call.arguments["token"] == "ETH")
}

@Test func parsesSingleSwapCall() {
    let raw = #"<|tool_call>call:swap{from_token:<|"|>USDC<|"|>,to_token:<|"|>ETH<|"|>,amount:<|"|>100<|"|>,amount_side:<|"|>input<|"|>}<tool_call|>"#
    let calls = Gemma4FallbackParser.parse(raw)
    #expect(calls.count == 1)
    #expect(calls[0].name == "swap")
    #expect(calls[0].arguments["from_token"] == "USDC")
    #expect(calls[0].arguments["amount_side"] == "input")
}

@Test func parsesMultipleCallsInOneTurn() {
    let raw = """
    <|tool_call>call:transfer{to:<|"|>a.eth<|"|>,amount:<|"|>1<|"|>}<tool_call|> some text in between
    <|tool_call>call:swap{from_token:<|"|>USDC<|"|>,to_token:<|"|>ETH<|"|>,amount:<|"|>50<|"|>}<tool_call|>
    """
    let calls = Gemma4FallbackParser.parse(raw)
    #expect(calls.count == 2)
    #expect(calls[0].name == "transfer")
    #expect(calls[1].name == "swap")
}

@Test func returnsEmptyForPlainText() {
    let calls = Gemma4FallbackParser.parse("Sure, what address?")
    #expect(calls.isEmpty)
}

@Test func returnsEmptyForUnterminatedToolCall() {
    let raw = #"<|tool_call>call:transfer{to:<|"|>vitalik.eth<|"|>"#
    let calls = Gemma4FallbackParser.parse(raw)
    #expect(calls.isEmpty)
}

@Test func handlesValueWithoutQuoteMarkersAsBareString() {
    let raw = #"<|tool_call>call:transfer{to:bare_value,amount:<|"|>0.1<|"|>}<tool_call|>"#
    let calls = Gemma4FallbackParser.parse(raw)
    #expect(calls.count == 1)
    #expect(calls[0].arguments["to"] == "bare_value")
    #expect(calls[0].arguments["amount"] == "0.1")
}
