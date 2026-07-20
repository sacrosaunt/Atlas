import { spawnSync } from "node:child_process";
import { createHmac, randomBytes } from "node:crypto";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { ContactIndex } from "./contacts.js";
import { privateAttachmentName, redactSensitiveText } from "./privacy-redaction.js";

const APPLE_EPOCH_UNIX_SECONDS = 978_307_200;
const DEFAULT_DB_PATH = join(homedir(), "Library", "Messages", "chat.db");
const DEFAULT_DECODER_PATH = join(
  homedir(),
  "Atlas",
  "bin",
  "atlas-attributed-decoder",
);

function clamp(value, minimum, maximum, fallback) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(maximum, Math.max(minimum, Math.trunc(parsed)));
}

function appleSecondsToIso(value) {
  if (value === null || value === undefined) return null;
  return new Date((Number(value) + APPLE_EPOCH_UNIX_SECONDS) * 1000).toISOString();
}

function isoToAppleSeconds(value, label) {
  if (!value) return null;
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds)) throw new Error(`${label} must be an ISO-8601 date`);
  return Math.trunc(milliseconds / 1000 - APPLE_EPOCH_UNIX_SECONDS);
}

function decodeAttributedBodies(rows, decoderPath) {
  const bodies = rows.map((row) => {
    if (row.text || !row.attributed_body) return null;
    return Buffer.from(row.attributed_body).toString("base64");
  });

  if (!bodies.some(Boolean) || !existsSync(decoderPath)) return rows;

  const result = spawnSync(decoderPath, [], {
    input: JSON.stringify({ bodies }),
    encoding: "utf8",
    maxBuffer: 128 * 1024 * 1024,
    timeout: 60_000,
  });

  if (result.status !== 0) return rows;

  try {
    const decoded = JSON.parse(result.stdout).texts;
    return rows.map((row, index) => ({
      ...row,
      text: row.text ?? decoded[index] ?? null,
    }));
  } catch {
    return rows;
  }
}

function safeContactValue(value) {
  const redacted = redactSensitiveText(value)?.trim();
  if (!redacted || redacted.includes("[redacted:")) {
    return null;
  }
  return redacted;
}

function cleanMessage(row, personForIdentifier) {
  const attachments = row.attachments_json
    ? JSON.parse(row.attachments_json).filter((item) => item.filename || item.mime_type)
    : [];
  return {
    message_id: row.message_id,
    sent_at: appleSecondsToIso(row.apple_seconds),
    direction: row.is_from_me ? "from_me" : "to_me",
    sender: row.is_from_me
      ? { person_id: "me", name: "You" }
      : personForIdentifier(row.sender),
    service: row.service,
    text: redactSensitiveText(row.text),
    subject: redactSensitiveText(row.subject),
    is_reply: Boolean(row.reply_to_guid),
    attachments: attachments.map((item) => ({
      name: privateAttachmentName(item.transfer_name ?? item.filename),
      mime_type: item.mime_type ?? null,
    })),
  };
}

export class IMessageStore {
  constructor({ databasePath, decoderPath, identitySecret } = {}) {
    this.databasePath = databasePath ?? process.env.ATLAS_MESSAGES_DB ?? DEFAULT_DB_PATH;
    this.decoderPath = decoderPath ?? process.env.ATLAS_DECODER_PATH ?? DEFAULT_DECODER_PATH;
    this.db = new DatabaseSync(this.databasePath, {
      open: true,
      readOnly: true,
      timeout: 5_000,
    });
    this.db.exec("PRAGMA query_only = ON");
    this.contacts = new ContactIndex();
    this.identitySecret = identitySecret ?? randomBytes(32);
    this.conversationByPublicId = new Map();
    this.personByPublicId = new Map();
    this.refreshIdentityIndex();
  }

  opaqueId(namespace, value) {
    const digest = createHmac("sha256", this.identitySecret)
      .update(`${namespace}:${value}`)
      .digest("base64url")
      .slice(0, 18);
    return `${namespace}_${digest}`;
  }

