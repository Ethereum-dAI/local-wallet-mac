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

@Test func shieldToolRequiresAmount() throws {
    let tools = ToolDefinitions.phase1
    let shield = try #require(tools.first { $0.name == "shield" })
    let schema = try JSONSerialization.jsonObject(with: Data(shield.parametersJSONSchema.utf8)) as! [String: Any]
    let props = schema["properties"] as! [String: Any]
    #expect(props["amount"] != nil)
    #expect(props["token"] != nil)
    let required = schema["required"] as! [String]
    #expect(required == ["amount"])
}

@Test func unshieldToolRequiresAmountAndRecipient() throws {
    let tools = ToolDefinitions.phase1
    let unshield = try #require(tools.first { $0.name == "unshield" })
    let schema = try JSONSerialization.jsonObject(with: Data(unshield.parametersJSONSchema.utf8)) as! [String: Any]
    let props = schema["properties"] as! [String: Any]
    #expect(props["amount"] != nil)
    #expect(props["to"] != nil)
    let required = schema["required"] as! [String]
    #expect(required.sorted() == ["amount", "to"])
}

@Test func phase1ContainsAllFourTools() {
    #expect(ToolDefinitions.phase1.count == 4)
    #expect(ToolDefinitions.phase1.map(\.name).sorted() == ["shield", "swap", "transfer", "unshield"])
}

@Test func systemNudgeMentionsToolCallObligation() {
    let nudge = ToolDefinitions.systemNudge
    #expect(nudge.contains("on-chain action"))
    #expect(nudge.contains("MUST call"))
    #expect(nudge.contains("Never invent"))
}
