import Foundation
import SQLite3

public enum WalletTransactionOperation: String, Codable, Equatable, Sendable, CaseIterable {
    case transfer
    case swap
    case approval
    case batch
    case deploy
    case unknown
}

public enum WalletTransactionStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case created
    case submitted
    case pending
    case looksIncluded = "looks_included"
    case included
    case reverted
    case failed
    case cancelled
    case dropped
    case unknown

    public var isTerminal: Bool {
        switch self {
        case .included, .reverted, .failed, .cancelled, .dropped:
            return true
        case .created, .submitted, .pending, .looksIncluded, .unknown:
            return false
        }
    }

    public var requiresReceiptRefresh: Bool {
        switch self {
        case .created, .submitted, .pending, .looksIncluded, .unknown:
            return true
        case .included, .reverted, .failed, .cancelled, .dropped:
            return false
        }
    }

    public var hasFinalReceipt: Bool {
        switch self {
        case .included, .reverted:
            return true
        case .created, .submitted, .pending, .looksIncluded, .failed, .cancelled, .dropped, .unknown:
            return false
        }
    }
}

public struct WalletTransactionDraft: Codable, Equatable, Sendable {
    public var operation: WalletTransactionOperation
    public var amount: String?
    public var token: String?
    public var counterparty: String?
    public var counterpartyName: String?
    public var route: String?
    public var amountOut: String?
    public var minimumReceived: String?
    public var conversationID: UUID?
    public var messageID: UUID?
    public var detailsJSON: String?

    public init(
        operation: WalletTransactionOperation,
        amount: String? = nil,
        token: String? = nil,
        counterparty: String? = nil,
        counterpartyName: String? = nil,
        route: String? = nil,
        amountOut: String? = nil,
        minimumReceived: String? = nil,
        conversationID: UUID? = nil,
        messageID: UUID? = nil,
        detailsJSON: String? = nil
    ) {
        self.operation = operation
        self.amount = amount
        self.token = token
        self.counterparty = counterparty
        self.counterpartyName = counterpartyName
        self.route = route
        self.amountOut = amountOut
        self.minimumReceived = minimumReceived
        self.conversationID = conversationID
        self.messageID = messageID
        self.detailsJSON = detailsJSON
    }
}

public struct WalletTransactionReceiptUpdate: Equatable, Sendable {
    public var chainID: UInt64
    public var userOpHash: String
    public var transactionHash: String
    public var blockNumber: String?
    public var success: Bool
    public var actualGasCost: String?
    public var actualGasUsed: String?
    public var revertReason: String?
    public var tentative: Bool
    public var invalidated: Bool
    public var updatedAt: Date

    public init(
        chainID: UInt64,
        userOpHash: String,
        transactionHash: String,
        blockNumber: String? = nil,
        success: Bool,
        actualGasCost: String? = nil,
        actualGasUsed: String? = nil,
        revertReason: String? = nil,
        tentative: Bool = false,
        invalidated: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.chainID = chainID
        self.userOpHash = userOpHash
        self.transactionHash = transactionHash
        self.blockNumber = blockNumber
        self.success = success
        self.actualGasCost = actualGasCost
        self.actualGasUsed = actualGasUsed
        self.revertReason = revertReason
        self.tentative = tentative
        self.invalidated = invalidated
        self.updatedAt = updatedAt
    }
}

