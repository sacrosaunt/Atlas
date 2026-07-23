import Foundation

struct ChatMessageRecord: Codable, Sendable {
    let id: Int
    let role: String
    let content: String
    let messages_read: Int?
    let delivery_status: String
    let created_at: String
}

struct ChatRecord: Codable, Sendable {
    let id: String
    let codex_thread_id: String?
    let title: String
    let summary: String?
    let created_at: String
    let updated_at: String
    let messages: [ChatMessageRecord]
}

struct ChatSummaryRecord: Codable, Sendable {
    let id: String
    let codex_thread_id: String?
    let title: String
    let summary: String?
    let created_at: String
    let updated_at: String
    let preview: String?
    let message_count: Int
}

struct InsightSnapshotRecord: Codable, Sendable {
    var content: String?
    var codex_thread_id: String?
    var source_message_count: Int
    var status: String
    var error: String?
    var updated_at: String?
    var format_version: Int
}

final class AtlasHistory: @unchecked Sendable {
    private let database: SQLiteDatabase

    init(path: URL) throws {
        database = try SQLiteDatabase(path: path.path)
        try database.executeScript("""
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS chats (
          id TEXT PRIMARY KEY,
          codex_thread_id TEXT UNIQUE,
          title TEXT NOT NULL,
          summary TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS chat_messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
          role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
          content TEXT NOT NULL,
          messages_read INTEGER,
          delivery_status TEXT NOT NULL DEFAULT 'delivered',
          created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS chat_messages_chat_id ON chat_messages(chat_id, id);
        CREATE TABLE IF NOT EXISTS insight_snapshots (
          id INTEGER PRIMARY KEY CHECK(id = 1),
          content TEXT,
          codex_thread_id TEXT,
          source_message_count INTEGER NOT NULL DEFAULT 0,
          status TEXT NOT NULL DEFAULT 'idle',
          error TEXT,
          updated_at TEXT,
          format_version INTEGER NOT NULL DEFAULT 1
        );
        INSERT OR IGNORE INTO insight_snapshots (id) VALUES (1);
        UPDATE insight_snapshots SET status = 'idle' WHERE status = 'refreshing';
        """)
        try ensureColumn(table: "insight_snapshots", name: "format_version", definition: "INTEGER NOT NULL DEFAULT 1")
        try ensureColumn(table: "chats", name: "summary", definition: "TEXT")
        try ensureColumn(table: "chat_messages", name: "messages_read", definition: "INTEGER")
        let hadDeliveryStatus = try database.query("PRAGMA table_info(chat_messages)")
            .contains { $0["name"]?.string == "delivery_status" }
        try ensureColumn(table: "chat_messages", name: "delivery_status", definition: "TEXT NOT NULL DEFAULT 'delivered'")
        try database.executeScript("""
        UPDATE chat_messages AS pending
        SET delivery_status = CASE
          WHEN EXISTS (
            SELECT 1 FROM chat_messages AS response
            WHERE response.chat_id = pending.chat_id
              AND response.id > pending.id
              AND response.role = 'assistant'
          ) THEN 'delivered'
          ELSE 'failed'
        END
        WHERE pending.role = 'user' AND pending.delivery_status = 'sending';
        """)
        if !hadDeliveryStatus {
            try database.executeScript("""
            UPDATE chat_messages AS orphaned
            SET delivery_status = 'failed'
            WHERE orphaned.role = 'user'
              AND orphaned.delivery_status = 'delivered'
              AND NOT EXISTS (
                SELECT 1 FROM chat_messages AS response
                WHERE response.chat_id = orphaned.chat_id
                  AND response.id > orphaned.id
                  AND response.role = 'assistant'
              );
            """)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    func listChats() throws -> [ChatSummaryRecord] {
        try database.query("""
        SELECT c.id, c.codex_thread_id, c.title, c.summary, c.created_at, c.updated_at,
               (SELECT content FROM chat_messages m WHERE m.chat_id = c.id ORDER BY m.id DESC LIMIT 1) AS preview,
               (SELECT COUNT(*) FROM chat_messages m WHERE m.chat_id = c.id) AS message_count
        FROM chats c ORDER BY c.updated_at DESC
        """).compactMap { row in
            guard let id = row["id"]?.string,
                  let title = row["title"]?.string,
                  let created = row["created_at"]?.string,
                  let updated = row["updated_at"]?.string else { return nil }
            return ChatSummaryRecord(
                id: id,
                codex_thread_id: row["codex_thread_id"]?.string,
                title: title,
                summary: row["summary"]?.string,
                created_at: created,
                updated_at: updated,
                preview: row["preview"]?.string,
                message_count: row["message_count"]?.int ?? 0
            )
        }
    }

    func getChat(_ id: String) throws -> ChatRecord? {
        guard let row = try database.query("""
        SELECT id, codex_thread_id, title, summary, created_at, updated_at FROM chats WHERE id = ?
        """, bindings: [.text(id)]).first,
              let title = row["title"]?.string,
              let created = row["created_at"]?.string,
              let updated = row["updated_at"]?.string else { return nil }
        let messages = try database.query("""
        SELECT id, role, content, messages_read, delivery_status, created_at
        FROM chat_messages WHERE chat_id = ? ORDER BY id
        """, bindings: [.text(id)]).compactMap { message -> ChatMessageRecord? in
            guard let messageID = message["id"]?.int,
                  let role = message["role"]?.string,
                  let content = message["content"]?.string,
                  let timestamp = message["created_at"]?.string else { return nil }
            return .init(
                id: messageID,
                role: role,
                content: content,
                messages_read: message["messages_read"]?.int,
                delivery_status: message["delivery_status"]?.string ?? "delivered",
                created_at: timestamp
            )
        }
        return ChatRecord(
            id: id,
            codex_thread_id: row["codex_thread_id"]?.string,
            title: title,
            summary: row["summary"]?.string,
            created_at: created,
            updated_at: updated,
            messages: messages
        )
    }

    func createChat(prompt: String) throws -> ChatRecord {
        let id = UUID().uuidString.lowercased()
        let timestamp = atlasNow()
        let cleaned = prompt.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = cleaned.count <= 64 ? cleaned : String(cleaned.prefix(61)) + "…"
        try database.execute(
            "INSERT INTO chats (id, title, created_at, updated_at) VALUES (?, ?, ?, ?)",
            bindings: [.text(id), .text(title), .text(timestamp), .text(timestamp)]
        )
        try appendMessage(chatID: id, role: "user", content: prompt, timestamp: timestamp, deliveryStatus: "sending")
        return try getChat(id)!
    }

    @discardableResult
    func appendMessage(
        chatID: String,
        role: String,
        content: String,
        timestamp: String = atlasNow(),
        messagesRead: Int? = nil,
        deliveryStatus: String = "delivered"
    ) throws -> Int {
        try database.execute(
            "INSERT INTO chat_messages (chat_id, role, content, messages_read, delivery_status, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            bindings: [.text(chatID), .text(role), .text(content), messagesRead.map { .integer(Int64($0)) } ?? .null, .text(deliveryStatus), .text(timestamp)]
        )
        let messageID = Int(database.lastInsertRowID)
        try database.execute(
            "UPDATE chats SET updated_at = ? WHERE id = ?",
            bindings: [.text(timestamp), .text(chatID)]
        )
        return messageID
    }

    func getMessage(chatID: String, messageID: Int) throws -> ChatMessageRecord? {
        guard let message = try database.query("""
        SELECT id, role, content, messages_read, delivery_status, created_at
        FROM chat_messages WHERE chat_id = ? AND id = ?
        """, bindings: [.text(chatID), .integer(Int64(messageID))]).first,
              let id = message["id"]?.int,
              let role = message["role"]?.string,
              let content = message["content"]?.string,
              let timestamp = message["created_at"]?.string else { return nil }
        return .init(
            id: id,
            role: role,
            content: content,
            messages_read: message["messages_read"]?.int,
            delivery_status: message["delivery_status"]?.string ?? "delivered",
            created_at: timestamp
        )
    }

    func updateMessageDelivery(chatID: String, messageID: Int, status: String) throws {
        try database.execute(
            "UPDATE chat_messages SET delivery_status = ? WHERE chat_id = ? AND id = ? AND role = 'user'",
            bindings: [.text(status), .text(chatID), .integer(Int64(messageID))]
        )
    }

    func failMessageIfSending(chatID: String, messageID: Int) throws {
        try database.execute(
            "UPDATE chat_messages SET delivery_status = 'failed' WHERE chat_id = ? AND id = ? AND role = 'user' AND delivery_status = 'sending'",
            bindings: [.text(chatID), .integer(Int64(messageID))]
        )
    }

    @discardableResult
    func deleteMessage(chatID: String, messageID: Int) throws -> Bool {
        try database.execute(
            "DELETE FROM chat_messages WHERE chat_id = ? AND id = ?",
            bindings: [.text(chatID), .integer(Int64(messageID))]
        )
        return database.changes > 0
    }

    func attachThread(chatID: String, threadID: String) throws {
        try database.execute(
            "UPDATE chats SET codex_thread_id = ?, updated_at = ? WHERE id = ?",
            bindings: [.text(threadID), .text(atlasNow()), .text(chatID)]
        )
    }

    func updateChatMetadata(chatID: String, title: String, summary: String) throws {
        try database.execute(
            "UPDATE chats SET title = ?, summary = ?, updated_at = ? WHERE id = ?",
            bindings: [.text(title), .text(summary), .text(atlasNow()), .text(chatID)]
        )
    }

    @discardableResult
    func deleteChat(_ id: String) throws -> Bool {
        try database.execute("DELETE FROM chats WHERE id = ?", bindings: [.text(id)])
        return database.changes > 0
    }

    func getInsights() throws -> InsightSnapshotRecord {
        let row = try database.query("""
        SELECT content, codex_thread_id, source_message_count, status, error, updated_at, format_version
        FROM insight_snapshots WHERE id = 1
        """).first ?? [:]
        return .init(
            content: row["content"]?.string,
            codex_thread_id: row["codex_thread_id"]?.string,
            source_message_count: row["source_message_count"]?.int ?? 0,
            status: row["status"]?.string ?? "idle",
            error: row["error"]?.string,
            updated_at: row["updated_at"]?.string,
            format_version: row["format_version"]?.int ?? 1
        )
    }

    func beginInsightRefresh() throws {
        try database.execute("UPDATE insight_snapshots SET status = 'refreshing', error = NULL WHERE id = 1")
    }

    func completeInsightRefresh(content: String, threadID: String, sourceMessageCount: Int, formatVersion: Int = 4) throws {
        try database.execute("""
        UPDATE insight_snapshots SET content = ?, codex_thread_id = ?, source_message_count = ?,
          status = 'ready', error = NULL, updated_at = ?, format_version = ? WHERE id = 1
        """, bindings: [.text(content), .text(threadID), .integer(Int64(sourceMessageCount)), .text(atlasNow()), .integer(Int64(formatVersion))])
    }

    func failInsightRefresh(_ error: Error) throws {
        try database.execute(
            "UPDATE insight_snapshots SET status = 'error', error = ? WHERE id = 1",
            bindings: [.text(error.localizedDescription)]
        )
    }

    private func ensureColumn(table: String, name: String, definition: String) throws {
        let columns = try database.query("PRAGMA table_info(\(table))")
        guard !columns.contains(where: { $0["name"]?.string == name }) else { return }
        try database.executeScript("ALTER TABLE \(table) ADD COLUMN \(name) \(definition)")
    }
}
