import Foundation
import SQLite3

public enum ChatSQLiteMigrationError: Error, Equatable, Sendable {
    case prepareFailed(String)
    case stepFailed(String)
    case execFailed(String)
}

public enum ChatSQLiteMigration {
    public static let currentVersion: Int32 = 3

    public static func migrate(database: OpaquePointer) throws {
        let version = try readUserVersion(database)
        if version < 1 {
            try migrateV0toV1(database: database)
        }
        if version < 2 {
            try migrateV1toV2(database: database)
        }
        if version < 3 {
            try migrateV2toV3(database: database)
        }
    }

    private static func readUserVersion(_ db: OpaquePointer) throws -> Int32 {
        var stmt: OpaquePointer? = nil
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else {
            throw ChatSQLiteMigrationError.prepareFailed("PRAGMA user_version")
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw ChatSQLiteMigrationError.stepFailed("PRAGMA user_version")
        }
        return sqlite3_column_int(stmt, 0)
    }

    private static func migrateV0toV1(database db: OpaquePointer) throws {
        let sql = """
        BEGIN;
        CREATE TABLE chat_messages_v1 (
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
        );
        INSERT INTO chat_messages_v1
            (id, conversation_id, role, kind, text, thinking, duration, prompt_tokens, generated_tokens, context_size, created_at)
        SELECT id, conversation_id, role,
               CASE role WHEN 'user' THEN 'userText' WHEN 'assistant' THEN 'assistantText' ELSE 'assistantText' END,
               text, thinking, duration, prompt_tokens, generated_tokens, context_size, created_at
        FROM chat_messages;
        DROP TABLE chat_messages;
        ALTER TABLE chat_messages_v1 RENAME TO chat_messages;
        CREATE INDEX IF NOT EXISTS idx_chat_messages_conversation_created
            ON chat_messages(conversation_id, created_at);
        PRAGMA user_version = 1;
        COMMIT;
        """
        var err: UnsafeMutablePointer<CChar>? = nil
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw ChatSQLiteMigrationError.execFailed("migrate v0->v1: \(msg)")
        }
    }

    private static func migrateV1toV2(database db: OpaquePointer) throws {
        let sql = "PRAGMA user_version = 2;"
        var err: UnsafeMutablePointer<CChar>? = nil
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw ChatSQLiteMigrationError.execFailed("migrate v1->v2: \(msg)")
        }
    }

    private static func migrateV2toV3(database db: OpaquePointer) throws {
        let sql = """
        BEGIN;
        ALTER TABLE chat_messages ADD COLUMN audio_path TEXT;
        ALTER TABLE chat_messages ADD COLUMN audio_duration_ms INTEGER;
        ALTER TABLE chat_messages ADD COLUMN audio_waveform TEXT;
        PRAGMA user_version = 3;
        COMMIT;
        """
        var err: UnsafeMutablePointer<CChar>? = nil
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw ChatSQLiteMigrationError.execFailed("migrate v2->v3: \(msg)")
        }
    }
}
