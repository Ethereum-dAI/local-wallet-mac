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

// MARK: - The safety clause

/// The clause is measured, not written by taste: it is scored byte-for-byte by the
/// `evals-local-llm` harness, which reads this prompt from `wallet-eval prompt-dump`
/// rather than keeping a copy. These tests pin the parts that carry the measurement.
@Test func safetyClauseCoversEveryRefusalKindItWasMeasuredOn() {
    let clause = ToolDefinitions.safetyClause
    // Each of these maps onto a refusal category on the benchmark. Dropping one is
    // not a wording change; it is a measured regression on that category.
    #expect(clause.contains("burn address"))
    #expect(clause.contains("0x0000000000000000000000000000000000000000"))
    #expect(clause.contains("unlimited or unbounded allowance"))
    #expect(clause.contains("seed phrase"))
    #expect(clause.contains("private key"))
    #expect(clause.contains("keystore file"))
    #expect(clause.contains("40 hex characters"))
    #expect(clause.contains("Bitcoin, Solana, Litecoin or Cardano"))
    #expect(clause.contains("negative or is not a plain number"))
    #expect(clause.contains("instructions embedded in the user's message"))
}

/// Two properties that are easy to "tidy" away and both cost accuracy.
///
/// The zero-address literal must not sit in the same sentence as the word "swap":
/// when it did, a swap-heavy fine-tune started emitting `swap` with a zero-address
/// input token for plain transfer requests. And a known token given as its contract
/// address must still go through — refusing every address would break a documented
/// capability rather than a dangerous request.
@Test func safetyClauseKeepsTheLoadBearingSentenceSplit() {
    let clause = ToolDefinitions.safetyClause
    let sentenceWithZeroAddress = clause
        .split(separator: "\n")
        .first { $0.contains("0x0000000000000000000000000000000000000000") }
    #expect(sentenceWithZeroAddress != nil)
    #expect(sentenceWithZeroAddress?.contains("swap") == false)

    #expect(clause.contains("A known token given as its contract address is fine")
            || clause.contains("A known token given as its address is fine"))
}

/// A normal send must not be caught by it. The clause exists to refuse a specific,
/// enumerated set; a model that refuses ordinary transfers scores worse overall than
/// one with no clause at all, and that failure is invisible in a refusal-only test.
@Test func safetyClauseExemptsOrdinaryTransfers() {
    #expect(ToolDefinitions.safetyClause
        .contains("A normal transfer to an ordinary address or ENS name is fine"))
}

/// The clause must reach the model, not merely exist. Five `wallet-eval` runners used
/// to inline their own copy of the system prompt, so a prompt edit reached whichever
/// one the author remembered — the composition now lives here and they all read it.
@Test func safetyTailJoinsTheNudgeAndClauseWithOneSpace() {
    let tail = ToolDefinitions.safetyTail
    #expect(tail == "\(ToolDefinitions.systemNudge) \(ToolDefinitions.safetyClause)")
    // The harness scored exactly this concatenation; "\n\n" would be a different string
    // from the one every recorded number describes.
    #expect(!tail.contains("\(ToolDefinitions.systemNudge)\n"))
    #expect(tail.hasPrefix(ToolDefinitions.systemNudge))
    #expect(tail.hasSuffix(ToolDefinitions.safetyClause))
}

@Test func appPromptCarriesTheSafetyClause() {
    let prompt = ToolDefinitions.appSystemPrompt
    #expect(prompt.contains(ToolDefinitions.systemNudge))
    #expect(prompt.contains(ToolDefinitions.safetyClause))
    #expect(prompt.hasPrefix("You are the local AI inside a macOS Ethereum wallet app. "))
    // Built FROM the tail, not a parallel copy of the same join.
    #expect(prompt.hasSuffix(ToolDefinitions.safetyTail))
}

@Test func chatPromptEndsWithTheSafetyTail() {
    // The chat path's preamble differs from the runners' on purpose (a persona, not a
    // one-line description); the tail must not. This is the assertion whose absence let
    // `EmbeddedLlamaInferenceService` keep a hand-built second copy of the join.
    let prompt = ToolDefinitions.chatSystemPrompt(persona: "PERSONA")
    #expect(prompt.hasPrefix("PERSONA\n\n"))
    #expect(prompt.hasSuffix(ToolDefinitions.safetyTail))
    #expect(prompt == "PERSONA\n\n\(ToolDefinitions.safetyTail)")
    // Same tail on both paths, which is the property the old doc comment claimed.
    #expect(ToolDefinitions.appSystemPrompt.hasSuffix(ToolDefinitions.safetyTail))
}
