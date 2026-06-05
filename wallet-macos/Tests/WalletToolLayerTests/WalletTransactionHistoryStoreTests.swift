import Foundation
import Testing
@testable import WalletToolLayer

@Test func walletHistoryRecordsSubmittedOperationAsNotDone() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let record = try store.recordSubmitted(
        WalletTransactionDraft(
            operation: .transfer,
            amount: "0.1",
            token: "ETH",
            counterparty: "0x1111111111111111111111111111111111111111"
        ),
        userOpHash: "0xaaa",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 11_155_111,
        chainName: "Ethereum Sepolia",
        createdAt: Date(timeIntervalSince1970: 100)
    )

    #expect(record.status == .submitted)
    #expect(record.status != .included)

    let loaded = try store.loadRecords(accountAddress: "0xabc0000000000000000000000000000000000000", chainID: 11_155_111)
    #expect(loaded.count == 1)
    #expect(loaded[0].userOpHash == "0xaaa")
    #expect(loaded[0].status == .submitted)
}

@Test func walletHistoryKeepsTxHashPendingUntilReceiptConfirmsSuccess() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try store.recordSubmitted(
        WalletTransactionDraft(operation: .swap, amount: "2 USDC", token: "USDC -> ETH"),
        userOpHash: "0xbbb",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 11_155_111,
        chainName: "Ethereum Sepolia"
    )

    let pending = try store.markPending(
        userOpHash: "0xbbb",
        chainID: 11_155_111,
        transactionHash: "0xtxbbb"
    )

    #expect(pending?.transactionHash == "0xtxbbb")
    #expect(pending?.status == .pending)
    #expect(pending?.status != .included)
}

@Test func walletHistoryReceiptSuccessMarksIncluded() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "10", token: "USDC"),
        userOpHash: "0xccc",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )

    let updated = try store.applyReceipt(WalletTransactionReceiptUpdate(
        chainID: 1,
        userOpHash: "0xccc",
        transactionHash: "0xtxccc",
        success: true,
        actualGasCost: "0x10",
        actualGasUsed: "0x20"
    ))

    #expect(updated?.status == .included)
    #expect(updated?.transactionHash == "0xtxccc")
    #expect(updated?.actualGasCost == "0x10")
    #expect(updated?.actualGasUsed == "0x20")
}

@Test func walletHistoryReceiptFailureMarksReverted() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try store.recordSubmitted(
        WalletTransactionDraft(operation: .swap, amount: "2 USDC", token: "USDC -> ETH"),
        userOpHash: "0xddd",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 11_155_111,
        chainName: "Ethereum Sepolia"
    )

    let updated = try store.applyReceipt(WalletTransactionReceiptUpdate(
        chainID: 11_155_111,
        userOpHash: "0xddd",
        transactionHash: "0xtxddd",
        success: false,
        revertReason: "execution reverted"
    ))

    #expect(updated?.status == .reverted)
    #expect(updated?.status != .included)
    #expect(updated?.revertReason == "execution reverted")
}

@Test func walletHistoryDoesNotDowngradeTerminalReceiptDuringBackfill() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xeee",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 11_155_111,
        chainName: "Ethereum Sepolia"
    )
    try store.applyReceipt(WalletTransactionReceiptUpdate(
        chainID: 11_155_111,
        userOpHash: "0xeee",
        transactionHash: "0xtxeee",
        success: true
    ))

    try store.upsert(WalletTransactionRecord(
        chainID: 11_155_111,
        chainName: "Ethereum Sepolia",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        operation: .transfer,
        status: .pending,
        userOpHash: "0xeee",
        amount: "1",
        token: "ETH"
    ))

    let loaded = try #require(try store.loadRecord(userOpHash: "0xeee", chainID: 11_155_111))
    #expect(loaded.status == .included)
    #expect(loaded.transactionHash == "0xtxeee")
}

