import XCTest
@testable import WalletToolLayer

/// Qwen-family models emit `<tool_call>{json}</tool_call>`, which differs from
/// Gemma's `<|tool_call>call:…<tool_call|>` by a single pipe. That one character
/// meant the wallet could not execute a tool call from any Qwen model: the Gemma
/// fallback is gated on `contains("<|tool_call>")`, which Hermes output can never
/// satisfy, and upstream llama.cpp rejects the turn outright. These tests pin the
/// distinction so it cannot regress.
final class HermesFallbackParserTests: XCTestCase {

    func testParsesASingleCall() {
        let text = """
        <tool_call>
        {"name": "transfer", "arguments": {"to": "vitalik.eth", "amount": "0.25", "token": "ETH"}}
        </tool_call>
        """
        let calls = HermesFallbackParser.parse(text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "transfer")
        XCTAssertEqual(calls[0].arguments["to"], "vitalik.eth")
        XCTAssertEqual(calls[0].arguments["amount"], "0.25")
        XCTAssertEqual(calls[0].arguments["token"], "ETH")
    }

    func testParsesCallPrecededByAThinkBlock() {
        // The shape Qwen actually produced in the funnel probe.
        let text = """
        <think>This is a transfer. The wallet takes amount in human units.</think>
        <tool_call>
        {"name": "transfer", "arguments": {"to": "0x000000000000000000000000000000000000dEaD", "amount": "0.07", "token": "DAI"}}
        </tool_call>
        """
        let calls = HermesFallbackParser.parse(text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "transfer")
        XCTAssertEqual(HermesFallbackParser.reasoning(in: text),
                       "This is a transfer. The wallet takes amount in human units.")
        XCTAssertNil(HermesFallbackParser.content(in: text),
                     "reasoning and the call block are not user-facing prose")
    }

    func testParsesMultipleCalls() {
        let text = """
        <tool_call>
        {"name": "transfer", "arguments": {"to": "a.eth", "amount": "1"}}
        </tool_call>
        <tool_call>
        {"name": "swap", "arguments": {"from_token": "ETH", "to_token": "USDC", "amount": "2"}}
        </tool_call>
        """
        let calls = HermesFallbackParser.parse(text)
        XCTAssertEqual(calls.map(\.name), ["transfer", "swap"])
        XCTAssertEqual(calls[0].id, "call_0")
        XCTAssertEqual(calls[1].id, "call_1")
    }

    func testNonStringArgumentsAreSerialisedNotDropped() {
        let text = #"<tool_call>{"name":"transfer","arguments":{"to":"a.eth","amount":5,"tags":["x"]}}</tool_call>"#
        let calls = HermesFallbackParser.parse(text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].arguments["amount"], "5")
        XCTAssertEqual(calls[0].arguments["tags"], "[\"x\"]")
    }

    func testArgumentsSuppliedAsAJSONStringAreAccepted() {
        let text = #"<tool_call>{"name":"swap","arguments":"{\"from_token\":\"ETH\",\"to_token\":\"DAI\",\"amount\":\"1\"}"}</tool_call>"#
        let calls = HermesFallbackParser.parse(text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].arguments["from_token"], "ETH")
        XCTAssertEqual(calls[0].arguments["to_token"], "DAI")
    }

    func testOneMalformedBlockDoesNotDiscardAGoodOne() {
        let text = """
        <tool_call>
        {"name": "transfer", "arguments": {"to": "a.eth", "amount": "1"}}
        </tool_call>
        <tool_call>
        {"name": "swap", "arguments": {  TRUNCATED
        """
        let calls = HermesFallbackParser.parse(text)
        XCTAssertEqual(calls.count, 1, "the well-formed call must survive")
        XCTAssertEqual(calls[0].name, "transfer")
    }

    func testUnterminatedBlockYieldsNothing() {
        let text = #"<tool_call>{"name": "transfer", "arguments": {"to": "a.eth""#
        XCTAssertTrue(HermesFallbackParser.parse(text).isEmpty)
    }

    func testGemmaDSLIsNotMistakenForHermes() {
        // The whole point of the pipe: Gemma output must not route here.
        let gemma = #"<|tool_call>call:transfer{to:<|"|>vitalik.eth<|"|>}<tool_call|>"#
        XCTAssertFalse(HermesFallbackParser.looksLikeHermes(gemma))
        XCTAssertTrue(HermesFallbackParser.parse(gemma).isEmpty)
    }

    func testPlainProseIsNotAToolCall() {
        let prose = "I can't send funds to a burn address. Did you mean a different recipient?"
        XCTAssertFalse(HermesFallbackParser.looksLikeHermes(prose))
        XCTAssertTrue(HermesFallbackParser.parse(prose).isEmpty)
        XCTAssertEqual(HermesFallbackParser.content(in: prose), prose)
    }

    func testContentKeepsProseAlongsideACall() {
        let text = """
        Sending that now.
        <tool_call>
        {"name": "transfer", "arguments": {"to": "a.eth", "amount": "1"}}
        </tool_call>
        """
        XCTAssertEqual(HermesFallbackParser.content(in: text), "Sending that now.")
    }

    // MARK: - dispatch

    func testFallbackTurnRoutesHermes() {
        let text = #"<tool_call>{"name":"swap","arguments":{"from_token":"ETH","to_token":"USDC","amount":"1"}}</tool_call>"#
        let turn = BridgePEGExtractor.fallbackTurn(from: text)
        XCTAssertEqual(turn?.toolCalls.first?.name, "swap")
    }

    func testFallbackTurnRoutesGemma() {
        let text = #"<|tool_call>call:transfer{to:<|"|>vitalik.eth<|"|>,amount:<|"|>1<|"|>}<tool_call|>"#
        let turn = BridgePEGExtractor.fallbackTurn(from: text)
        XCTAssertEqual(turn?.toolCalls.first?.name, "transfer")
    }

    func testFallbackTurnReturnsNilWhenNoDialectMatches() {
        XCTAssertNil(BridgePEGExtractor.fallbackTurn(from: "just some prose"))
    }
}
