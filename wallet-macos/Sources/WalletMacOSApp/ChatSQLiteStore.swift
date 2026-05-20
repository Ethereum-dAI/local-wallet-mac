import Foundation
import SQLite3
import WalletToolLayer

enum ChatStoreError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
    case bindFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "Could not open chat database: \(message)"
        case .prepareFailed(let message):
            return "Could not prepare chat database statement: \(message)"
        case .executeFailed(let message):
            return "Could not execute chat database statement: \(message)"
        case .bindFailed(let message):
            return "Could not bind chat database value: \(message)"
        }
    }
}

final class ChatSQLiteStore {
    private let databaseURL: URL
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("LocalWallet", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.databaseURL = directory.appendingPathComponent("chat.sqlite")
    }

    func loadConversations() throws -> [ChatConversation] {
        let database = try openDatabase()
        defer {
            sqlite3_close(database)
        }

        try createSchema(in: database)

        let sql = """
        SELECT id, title, created_at, updated_at
        FROM chat_conversations
        ORDER BY updated_at DESC
        """
        let statement = try prepare(sql, in: database)
        defer {
            sqlite3_finalize(statement)
        }

        var conversations: [ChatConversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = columnText(statement, 0),
                let id = UUID(uuidString: idText),
                let title = columnText(statement, 1)
            else {
                continue
            }

            let messages = try loadMessages(for: id, in: database)
            conversations.append(ChatConversation(
                id: id,
                title: title,
                messages: messages,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            ))
        }

        return conversations
    }

    func createConversation(_ conversation: ChatConversation) throws {
        let database = try openDatabase()
        defer {
            sqlite3_close(database)
        }

        try createSchema(in: database)
        try insertConversation(conversation, in: database)
    }

    func updateConversationMetadata(_ conversation: ChatConversation) throws {
        let database = try openDatabase()
        defer {
            sqlite3_close(database)
        }

        try createSchema(in: database)
        let statement = try prepare(
            "UPDATE chat_conversations SET title = ?, updated_at = ? WHERE id = ?",
            in: database
        )
        defer {
            sqlite3_finalize(statement)
        }

        try bind(conversation.title, at: 1, in: statement)
        sqlite3_bind_double(statement, 2, conversation.updatedAt.timeIntervalSince1970)
        try bind(conversation.id.uuidString, at: 3, in: statement)
        try stepDone(statement, database: database)
    }

    func appendMessage(_ message: ChatMessage, to conversationID: UUID) throws {
        let database = try openDatabase()
        defer {
            sqlite3_close(database)
        }

        try createSchema(in: database)
        try insertMessage(message, conversationID: conversationID, createdAt: Date(), in: database)
    }

