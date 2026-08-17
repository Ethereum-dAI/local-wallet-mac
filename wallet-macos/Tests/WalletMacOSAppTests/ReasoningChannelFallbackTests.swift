import Foundation
import Testing
@testable import WalletMacOSApp
@testable import WalletToolLayer

/// Qwen3 emits `<think> … </think>`, which the Gemma-only fallback did not
/// recognise — so the whole reasoning monologue was printed to the user as the
/// answer. These cover both marker styles and the streaming states in between.
struct ReasoningChannelFallbackTests {
    /// Verbatim shape of the leak that was reported: `</think>` butted straight
    /// against the answer, no newline.
    @Test func qwenThinkBlockIsSplitOffTheAnswer() {
        let raw = "<think>\nOkay, the user is asking again. Keep it consistent. </think>Ethereum is a decentralized blockchain."
        let split = ReasoningChannelFallback.streamingSplit(of: raw)
        #expect(split.content == "Ethereum is a decentralized blockchain.")
        #expect(split.reasoning?.contains("Keep it consistent") == true)
        #expect(split.content.contains("<think>") == false)
        #expect(split.content.contains("</think>") == false)
    }

    /// Gemma's style still works, channel name still dropped.
    @Test func gemmaChannelMarkersStillSplitAndDropTheChannelName() {
        let raw = "<|channel>thought weighing the options<channel|>Here is the answer."
        let split = ReasoningChannelFallback.streamingSplit(of: raw)
        #expect(split.content == "Here is the answer.")
        #expect(split.reasoning == "weighing the options")
    }

    /// `<think>` has no channel name; stripping leading letters would eat the first
    /// word of the reasoning.
    @Test func theFirstWordOfQwensReasoningSurvives() {
        let split = ReasoningChannelFallback.streamingSplit(of: "<think>Okay so</think>Answer.")
        #expect(split.reasoning == "Okay so")
    }

    /// Several templates pre-fill the opening tag, so the model's own output starts
    /// inside the reasoning and only ever closes it.
    @Test func aClosingTagWithNoOpenerTreatsEverythingBeforeItAsReasoning() {
        let split = ReasoningChannelFallback.streamingSplit(of: "weighing it up</think>The answer is 42.")
        #expect(split.reasoning == "weighing it up")
        #expect(split.content == "The answer is 42.")
    }

    /// Mid-stream: reasoning has opened and not closed, so nothing is an answer yet.
    @Test func anUnclosedThinkBlockPublishesNoContent() {
        let split = ReasoningChannelFallback.streamingSplit(of: "<think>still working")
        #expect(split.reasoning == "still working")
        #expect(split.content.isEmpty)
    }

    @Test func plainTextIsLeftAlone() {
        let split = ReasoningChannelFallback.streamingSplit(of: "Ethereum is a blockchain.")
        #expect(split.reasoning == nil)
        #expect(split.content == "Ethereum is a blockchain.")
    }

    /// Text either side of the block is one answer, not two.
    @Test func contentBeforeAndAfterTheBlockIsJoined() {
        let split = ReasoningChannelFallback.streamingSplit(of: "Short answer: yes.<think>because</think>Longer version follows.")
        #expect(split.reasoning == "because")
        #expect(split.content == "Short answer: yes.\n\nLonger version follows.")
    }

    /// `normalise` only rescues a turn the parser left unsplit; a turn that already
    /// has reasoning must not be re-split.
    @Test func normaliseLeavesAnAlreadySplitTurnAlone() {
        let parsed = ParsedAssistantTurnFlat(content: "Answer.", reasoning: "already split", toolCalls: [])
        let result = ReasoningChannelFallback.normalise(parsed)
        #expect(result.content == "Answer.")
        #expect(result.reasoning == "already split")
    }

    @Test func normaliseStripsMarkersFromAnExistingReasoningField() {
        let parsed = ParsedAssistantTurnFlat(
            content: nil,
            reasoning: "<think>Which token? ETH or another ERC-20?</think>",
            toolCalls: []
        )
        let result = ReasoningChannelFallback.normalise(parsed)

        #expect(result.reasoning == "Which token? ETH or another ERC-20?")
        #expect(result.content == nil)
        #expect(result.toolCalls.isEmpty)
    }

    @Test func sanitizerHandlesKnownOuterMarkersAndWhitespace() {
        #expect(
            ReasoningChannelFallback.sanitizedReasoning(
                "  <think> deciding </think>  "
            ) == "deciding"
        )
        #expect(
            ReasoningChannelFallback.sanitizedReasoning(
                "<|channel>thought weighing the options<channel|>"
            ) == "weighing the options"
        )
    }

    @Test func sanitizerPreservesEmbeddedOrUnmatchedMarkerExamples() {
        #expect(
            ReasoningChannelFallback.sanitizedReasoning("Explain <think> tags")
                == "Explain <think> tags"
        )
        #expect(
            ReasoningChannelFallback.sanitizedReasoning("<think>unfinished")
                == "<think>unfinished"
        )
    }

    @Test func sanitizerDropsAnEmptyOuterBlock() {
        #expect(ReasoningChannelFallback.sanitizedReasoning(" <think>  </think> ") == nil)
    }

    @Test func normaliseRescuesAQwenTurnTheParserMissed() {
        let parsed = ParsedAssistantTurnFlat(
            content: "<think>deciding</think>Ethereum is a blockchain.",
            reasoning: nil,
            toolCalls: []
        )
        let result = ReasoningChannelFallback.normalise(parsed)
        #expect(result.content == "Ethereum is a blockchain.")
        #expect(result.reasoning == "deciding")
    }

    /// Reasoning must never swallow a tool call — that would silently drop a
    /// transfer the user asked for.
    @Test func toolCallsSurviveTheSplit() {
        let call = ParsedToolCall(id: "call-1", name: "transfer", arguments: ["to": "0xdead"])
        let parsed = ParsedAssistantTurnFlat(
            content: "<think>they want a transfer</think>Sending now.",
            reasoning: nil,
            toolCalls: [call]
        )
        let result = ReasoningChannelFallback.normalise(parsed)
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls.first?.name == "transfer")
        #expect(result.content == "Sending now.")
    }

    /// A model emitting both styles is split at whichever came first, not at
    /// whichever the marker table happens to list first.
    @Test func theEarliestMarkerWins() {
        let split = ReasoningChannelFallback.streamingSplit(of: "<think>first</think>mid<|channel>x second<channel|>end")
        #expect(split.reasoning == "first")
        #expect(split.content.hasPrefix("mid"))
    }

}