  conversationId(chatId) {
    return this.opaqueId("conv", chatId);
  }

  personId(identifier) {
    return this.opaqueId("person", identifier);
  }

  refreshIdentityIndex() {
    this.conversationByPublicId.clear();
    for (const row of this.db.prepare("SELECT ROWID AS chat_id FROM chat").all()) {
      this.conversationByPublicId.set(this.conversationId(row.chat_id), row.chat_id);
    }
    this.personByPublicId.clear();
    for (const row of this.db.prepare("SELECT ROWID AS handle_id, id FROM handle WHERE id IS NOT NULL").all()) {
      this.personByPublicId.set(this.personId(row.id), row);
    }
  }

  resolveConversationId(publicId, { optional = false } = {}) {
    if (!publicId && optional) return null;
    let chatId = this.conversationByPublicId.get(publicId);
    if (!chatId) {
      this.refreshIdentityIndex();
      chatId = this.conversationByPublicId.get(publicId);
    }
    if (!chatId) throw new Error("Unknown conversation_id");
    return chatId;
  }

  resolvePersonIds(publicIds = []) {
    const resolved = [];
    for (const publicId of publicIds) {
      let person = this.personByPublicId.get(publicId);
      if (!person) {
        this.refreshIdentityIndex();
        person = this.personByPublicId.get(publicId);
      }
      if (!person) throw new Error("Unknown person_id");
      resolved.push(person.handle_id);
    }
    return [...new Set(resolved)];
  }

  personForIdentifier(identifier) {
    if (!identifier) return { person_id: "unknown", name: "Unknown person" };
    const profile = this.contacts.profileFor(identifier);
    const contactName = safeContactValue(profile?.name);
    const person = {
      person_id: this.personId(identifier),
      name: contactName ?? "Unknown person",
    };
    for (const [key, value] of [
      ["nickname", profile?.nickname],
      ["company", profile?.company],
      ["job_title", profile?.job_title],
      ["department", profile?.department],
    ]) {
      const safeValue = safeContactValue(value);
      if (safeValue && !(key === "nickname" && safeValue === contactName)) person[key] = safeValue;
    }
    return person;
  }

  senderForIdentifier(identifier) {
    const person = this.personForIdentifier(identifier);
    return { person_id: person.person_id, name: person.name };
  }

  participantsForChat(chatId) {
    return this.db.prepare(`
      SELECT h.id FROM chat_handle_join chj
      JOIN handle h ON h.ROWID = chj.handle_id
      WHERE chj.chat_id = ? ORDER BY h.ROWID
    `).all(chatId).map((row) => this.personForIdentifier(row.id));
  }

  safeConversationName(displayName, participants) {
    const redacted = redactSensitiveText(displayName)?.trim();
    if (redacted && !redacted.includes("[redacted:")) {
      return redacted;
    }
    const names = participants.map((person) => person.name).filter((name) => name !== "Unknown person");
    return names.length ? names.join(", ") : "Unnamed conversation";
  }

  info() {
    const counts = this.db.prepare(`
      SELECT
        (SELECT COUNT(*) FROM message) AS messages,
        (SELECT COUNT(*) FROM chat) AS conversations,
        (SELECT COUNT(*) FROM handle) AS handles
    `).get();
    return {
      access: "read-only",
      messages: counts.messages,
      conversations: counts.conversations,
      people: counts.handles,
    };
  }

