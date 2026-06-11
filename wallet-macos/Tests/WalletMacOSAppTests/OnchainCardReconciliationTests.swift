import Foundation
import Testing
import WalletToolLayer
@testable import WalletMacOSApp

private func historyRecord(
    userOpHash: String,
    status: WalletTransactionStatus,
    txHash: String?
) -> WalletTransactionRecord {
    WalletTransactionRecord(
        chainID: 11_155_111,
        chainName: "Ethereum Sepolia",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        operation: .transfer,
        status: status,
        userOpHash: userOpHash,
        transactionHash: txHash
    )
}

private func submittedSummary(userOpHash: String) -> OnchainTransactionSummary {
    OnchainTransactionSummary(
        chainName: "Ethereum Sepolia",
        chainID: 11_155_111,
        amount: "0.1",
        token: "ETH",
        recipient: "0x1111111111111111111111111111111111111111",
        recipientName: nil,
        resolvedRecipient: nil,
        resolutionChainName: nil,
        resolutionChainID: nil,
        ccipReadUsed: nil,
        operation: .transfer,
        amountOut: nil,
        minimumReceived: nil,
        route: nil,
        userOpHash: userOpHash,
        transactionHash: nil,
        status: .submitted,
        createdAt: Date(timeIntervalSince1970: 100)
    )
}

private func freshChatStore() -> (ChatSQLiteStore, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("chat-\(UUID().uuidString)")
        .appendingPathExtension("sqlite")
    return (ChatSQLiteStore(databaseURL: url), url)
}

@Test func showsSpeedUpAndCancelOnlyWhenEscapable() {
    #expect(OnchainTransactionActions.canEscape(status: .submitted, blocked: false) == true)
    #expect(OnchainTransactionActions.canEscape(status: .pending, blocked: false) == true)
    #expect(OnchainTransactionActions.canEscape(status: .included, blocked: false) == false)
    #expect(OnchainTransactionActions.canEscape(status: .submitted, blocked: true) == true)
}

@Test func blockedReasonShownWhenBlocked() {
    #expect(OnchainTransactionActions.displayBlockedReason(blocked: true, reason: "gas_relay_stuck") == "Speed up unavailable: gas exceeds cap. Cancel is still available.")
    #expect(OnchainTransactionActions.displayBlockedReason(blocked: false, reason: "gas_relay_stuck") == nil)
}

@Test func summaryStatusCollapsesWalletTransactionStatusCases() {
    #expect(OnchainTransactionSummary.Status(historyStatus: .included) == .included)
    #expect(OnchainTransactionSummary.Status(historyStatus: .reverted) == .reverted)
    #expect(OnchainTransactionSummary.Status(historyStatus: .failed) == .reverted)
    #expect(OnchainTransactionSummary.Status(historyStatus: .submitted) == .submitted)
    #expect(OnchainTransactionSummary.Status(historyStatus: .created) == .pending)
    #expect(OnchainTransactionSummary.Status(historyStatus: .pending) == .pending)
    #expect(OnchainTransactionSummary.Status(historyStatus: .unknown) == .pending)
    #expect(OnchainTransactionSummary.Status(historyStatus: .looksIncluded) == .pending)
    #expect(OnchainTransactionSummary.Status(historyStatus: .cancelled) == .cancelled)
    #expect(OnchainTransactionSummary.Status(historyStatus: .dropped) == .reverted)
}

@Test func decodeRoundTripsOnchainTransactionMessage() throws {
    let summary = submittedSummary(userOpHash: "0xAAA")
    let message = ChatMessage.onchainTransaction(summary)
    let decoded = try #require(OnchainTransactionSummary.decode(from: message))
    #expect(decoded == summary)
    #expect(OnchainTransactionSummary.decode(from: ChatMessage.userText("hi")) == nil)
}

