import Foundation
import Testing
@testable import WalletToolLayer

@Test func toolIntentRoundTripsThroughJSON() throws {
    let intent = ToolIntent(
        id: UUID(),
        tool: .transfer,
        args: ["to": "vitalik.eth", "amount": "0.1", "token": "ETH"],
        rawDSL: "<|tool_call>call:transfer{...}<tool_call|>",
        source: .model,
        disposition: .pending,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let data = try JSONEncoder().encode(intent)
    let decoded = try JSONDecoder().decode(ToolIntent.self, from: data)
    #expect(decoded == intent)
}

@Test func toolIntentSourceAndDispositionRawValues() {
    #expect(ToolIntent.Source.model.rawValue == "model")
    #expect(ToolIntent.Source.slash.rawValue == "slash")
    #expect(ToolIntent.Disposition.pending.rawValue == "pending")
    #expect(ToolIntent.Disposition.confirmed.rawValue == "confirmed")
    #expect(ToolIntent.Disposition.edited.rawValue == "edited")
    #expect(ToolIntent.Disposition.rejected.rawValue == "rejected")
}

@Test func toolIntentToolRawValues() {
    #expect(ToolIntent.Tool.transfer.rawValue == "transfer")
    #expect(ToolIntent.Tool.swap.rawValue == "swap")
}