  listConversations({ query, limit } = {}) {
    const safeLimit = clamp(limit, 1, 100, 25);
    const search = query?.trim() ? `%${query.trim()}%` : null;
    const contactHandles = query?.trim()
      ? this.db.prepare("SELECT id FROM handle").all()
        .map((row) => row.id)
        .filter((id) => this.contacts.matches(id, query.trim()))
      : [];
    const rows = this.db.prepare(`
      SELECT
        c.ROWID AS chat_id,
        c.guid,
        c.chat_identifier,
        c.display_name,
        c.service_name,
        c.is_archived,
        (
          SELECT GROUP_CONCAT(h.id, ', ')
          FROM chat_handle_join chj
          JOIN handle h ON h.ROWID = chj.handle_id
          WHERE chj.chat_id = c.ROWID
        ) AS participants,
        CASE
          WHEN ABS(MAX(cmj.message_date)) > 1000000000000
            THEN CAST(MAX(cmj.message_date) / 1000000000 AS INTEGER)
          ELSE MAX(cmj.message_date)
        END AS last_apple_seconds
      FROM chat c
      LEFT JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
      WHERE (
        :search IS NULL
        OR c.display_name LIKE :search COLLATE NOCASE
        OR c.chat_identifier LIKE :search COLLATE NOCASE
        OR EXISTS (
          SELECT 1
          FROM chat_handle_join search_chj
          JOIN handle search_h ON search_h.ROWID = search_chj.handle_id
          WHERE search_chj.chat_id = c.ROWID
            AND search_h.id LIKE :search COLLATE NOCASE
        )
        OR EXISTS (
          SELECT 1
          FROM chat_handle_join contact_chj
          JOIN handle contact_h ON contact_h.ROWID = contact_chj.handle_id
          WHERE contact_chj.chat_id = c.ROWID
            AND contact_h.id IN (SELECT value FROM json_each(:contact_handles))
        )
      )
      GROUP BY c.ROWID
      ORDER BY MAX(cmj.message_date) DESC
      LIMIT :limit
    `).all({ search, contact_handles: JSON.stringify(contactHandles), limit: safeLimit });

    return rows.map((row) => ({
      conversation_id: this.conversationId(row.chat_id),
      name: this.safeConversationName(
        row.display_name,
        (row.participants?.split(", ") ?? []).map((identifier) => this.personForIdentifier(identifier)),
      ),
      participants: (row.participants?.split(", ") ?? [])
        .map((identifier) => this.personForIdentifier(identifier)),
      service: row.service_name,
      archived: Boolean(row.is_archived),
      last_message_at: appleSecondsToIso(row.last_apple_seconds),
    }));
  }

  listPeople({ query, limit } = {}) {
    const safeLimit = clamp(limit, 1, 200, 50);
    const needle = query?.trim().toLocaleLowerCase() ?? "";
    const rows = this.db.prepare(`
      SELECT h.id AS identifier,
             COUNT(DISTINCT chj.chat_id) AS conversation_count,
             CASE
               WHEN ABS(MAX(cmj.message_date)) > 1000000000000
                 THEN CAST(MAX(cmj.message_date) / 1000000000 AS INTEGER)
               ELSE MAX(cmj.message_date)
             END AS last_apple_seconds
      FROM handle h
      LEFT JOIN chat_handle_join chj ON chj.handle_id = h.ROWID
      LEFT JOIN chat_message_join cmj ON cmj.chat_id = chj.chat_id
      WHERE h.id IS NOT NULL
      GROUP BY h.ROWID
      ORDER BY MAX(cmj.message_date) DESC
    `).all();
    return rows
      .map((row) => ({
        ...this.personForIdentifier(row.identifier),
        conversation_count: row.conversation_count,
        last_message_at: appleSecondsToIso(row.last_apple_seconds),
        _matches: !needle
          || this.contacts.nameFor(row.identifier)?.toLocaleLowerCase().includes(needle)
          || this.contacts.matches(row.identifier, needle),
      }))
      .filter((person) => person._matches)
      .slice(0, safeLimit)
      .map(({ _matches, ...person }) => person);
  }