public struct WalletTransactionRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var chainID: UInt64
    public var chainName: String
    public var accountAddress: String
    public var operation: WalletTransactionOperation
    public var status: WalletTransactionStatus
    public var userOpHash: String
    public var transactionHash: String?
    public var blockNumber: String?
    public var amount: String?
    public var token: String?
    public var counterparty: String?
    public var counterpartyName: String?
    public var route: String?
    public var amountOut: String?
    public var minimumReceived: String?
    public var actualGasCost: String?
    public var actualGasUsed: String?
    public var revertReason: String?
    public var conversationID: UUID?
    public var messageID: UUID?
    public var detailsJSON: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        chainID: UInt64,
        chainName: String,
        accountAddress: String,
        operation: WalletTransactionOperation,
        status: WalletTransactionStatus,
        userOpHash: String,
        transactionHash: String? = nil,
        blockNumber: String? = nil,
        amount: String? = nil,
        token: String? = nil,
        counterparty: String? = nil,
        counterpartyName: String? = nil,
        route: String? = nil,
        amountOut: String? = nil,
        minimumReceived: String? = nil,
        actualGasCost: String? = nil,
        actualGasUsed: String? = nil,
        revertReason: String? = nil,
        conversationID: UUID? = nil,
        messageID: UUID? = nil,
        detailsJSON: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.chainID = chainID
        self.chainName = chainName
        self.accountAddress = accountAddress
        self.operation = operation
        self.status = status
        self.userOpHash = userOpHash
        self.transactionHash = transactionHash
        self.blockNumber = blockNumber
        self.amount = amount
        self.token = token
        self.counterparty = counterparty
        self.counterpartyName = counterpartyName
        self.route = route
        self.amountOut = amountOut
        self.minimumReceived = minimumReceived
        self.actualGasCost = actualGasCost
        self.actualGasUsed = actualGasUsed
        self.revertReason = revertReason
        self.conversationID = conversationID
        self.messageID = messageID
        self.detailsJSON = detailsJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum WalletTransactionHistoryError: LocalizedError, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
    case bindFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "Could not open wallet history database: \(message)"
        case .prepareFailed(let message):
            return "Could not prepare wallet history statement: \(message)"
        case .executeFailed(let message):
            return "Could not execute wallet history statement: \(message)"
        case .bindFailed(let message):
            return "Could not bind wallet history value: \(message)"
        }
    }
}

