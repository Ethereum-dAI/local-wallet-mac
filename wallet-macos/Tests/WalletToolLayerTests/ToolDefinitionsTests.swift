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

@Test func bundlerTopUpToolAcceptsAmountOnly() throws {
    let tool = try #require(ToolDefinitions.phase1.first { $0.name == "top_up_bundler" })
    let schema = try #require(
        JSONSerialization.jsonObject(with: Data(tool.parametersJSONSchema.utf8))
            as? [String: Any]
    )
    let properties = try #require(schema["properties"] as? [String: Any])

    #expect(Set(properties.keys) == ["amount"])
    #expect(schema["required"] as? [String] == ["amount"])
    #expect(schema["additionalProperties"] as? Bool == false)
    #expect(tool.description.contains("trusted local state"))
}

@Test func phase1ContainsAllThreeTools() {
    #expect(ToolDefinitions.phase1.count == 3)
    #expect(ToolDefinitions.phase1.map(\.name).sorted() == [
        "swap", "top_up_bundler", "transfer",
    ])
}

@Test func systemNudgeMentionsToolCallObligation() {
    let nudge = ToolDefinitions.systemNudge
    #expect(nudge.contains("on-chain action"))
    #expect(nudge.contains("MUST call"))
    #expect(nudge.contains("Never invent"))
    #expect(nudge.contains("top_up_bundler"))
    #expect(nudge.contains("never invent or request a destination address"))
}