  indexableConversations() {
    return this.db.prepare(`
      SELECT c.ROWID AS chat_id, c.display_name,
             COUNT(DISTINCT m.ROWID) AS message_count
      FROM chat c
      JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
      JOIN message m ON m.ROWID = cmj.message_id
      WHERE m.item_type = 0
      GROUP BY c.ROWID
      HAVING message_count > 0
      ORDER BY c.ROWID
    `).all().map((row) => {
      const participants = this.participantsForChat(row.chat_id);
      return {
        conversation_id: this.conversationId(row.chat_id),
        name: this.safeConversationName(row.display_name, participants),
        person_ids: participants.map((person) => person.person_id),
        message_count: row.message_count,
      };
    });
  }

  indexableMessages({ conversation_id, after_message_id = 0, limit = 256 } = {}) {
    const safeChatId = this.resolveConversationId(conversation_id);
    const safeAfter = clamp(after_message_id, 0, Number.MAX_SAFE_INTEGER, 0);
    const safeLimit = clamp(limit, 1, 1_000, 256);
    let rows = this.db.prepare(`
      SELECT m.ROWID AS message_id, m.text,
             m.attributedBody AS attributed_body, m.subject, m.is_from_me,
             m.service, m.reply_to_guid, h.id AS sender,
             CASE
               WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER)
               ELSE m.date
             END AS apple_seconds,
             '[]' AS attachments_json
      FROM chat_message_join cmj
      JOIN message m ON m.ROWID = cmj.message_id
      LEFT JOIN handle h ON h.ROWID = m.handle_id
      WHERE cmj.chat_id = :chat_id
        AND m.item_type = 0
        AND m.ROWID > :after
      ORDER BY m.ROWID
      LIMIT :limit
    `).all({ chat_id: safeChatId, after: safeAfter, limit: safeLimit });
    rows = decodeAttributedBodies(rows, this.decoderPath);
    return {
      messages: rows.map((row) => cleanMessage(
        row,
        (identifier) => this.senderForIdentifier(identifier),
      )),
      scanned_through_message_id: rows.at(-1)?.message_id ?? safeAfter,
      has_more: rows.length === safeLimit,
    };
  }

  readConversation({ conversation_id, limit, before_message_id, since, until } = {}) {
    const safeChatId = this.resolveConversationId(conversation_id);
    const safeLimit = clamp(limit, 1, 10_000, 100);
    const before = before_message_id
      ? clamp(before_message_id, 1, Number.MAX_SAFE_INTEGER, null)
      : null;
    const sinceApple = isoToAppleSeconds(since, "since");
    const untilApple = isoToAppleSeconds(until, "until");

    const chat = this.db.prepare(`
      SELECT ROWID AS chat_id, display_name AS name, service_name AS service
      FROM chat WHERE ROWID = ?
    `).get(safeChatId);
    if (!chat) throw new Error("Unknown conversation_id");

    let rows = this.db.prepare(`
      SELECT
        m.ROWID AS message_id,
        m.guid,
        m.text,
        m.attributedBody AS attributed_body,
        m.subject,
        m.is_from_me,
        m.service,
        m.reply_to_guid,
        h.id AS sender,
        CASE
          WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER)
          ELSE m.date
        END AS apple_seconds,
        (
          SELECT json_group_array(json_object(
            'filename', a.filename,
            'mime_type', a.mime_type,
            'transfer_name', a.transfer_name
          ))
          FROM message_attachment_join maj
          JOIN attachment a ON a.ROWID = maj.attachment_id
          WHERE maj.message_id = m.ROWID
        ) AS attachments_json
      FROM chat_message_join cmj
      JOIN message m ON m.ROWID = cmj.message_id
      LEFT JOIN handle h ON h.ROWID = m.handle_id
      WHERE cmj.chat_id = :chat_id
        AND (:before IS NULL OR m.ROWID < :before)
        AND (:since IS NULL OR (CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER) ELSE m.date END) >= :since)
        AND (:until IS NULL OR (CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER) ELSE m.date END) < :until)
      ORDER BY m.date DESC, m.ROWID DESC
      LIMIT :limit
    `).all({ chat_id: safeChatId, before, since: sinceApple, until: untilApple, limit: safeLimit });

    rows = decodeAttributedBodies(rows, this.decoderPath);
    const participants = this.participantsForChat(safeChatId);
    const messages = rows
      .map((row) => cleanMessage(row, (identifier) => this.senderForIdentifier(identifier)))
      .reverse();
    return {
      conversation: {
        conversation_id,
        name: this.safeConversationName(chat.name, participants),
        participants,
        service: chat.service,
      },
      messages,
      next_before_message_id: rows.length === safeLimit
        ? Math.min(...rows.map((row) => row.message_id))
        : null,
    };
  }