public final class WalletTransactionHistoryStore {
    public let databaseURL: URL
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(databaseURL: URL? = nil, fileManager: FileManager = .default) {
        let resolvedURL = databaseURL ?? Self.defaultDatabaseURL(fileManager: fileManager)
        try? fileManager.createDirectory(
            at: resolvedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.databaseURL = resolvedURL
    }

    public static func defaultDatabaseURL(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("LocalWallet", isDirectory: true)
            .appendingPathComponent("wallet-history.sqlite")
    }

    @discardableResult
    public func recordSubmitted(
        _ draft: WalletTransactionDraft,
        userOpHash: String,
        accountAddress: String,
        chainID: UInt64,
        chainName: String,
        createdAt: Date = Date()
    ) throws -> WalletTransactionRecord {
        let record = WalletTransactionRecord(
            chainID: chainID,
            chainName: chainName,
            accountAddress: accountAddress,
            operation: draft.operation,
            status: .submitted,
            userOpHash: userOpHash,
            amount: draft.amount,
            token: draft.token,
            counterparty: draft.counterparty,
            counterpartyName: draft.counterpartyName,
            route: draft.route,
            amountOut: draft.amountOut,
            minimumReceived: draft.minimumReceived,
            conversationID: draft.conversationID,
            messageID: draft.messageID,
            detailsJSON: draft.detailsJSON,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try upsert(record)
        return try loadRecord(userOpHash: userOpHash, chainID: chainID) ?? record
    }

    @discardableResult
    public func applyReceipt(_ update: WalletTransactionReceiptUpdate) throws -> WalletTransactionRecord? {
        guard var record = try loadRecord(userOpHash: update.userOpHash, chainID: update.chainID) else {
            return nil
        }
        if update.invalidated {
            guard !record.status.isTerminal else {
                return record
            }
            record.status = .submitted
            record.transactionHash = nil
            record.blockNumber = nil
            record.actualGasCost = nil
            record.actualGasUsed = nil
            record.revertReason = nil
            record.updatedAt = update.updatedAt
            try upsert(record)
            return try loadRecord(userOpHash: update.userOpHash, chainID: update.chainID)
        }
        record.status = update.tentative ? .looksIncluded : (update.success ? .included : .reverted)
        record.transactionHash = update.transactionHash
        record.blockNumber = update.blockNumber
        record.actualGasCost = update.actualGasCost
        record.actualGasUsed = update.actualGasUsed
        record.revertReason = update.revertReason
        record.updatedAt = update.updatedAt
        try upsert(record)
        return try loadRecord(userOpHash: update.userOpHash, chainID: update.chainID)
    }

    @discardableResult
    public func markPending(
        userOpHash: String,
        chainID: UInt64,
        transactionHash: String? = nil,
        updatedAt: Date = Date()
    ) throws -> WalletTransactionRecord? {
        guard var record = try loadRecord(userOpHash: userOpHash, chainID: chainID) else {
            return nil
        }
        guard !record.status.isTerminal else {
            return record
        }
        record.status = .pending
        if let transactionHash {
            record.transactionHash = transactionHash
        }
        record.updatedAt = updatedAt
        try upsert(record)
        return try loadRecord(userOpHash: userOpHash, chainID: chainID)
    }

    @discardableResult
    public func markCancelled(
        userOpHash: String,
        chainID: UInt64,
        transactionHash: String? = nil,
        updatedAt: Date = Date()
    ) throws -> WalletTransactionRecord? {
        guard var record = try loadRecord(userOpHash: userOpHash, chainID: chainID) else {
            return nil
        }
        if record.status == .included || (record.status.isTerminal && transactionHash == nil) {
            return record
        }
        record.status = .cancelled
        if let transactionHash {
            record.transactionHash = transactionHash
        }
        record.updatedAt = updatedAt
        try upsert(record)
        return try loadRecord(userOpHash: userOpHash, chainID: chainID)
    }

    @discardableResult
    public func markTerminalWithoutReceipt(
        userOpHash: String,
        chainID: UInt64,
        status: WalletTransactionStatus,
        reason: String? = nil,
        updatedAt: Date = Date()
    ) throws -> WalletTransactionRecord? {
        guard status == .failed || status == .dropped else {
            return try loadRecord(userOpHash: userOpHash, chainID: chainID)
        }
        guard var record = try loadRecord(userOpHash: userOpHash, chainID: chainID) else {
            return nil
        }
        guard !record.status.isTerminal else {
            return record
        }
        record.status = status
        if let reason, !reason.isEmpty {
            record.revertReason = reason
        }
        record.updatedAt = updatedAt
        try upsert(record)
        return try loadRecord(userOpHash: userOpHash, chainID: chainID)
    }

    public func upsert(_ incoming: WalletTransactionRecord) throws {
        var record = incoming
        if let existing = try loadRecord(userOpHash: incoming.userOpHash, chainID: incoming.chainID) {
            record.id = existing.id
            record.createdAt = existing.createdAt
            let isCancellationCorrection = existing.status == .reverted
                && incoming.status == .cancelled
                && incoming.transactionHash != nil
            if existing.status.hasFinalReceipt && !incoming.status.hasFinalReceipt && !isCancellationCorrection {
                record.status = existing.status
                record.transactionHash = existing.transactionHash
                record.blockNumber = existing.blockNumber
                record.actualGasCost = existing.actualGasCost
                record.actualGasUsed = existing.actualGasUsed
                record.revertReason = existing.revertReason
                record.updatedAt = max(existing.updatedAt, incoming.updatedAt)
            }
        }

        let database = try openDatabase()
        defer {
            sqlite3_close(database)
        }
        let statement = try prepare("""
        INSERT INTO wallet_transactions (
            id, chain_id, chain_name, account_address, operation, status, user_op_hash, transaction_hash, block_number,
            amount, token, counterparty, counterparty_name, route, amount_out, minimum_received,
            actual_gas_cost, actual_gas_used, revert_reason, conversation_id, message_id, details_json, created_at, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(chain_id, user_op_hash) DO UPDATE SET
            chain_name = excluded.chain_name,
            account_address = excluded.account_address,
            operation = excluded.operation,
            status = excluded.status,
            transaction_hash = excluded.transaction_hash,
            block_number = excluded.block_number,
            amount = excluded.amount,
            token = excluded.token,
            counterparty = excluded.counterparty,
            counterparty_name = excluded.counterparty_name,
            route = excluded.route,
            amount_out = excluded.amount_out,
            minimum_received = excluded.minimum_received,
            actual_gas_cost = excluded.actual_gas_cost,
            actual_gas_used = excluded.actual_gas_used,
            revert_reason = excluded.revert_reason,
            conversation_id = COALESCE(excluded.conversation_id, wallet_transactions.conversation_id),
            message_id = COALESCE(excluded.message_id, wallet_transactions.message_id),
            details_json = COALESCE(excluded.details_json, wallet_transactions.details_json),
            updated_at = excluded.updated_at
        """, in: database)
        defer {
            sqlite3_finalize(statement)
        }

        try bind(record, in: statement)
        try stepDone(statement, database: database)
    }

    public func loadRecords(
        accountAddress: String? = nil,
        chainID: UInt64? = nil,
        limit: Int = 200
    ) throws -> [WalletTransactionRecord] {
        let cappedLimit = max(1, min(limit, 1_000))
        var conditions: [String] = []
        var binders: [(OpaquePointer, Int32) throws -> Void] = []
        if let accountAddress {
            conditions.append("LOWER(account_address) = LOWER(?)")
            binders.append { [accountAddress] statement, index in
                try self.bind(accountAddress, at: index, in: statement)
            }
        }
        if let chainID {
            conditions.append("chain_id = ?")
            binders.append { statement, index in
                sqlite3_bind_int64(statement, index, sqlite3_int64(chainID))
            }
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let database = try openDatabase()
        defer {
            sqlite3_close(database)
        }
        let statement = try prepare("""
        SELECT \(Self.selectColumns)
        FROM wallet_transactions
        \(whereClause)
        ORDER BY updated_at DESC, created_at DESC
        LIMIT \(cappedLimit)
        """, in: database)
        defer {
            sqlite3_finalize(statement)
        }

        for (offset, binder) in binders.enumerated() {
            try binder(statement, Int32(offset + 1))
        }

        var records: [WalletTransactionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let record = decodeRecord(statement) {
                records.append(record)
            }
        }
        return records
    }

    public func loadUnfinalizedRecords(
        accountAddress: String? = nil,
        chainID: UInt64? = nil,
        limit: Int = 200
    ) throws -> [WalletTransactionRecord] {
        try loadRecords(accountAddress: accountAddress, chainID: chainID, limit: limit)
            .filter { $0.status.requiresReceiptRefresh }
    }

    public func loadReceiptRefreshCandidates(
        accountAddress: String? = nil,
        chainID: UInt64? = nil,
        limit: Int = 200
    ) throws -> [WalletTransactionRecord] {
        try loadRecords(accountAddress: accountAddress, chainID: chainID, limit: limit)
            .filter { record in
                record.status.requiresReceiptRefresh
                    || record.status == .cancelled
                    || record.status == .dropped
            }
    }

    public func deleteAll() throws {
        let database = try openDatabase()
        defer {
            sqlite3_close(database)
        }
        try execute("DELETE FROM wallet_transactions", in: database)
    }

    public func loadRecord(userOpHash: String, chainID: UInt64) throws -> WalletTransactionRecord? {
        let database = try openDatabase()
        defer {
            sqlite3_close(database)
        }
        let statement = try prepare("""
        SELECT \(Self.selectColumns)
        FROM wallet_transactions
        WHERE chain_id = ? AND LOWER(user_op_hash) = LOWER(?)
        LIMIT 1
        """, in: database)
        defer {
            sqlite3_finalize(statement)
        }

        sqlite3_bind_int64(statement, 1, sqlite3_int64(chainID))
        try bind(userOpHash, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return decodeRecord(statement)
    }

    private static let selectColumns = """
    id, chain_id, chain_name, account_address, operation, status, user_op_hash, transaction_hash, block_number,
    amount, token, counterparty, counterparty_name, route, amount_out, minimum_received,
    actual_gas_cost, actual_gas_used, revert_reason, conversation_id, message_id, details_json, created_at, updated_at
    """

    private func openDatabase() throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown SQLite error"
            if let database {
                sqlite3_close(database)
            }
            throw WalletTransactionHistoryError.openFailed(message)
        }

        try execute("PRAGMA foreign_keys = ON", in: database)
        try createSchema(in: database)
        return database
    }

    private func createSchema(in database: OpaquePointer) throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS wallet_transactions (
            id TEXT PRIMARY KEY,
            chain_id INTEGER NOT NULL,
            chain_name TEXT NOT NULL,
            account_address TEXT NOT NULL,
            operation TEXT NOT NULL,
            status TEXT NOT NULL,
            user_op_hash TEXT NOT NULL,
            transaction_hash TEXT,
            block_number TEXT,
            amount TEXT,
            token TEXT,
            counterparty TEXT,
            counterparty_name TEXT,
            route TEXT,
            amount_out TEXT,
            minimum_received TEXT,
            actual_gas_cost TEXT,
            actual_gas_used TEXT,
            revert_reason TEXT,
            conversation_id TEXT,
            message_id TEXT,
            details_json TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(chain_id, user_op_hash)
        )
        """, in: database)

        try execute("""
        CREATE INDEX IF NOT EXISTS idx_wallet_transactions_account_chain_updated
        ON wallet_transactions(account_address, chain_id, updated_at)
        """, in: database)

        try execute("""
        CREATE INDEX IF NOT EXISTS idx_wallet_transactions_status
        ON wallet_transactions(status)
        """, in: database)
    }

    private func bind(_ record: WalletTransactionRecord, in statement: OpaquePointer) throws {
        try bind(record.id.uuidString, at: 1, in: statement)
        sqlite3_bind_int64(statement, 2, sqlite3_int64(record.chainID))
        try bind(record.chainName, at: 3, in: statement)
        try bind(record.accountAddress, at: 4, in: statement)
        try bind(record.operation.rawValue, at: 5, in: statement)
        try bind(record.status.rawValue, at: 6, in: statement)
        try bind(record.userOpHash, at: 7, in: statement)
        try bindOptional(record.transactionHash, at: 8, in: statement)
        try bindOptional(record.blockNumber, at: 9, in: statement)
        try bindOptional(record.amount, at: 10, in: statement)
        try bindOptional(record.token, at: 11, in: statement)
        try bindOptional(record.counterparty, at: 12, in: statement)
        try bindOptional(record.counterpartyName, at: 13, in: statement)
        try bindOptional(record.route, at: 14, in: statement)
        try bindOptional(record.amountOut, at: 15, in: statement)
        try bindOptional(record.minimumReceived, at: 16, in: statement)
        try bindOptional(record.actualGasCost, at: 17, in: statement)
        try bindOptional(record.actualGasUsed, at: 18, in: statement)
        try bindOptional(record.revertReason, at: 19, in: statement)
        try bindOptional(record.conversationID?.uuidString, at: 20, in: statement)
        try bindOptional(record.messageID?.uuidString, at: 21, in: statement)
        try bindOptional(record.detailsJSON, at: 22, in: statement)
        sqlite3_bind_double(statement, 23, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 24, record.updatedAt.timeIntervalSince1970)
    }

    private func decodeRecord(_ statement: OpaquePointer) -> WalletTransactionRecord? {
        guard
            let idText = columnText(statement, 0),
            let id = UUID(uuidString: idText),
            let chainName = columnText(statement, 2),
            let accountAddress = columnText(statement, 3),
            let operationText = columnText(statement, 4),
            let statusText = columnText(statement, 5),
            let status = WalletTransactionStatus(rawValue: statusText),
            let userOpHash = columnText(statement, 6)
        else {
            return nil
        }

        // Rows written by a build with operations this one no longer knows (the removed
        // RAILGUN shield/unshield) degrade to `.unknown` instead of being dropped.
        // Dropping them is worse than showing them: `loadRecords` applies its LIMIT in
        // SQL and filters here, so a dropped row silently shrinks the page, and an
        // unfinalized one would never reach `loadUnfinalizedRecords` again while still
        // holding its UNIQUE(chain_id, user_op_hash) key.
        let operation = WalletTransactionOperation(rawValue: operationText) ?? .unknown

        return WalletTransactionRecord(
            id: id,
            chainID: UInt64(sqlite3_column_int64(statement, 1)),
            chainName: chainName,
            accountAddress: accountAddress,
            operation: operation,
            status: status,
            userOpHash: userOpHash,
            transactionHash: columnText(statement, 7),
            blockNumber: columnText(statement, 8),
            amount: columnText(statement, 9),
            token: columnText(statement, 10),
            counterparty: columnText(statement, 11),
            counterpartyName: columnText(statement, 12),
            route: columnText(statement, 13),
            amountOut: columnText(statement, 14),
            minimumReceived: columnText(statement, 15),
            actualGasCost: columnText(statement, 16),
            actualGasUsed: columnText(statement, 17),
            revertReason: columnText(statement, 18),
            conversationID: columnText(statement, 19).flatMap(UUID.init(uuidString:)),
            messageID: columnText(statement, 20).flatMap(UUID.init(uuidString:)),
            detailsJSON: columnText(statement, 21),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 22)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 23))
        )
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? sqliteError(database)
            sqlite3_free(errorMessage)
            throw WalletTransactionHistoryError.executeFailed(message)
        }
    }

    private func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw WalletTransactionHistoryError.prepareFailed(sqliteError(database))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer, database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw WalletTransactionHistoryError.executeFailed(sqliteError(database))
        }
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw WalletTransactionHistoryError.bindFailed(value)
        }
    }

    private func bindOptional(_ value: String?, at index: Int32, in statement: OpaquePointer) throws {
        guard let value, !value.isEmpty else {
            sqlite3_bind_null(statement, index)
            return
        }
        try bind(value, at: index, in: statement)
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        guard let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func sqliteError(_ database: OpaquePointer) -> String {
        sqlite3_errmsg(database).map { String(cString: $0) } ?? "Unknown SQLite error"
    }
}