    func updateMessage(_ message: ChatMessage, in conversationID: UUID) throws {
        let database = try openDatabase()
        defer {
            sqlite3_close(database)
        }

        try createSchema(in: database)
        let statement = try prepare("""
        UPDATE chat_messages
        SET role = ?, kind = ?, text = ?, thinking = ?, duration = ?, prompt_tokens = ?, generated_tokens = ?, context_size = ?, tool_intent_json = ?, tool_call_id = ?
        WHERE id = ? AND conversation_id = ?
        """, in: database)
        defer {
            sqlite3_finalize(statement)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let toolIntentJSON: String?
        if let toolIntent = message.toolIntent {
            let data = try encoder.encode(toolIntent)
            toolIntentJSON = String(data: data, encoding: .utf8)
        } else {
            toolIntentJSON = nil
        }

        try bind(message.role.rawValue, at: 1, in: statement)
        try bind(message.kind.rawValue, at: 2, in: statement)
        try bindNullable(message.text, at: 3, in: statement)
        try bindOptional(message.thinking, at: 4, in: statement)

        if let stats = message.stats {
            sqlite3_bind_double(statement, 5, stats.duration)
            sqlite3_bind_int64(statement, 6, sqlite3_int64(stats.promptTokens))
            sqlite3_bind_int64(statement, 7, sqlite3_int64(stats.generatedTokens))
            sqlite3_bind_int64(statement, 8, sqlite3_int64(stats.contextSize))
        } else {
            sqlite3_bind_null(statement, 5)
            sqlite3_bind_null(statement, 6)
            sqlite3_bind_null(statement, 7)
            sqlite3_bind_null(statement, 8)
        }

        try bindNullable(toolIntentJSON, at: 9, in: statement)
        try bindNullable(message.toolCallId, at: 10, in: statement)
        try bind(message.id.uuidString, at: 11, in: statement)
        try bind(conversationID.uuidString, at: 12, in: statement)
        try stepDone(statement, database: database)
    }

    func deleteMessage(_ messageID: UUID, from conversationID: UUID) throws {
        let database = try openDatabase()
        defer {
            sqlite3_close(database)
        }

        try createSchema(in: database)
        let statement = try prepare(
            "DELETE FROM chat_messages WHERE id = ? AND conversation_id = ?",
            in: database
        )
        defer {
            sqlite3_finalize(statement)
        }

        try bind(messageID.uuidString, at: 1, in: statement)
        try bind(conversationID.uuidString, at: 2, in: statement)
        try stepDone(statement, database: database)
    }

    func deleteConversation(_ conversationID: UUID) throws {
        let database = try openDatabase()
        defer {
            sqlite3_close(database)
        }

        try createSchema(in: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", in: database)
        do {
            let deleteMessages = try prepare(
                "DELETE FROM chat_messages WHERE conversation_id = ?",
                in: database
            )
            try bind(conversationID.uuidString, at: 1, in: deleteMessages)
            try stepDone(deleteMessages, database: database)
            sqlite3_finalize(deleteMessages)

            let deleteConversation = try prepare(
                "DELETE FROM chat_conversations WHERE id = ?",
                in: database
            )
            try bind(conversationID.uuidString, at: 1, in: deleteConversation)
            try stepDone(deleteConversation, database: database)
            sqlite3_finalize(deleteConversation)

            try execute("COMMIT", in: database)
        } catch {
            try? execute("ROLLBACK", in: database)
            throw error
        }
    }

    func replaceConversations(_ conversations: [ChatConversation]) throws {
        let database = try openDatabase()
        defer {
            sqlite3_close(database)
        }

        try createSchema(in: database)
        try execute("BEGIN IMMEDIATE TRANSACTION", in: database)
        do {
            try execute("DELETE FROM chat_messages", in: database)
            try execute("DELETE FROM chat_conversations", in: database)

            for conversation in conversations {
                try insertConversation(conversation, in: database)
                for (index, message) in conversation.messages.enumerated() {
                    let createdAt = conversation.createdAt.addingTimeInterval(Double(index) * 0.001)
                    try insertMessage(message, conversationID: conversation.id, createdAt: createdAt, in: database)
                }
            }

            try execute("COMMIT", in: database)
        } catch {
            try? execute("ROLLBACK", in: database)
            throw error
        }
    }

    private func openDatabase() throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown SQLite error"
            if let database {
                sqlite3_close(database)
            }
            throw ChatStoreError.openFailed(message)
        }

        try execute("PRAGMA foreign_keys = ON", in: database)
        try createSchema(in: database)
        try ChatSQLiteMigration.migrate(database: database)
        return database
    }

    private func createSchema(in database: OpaquePointer) throws {
        let hadMessagesTable = try tableExists("chat_messages", in: database)

        try execute("""
        CREATE TABLE IF NOT EXISTS chat_conversations (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """, in: database)

        try execute("""
        CREATE TABLE IF NOT EXISTS chat_messages (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            role TEXT NOT NULL,
            kind TEXT NOT NULL DEFAULT 'assistantText',
            text TEXT,
            thinking TEXT,
            duration REAL,
            prompt_tokens INTEGER,
            generated_tokens INTEGER,
            context_size INTEGER,
            tool_intent_json TEXT,
            tool_call_id TEXT,
            created_at REAL NOT NULL,
            FOREIGN KEY(conversation_id) REFERENCES chat_conversations(id) ON DELETE CASCADE
        )
        """, in: database)

        try execute("""
        CREATE INDEX IF NOT EXISTS idx_chat_messages_conversation_created
        ON chat_messages(conversation_id, created_at)
        """, in: database)

        try execute("""
        CREATE INDEX IF NOT EXISTS idx_chat_conversations_updated
        ON chat_conversations(updated_at)
        """, in: database)

        let hasV1MessagesTable: Bool
        if hadMessagesTable {
            hasV1MessagesTable = try tableHasColumn("kind", in: "chat_messages", database: database)
        } else {
            hasV1MessagesTable = true
        }
        if hasV1MessagesTable {
            try execute("PRAGMA user_version = 1", in: database)
        }
    }