  searchMessages({
    query,
    conversation_id,
    person_ids = [],
    person_match = "any",
    limit,
    since,
    until,
    direction,
  } = {}) {
    const needle = query?.trim();
    if (!needle) throw new Error("query is required");
    if (needle.length > 500) throw new Error("query must be 500 characters or fewer");
    const safeLimit = clamp(limit, 1, 5_000, 50);
    const safeChatId = this.resolveConversationId(conversation_id, { optional: true });
    const personHandleIds = this.resolvePersonIds(person_ids);
    const requiredPersonCount = person_match === "all" ? personHandleIds.length : Math.min(1, personHandleIds.length);
    const sinceApple = isoToAppleSeconds(since, "since");
    const untilApple = isoToAppleSeconds(until, "until");
    const fromMe = direction === "from_me" ? 1 : direction === "to_me" ? 0 : null;

    let rows = this.db.prepare(`
      SELECT
        m.ROWID AS message_id,
        m.guid,
        m.text,
        m.attributedBody AS attributed_body,
        m.subject,
        m.is_from_me,
        m.service,
        m.reply_to_guid,
        h.id AS sender,
        c.ROWID AS chat_id,
        c.display_name AS chat_name,
        CASE
          WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER)
          ELSE m.date
        END AS apple_seconds,
        '[]' AS attachments_json
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      JOIN chat c ON c.ROWID = cmj.chat_id
      LEFT JOIN handle h ON h.ROWID = m.handle_id
      WHERE (:chat_id IS NULL OR c.ROWID = :chat_id)
        AND (
          :required_person_count = 0
          OR (
            SELECT COUNT(DISTINCT filtered_people.handle_id)
            FROM chat_handle_join filtered_people
            WHERE filtered_people.chat_id = c.ROWID
              AND filtered_people.handle_id IN (SELECT value FROM json_each(:person_handle_ids))
          ) >= :required_person_count
        )
        AND (:since IS NULL OR (CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER) ELSE m.date END) >= :since)
        AND (:until IS NULL OR (CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER) ELSE m.date END) < :until)
        AND (:from_me IS NULL OR m.is_from_me = :from_me)
        AND (
          m.text LIKE :like_query COLLATE NOCASE
          OR instr(m.attributedBody, :blob_query) > 0
        )
      ORDER BY m.date DESC, m.ROWID DESC
      LIMIT :limit
    `).all({
      chat_id: safeChatId,
      required_person_count: requiredPersonCount,
      person_handle_ids: JSON.stringify(personHandleIds),
      since: sinceApple,
      until: untilApple,
      from_me: fromMe,
      like_query: `%${needle}%`,
      blob_query: Buffer.from(needle, "utf8"),
      limit: safeLimit,
    });

    rows = decodeAttributedBodies(rows, this.decoderPath);
    return rows.map((row) => ({
      conversation_id: this.conversationId(row.chat_id),
      conversation_name: this.safeConversationName(
        row.chat_name,
        this.participantsForChat(row.chat_id),
      ),
      ...cleanMessage(row, (identifier) => this.senderForIdentifier(identifier)),
    }));
  }

