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

private func temporaryHistoryStore() -> (WalletTransactionHistoryStore, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wallet-history-\(UUID().uuidString)")
        .appendingPathExtension("sqlite")
    return (WalletTransactionHistoryStore(databaseURL: url), url)
}
