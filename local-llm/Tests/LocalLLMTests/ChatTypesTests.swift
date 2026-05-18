import Foundation
import Testing
@testable import LocalLLM

@Test func toolDefinitionSerializesToOpenAISchema() throws {
    let tool = ToolDefinition(
        name: "transfer",
        description: "Send tokens.",
        parametersJSONSchema: """
        {"type":"object","properties":{"to":{"type":"string"}},"required":["to"]}
        """
    )

    let json = ToolDefinition.toOpenAISchemaJSON([tool])
    let data = try #require(json.data(using: .utf8))
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let wrapper = try #require(root.first)

    #expect(root.count == 1)
    #expect(wrapper["type"] as? String == "function")

    let function = try #require(wrapper["function"] as? [String: Any])
    #expect(function["name"] as? String == "transfer")
    #expect(function["description"] as? String == "Send tokens.")

    let parameters = try #require(function["parameters"] as? [String: Any])
    #expect(parameters["type"] as? String == "object")

    let properties = try #require(parameters["properties"] as? [String: Any])
    let to = try #require(properties["to"] as? [String: Any])
    #expect(to["type"] as? String == "string")
    #expect(parameters["required"] as? [String] == ["to"])
}

@Test func chatMessageRoundTripsThroughJSONEncoder() throws {
    let message = ChatMessage(
        role: .assistant,
        content: "Hi there",
        toolCalls: [
            ToolCall(
                id: "call_0",
                function: ToolCall.Function(name: "transfer", arguments: "{}")
            )
        ],
        reasoning: "thought"
    )

    let data = try JSONEncoder().encode(message)
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

    #expect(decoded == message)
}

@Test func toolDefinitionEscapesQuotesInDescription() throws {
    let tool = ToolDefinition(
        name: "transfer",
        description: #"Send "tokens"."#,
        parametersJSONSchema: #"{"type":"object"}"#
    )

    let json = ToolDefinition.toOpenAISchemaJSON([tool])
    let data = try #require(json.data(using: .utf8))
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let wrapper = try #require(root.first)
    let function = try #require(wrapper["function"] as? [String: Any])

    #expect(function["description"] as? String == #"Send "tokens"."#)
}

@Test func samplerOptionsDefaultsMatchSpec() {
    let options = SamplerOptions()

    #expect(options.temperature == 0.7)
    #expect(options.topP == 0.95)
    #expect(options.topK == 64)
    #expect(options.minP == 0.05)
    #expect(options.repeatPenalty == 1.0)
    #expect(options.maxTokens == 512)
    #expect(options.seed == 0)
    #expect(options.stopSequences == [])
    #expect(options.grammarGBNF == nil)
    #expect(options.enableThinking)
}