@Test func walletHistoryDedupesByChainAndUserOperationHash() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xfff",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 11_155_111,
        chainName: "Ethereum Sepolia"
    )
    try store.recordSubmitted(
        WalletTransactionDraft(operation: .swap, amount: "2 USDC", token: "USDC -> ETH"),
        userOpHash: "0xfff",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 11_155_111,
        chainName: "Ethereum Sepolia"
    )
    try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xfff",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )

    #expect(try store.loadRecords(accountAddress: "0xabc0000000000000000000000000000000000000", chainID: 11_155_111).count == 1)
    #expect(try store.loadRecords(accountAddress: "0xabc0000000000000000000000000000000000000").count == 2)
}

@Test func looksIncludedStatusIsNonTerminalAndRefreshable() {
    #expect(WalletTransactionStatus.looksIncluded.isTerminal == false)
    #expect(WalletTransactionStatus.looksIncluded.requiresReceiptRefresh == true)
    #expect(WalletTransactionStatus.looksIncluded.rawValue == "looks_included")
}

@Test func cancelledAndDroppedAreTerminal() {
    #expect(WalletTransactionStatus.cancelled.isTerminal == true)
    #expect(WalletTransactionStatus.dropped.isTerminal == true)
    #expect(WalletTransactionStatus.cancelled.requiresReceiptRefresh == false)
    #expect(WalletTransactionStatus.dropped.requiresReceiptRefresh == false)
    #expect(WalletTransactionStatus.cancelled.hasFinalReceipt == false)
    #expect(WalletTransactionStatus.dropped.hasFinalReceipt == false)
    #expect(WalletTransactionStatus.failed.hasFinalReceipt == false)
    #expect(WalletTransactionStatus.included.hasFinalReceipt == true)
    #expect(WalletTransactionStatus.reverted.hasFinalReceipt == true)
}

@Test func receiptUpdateDefaultsTentativeAndInvalidatedFalse() {
    let update = WalletTransactionReceiptUpdate(
        chainID: 1,
        userOpHash: "0x1",
        transactionHash: "0xtx",
        success: true
    )
    #expect(update.tentative == false)
    #expect(update.invalidated == false)
}

@Test func receiptUpdateAcceptsTentative() {
    let update = WalletTransactionReceiptUpdate(
        chainID: 1,
        userOpHash: "0x1",
        transactionHash: "0xtx",
        success: true,
        tentative: true,
        invalidated: false
    )
    #expect(update.tentative == true)
}

@Test func tentativeReceiptMarksLooksIncludedNotIncluded() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xt1",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )
    let updated = try store.applyReceipt(WalletTransactionReceiptUpdate(
        chainID: 1,
        userOpHash: "0xt1",
        transactionHash: "0xtx",
        success: true,
        tentative: true
    ))
    #expect(updated?.status == .looksIncluded)
    #expect(updated?.status != .included)
    #expect(updated?.transactionHash == "0xtx")
}

@Test func verifiedReceiptStillMarksIncluded() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xt2",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )
    let updated = try store.applyReceipt(WalletTransactionReceiptUpdate(
        chainID: 1,
        userOpHash: "0xt2",
        transactionHash: "0xtx",
        success: true,
        tentative: false
    ))
    #expect(updated?.status == .included)
}

@Test func invalidatedReceiptSelfCorrectsLooksIncludedBackToSubmitted() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xi1",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )
    _ = try store.applyReceipt(WalletTransactionReceiptUpdate(
        chainID: 1,
        userOpHash: "0xi1",
        transactionHash: "0xtx",
        success: true,
        tentative: true
    ))
    let corrected = try store.applyReceipt(WalletTransactionReceiptUpdate(
        chainID: 1,
        userOpHash: "0xi1",
        transactionHash: "0xtx",
        success: true,
        tentative: true,
        invalidated: true
    ))
    #expect(corrected?.status == .submitted)
    #expect(corrected?.transactionHash == nil)
}

@Test func upsertAllowsLooksIncludedToBeRefreshedToIncluded() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xr1",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )
    _ = try store.applyReceipt(WalletTransactionReceiptUpdate(
        chainID: 1,
        userOpHash: "0xr1",
        transactionHash: "0xtx",
        success: true,
        tentative: true
    ))
    let verified = try store.applyReceipt(WalletTransactionReceiptUpdate(
        chainID: 1,
        userOpHash: "0xr1",
        transactionHash: "0xtx",
        success: true
    ))
    #expect(verified?.status == .included)
}

