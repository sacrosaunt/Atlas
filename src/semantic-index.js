import { createHash } from "node:crypto";
import {
  createReadStream,
  createWriteStream,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { once } from "node:events";
import { execFileSync, spawn } from "node:child_process";
import { DatabaseSync } from "node:sqlite";
import { setImmediate as yieldToEventLoop } from "node:timers/promises";
import * as sqliteVec from "sqlite-vec";

const STATE_DIRECTORY = join(
  homedir(),
  "Library",
  "Application Support",
  "Atlas",
  "SemanticSearch",
);
const MODEL_PATH = join(STATE_DIRECTORY, "semantic-search.gguf");
const PARTIAL_MODEL_PATH = `${MODEL_PATH}.part`;
const DATABASE_PATH = join(STATE_DIRECTORY, "search.sqlite");
const SETTINGS_PATH = join(STATE_DIRECTORY, "settings.json");

const MODEL_URL = "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/main/Qwen3-Embedding-0.6B-Q8_0.gguf";
const MODEL_BYTES = 639_150_592;
const MODEL_SHA256 = "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439";
const VECTOR_DIMENSIONS = 384;
const SCHEMA_VERSION = "3";
const EMBEDDING_ORDER = "reverse_chronological_v1";
const CHUNK_MESSAGES = 8;
const CHUNK_STRIDE = 6;
const EMBEDDING_WORKERS = 2;
const INDEX_INTERVAL_MS = 30 * 60 * 1_000;
const POWER_CHECK_INTERVAL_MS = 30_000;

export function readPowerState({ pauseOnBattery = true } = {}) {
  try {
    const batteryOutput = execFileSync("/usr/bin/pmset", ["-g", "batt"], {
      encoding: "utf8",
      timeout: 2_000,
    });
    const onBattery = /Now drawing from 'Battery Power'/i.test(batteryOutput);
    const customOutput = execFileSync("/usr/bin/pmset", ["-g", "custom"], {
      encoding: "utf8",
      timeout: 2_000,
    });
    const activeSection = onBattery
      ? customOutput.split(/AC Power:/i)[0]
      : (customOutput.split(/AC Power:/i)[1] ?? customOutput);
    const lowPowerMode = /lowpowermode\s+1\b/i.test(activeSection);
    let thermalPressure = false;
    try {
      const thermalOutput = execFileSync("/usr/bin/pmset", ["-g", "therm"], {
        encoding: "utf8",
        timeout: 2_000,
      });
      const speedLimit = thermalOutput.match(/CPU_Speed_Limit\s*=\s*(\d+)/i)?.[1];
      thermalPressure = /thermal pressure[^\n]*(serious|critical)/i.test(thermalOutput)
        || /Thermal_Level\s*=\s*[1-9]/i.test(thermalOutput)
        || (speedLimit !== undefined && Number(speedLimit) < 80);
    } catch {
      thermalPressure = false;
    }
    const shouldPause = (pauseOnBattery && onBattery) || lowPowerMode || thermalPressure;
    return {
      shouldPause,
      onAC: !onBattery,
      verified: true,
      reason: lowPowerMode
        ? "low_power_mode"
        : thermalPressure
          ? "thermal"
          : pauseOnBattery && onBattery
            ? "battery"
            : null,
    };
  } catch {
    return { shouldPause: false, onAC: false, verified: false, reason: null };
  }
}

function safeJson(value, fallback) {
  try { return JSON.parse(value); } catch { return fallback; }
}

function bytesOnDisk(path) {
  try { return statSync(path).size; } catch { return 0; }
}

function normalizeVector(values) {
  const dimensions = Math.min(VECTOR_DIMENSIONS, values.length);
  let squaredLength = 0;
  for (let index = 0; index < dimensions; index += 1) {
    squaredLength += values[index] * values[index];
  }
  const length = Math.sqrt(squaredLength) || 1;
  const reduced = new Float32Array(VECTOR_DIMENSIONS);
  for (let index = 0; index < dimensions; index += 1) {
    reduced[index] = values[index] / length;
  }
  return Buffer.from(reduced.buffer, reduced.byteOffset, reduced.byteLength);
}

function tokenizeFtsQuery(query) {
  const tokens = query.normalize("NFKC").match(/[\p{L}\p{N}]{2,}/gu) ?? [];
  return [...new Set(tokens.slice(0, 32).map((token) => token.replaceAll('"', '""')))]
    .map((token) => `"${token}"*`)
    .join(" OR ");
}

function tokenizeLiteralFtsQuery(query) {
  const tokens = query.normalize("NFKC").match(/[\p{L}\p{N}]{2,}/gu) ?? [];
  return [...new Set(tokens.slice(0, 32).map((token) => token.replaceAll('"', '""')))]
    .map((token) => `"${token}"*`)
    .join(" AND ");
}

function formatDocument(messages) {
  return messages
    .filter((message) => message.text || message.subject)
    .map((message) => {
      const author = message.direction === "from_me" ? "You" : (message.sender?.name || "Contact");
      const body = [message.subject, message.text].filter(Boolean).join(" — ").trim();
      return `${message.sent_at || "Unknown date"} · ${author}: ${body}`;
    })
    .join("\n")
    .slice(0, 24_000);
}

function parseStoredJson(value) {
  return safeJson(value, []);
}

function publicDocument(row, relevance) {
  return {
    passage_id: `passage_${row.id}`,
    conversation_id: row.conversation_id,
    conversation_name: row.conversation_name,
    start_at: row.start_at,
    end_at: row.end_at,
    message_count: row.message_count,
    person_ids: parseStoredJson(row.person_ids),
    directions: parseStoredJson(row.directions),
    text: row.text,
    relevance: Math.max(0, Math.min(1, Number(relevance.toFixed(4)))),
  };
}

export class SemanticIndex {
  constructor({
    store,
    stateDirectory = STATE_DIRECTORY,
    powerStateProvider = readPowerState,
    powerPausePollMs = 2_000,
    sleepAssertionEnabled = true,
    preEmbeddingTask = null,
  } = {}) {
    this.store = store;
    this.stateDirectory = stateDirectory;
    this.modelPath = join(stateDirectory, "semantic-search.gguf");
    this.partialModelPath = `${this.modelPath}.part`;
    this.databasePath = join(stateDirectory, "search.sqlite");
    this.settingsPath = join(stateDirectory, "settings.json");
    mkdirSync(this.stateDirectory, { recursive: true, mode: 0o700 });
    this.enabled = this.readSettings().enabled === true;
    this.phase = this.enabled && existsSync(this.modelPath) ? "preparing" : "off";
    this.textPhase = "pending";
    this.textError = null;
    this.error = null;
    this.downloadedBytes = bytesOnDisk(this.partialModelPath);
    this.indexedMessages = 0;
    this.totalMessages = 0;
    this.indexedDocuments = 0;
    this.embeddedDocuments = 0;
    this.totalDocuments = 0;
    this.abortController = null;
    this.job = null;
    this.downloadAbortController = null;
    this.downloadJob = null;
    this.database = null;
    this.llama = null;
    this.model = null;
    this.embeddingContexts = [];
    this.modelVerified = false;
    this.embeddingQueues = Array.from({ length: EMBEDDING_WORKERS }, () => Promise.resolve());
    this.nextEmbeddingWorker = 0;
    this.modelLoadPromise = null;
    this.embeddingRate = 0;
    this.embeddingRateUpdatedAt = null;
    this.embeddingStartedAt = null;
    this.publishedEtaSeconds = null;
    this.etaPublishedAt = null;
    this.timer = null;
    this.powerTimer = null;
    this.powerStateProvider = powerStateProvider;
    this.powerPausePollMs = powerPausePollMs;
    this.powerState = this.powerStateProvider();
    this.sleepAssertionEnabled = sleepAssertionEnabled;
    this.sleepAssertionProcess = null;
    this.preEmbeddingTask = preEmbeddingTask;
  }

  readSettings() {
    if (!existsSync(this.settingsPath)) return { enabled: false };
    try { return safeJson(readFileSync(this.settingsPath, "utf8"), { enabled: false }); }
    catch { return { enabled: false }; }
  }

  writeSettings() {
    const temporaryPath = `${this.settingsPath}.tmp`;
    writeFileSync(temporaryPath, `${JSON.stringify({ enabled: this.enabled }, null, 2)}\n`, {
      mode: 0o600,
    });
    renameSync(temporaryPath, this.settingsPath);
  }

  start() {
    this.startIndexing();
    this.timer = setInterval(() => {
      if (!this.job) this.startIndexing();
    }, INDEX_INTERVAL_MS);
    this.timer.unref?.();
    this.powerTimer = setInterval(() => {
      this.powerState = this.powerStateProvider();
      this.updateSleepAssertion();
    }, POWER_CHECK_INTERVAL_MS);
    this.powerTimer.unref?.();
  }

  setPreEmbeddingTask(task) {
    this.preEmbeddingTask = task;
  }

  isModelInstalled() {
    return bytesOnDisk(this.modelPath) === MODEL_BYTES;
  }

  status() {
    const activelyBuilding = this.job
      && (this.textPhase === "indexing" || ["embedding", "paused"].includes(this.phase));
    if (!activelyBuilding && (this.database || existsSync(this.databasePath))) {
      try {
        const database = this.openDatabase();
        this.indexedDocuments = Number(database.prepare("SELECT COUNT(*) AS count FROM documents").get().count);
        this.totalDocuments = this.indexedDocuments;
        this.embeddedDocuments = Number(database.prepare(
          "SELECT COUNT(*) AS count FROM documents WHERE embedding IS NOT NULL",
        ).get().count);
        this.indexedMessages = Number(database.prepare(
          "SELECT COALESCE(SUM(indexed_messages), 0) AS count FROM conversations",
        ).get().count);
      } catch {
        // A corrupt sidecar is surfaced when indexing or searching attempts to use it.
      }
    }
    return {
      enabled: this.enabled,
      installed: this.isModelInstalled(),
      phase: this.phase,
      text_index_phase: this.textPhase,
      text_index_error: this.textError,
      pause_reason: this.phase === "paused" ? this.powerState.reason : null,
      preventing_sleep: Boolean(this.sleepAssertionProcess),
      downloaded_bytes: ["downloading", "verifying"].includes(this.phase)
        ? this.downloadedBytes
        : (this.isModelInstalled() ? MODEL_BYTES : bytesOnDisk(this.partialModelPath)),
      total_download_bytes: MODEL_BYTES,
      indexed_messages: this.indexedMessages,
      total_messages: this.totalMessages,
      indexed_documents: this.indexedDocuments,
      embedded_documents: this.embeddedDocuments,
      total_documents: this.totalDocuments,
      eta_seconds: this.currentEtaSeconds(),
      index_bytes: bytesOnDisk(this.databasePath)
        + bytesOnDisk(`${this.databasePath}-wal`)
        + bytesOnDisk(`${this.databasePath}-shm`),
      error: this.error,
    };
  }

  async enable() {
    this.enabled = true;
    this.error = null;
    this.writeSettings();
    if (this.isModelInstalled()) this.startIndexing();
    else this.startDownload();
    return this.status();
  }

  async disable() {
    this.enabled = false;
    this.writeSettings();
    if (["embedding", "paused"].includes(this.phase)) this.abortController?.abort();
    this.downloadAbortController?.abort();
    this.phase = "off";
    this.updateSleepAssertion(false);
    this.error = null;
    return this.status();
  }

  async remove() {
    const wasEmbedding = ["embedding", "paused"].includes(this.phase);
    await this.disable();
    if (wasEmbedding && this.job) await this.job.catch(() => {});
    if (this.downloadJob) await this.downloadJob.catch(() => {});
    await this.disposeModel();
    for (const path of [
      this.modelPath,
      this.partialModelPath,
    ]) {
      rmSync(path, { force: true });
    }
    if (this.database || existsSync(this.databasePath)) {
      const database = this.openDatabase();
      database.exec("UPDATE documents SET embedding = NULL");
    }
    this.downloadedBytes = 0;
    this.embeddedDocuments = 0;
    this.embeddingRate = 0;
    this.embeddingRateUpdatedAt = null;
    this.embeddingStartedAt = null;
    this.publishedEtaSeconds = null;
    this.etaPublishedAt = null;
    return this.status();
  }

  startDownload() {
    if (this.downloadJob) return this.downloadJob;
    this.downloadAbortController = new AbortController();
    this.phase = "downloading";
    this.error = null;
    this.downloadJob = this.downloadModel(this.downloadAbortController.signal)
      .then(async () => {
        if (this.job) await this.job.catch(() => {});
        if (this.enabled) return this.startIndexing();
        this.phase = "off";
        return undefined;
      })
      .catch((error) => this.handleJobError(error))
      .finally(() => {
        this.downloadJob = null;
        this.downloadAbortController = null;
      });
    return this.downloadJob;
  }

  startIndexing() {
    if (this.job) return this.job;
    this.abortController = new AbortController();
    this.job = this.indexMessages(this.abortController.signal)
      .catch((error) => {
        if (error?.name === "AbortError") return this.handleJobError(error);
        this.textPhase = "error";
        this.textError = error instanceof Error ? error.message : String(error);
        console.error("Fast text indexing failed", error);
      })
      .finally(() => {
        this.job = null;
        this.abortController = null;
      });
    return this.job;
  }

  handleJobError(error) {
    if (error?.name === "AbortError") {
      this.phase = "off";
      this.updateSleepAssertion(false);
      return;
    }
    this.phase = "error";
    this.updateSleepAssertion(false);
    this.error = error instanceof Error ? error.message : String(error);
    console.error("Enhanced search failed", error);
  }

  async downloadModel(signal) {
    rmSync(this.partialModelPath, { force: true });
    this.downloadedBytes = 0;
    const response = await fetch(MODEL_URL, { signal, redirect: "follow" });
    if (!response.ok || !response.body) {
      throw new Error(`Download failed with HTTP ${response.status}`);
    }
    const output = createWriteStream(this.partialModelPath, { flags: "wx", mode: 0o600 });
    try {
      for await (const chunk of response.body) {
        if (signal.aborted) throw new DOMException("Download cancelled", "AbortError");
        const buffer = Buffer.from(chunk);
        if (!output.write(buffer)) await once(output, "drain");
        this.downloadedBytes += buffer.length;
      }
      output.end();
      await once(output, "close");
    } catch (error) {
      output.destroy();
      rmSync(this.partialModelPath, { force: true });
      this.downloadedBytes = 0;
      throw error;
    }
    if (this.downloadedBytes !== MODEL_BYTES) {
      rmSync(this.partialModelPath, { force: true });
      throw new Error("The downloaded search component had an unexpected size");
    }
    this.phase = "verifying";
    const hash = createHash("sha256");
    for await (const chunk of createReadStream(this.partialModelPath)) {
      if (signal.aborted) {
        rmSync(this.partialModelPath, { force: true });
        throw new DOMException("Download cancelled", "AbortError");
      }
      hash.update(chunk);
    }
    if (hash.digest("hex") !== MODEL_SHA256) {
      rmSync(this.partialModelPath, { force: true });
      throw new Error("The downloaded search component could not be verified");
    }
    renameSync(this.partialModelPath, this.modelPath);
    this.modelVerified = true;
  }

  openDatabase() {
    if (this.database) return this.database;
    const database = new DatabaseSync(this.databasePath, { allowExtension: true, timeout: 5_000 });
    sqliteVec.load(database);
    database.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = NORMAL;
      PRAGMA foreign_keys = ON;
      CREATE TABLE IF NOT EXISTS metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    `);
    const schema = database.prepare("SELECT value FROM metadata WHERE key = 'schema_version'").get()?.value;
    const dimensions = database.prepare("SELECT value FROM metadata WHERE key = 'vector_dimensions'").get()?.value;
    const modelHash = database.prepare("SELECT value FROM metadata WHERE key = 'model_sha256'").get()?.value;
    if (schema && (schema !== SCHEMA_VERSION
      || dimensions !== String(VECTOR_DIMENSIONS)
      || modelHash !== MODEL_SHA256)) {
      database.exec(`
        DROP TABLE IF EXISTS messages_fts;
        DROP TABLE IF EXISTS messages;
        DROP TABLE IF EXISTS documents_fts;
        DROP TABLE IF EXISTS documents;
        DROP TABLE IF EXISTS conversations;
        DELETE FROM metadata;
      `);
    }
    database.exec(`
      CREATE TABLE IF NOT EXISTS conversations (
        conversation_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        person_ids TEXT NOT NULL,
        message_count INTEGER NOT NULL DEFAULT 0,
        last_message_id INTEGER NOT NULL DEFAULT 0,
        indexed_messages INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS documents (
        id INTEGER PRIMARY KEY,
        conversation_id TEXT NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,
        start_message_id INTEGER NOT NULL,
        end_message_id INTEGER NOT NULL,
        start_at TEXT,
        end_at TEXT,
        person_ids TEXT NOT NULL,
        directions TEXT NOT NULL,
        text TEXT NOT NULL,
        message_count INTEGER NOT NULL,
        embedding BLOB CHECK(embedding IS NULL OR vec_length(embedding) = ${VECTOR_DIMENSIONS}),
        UNIQUE(conversation_id, start_message_id, end_message_id)
      );
      CREATE INDEX IF NOT EXISTS documents_conversation ON documents(conversation_id);
      CREATE INDEX IF NOT EXISTS documents_dates ON documents(start_at, end_at);
      CREATE INDEX IF NOT EXISTS documents_pending_embeddings
        ON documents(id) WHERE embedding IS NULL;
      CREATE INDEX IF NOT EXISTS documents_pending_embeddings_newest
        ON documents(end_at DESC, id DESC) WHERE embedding IS NULL;
      CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
        text,
        tokenize='unicode61 remove_diacritics 2'
      );
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY,
        conversation_id TEXT NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,
        message_id INTEGER NOT NULL,
        sent_at TEXT,
        direction TEXT NOT NULL,
        sender_json TEXT NOT NULL,
        service TEXT,
        subject TEXT,
        text TEXT,
        is_reply INTEGER NOT NULL DEFAULT 0,
        person_ids TEXT NOT NULL,
        UNIQUE(conversation_id, message_id)
      );
      CREATE INDEX IF NOT EXISTS messages_conversation_date
        ON messages(conversation_id, sent_at DESC);
      CREATE INDEX IF NOT EXISTS messages_date ON messages(sent_at DESC);
      CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
        content,
        tokenize='unicode61 remove_diacritics 2'
      );
    `);
    const setMetadata = database.prepare(
      "INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)",
    );
    const embeddingOrder = database.prepare(
      "SELECT value FROM metadata WHERE key = 'embedding_order'",
    ).get()?.value;
    if (embeddingOrder !== EMBEDDING_ORDER) {
      database.exec("UPDATE documents SET embedding = NULL");
    }
    setMetadata.run("schema_version", SCHEMA_VERSION);
    setMetadata.run("vector_dimensions", String(VECTOR_DIMENSIONS));
    setMetadata.run("model_sha256", MODEL_SHA256);
    setMetadata.run("embedding_order", EMBEDDING_ORDER);
    this.database = database;
    return database;
  }

  async loadModel() {
    if (this.embeddingContexts.length) return this.embeddingContexts;
    if (!this.modelLoadPromise) {
      this.modelLoadPromise = (async () => {
        if (!this.modelVerified) {
          const hash = createHash("sha256");
          for await (const chunk of createReadStream(this.modelPath)) hash.update(chunk);
          if (hash.digest("hex") !== MODEL_SHA256) {
            throw new Error("The local search component could not be verified");
          }
          this.modelVerified = true;
        }
        const { getLlama, LlamaLogLevel } = await import("node-llama-cpp");
        this.llama = await getLlama({ gpu: "metal", build: "never", logLevel: LlamaLogLevel.error });
        this.model = await this.llama.loadModel({
          modelPath: this.modelPath,
          gpuLayers: "auto",
          useMmap: true,
        });
        if (this.model.embeddingVectorSize < VECTOR_DIMENSIONS) {
          throw new Error("The local search component has an incompatible vector size");
        }
        for (let index = 0; index < EMBEDDING_WORKERS; index += 1) {
          this.embeddingContexts.push(await this.model.createEmbeddingContext({
            contextSize: 2_048,
            batchSize: 512,
            threads: 0,
          }));
        }
        return this.embeddingContexts;
      })().finally(() => { this.modelLoadPromise = null; });
    }
    return this.modelLoadPromise;
  }

  async disposeModel() {
    await Promise.allSettled(this.embeddingContexts.map((context) => context.dispose()));
    await this.model?.dispose?.();
    await this.llama?.dispose?.();
    this.embeddingContexts = [];
    this.embeddingQueues = Array.from({ length: EMBEDDING_WORKERS }, () => Promise.resolve());
    this.nextEmbeddingWorker = 0;
    this.modelLoadPromise = null;
    this.model = null;
    this.llama = null;
  }

  async embed(text, { query = false } = {}) {
    const input = query
      ? `Instruct: Find passages from a private message history that answer or illuminate the question.\nQuery: ${text}`
      : text;
    await this.loadModel();
    const worker = this.nextEmbeddingWorker % this.embeddingContexts.length;
    this.nextEmbeddingWorker += 1;
    const operation = this.embeddingQueues[worker].then(async () => {
      const tokens = this.model.tokenize(input);
      const embeddingInput = tokens.length > 2_040 ? tokens.slice(0, 2_040) : tokens;
      const embedding = await this.embeddingContexts[worker].getEmbeddingFor(embeddingInput);
      return normalizeVector(embedding.vector);
    });
    this.embeddingQueues[worker] = operation.catch(() => {});
    return operation;
  }

  async indexMessages(signal) {
    await yieldToEventLoop();
    this.textPhase = "indexing";
    this.textError = null;
    this.updateSleepAssertion(false);
    const database = this.openDatabase();
    const conversations = this.store.indexableConversations();
    this.totalMessages = conversations.reduce((total, chat) => total + Number(chat.message_count), 0);
    this.indexedMessages = Number(database.prepare(
      "SELECT COALESCE(SUM(indexed_messages), 0) AS count FROM conversations",
    ).get().count);
    this.indexedDocuments = Number(database.prepare("SELECT COUNT(*) AS count FROM documents").get().count);
    this.totalDocuments = this.indexedDocuments;
    const upsertConversation = database.prepare(`
      INSERT INTO conversations(conversation_id, name, person_ids, message_count)
      VALUES (:conversation_id, :name, :person_ids, :message_count)
      ON CONFLICT(conversation_id) DO UPDATE SET
        name = excluded.name,
        person_ids = excluded.person_ids,
        message_count = excluded.message_count
    `);
    const getConversation = database.prepare(
      "SELECT last_message_id, indexed_messages FROM conversations WHERE conversation_id = ?",
    );
    const insertDocument = database.prepare(`
      INSERT OR IGNORE INTO documents(
        conversation_id, start_message_id, end_message_id, start_at, end_at,
        person_ids, directions, text, message_count
      ) VALUES (
        :conversation_id, :start_message_id, :end_message_id, :start_at, :end_at,
        :person_ids, :directions, :text, :message_count
      ) RETURNING id
    `);
    const insertFts = database.prepare("INSERT INTO documents_fts(rowid, text) VALUES (?, ?)");
    const insertMessage = database.prepare(`
      INSERT OR IGNORE INTO messages(
        conversation_id, message_id, sent_at, direction, sender_json, service,
        subject, text, is_reply, person_ids
      ) VALUES (
        :conversation_id, :message_id, :sent_at, :direction, :sender_json, :service,
        :subject, :text, :is_reply, :person_ids
      ) RETURNING id
    `);
    const insertMessageFts = database.prepare("INSERT INTO messages_fts(rowid, content) VALUES (?, ?)");
    const updateCursor = database.prepare(`
      UPDATE conversations SET last_message_id = ?, indexed_messages = indexed_messages + ?
      WHERE conversation_id = ?
    `);

    for (const conversation of conversations) {
      if (signal.aborted) throw new DOMException("Indexing cancelled", "AbortError");
      upsertConversation.run({
        ...conversation,
        person_ids: JSON.stringify(conversation.person_ids),
      });
      const stored = getConversation.get(conversation.conversation_id);
      let cursor = Number(stored?.last_message_id ?? 0);
      while (true) {
        if (signal.aborted) throw new DOMException("Indexing cancelled", "AbortError");
        const page = this.store.indexableMessages({
          conversation_id: conversation.conversation_id,
          after_message_id: cursor,
          limit: 512,
        });
        if (!page.messages.length) break;
        database.exec("BEGIN IMMEDIATE");
        try {
          for (const message of page.messages) {
            const content = [message.subject, message.text].filter(Boolean).join(" — ").trim();
            if (!content) continue;
            const messageRow = insertMessage.get({
              conversation_id: conversation.conversation_id,
              message_id: message.message_id,
              sent_at: message.sent_at ?? null,
              direction: message.direction,
              sender_json: JSON.stringify(message.sender ?? { person_id: "unknown", name: "Unknown" }),
              service: message.service ?? null,
              subject: message.subject ?? null,
              text: message.text ?? null,
              is_reply: message.is_reply ? 1 : 0,
              person_ids: JSON.stringify(conversation.person_ids),
            });
            if (messageRow?.id) insertMessageFts.run(messageRow.id, content);
          }
          for (let offset = 0; offset < page.messages.length; offset += CHUNK_STRIDE) {
            if (signal.aborted) throw new DOMException("Indexing cancelled", "AbortError");
            const messages = page.messages.slice(offset, offset + CHUNK_MESSAGES);
            const text = formatDocument(messages);
            if (!text) continue;
            const directions = [...new Set(messages.map((message) => message.direction))];
            const row = insertDocument.get({
              conversation_id: conversation.conversation_id,
              start_message_id: messages[0].message_id,
              end_message_id: messages.at(-1).message_id,
              start_at: messages[0].sent_at,
              end_at: messages.at(-1).sent_at,
              person_ids: JSON.stringify(conversation.person_ids),
              directions: JSON.stringify(directions),
              text,
              message_count: messages.length,
            });
            if (row?.id) insertFts.run(row.id, text);
          }
          database.exec("COMMIT");
        } catch (error) {
          database.exec("ROLLBACK");
          throw error;
        }
        const nextCursor = Number(page.scanned_through_message_id);
        updateCursor.run(nextCursor, page.messages.length, conversation.conversation_id);
        cursor = nextCursor;
        this.indexedMessages += page.messages.length;
        await yieldToEventLoop();
        if (!page.has_more) break;
      }
    }
    this.indexedMessages = Number(database.prepare(
      "SELECT COALESCE(SUM(indexed_messages), 0) AS count FROM conversations",
    ).get().count);
    this.indexedDocuments = Number(database.prepare("SELECT COUNT(*) AS count FROM documents").get().count);
    this.totalDocuments = this.indexedDocuments;
    this.textPhase = "ready";
    if (this.preEmbeddingTask) await this.preEmbeddingTask();
    if (this.enabled && this.isModelInstalled()) await this.embedDocuments(signal);
    else if (this.phase !== "downloading") this.phase = "off";
  }

  async embedDocuments(signal) {
    const database = this.openDatabase();
    this.phase = "embedding";
    this.updateSleepAssertion();
    this.totalDocuments = Number(database.prepare("SELECT COUNT(*) AS count FROM documents").get().count);
    this.embeddedDocuments = Number(database.prepare(
      "SELECT COUNT(*) AS count FROM documents WHERE embedding IS NOT NULL",
    ).get().count);
    this.embeddingRate = 0;
    this.embeddingRateUpdatedAt = performance.now();
    this.embeddingStartedAt = Date.now();
    this.publishedEtaSeconds = null;
    this.etaPublishedAt = null;
    const nextDocuments = database.prepare(`
      SELECT id, text FROM documents
      WHERE embedding IS NULL
      ORDER BY end_at DESC, id DESC
      LIMIT 128
    `);
    const updateEmbedding = database.prepare("UPDATE documents SET embedding = ? WHERE id = ?");
    while (true) {
      if (signal.aborted || !this.enabled) throw new DOMException("Indexing cancelled", "AbortError");
      await this.waitForPower(signal);
      const rows = nextDocuments.all();
      if (!rows.length) break;
      for (let offset = 0; offset < rows.length; offset += EMBEDDING_WORKERS) {
        if (signal.aborted || !this.enabled) throw new DOMException("Indexing cancelled", "AbortError");
        await this.waitForPower(signal);
        const batch = rows.slice(offset, offset + EMBEDDING_WORKERS);
        const batchStartedAt = performance.now();
        const embeddings = await Promise.all(batch.map((row) => this.embed(row.text)));
        batch.forEach((row, index) => updateEmbedding.run(embeddings[index], row.id));
        this.embeddedDocuments += batch.length;
        const elapsedSeconds = Math.max(0.001, (performance.now() - batchStartedAt) / 1_000);
        const instantaneousRate = batch.length / elapsedSeconds;
        this.embeddingRate = this.embeddingRate > 0
          ? this.embeddingRate * 0.85 + instantaneousRate * 0.15
          : instantaneousRate;
        this.embeddingRateUpdatedAt = performance.now();
      }
    }
    this.phase = "ready";
    this.updateSleepAssertion(false);
  }

  currentEtaSeconds() {
    if (this.phase !== "embedding"
      || this.embeddingRate <= 0
      || !this.embeddingStartedAt
      || Date.now() - this.embeddingStartedAt < 120_000) {
      return null;
    }
    const now = Date.now();
    if (this.publishedEtaSeconds === null
      || this.etaPublishedAt === null
      || now - this.etaPublishedAt >= 60_000) {
      this.publishedEtaSeconds = Math.ceil(
        (this.totalDocuments - this.embeddedDocuments) / this.embeddingRate,
      );
      this.etaPublishedAt = now;
    }
    return this.publishedEtaSeconds;
  }

  updateSleepAssertion(shouldPrevent = (
    this.phase === "embedding"
      && this.powerState.verified
      && this.powerState.onAC
      && !this.powerState.shouldPause
  )) {
    if (!this.sleepAssertionEnabled) shouldPrevent = false;
    if (shouldPrevent && !this.sleepAssertionProcess) {
      const child = spawn("/usr/bin/caffeinate", ["-i", "-w", String(process.pid)], {
        stdio: "ignore",
      });
      child.unref();
      child.once("exit", () => {
        if (this.sleepAssertionProcess === child) this.sleepAssertionProcess = null;
      });
      child.once("error", () => {
        if (this.sleepAssertionProcess === child) this.sleepAssertionProcess = null;
      });
      this.sleepAssertionProcess = child;
    } else if (!shouldPrevent && this.sleepAssertionProcess) {
      this.sleepAssertionProcess.kill("SIGTERM");
      this.sleepAssertionProcess = null;
    }
  }

  async waitForPower(signal) {
    let wasPaused = false;
    while (this.powerState.shouldPause) {
      wasPaused = true;
      this.phase = "paused";
      this.updateSleepAssertion(false);
      await new Promise((resolve, reject) => {
        const abort = () => {
          clearTimeout(timer);
          reject(new DOMException("Indexing cancelled", "AbortError"));
        };
        const timer = setTimeout(() => {
          signal.removeEventListener("abort", abort);
          resolve();
        }, this.powerPausePollMs);
        if (signal.aborted) abort();
        else signal.addEventListener("abort", abort, { once: true });
      });
      this.powerState = this.powerStateProvider();
    }
    if (wasPaused) {
      this.embeddingRate = 0;
      this.embeddingStartedAt = Date.now();
      this.publishedEtaSeconds = null;
      this.etaPublishedAt = null;
    }
    this.phase = "embedding";
    this.updateSleepAssertion();
  }

  searchMessages({
    query,
    conversation_id,
    person_ids = [],
    person_match = "any",
    limit = 50,
    since,
    until,
    direction,
  } = {}) {
    if (this.textPhase !== "ready" || !existsSync(this.databasePath)) return null;
    const ftsQuery = tokenizeLiteralFtsQuery(query ?? "");
    if (!ftsQuery) return null;
    const safeLimit = Math.max(1, Math.min(5_000, Number(limit) || 50));
    const parameters = { fts_query: ftsQuery, limit: safeLimit };
    const clauses = ["messages_fts MATCH :fts_query"];
    if (conversation_id) {
      clauses.push("m.conversation_id = :conversation_id");
      parameters.conversation_id = conversation_id;
    }
    if (since) {
      clauses.push("m.sent_at >= :since");
      parameters.since = new Date(since).toISOString();
    }
    if (until) {
      clauses.push("m.sent_at < :until");
      parameters.until = new Date(until).toISOString();
    }
    if (direction) {
      clauses.push("m.direction = :direction");
      parameters.direction = direction;
    }
    const safePeople = [...new Set(person_ids)].slice(0, 25);
    if (safePeople.length) {
      if (person_match === "all") {
        safePeople.forEach((personId, index) => {
          parameters[`person_${index}`] = personId;
          clauses.push(`EXISTS (SELECT 1 FROM json_each(m.person_ids) WHERE value = :person_${index})`);
        });
      } else {
        const placeholders = safePeople.map((personId, index) => {
          parameters[`person_${index}`] = personId;
          return `:person_${index}`;
        });
        clauses.push(`EXISTS (SELECT 1 FROM json_each(m.person_ids) WHERE value IN (${placeholders.join(", ")}))`);
      }
    }
    return this.openDatabase().prepare(`
      SELECT m.*, c.name AS conversation_name
      FROM messages_fts
      JOIN messages m ON m.id = messages_fts.rowid
      JOIN conversations c ON c.conversation_id = m.conversation_id
      WHERE ${clauses.join(" AND ")}
      ORDER BY m.sent_at DESC, m.message_id DESC
      LIMIT :limit
    `).all(parameters).map((row) => ({
      conversation_id: row.conversation_id,
      conversation_name: row.conversation_name,
      message_id: row.message_id,
      sent_at: row.sent_at,
      direction: row.direction,
      sender: safeJson(row.sender_json, { person_id: "unknown", name: "Unknown" }),
      service: row.service,
      text: row.text,
      subject: row.subject,
      is_reply: Boolean(row.is_reply),
      attachments: [],
    }));
  }

  availabilityError() {
    if (!this.enabled) return "Enhanced local search is turned off in Atlas settings";
    if (!this.isModelInstalled()) return "Enhanced local search has not finished downloading";
    if (existsSync(this.databasePath)) {
      try {
        this.indexedDocuments = Number(this.openDatabase()
          .prepare("SELECT COUNT(*) AS count FROM documents").get().count);
      } catch {
        this.indexedDocuments = 0;
      }
    }
    if (!existsSync(this.databasePath) || this.indexedDocuments === 0) {
      return "Enhanced local search is still preparing the message history";
    }
    return null;
  }

  async search({
    query,
    conversation_id,
    person_ids = [],
    person_match = "any",
    limit = 30,
    since,
    until,
    direction,
  } = {}) {
    const unavailable = this.availabilityError();
    if (unavailable) throw new Error(unavailable);
    const safeLimit = Math.max(1, Math.min(200, Number(limit) || 30));
    const database = this.openDatabase();
    const parameters = { candidate_limit: Math.min(800, safeLimit * 5) };
    const clauses = [];
    if (conversation_id) {
      clauses.push("d.conversation_id = :conversation_id");
      parameters.conversation_id = conversation_id;
    }
    if (since) {
      clauses.push("d.end_at >= :since");
      parameters.since = new Date(since).toISOString();
    }
    if (until) {
      clauses.push("d.start_at < :until");
      parameters.until = new Date(until).toISOString();
    }
    if (direction) {
      clauses.push("EXISTS (SELECT 1 FROM json_each(d.directions) WHERE value = :direction)");
      parameters.direction = direction;
    }
    const safePeople = [...new Set(person_ids)].slice(0, 25);
    if (safePeople.length) {
      if (person_match === "all") {
        safePeople.forEach((personId, index) => {
          parameters[`person_${index}`] = personId;
          clauses.push(`EXISTS (SELECT 1 FROM json_each(d.person_ids) WHERE value = :person_${index})`);
        });
      } else {
        const placeholders = safePeople.map((personId, index) => {
          parameters[`person_${index}`] = personId;
          return `:person_${index}`;
        });
        clauses.push(`EXISTS (SELECT 1 FROM json_each(d.person_ids) WHERE value IN (${placeholders.join(", ")}))`);
      }
    }
    const where = clauses.length ? `WHERE ${clauses.join(" AND ")}` : "";
    const embeddedCount = Number(database.prepare(
      "SELECT COUNT(*) AS count FROM documents WHERE embedding IS NOT NULL",
    ).get().count);
    const totalDocumentCount = Number(database.prepare("SELECT COUNT(*) AS count FROM documents").get().count);
    const latestUnembedded = embeddedCount < totalDocumentCount
      ? database.prepare(
        "SELECT MAX(end_at) AS latest_unembedded FROM documents WHERE embedding IS NULL",
      ).get().latest_unembedded
      : null;
    let semantic = [];
    if (embeddedCount > 0) {
      const queryVector = await this.embed(query, { query: true });
      semantic = database.prepare(`
        SELECT d.*, c.name AS conversation_name,
               vec_distance_cosine(d.embedding, :vector) AS distance
        FROM documents d
        JOIN conversations c ON c.conversation_id = d.conversation_id
        ${where ? `${where} AND` : "WHERE"} d.embedding IS NOT NULL
        ORDER BY distance LIMIT :candidate_limit
      `).all({ ...parameters, vector: queryVector });
    }

    const lexicalQuery = tokenizeFtsQuery(query);
    let lexical = [];
    if (lexicalQuery) {
      const lexicalParameters = { ...parameters, fts_query: lexicalQuery };
      lexical = database.prepare(`
        SELECT d.*, c.name AS conversation_name, bm25(documents_fts) AS lexical_score
        FROM documents_fts
        JOIN documents d ON d.id = documents_fts.rowid
        JOIN conversations c ON c.conversation_id = d.conversation_id
        ${where ? `${where} AND` : "WHERE"} documents_fts MATCH :fts_query
        ORDER BY lexical_score
        LIMIT :candidate_limit
      `).all(lexicalParameters);
    }

    const ranked = new Map();
    semantic.forEach((row, rank) => {
      ranked.set(row.id, {
        row,
        score: 1 / (60 + rank + 1),
        semanticSimilarity: 1 - Number(row.distance),
        sources: new Set(["semantic"]),
      });
    });
    lexical.forEach((row, rank) => {
      const existing = ranked.get(row.id) ?? {
        row,
        score: 0,
        semanticSimilarity: 0,
        sources: new Set(),
      };
      existing.score += 1 / (60 + rank + 1);
      existing.sources.add("keyword");
      ranked.set(row.id, existing);
    });
    const results = [...ranked.values()]
      .sort((left, right) => right.score - left.score)
      .slice(0, safeLimit)
      .map((item) => ({
        ...publicDocument(item.row, Math.max(item.semanticSimilarity, item.score * 20)),
        match: item.sources.size === 2 ? "hybrid" : [...item.sources][0],
      }));
    return {
      query,
      indexed_messages: this.indexedMessages,
      embedded_passages: embeddedCount,
      semantic_coverage_percent: totalDocumentCount
        ? Number((embeddedCount * 100 / totalDocumentCount).toFixed(2))
        : 0,
      semantic_fully_covered_after: latestUnembedded,
      text_index_complete: this.phase !== "indexing",
      semantic_index_complete: this.phase === "ready",
      passages: results,
    };
  }

  async close() {
    if (this.timer) clearInterval(this.timer);
    if (this.powerTimer) clearInterval(this.powerTimer);
    this.updateSleepAssertion(false);
    this.abortController?.abort();
    this.downloadAbortController?.abort();
    if (this.job) await this.job.catch(() => {});
    if (this.downloadJob) await this.downloadJob.catch(() => {});
    await this.disposeModel();
    this.database?.close();
    this.database = null;
  }
}

export const semanticSearchDownloadBytes = MODEL_BYTES;