    private func loadMessages(for conversationID: UUID, in database: OpaquePointer) throws -> [ChatMessage] {
        let statement = try prepare("""
        SELECT id, role, kind, text, thinking, duration, prompt_tokens, generated_tokens, context_size, tool_intent_json, tool_call_id
        FROM chat_messages
        WHERE conversation_id = ?
        ORDER BY created_at ASC
        """, in: database)
        defer {
            sqlite3_finalize(statement)
        }

        try bind(conversationID.uuidString, at: 1, in: statement)

        var messages: [ChatMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idText = columnText(statement, 0),
                let id = UUID(uuidString: idText),
                let roleText = columnText(statement, 1),
                let role = ChatMessage.Role(rawValue: roleText)
            else {
                continue
            }

            let kind = columnText(statement, 2)
                .flatMap(ChatMessage.Kind.init(rawValue:)) ?? .assistantText
            let duration = columnDouble(statement, 5)
            let promptTokens = columnInt(statement, 6)
            let generatedTokens = columnInt(statement, 7)
            let contextSize = columnInt(statement, 8)
            let stats: ChatGenerationStats?
            if let duration, let promptTokens, let generatedTokens, let contextSize {
                stats = ChatGenerationStats(
                    duration: duration,
                    promptTokens: promptTokens,
                    generatedTokens: generatedTokens,
                    contextSize: contextSize
                )
            } else {
                stats = nil
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let toolIntent = columnText(statement, 9)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? decoder.decode(ToolIntent.self, from: $0) }

            messages.append(ChatMessage(
                id: id,
                kind: kind,
                role: role,
                text: columnText(statement, 3),
                thinking: columnText(statement, 4),
                stats: stats,
                toolIntent: toolIntent,
                toolCallId: columnText(statement, 10)
            ))
        }

        return messages
    }

    private func insertConversation(_ conversation: ChatConversation, in database: OpaquePointer) throws {
        let statement = try prepare("""
        INSERT OR REPLACE INTO chat_conversations (id, title, created_at, updated_at)
        VALUES (?, ?, ?, ?)
        """, in: database)
        defer {
            sqlite3_finalize(statement)
        }

        try bind(conversation.id.uuidString, at: 1, in: statement)
        try bind(conversation.title, at: 2, in: statement)
        sqlite3_bind_double(statement, 3, conversation.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, conversation.updatedAt.timeIntervalSince1970)
        try stepDone(statement, database: database)
    }

