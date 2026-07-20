import { randomUUID } from "node:crypto";
import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";

const DEFAULT_PATH = join(
  homedir(),
  "Library",
  "Application Support",
  "Atlas",
  "atlas.sqlite",
);

function now() {
  return new Date().toISOString();
}

function titleFromPrompt(prompt) {
  const clean = prompt.replace(/\s+/g, " ").trim();
  return clean.length <= 64 ? clean : `${clean.slice(0, 61)}…`;
}

export class AtlasHistory {
  constructor({ databasePath = DEFAULT_PATH } = {}) {
    mkdirSync(dirname(databasePath), { recursive: true, mode: 0o700 });
    this.databasePath = databasePath;
    this.db = new DatabaseSync(databasePath);
    this.db.exec(`
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
        created_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS chat_messages_chat_id
        ON chat_messages(chat_id, id);
      CREATE TABLE IF NOT EXISTS insight_snapshots (
        id INTEGER PRIMARY KEY CHECK(id = 1),
        content TEXT,
        codex_thread_id TEXT,
        source_message_count INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'idle',
        error TEXT,
        updated_at TEXT
      );
      INSERT OR IGNORE INTO insight_snapshots (id) VALUES (1);
      UPDATE insight_snapshots SET status = 'idle' WHERE status = 'refreshing';
    `);
    const insightColumns = new Set(
      this.db.prepare("PRAGMA table_info(insight_snapshots)").all().map((row) => row.name),
    );
    if (!insightColumns.has("format_version")) {
      this.db.exec("ALTER TABLE insight_snapshots ADD COLUMN format_version INTEGER NOT NULL DEFAULT 1");
    }
    const chatColumns = new Set(
      this.db.prepare("PRAGMA table_info(chats)").all().map((row) => row.name),
    );
    if (!chatColumns.has("summary")) {
      this.db.exec("ALTER TABLE chats ADD COLUMN summary TEXT");
    }
    const messageColumns = new Set(
      this.db.prepare("PRAGMA table_info(chat_messages)").all().map((row) => row.name),
    );
    if (!messageColumns.has("messages_read")) {
      this.db.exec("ALTER TABLE chat_messages ADD COLUMN messages_read INTEGER");
    }
    for (const file of [databasePath, `${databasePath}-wal`, `${databasePath}-shm`]) {
      if (existsSync(file)) chmodSync(file, 0o600);
    }
  }

  listChats() {
    return this.db.prepare(`
      SELECT c.id, c.codex_thread_id, c.title, c.summary, c.created_at, c.updated_at,
             (SELECT content FROM chat_messages m
              WHERE m.chat_id = c.id ORDER BY m.id DESC LIMIT 1) AS preview,
             (SELECT COUNT(*) FROM chat_messages m WHERE m.chat_id = c.id) AS message_count
      FROM chats c
      ORDER BY c.updated_at DESC
    `).all();
  }

  getChat(id) {
    const chat = this.db.prepare(`
      SELECT id, codex_thread_id, title, summary, created_at, updated_at
      FROM chats WHERE id = ?
    `).get(id);
    if (!chat) return null;
    return {
      ...chat,
      messages: this.db.prepare(`
        SELECT id, role, content, messages_read, created_at
        FROM chat_messages WHERE chat_id = ? ORDER BY id
      `).all(id),
    };
  }

  createChat(prompt) {
    const id = randomUUID();
    const timestamp = now();
    this.db.prepare(`
      INSERT INTO chats (id, title, created_at, updated_at)
      VALUES (?, ?, ?, ?)
    `).run(id, titleFromPrompt(prompt), timestamp, timestamp);
    this.appendMessage(id, "user", prompt, { timestamp });
    return this.getChat(id);
  }

  appendMessage(chatId, role, content, { timestamp = now(), messagesRead = null } = {}) {
    this.db.prepare(`
      INSERT INTO chat_messages (chat_id, role, content, messages_read, created_at)
      VALUES (?, ?, ?, ?, ?)
    `).run(chatId, role, content, messagesRead, timestamp);
    this.db.prepare("UPDATE chats SET updated_at = ? WHERE id = ?").run(timestamp, chatId);
  }

  attachThread(chatId, threadId) {
    this.db.prepare(`
      UPDATE chats SET codex_thread_id = ?, updated_at = ? WHERE id = ?
    `).run(threadId, now(), chatId);
  }

  updateChatMetadata(chatId, { title, summary }) {
    this.db.prepare(`
      UPDATE chats SET title = ?, summary = ?, updated_at = ? WHERE id = ?
    `).run(title, summary, now(), chatId);
  }

  deleteChat(id) {
    const result = this.db.prepare("DELETE FROM chats WHERE id = ?").run(id);
    return result.changes > 0;
  }

  getInsights() {
    return this.db.prepare(`
      SELECT content, codex_thread_id, source_message_count, status, error, updated_at, format_version
      FROM insight_snapshots WHERE id = 1
    `).get();
  }

  beginInsightRefresh() {
    this.db.prepare(`
      UPDATE insight_snapshots SET status = 'refreshing', error = NULL WHERE id = 1
    `).run();
  }

  completeInsightRefresh({ content, threadId, sourceMessageCount, formatVersion = 2 }) {
    this.db.prepare(`
      UPDATE insight_snapshots
      SET content = ?, codex_thread_id = ?, source_message_count = ?,
          status = 'ready', error = NULL, updated_at = ?, format_version = ?
      WHERE id = 1
    `).run(content, threadId, sourceMessageCount, now(), formatVersion);
  }

  failInsightRefresh(error) {
    this.db.prepare(`
      UPDATE insight_snapshots SET status = 'error', error = ? WHERE id = 1
    `).run(error instanceof Error ? error.message : String(error));
  }
}
