import Foundation
import Testing
import LocalLLM
@testable import WalletToolLayer

@Test func transferToolHasRequiredFields() throws {
    let tools = ToolDefinitions.phase1
    let transfer = try #require(tools.first { $0.name == "transfer" })
    let schema = try JSONSerialization.jsonObject(with: Data(transfer.parametersJSONSchema.utf8)) as! [String: Any]
    let props = schema["properties"] as! [String: Any]
    #expect(props["to"] != nil)
    #expect(props["amount"] != nil)
    #expect(props["token"] != nil)
    let required = schema["required"] as! [String]
    #expect(required.sorted() == ["amount", "to"])
}

@Test func swapToolOnlySupportsInputAmountSide() throws {
    let tools = ToolDefinitions.phase1
    let swap = try #require(tools.first { $0.name == "swap" })
    let schema = try JSONSerialization.jsonObject(with: Data(swap.parametersJSONSchema.utf8)) as! [String: Any]
    let props = schema["properties"] as! [String: Any]
    let amountSide = props["amount_side"] as! [String: Any]
    let enumValues = amountSide["enum"] as! [String]
    #expect(enumValues == ["input"])
    let required = schema["required"] as! [String]
    #expect(required.sorted() == ["amount", "from_token", "to_token"])
}

@Test func phase1ContainsExactlyTwoTools() {
    #expect(ToolDefinitions.phase1.count == 2)
    #expect(ToolDefinitions.phase1.map(\.name).sorted() == ["swap", "transfer"])
}

@Test func systemNudgeMentionsToolCallObligation() {
    let nudge = ToolDefinitions.systemNudge
    #expect(nudge.contains("on-chain action"))
    #expect(nudge.contains("MUST call"))
    #expect(nudge.contains("Never invent"))
}