  conversationStats({ conversation_id, since, until } = {}) {
    const safeChatId = this.resolveConversationId(conversation_id, { optional: true });
    const sinceApple = isoToAppleSeconds(since, "since");
    const untilApple = isoToAppleSeconds(until, "until");
    const dateExpression = "CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER) ELSE m.date END";
    const filters = `
      (:chat_id IS NULL OR cmj.chat_id = :chat_id)
      AND (:since IS NULL OR ${dateExpression} >= :since)
      AND (:until IS NULL OR ${dateExpression} < :until)
      AND m.item_type = 0
    `;
    const params = { chat_id: safeChatId, since: sinceApple, until: untilApple };
    const totals = this.db.prepare(`
      SELECT COUNT(DISTINCT m.ROWID) AS messages,
             SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS from_me,
             SUM(CASE WHEN m.is_from_me = 0 THEN 1 ELSE 0 END) AS to_me,
             MIN(${dateExpression}) AS first_apple_seconds,
             MAX(${dateExpression}) AS last_apple_seconds,
             COUNT(DISTINCT cmj.chat_id) AS conversations
      FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      WHERE ${filters}
    `).get(params);
    const byYear = this.db.prepare(`
      SELECT strftime('%Y', ${dateExpression} + ${APPLE_EPOCH_UNIX_SECONDS}, 'unixepoch') AS year,
             COUNT(DISTINCT m.ROWID) AS messages,
             SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS from_me,
             SUM(CASE WHEN m.is_from_me = 0 THEN 1 ELSE 0 END) AS to_me
      FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      WHERE ${filters}
      GROUP BY year ORDER BY year
    `).all(params);
    return {
      scope: safeChatId ? { conversation_id } : { all_conversations: true },
      period: { since: since ?? null, until: until ?? null },
      totals: {
        ...totals,
        first_message_at: appleSecondsToIso(totals.first_apple_seconds),
        last_message_at: appleSecondsToIso(totals.last_apple_seconds),
        first_apple_seconds: undefined,
        last_apple_seconds: undefined,
      },
      by_year: byYear,
    };
  }

  sampleConversation({ conversation_id, since, until, limit } = {}) {
    const safeChatId = this.resolveConversationId(conversation_id);
    const safeLimit = clamp(limit, 5, 2_500, 60);
    const sinceApple = isoToAppleSeconds(since, "since");
    const untilApple = isoToAppleSeconds(until, "until");
    let rows = this.db.prepare(`
      WITH eligible AS (
        SELECT m.ROWID AS message_id, m.guid, m.text,
               m.attributedBody AS attributed_body, m.subject, m.is_from_me,
               m.service, m.reply_to_guid, h.id AS sender,
               CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER) ELSE m.date END AS apple_seconds,
               ROW_NUMBER() OVER (ORDER BY m.date, m.ROWID) AS row_number,
               COUNT(*) OVER () AS total_rows,
               '[]' AS attachments_json
        FROM chat_message_join cmj
        JOIN message m ON m.ROWID = cmj.message_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE cmj.chat_id = :chat_id
          AND m.item_type = 0
          AND (:since IS NULL OR (CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER) ELSE m.date END) >= :since)
          AND (:until IS NULL OR (CASE WHEN ABS(m.date) > 1000000000000 THEN CAST(m.date / 1000000000 AS INTEGER) ELSE m.date END) < :until)
      )
      SELECT * FROM eligible
      WHERE total_rows <= :limit
         OR (row_number - 1) % MAX(1, CAST(total_rows / :limit AS INTEGER)) = 0
      ORDER BY row_number LIMIT :limit
    `).all({ chat_id: safeChatId, since: sinceApple, until: untilApple, limit: safeLimit });
    rows = decodeAttributedBodies(rows, this.decoderPath);
    return {
      conversation_id,
      sampling: "evenly spaced across the requested period; not a random or complete sample",
      period: { since: since ?? null, until: until ?? null },
      messages: rows.map((row) => cleanMessage(
        row,
        (identifier) => this.senderForIdentifier(identifier),
      )),
    };
  }
}
