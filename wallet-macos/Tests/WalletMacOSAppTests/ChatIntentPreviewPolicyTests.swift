import Foundation
import Testing
import WalletToolLayer
@testable import WalletMacOSApp

@Test func automaticIntentPreviewOnlyRunsForLatestToolIntentCard() {
    let first = toolIntentMessage(tool: .swap)
    let second = toolIntentMessage(tool: .transfer)
    let messages = [
        ChatMessage.userText("swap 0.05 eth to usdc"),
        first,
        ChatMessage.assistantText("Some follow-up"),
        second
    ]

    #expect(ChatIntentPreviewPolicy.shouldAutomaticallyPreparePreview(for: first, in: messages) == false)
    #expect(ChatIntentPreviewPolicy.shouldAutomaticallyPreparePreview(for: second, in: messages))
}

@Test func automaticIntentPreviewDoesNotRunForHandledLatestCard() throws {
    let intent = ToolIntent(tool: .swap, args: ["amount": "0.05"], source: .model)
    let card = ChatMessage(kind: .toolIntent, role: .assistant, toolIntent: intent)
    let response = ChatMessage(
        kind: .toolResponse,
        role: .tool,
        text: #"{"status":"acknowledged"}"#,
        toolCallId: intent.id.uuidString
    )
    let messages = [
        ChatMessage.userText("swap 0.05 eth to usdc"),
        card,
        response
    ]

    #expect(ChatIntentPreviewPolicy.shouldAutomaticallyPreparePreview(for: card, in: messages) == false)
}

@Test func automaticIntentPreviewDoesNotRunForOlderPendingCardAfterHandledCard() {
    let oldPending = toolIntentMessage(tool: .swap)
    let handledIntent = ToolIntent(
        tool: .transfer,
        args: ["amount": "0.01", "token": "ETH"],
        source: .model,
        disposition: .confirmed
    )
    let handledCard = ChatMessage(kind: .toolIntent, role: .assistant, toolIntent: handledIntent)
    let messages = [
        oldPending,
        handledCard,
        ChatMessage(
            kind: .toolResponse,
            role: .tool,
            text: #"{"status":"submitted"}"#,
            toolCallId: handledIntent.id.uuidString
        )
    ]

    #expect(ChatIntentPreviewPolicy.shouldAutomaticallyPreparePreview(for: oldPending, in: messages) == false)
}

private func toolIntentMessage(tool: ToolIntent.Tool) -> ChatMessage {
    ChatMessage(
        kind: .toolIntent,
        role: .assistant,
        toolIntent: ToolIntent(
            tool: tool,
            args: ["amount": "0.05"],
            source: .model
        )
    )
}