@Test func onchainTransactionSigningModeIsOptionalAndPreserved() throws {
    var summary = submittedSummary(userOpHash: "0xAAA")
    #expect(summary.signingMode == nil)

    summary = OnchainTransactionSummary(
        chainName: summary.chainName,
        chainID: summary.chainID,
        amount: summary.amount,
        token: summary.token,
        recipient: summary.recipient,
        recipientName: summary.recipientName,
        resolvedRecipient: summary.resolvedRecipient,
        resolutionChainName: summary.resolutionChainName,
        resolutionChainID: summary.resolutionChainID,
        ccipReadUsed: summary.ccipReadUsed,
        operation: summary.operation,
        signingMode: "session",
        amountOut: summary.amountOut,
        minimumReceived: summary.minimumReceived,
        route: summary.route,
        userOpHash: summary.userOpHash,
        transactionHash: summary.transactionHash,
        status: summary.status,
        createdAt: summary.createdAt
    )

    let decoded = try #require(OnchainTransactionSummary.decode(from: .onchainTransaction(summary)))
    #expect(decoded.signingMode == "session")
    #expect(decoded.reconciled(with: historyRecord(
        userOpHash: "0xaaa",
        status: .included,
        txHash: "0xTX"
    )).signingMode == "session")
}

@Test func reconciledSummaryAdoptsIncludedStatusAndTxHashByUserOpHash() {
    let summary = submittedSummary(userOpHash: "0xAAA")
    let updated = summary.reconciled(with: historyRecord(
        userOpHash: "0xaaa",
        status: .included,
        txHash: "0xTX"
    ))
    #expect(updated.status == .included)
    #expect(updated.transactionHash == "0xTX")
    #expect(updated.userOpHash == summary.userOpHash)
    #expect(updated.amount == summary.amount)
}

@Test func reconciledSummaryIgnoresNonMatchingUserOpHash() {
    let summary = submittedSummary(userOpHash: "0xAAA")
    #expect(summary.reconciled(with: historyRecord(
        userOpHash: "0xBBB",
        status: .included,
        txHash: "0xTX"
    )) == summary)
}

@Test func reconciledSummaryMarksRevertedOnFailureReceipt() {
    let summary = submittedSummary(userOpHash: "0xAAA")
    #expect(summary.reconciled(with: historyRecord(
        userOpHash: "0xAAA",
        status: .reverted,
        txHash: "0xTX"
    )).status == .reverted)
}

@Test func reconciledSummaryMarksCancelledReplacementAsCancelled() {
    let summary = submittedSummary(userOpHash: "0xAAA")
    let updated = summary.reconciled(with: historyRecord(
        userOpHash: "0xAAA",
        status: .cancelled,
        txHash: "0xCANCEL"
    ))
    #expect(updated.status == .cancelled)
    #expect(updated.transactionHash == "0xCANCEL")
}

@Test func reconcileMessagesUpdatesMatchingOnchainCardPreservingMessageID() throws {
    let original = ChatMessage.onchainTransaction(submittedSummary(userOpHash: "0xAAA"))
    let other = ChatMessage.userText("hello")
    let out = reconcileMessages(
        [other, original],
        with: [historyRecord(userOpHash: "0xAAA", status: .included, txHash: "0xTX")]
    )
    let updatedCard = try #require(out.first { $0.kind == .onchainTransaction })
    #expect(updatedCard.id == original.id)
    let decoded = try #require(OnchainTransactionSummary.decode(from: updatedCard))
    #expect(decoded.status == .included)
    #expect(decoded.transactionHash == "0xTX")
    #expect(out.first?.text == "hello")
}

@Test func reconcileMessagesLeavesUnmatchedCardsUnchanged() {
    let original = ChatMessage.onchainTransaction(submittedSummary(userOpHash: "0xAAA"))
    let out = reconcileMessages(
        [original],
        with: [historyRecord(userOpHash: "0xZZZ", status: .included, txHash: "0xTX")]
    )
    #expect(out == [original])
}

@Test func reconciledRowUpdatesPersistedCardJSON() throws {
    let (store, url) = freshChatStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let conversation = ChatConversation(title: "t", messages: [])
    try store.createConversation(conversation)
    let card = ChatMessage.onchainTransaction(submittedSummary(userOpHash: "0xAAA"))
    try store.appendMessage(card, to: conversation.id)

    let reconciled = reconcileMessages(
        [card],
        with: [historyRecord(userOpHash: "0xAAA", status: .included, txHash: "0xTX")]
    )[0]
    try store.updateMessage(reconciled, in: conversation.id)

    let loaded = try #require(try store.loadConversations().first { $0.id == conversation.id })
    let stored = try #require(loaded.messages.first { $0.kind == .onchainTransaction })
    #expect(stored.id == card.id)
    let decoded = try #require(OnchainTransactionSummary.decode(from: stored))
    #expect(decoded.status == .included)
    #expect(decoded.transactionHash == "0xTX")
}