    private func insertMessage(
        _ message: ChatMessage,
        conversationID: UUID,
        createdAt: Date,
        in database: OpaquePointer
    ) throws {
        let statement = try prepare("""
        INSERT OR REPLACE INTO chat_messages (
            id, conversation_id, role, kind, text, thinking, duration, prompt_tokens, generated_tokens, context_size, tool_intent_json, tool_call_id, created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, in: database)
        defer {
            sqlite3_finalize(statement)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let toolIntentJSON: String?
        if let toolIntent = message.toolIntent {
            let data = try encoder.encode(toolIntent)
            toolIntentJSON = String(data: data, encoding: .utf8)
        } else {
            toolIntentJSON = nil
        }

        try bind(message.id.uuidString, at: 1, in: statement)
        try bind(conversationID.uuidString, at: 2, in: statement)
        try bind(message.role.rawValue, at: 3, in: statement)
        try bind(message.kind.rawValue, at: 4, in: statement)
        try bindNullable(message.text, at: 5, in: statement)
        try bindOptional(message.thinking, at: 6, in: statement)

        if let stats = message.stats {
            sqlite3_bind_double(statement, 7, stats.duration)
            sqlite3_bind_int64(statement, 8, sqlite3_int64(stats.promptTokens))
            sqlite3_bind_int64(statement, 9, sqlite3_int64(stats.generatedTokens))
            sqlite3_bind_int64(statement, 10, sqlite3_int64(stats.contextSize))
        } else {
            sqlite3_bind_null(statement, 7)
            sqlite3_bind_null(statement, 8)
            sqlite3_bind_null(statement, 9)
            sqlite3_bind_null(statement, 10)
        }

        try bindNullable(toolIntentJSON, at: 11, in: statement)
        try bindNullable(message.toolCallId, at: 12, in: statement)
        sqlite3_bind_double(statement, 13, createdAt.timeIntervalSince1970)
        try stepDone(statement, database: database)
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? sqliteError(database)
            sqlite3_free(errorMessage)
            throw ChatStoreError.executeFailed(message)
        }
    }

    private func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ChatStoreError.prepareFailed(sqliteError(database))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer, database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ChatStoreError.executeFailed(sqliteError(database))
        }
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw ChatStoreError.bindFailed(value)
        }
    }

    private func bindOptional(_ value: String?, at index: Int32, in statement: OpaquePointer) throws {
        guard let value, !value.isEmpty else {
            sqlite3_bind_null(statement, index)
            return
        }

        try bind(value, at: index, in: statement)
    }

    private func bindNullable(_ value: String?, at index: Int32, in statement: OpaquePointer) throws {
        guard let value else {
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

    private func columnDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_double(statement, index)
    }

    private func columnInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int64(statement, index))
    }

    private func sqliteError(_ database: OpaquePointer) -> String {
        sqlite3_errmsg(database).map { String(cString: $0) } ?? "Unknown SQLite error"
    }

    private func tableExists(_ tableName: String, in database: OpaquePointer) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            in: database
        )
        defer {
            sqlite3_finalize(statement)
        }

        try bind(tableName, at: 1, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func tableHasColumn(_ columnName: String, in tableName: String, database: OpaquePointer) throws -> Bool {
        let statement = try prepare("PRAGMA table_info(\(tableName))", in: database)
        defer {
            sqlite3_finalize(statement)
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            if columnText(statement, 1) == columnName {
                return true
            }
        }

        return false
    }
}

final class ChatPreferencesStore {
    private enum Keys {
        static let legacyConversations = "com.localwallet.demo.chat.conversations"
        static let activeConversationID = "com.localwallet.demo.chat.active-conversation-id"
        static let thinkingEnabled = "com.localwallet.demo.chat.thinking-enabled"
        static let sidebarVisible = "com.localwallet.demo.chat.sidebar-visible"
        static let migratedToSQLite = "com.localwallet.demo.chat.sqlite-migration-completed"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var activeConversationID: UUID? {
        get {
            defaults.string(forKey: Keys.activeConversationID).flatMap(UUID.init(uuidString:))
        }
        set {
            defaults.set(newValue?.uuidString, forKey: Keys.activeConversationID)
        }
    }

    var thinkingEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.thinkingEnabled) != nil else {
                return true
            }
            return defaults.bool(forKey: Keys.thinkingEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.thinkingEnabled)
        }
    }

    var sidebarVisible: Bool {
        get {
            guard defaults.object(forKey: Keys.sidebarVisible) != nil else {
                return true
            }
            return defaults.bool(forKey: Keys.sidebarVisible)
        }
        set {
            defaults.set(newValue, forKey: Keys.sidebarVisible)
        }
    }

    var migratedToSQLite: Bool {
        get {
            defaults.bool(forKey: Keys.migratedToSQLite)
        }
        set {
            defaults.set(newValue, forKey: Keys.migratedToSQLite)
        }
    }

    func loadLegacyConversations() -> [ChatConversation] {
        guard let data = defaults.data(forKey: Keys.legacyConversations) else {
            return []
        }
        return (try? JSONDecoder().decode([ChatConversation].self, from: data)) ?? []
    }
}
