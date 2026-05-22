import Foundation
import SQLite3
import Testing
@testable import WalletToolLayer

@Test func migrateToCurrentVersionPreservesExistingMessages() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID()).sqlite")
    defer { try? FileManager.default.removeItem(at: tmp) }

    var db: OpaquePointer? = nil
    #expect(sqlite3_open(tmp.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }

    let v0Create = """
    CREATE TABLE chat_conversations(
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE TABLE chat_messages(
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        role TEXT NOT NULL,
        text TEXT NOT NULL,
        thinking TEXT,
        duration REAL,
        prompt_tokens INTEGER,
        generated_tokens INTEGER,
        context_size INTEGER,
        created_at REAL NOT NULL
    );
    INSERT INTO chat_conversations VALUES('c1','my chat',1,1);
    INSERT INTO chat_messages(id,conversation_id,role,text,created_at) VALUES('m1','c1','user','hi',1);
    INSERT INTO chat_messages(id,conversation_id,role,text,created_at) VALUES('m2','c1','assistant','hello',2);
    """
    #expect(sqlite3_exec(db, v0Create, nil, nil, nil) == SQLITE_OK)

    try ChatSQLiteMigration.migrate(database: db!)

    var stmt: OpaquePointer? = nil
    #expect(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK)
    #expect(sqlite3_step(stmt) == SQLITE_ROW)
    let version = sqlite3_column_int(stmt, 0)
    sqlite3_finalize(stmt)
    #expect(version == 2)

    let select = "SELECT id, role, kind, text, tool_intent_json, tool_call_id FROM chat_messages ORDER BY created_at"
    #expect(sqlite3_prepare_v2(db, select, -1, &stmt, nil) == SQLITE_OK)
    var rows: [(id: String, role: String, kind: String, text: String, tij: Int, tci: Int)] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let role = String(cString: sqlite3_column_text(stmt, 1))
        let kind = String(cString: sqlite3_column_text(stmt, 2))
        let text = String(cString: sqlite3_column_text(stmt, 3))
        let tij = sqlite3_column_type(stmt, 4)
        let tci = sqlite3_column_type(stmt, 5)
        rows.append((id, role, kind, text, Int(tij), Int(tci)))
    }
    sqlite3_finalize(stmt)
    #expect(rows.count == 2)
    #expect(rows[0].id == "m1"); #expect(rows[0].role == "user"); #expect(rows[0].kind == "userText"); #expect(rows[0].text == "hi")
    #expect(rows[1].id == "m2"); #expect(rows[1].role == "assistant"); #expect(rows[1].kind == "assistantText"); #expect(rows[1].text == "hello")
    #expect(rows[0].tij == 5); #expect(rows[0].tci == 5)

    #expect(sqlite3_prepare_v2(db, "SELECT 1 FROM tool_intent_feedback LIMIT 1", -1, &stmt, nil) == SQLITE_OK)
    sqlite3_finalize(stmt)
}

@Test func migrateToCurrentVersionIsIdempotent() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("migration-idem-\(UUID()).sqlite")
    defer { try? FileManager.default.removeItem(at: tmp) }

    var db: OpaquePointer? = nil
    #expect(sqlite3_open(tmp.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }

    let v0Create = """
    CREATE TABLE chat_conversations(id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE TABLE chat_messages(id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, role TEXT NOT NULL, text TEXT NOT NULL, thinking TEXT, duration REAL, prompt_tokens INTEGER, generated_tokens INTEGER, context_size INTEGER, created_at REAL NOT NULL);
    """
    #expect(sqlite3_exec(db, v0Create, nil, nil, nil) == SQLITE_OK)

    try ChatSQLiteMigration.migrate(database: db!)
    try ChatSQLiteMigration.migrate(database: db!)

    var stmt: OpaquePointer? = nil
    sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil)
    sqlite3_step(stmt)
    let v = sqlite3_column_int(stmt, 0)
    sqlite3_finalize(stmt)
    #expect(v == 2)
}

@Test func migrateAcceptsFreshDatabase() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("migration-fresh-\(UUID()).sqlite")
    defer { try? FileManager.default.removeItem(at: tmp) }

    var db: OpaquePointer? = nil
    sqlite3_open(tmp.path, &db)
    defer { sqlite3_close(db) }

    let v1Create = """
    CREATE TABLE chat_conversations(id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE TABLE chat_messages(
        id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, role TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'assistantText',
        text TEXT, thinking TEXT, duration REAL, prompt_tokens INTEGER, generated_tokens INTEGER, context_size INTEGER,
        tool_intent_json TEXT, tool_call_id TEXT, created_at REAL NOT NULL
    );
    PRAGMA user_version = 1;
    """
    sqlite3_exec(db, v1Create, nil, nil, nil)

    try ChatSQLiteMigration.migrate(database: db!)

    var stmt: OpaquePointer? = nil
    #expect(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK)
    #expect(sqlite3_step(stmt) == SQLITE_ROW)
    let version = sqlite3_column_int(stmt, 0)
    sqlite3_finalize(stmt)
    #expect(version == 2)

    #expect(sqlite3_prepare_v2(db, "SELECT 1 FROM tool_intent_feedback LIMIT 1", -1, &stmt, nil) == SQLITE_OK)
    sqlite3_finalize(stmt)
}

@Test func migrateToCurrentVersionCreatesFeedbackConstraints() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("migration-feedback-\(UUID()).sqlite")
    defer { try? FileManager.default.removeItem(at: tmp) }

    var db: OpaquePointer? = nil
    #expect(sqlite3_open(tmp.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }

    let v1Create = """
    PRAGMA foreign_keys = ON;
    CREATE TABLE chat_conversations(id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE TABLE chat_messages(
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
    PRAGMA user_version = 1;
    """
    #expect(sqlite3_exec(db, v1Create, nil, nil, nil) == SQLITE_OK)

    try ChatSQLiteMigration.migrate(database: db!)

    let seed = """
    INSERT INTO chat_conversations VALUES('c1','my chat',1,1);
    INSERT INTO chat_messages(id,conversation_id,role,kind,created_at) VALUES('m1','c1','assistant','toolIntent',1);
    INSERT INTO tool_intent_feedback
        (id, conversation_id, message_id, intent_id, tool, prompt, args_json, rating, note, created_at, updated_at)
    VALUES
        ('f1', 'c1', 'm1', 'i1', 'transfer', 'send 1 eth', '{}', 'thumbs_up', NULL, 1, 1);
    """
    #expect(sqlite3_exec(db, seed, nil, nil, nil) == SQLITE_OK)

    let duplicate = """
    INSERT INTO tool_intent_feedback
        (id, conversation_id, message_id, intent_id, tool, prompt, args_json, rating, note, created_at, updated_at)
    VALUES
        ('f2', 'c1', 'm1', 'i2', 'transfer', 'send 2 eth', '{}', 'thumbs_down', 'wrong amount', 2, 2);
    """
    #expect(sqlite3_exec(db, duplicate, nil, nil, nil) == SQLITE_CONSTRAINT)

    #expect(sqlite3_exec(db, "DELETE FROM chat_messages WHERE id = 'm1'", nil, nil, nil) == SQLITE_OK)

    var stmt: OpaquePointer? = nil
    #expect(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM tool_intent_feedback", -1, &stmt, nil) == SQLITE_OK)
    #expect(sqlite3_step(stmt) == SQLITE_ROW)
    #expect(sqlite3_column_int(stmt, 0) == 0)
    sqlite3_finalize(stmt)
}