@Test func markCancelledFinalizesNonTerminalRow() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xc1",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )
    let cancelled = try store.markCancelled(
        userOpHash: "0xc1",
        chainID: 1,
        transactionHash: "0xcancel"
    )
    #expect(cancelled?.status == .cancelled)
    #expect(cancelled?.transactionHash == "0xcancel")
}

@Test func markCancelledDoesNotOverrideIncluded() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xc2",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )
    _ = try store.applyReceipt(WalletTransactionReceiptUpdate(
        chainID: 1,
        userOpHash: "0xc2",
        transactionHash: "0xtx",
        success: true
    ))
    let result = try store.markCancelled(userOpHash: "0xc2", chainID: 1)
    #expect(result?.status == .included)
}

@Test func markCancelledWithReplacementHashCorrectsRevertedRace() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xc3",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )
    _ = try store.applyReceipt(WalletTransactionReceiptUpdate(
        chainID: 1,
        userOpHash: "0xc3",
        transactionHash: "0xsynthetic",
        success: false
    ))
    let result = try store.markCancelled(
        userOpHash: "0xc3",
        chainID: 1,
        transactionHash: "0xcancel"
    )
    #expect(result?.status == .cancelled)
    #expect(result?.transactionHash == "0xcancel")
}

@Test func receiptOverridesCancelledWhenUserOperationLanded() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xc4",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )
    _ = try store.markCancelled(
        userOpHash: "0xc4",
        chainID: 1,
        transactionHash: "0xcancel"
    )
    let result = try store.applyReceipt(WalletTransactionReceiptUpdate(
        chainID: 1,
        userOpHash: "0xc4",
        transactionHash: "0xlanded",
        success: true
    ))
    #expect(result?.status == .included)
    #expect(result?.transactionHash == "0xlanded")
}

@Test func invalidatedReceiptDoesNotReopenCancelledRow() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xc5",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )
    _ = try store.markCancelled(
        userOpHash: "0xc5",
        chainID: 1,
        transactionHash: "0xcancel"
    )
    let result = try store.applyReceipt(WalletTransactionReceiptUpdate(
        chainID: 1,
        userOpHash: "0xc5",
        transactionHash: "0xinvalidated",
        success: true,
        invalidated: true
    ))
    #expect(result?.status == .cancelled)
    #expect(result?.transactionHash == "0xcancel")
}

@Test func recordSubmittedReopensCancelledSameHashForResubmission() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xc6",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )
    _ = try store.markCancelled(
        userOpHash: "0xc6",
        chainID: 1,
        transactionHash: "0xcancel"
    )

    let reopened = try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xc6",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )

    #expect(reopened.status == .submitted)
    #expect(reopened.transactionHash == nil)
    let loaded = try #require(try store.loadRecord(userOpHash: "0xc6", chainID: 1))
    #expect(loaded.status == .submitted)
    #expect(loaded.transactionHash == nil)
}

@Test func acceptBranchRecordsSubmittedRowThatStaysNonTerminal() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let recorded = try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "0.01", token: "ETH"),
        userOpHash: "0xfeedface",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )
    #expect(recorded.status == .submitted)

    let row = try #require(try store.loadRecord(userOpHash: "0xfeedface", chainID: 1))
    #expect(row.status == .submitted)
    #expect(row.transactionHash == nil)
    #expect(row.status.requiresReceiptRefresh)
    #expect(row.status.isTerminal == false)
}

@Test func storeMarkPendingLeavesSubmittedRowNonTerminal() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    _ = try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xrec2",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )
    let updated = try store.markPending(userOpHash: "0xrec2", chainID: 1)
    #expect(updated?.status == .pending)
    #expect(updated?.status.requiresReceiptRefresh == true)
}

@Test func storeMarksDroppedWithoutReceiptAndStopsRefreshing() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    _ = try store.recordSubmitted(
        WalletTransactionDraft(operation: .swap, amount: "2", token: "USDC -> ETH"),
        userOpHash: "0xdropped",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )
    let updated = try store.markTerminalWithoutReceipt(
        userOpHash: "0xdropped",
        chainID: 1,
        status: .dropped,
        reason: "auto_dropped_aged_no_receipt"
    )

    #expect(updated?.status == .dropped)
    #expect(updated?.revertReason == "auto_dropped_aged_no_receipt")
    #expect(try store.loadUnfinalizedRecords(
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1
    ).isEmpty)
}

@Test func terminalWithoutReceiptDoesNotOverrideFinalReceipt() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    _ = try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xincluded",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )
    _ = try store.applyReceipt(WalletTransactionReceiptUpdate(
        chainID: 1,
        userOpHash: "0xincluded",
        transactionHash: "0xtx",
        success: true
    ))
    let updated = try store.markTerminalWithoutReceipt(
        userOpHash: "0xincluded",
        chainID: 1,
        status: .dropped,
        reason: "late_drop"
    )

    #expect(updated?.status == .included)
    #expect(updated?.transactionHash == "0xtx")
    #expect(updated?.revertReason == nil)
}

@Test func submittedRowIsRefreshableUntilReceiptThenDropsOut() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    _ = try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xloop1",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )

    _ = try store.markPending(userOpHash: "0xloop1", chainID: 1)
    #expect(try store.loadUnfinalizedRecords(
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1
    ).count == 1)

    _ = try store.applyReceipt(WalletTransactionReceiptUpdate(
        chainID: 1,
        userOpHash: "0xloop1",
        transactionHash: "0xtx",
        success: true
    ))
    #expect(try store.loadRecord(userOpHash: "0xloop1", chainID: 1)?.status == .included)
    #expect(try store.loadUnfinalizedRecords(
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1
    ).isEmpty)
}

@Test func explicitReceiptRefreshCandidatesIncludeCancelledRows() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    _ = try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xrefresh-cancel",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )
    _ = try store.markCancelled(userOpHash: "0xrefresh-cancel", chainID: 1, transactionHash: "0xcancel")

    #expect(try store.loadUnfinalizedRecords(
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1
    ).isEmpty)
    #expect(try store.loadReceiptRefreshCandidates(
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1
    ).contains { $0.userOpHash == "0xrefresh-cancel" })
}

@Test func freshLoadReflectsFinalizedStatusForChatReload() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    _ = try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xtick1",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )
    _ = try store.applyReceipt(WalletTransactionReceiptUpdate(
        chainID: 1,
        userOpHash: "0xtick1",
        transactionHash: "0xtx",
        success: true
    ))

    let reloaded = try store.loadRecords(
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        limit: 200
    )
    let row = try #require(reloaded.first { $0.userOpHash == "0xtick1" })
    #expect(row.status == .included)
    #expect(row.transactionHash == "0xtx")
}

@Test func preexistingSubmittedRowIsPickedUpByUnfinalizedScanWithoutNewSend() throws {
    let (store, url) = temporaryHistoryStore()
    defer { try? FileManager.default.removeItem(at: url) }

    _ = try store.recordSubmitted(
        WalletTransactionDraft(operation: .transfer, amount: "1", token: "ETH"),
        userOpHash: "0xlaunch1",
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1,
        chainName: "Ethereum Mainnet"
    )

    let pending = try store.loadUnfinalizedRecords(
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1
    )
    #expect(pending.contains { $0.userOpHash == "0xlaunch1" })

    _ = try store.applyReceipt(WalletTransactionReceiptUpdate(
        chainID: 1,
        userOpHash: "0xlaunch1",
        transactionHash: "0xtx",
        success: true
    ))
    #expect(try store.loadRecord(userOpHash: "0xlaunch1", chainID: 1)?.status == .included)
    #expect(try store.loadUnfinalizedRecords(
        accountAddress: "0xabc0000000000000000000000000000000000000",
        chainID: 1
    ).isEmpty)
}

private func temporaryHistoryStore() -> (WalletTransactionHistoryStore, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wallet-history-\(UUID().uuidString)")
        .appendingPathExtension("sqlite")
    return (WalletTransactionHistoryStore(databaseURL: url), url)
}
