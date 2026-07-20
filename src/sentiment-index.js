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
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { once } from "node:events";
import { spawn } from "node:child_process";
import { setImmediate as yieldToEventLoop } from "node:timers/promises";
import { readPowerState } from "./semantic-index.js";
import { CoreMLToneClassifier } from "./coreml-tone-classifier.js";

const STATE_DIRECTORY = join(
  homedir(),
  "Library",
  "Application Support",
  "Atlas",
  "Sentiment",
);
const COREML_RUNNER_PATH = join(dirname(fileURLToPath(import.meta.url)), "..", "bin", "atlas-tone-coreml-runner");

const MODEL_REPOSITORY = "Xenova/twitter-roberta-base-sentiment-latest";
const MODEL_REVISION = "f3ec4d0925f90c3ca7ee7814f52d6ee7cf180445";
const SOURCE_MODEL_REVISION = "3216a57f2a0d9c45a2e6c20157c20c49fb4bf9c7";
const ONNX_MODEL_VERSION = `cardiff-twitter-roberta-onnx-int8:${MODEL_REVISION}`;
const COREML_MODEL_VERSION = `cardiff-twitter-roberta-coreml-fp16:${SOURCE_MODEL_REVISION}:safe-mask-v1`;
const MODEL_FILES = Object.freeze([
  {
    path: "onnx/model_quantized.onnx",
    bytes: 125_905_426,
    sha256: "046f7e4cc46b399558fa9b2de966f6b0d42c69e4b01f582bfb4099b01a0bb5d7",
  },
  {
    path: "config.json",
    bytes: 887,
    sha256: "cdf2b36e0066bd9996e3b9fb3f7c095dc656a0e62c6e3a7327d4ff5541e55b51",
  },
  {
    path: "tokenizer.json",
    bytes: 2_108_615,
    sha256: "1e6506713f00e34406a757acb80f9f3233c1c3950857d32bbc41bcd419d5d8b6",
  },
  {
    path: "tokenizer_config.json",
    bytes: 1_243,
    sha256: "09cb41b20740b45cbbb801d5f66d764cb85a7a62204e999d70f897d05f9f8592",
  },
  {
    path: "merges.txt",
    bytes: 456_318,
    sha256: "1ce1664773c50f3e0cc8842619a93edc4624525b728b188a9e0be33b7726adc5",
  },
  {
    path: "vocab.json",
    bytes: 798_293,
    sha256: "ed19656ea1707df69134c4af35c8ceda2cc9860bf2c3495026153a133670ab5e",
  },
  {
    path: "special_tokens_map.json",
    bytes: 958,
    sha256: "f23c8e6099631c233c16d9bf8dab198f610826cdd1b358f270f6d55c1863e857",
  },
]);
const TOTAL_DOWNLOAD_BYTES = MODEL_FILES.reduce((total, file) => total + file.bytes, 0);
const TURN_GAP_MS = 2 * 60 * 1_000;
const MAX_TURN_MESSAGES = 20;
const MAX_TURN_CHARACTERS = 2_000;
const WINDOW_TURNS = 5;
const WINDOW_STRIDE = 4;
const INFERENCE_BATCH_SIZE = 24;
const INFERENCE_FETCH_SIZE = INFERENCE_BATCH_SIZE * 10;
const MODEL_MAX_TOKENS = 512;
const POWER_POLL_MS = 15_000;

function bytesOnDisk(path) {
  try { return statSync(path).size; } catch { return 0; }
}

function safeJson(value, fallback) {
  try { return JSON.parse(value); } catch { return fallback; }
}

function normalizeMessageText(message) {
  return [message.subject, message.text]
    .filter(Boolean)
    .join(" — ")
    .replace(/https?:\/\/\S+|www\.\S+/giu, "http")
    .trim();
}

function messageSpeaker(message) {
  if (message.direction === "from_me") return "me";
  return safeJson(message.sender_json, {}).person_id || "contact";
}

function canJoinTurn(turn, message, text) {
  if (!turn || turn.speaker_key !== messageSpeaker(message)) return false;
  if (turn.message_count >= MAX_TURN_MESSAGES) return false;
  if (turn.text.length + text.length + 1 > MAX_TURN_CHARACTERS) return false;
  const previous = Date.parse(turn.end_at ?? "");
  const current = Date.parse(message.sent_at ?? "");
  return Number.isFinite(previous) && Number.isFinite(current)
    && current >= previous && current - previous <= TURN_GAP_MS;
}

export function buildSpeakerTurns(messages) {
  const turns = [];
  for (const message of messages) {
    const text = normalizeMessageText(message);
    if (!text) continue;
    const current = turns.at(-1);
    if (canJoinTurn(current, message, text)) {
      current.end_message_id = message.message_id;
      current.end_at = message.sent_at;
      current.message_count += 1;
      current.text = `${current.text}\n${text}`;
      continue;
    }
    turns.push({
      conversation_id: message.conversation_id,
      start_message_id: message.message_id,
      end_message_id: message.message_id,
      start_at: message.sent_at,
      end_at: message.sent_at,
      direction: message.direction,
      speaker_key: messageSpeaker(message),
      message_count: 1,
      text: text.slice(0, MAX_TURN_CHARACTERS),
    });
  }
  return turns;
}

export function buildConversationWindows(turns) {
  const windows = [];
  for (let offset = 0; offset < turns.length; offset += WINDOW_STRIDE) {
    const group = turns.slice(offset, offset + WINDOW_TURNS);
    if (group.length < 3 || new Set(group.map((turn) => turn.speaker_key)).size < 2) continue;
    windows.push({
      conversation_id: group[0].conversation_id,
      start_message_id: group[0].start_message_id,
      end_message_id: group.at(-1).end_message_id,
      start_at: group[0].start_at,
      end_at: group.at(-1).end_at,
      turn_count: group.length,
      directions: JSON.stringify([...new Set(group.map((turn) => turn.direction))]),
      text: group.map((turn) => turn.text).join("\n").slice(0, 4_000),
    });
  }
  return windows;
}

export function orderToneUnitsForInference(rows) {
  return [...rows].sort((left, right) => (
    left.text.length - right.text.length
      || String(right.end_at ?? "").localeCompare(String(left.end_at ?? ""))
      || Number(right.id ?? 0) - Number(left.id ?? 0)
  ));
}

function rounded(value) {
  return Number(Number(value ?? 0).toFixed(4));
}

function publicAggregate(row) {
  const count = Number(row?.count ?? 0);
  return {
    count,
    average: {
      negative: rounded(row?.negative),
      neutral: rounded(row?.neutral),
      positive: rounded(row?.positive),
      valence: rounded(row?.valence),
      confidence: rounded(row?.confidence),
    },
    dominant_share: count ? {
      negative: rounded(Number(row.negative_count) / count),
      neutral: rounded(Number(row.neutral_count) / count),
      positive: rounded(Number(row.positive_count) / count),
    } : { negative: 0, neutral: 0, positive: 0 },
  };
}

function aggregateSelect(alias) {
  return `
    COUNT(*) AS count,
    AVG(${alias}.negative) AS negative,
    AVG(${alias}.neutral) AS neutral,
    AVG(${alias}.positive) AS positive,
    AVG(${alias}.valence) AS valence,
    AVG(${alias}.confidence) AS confidence,
    SUM(CASE WHEN ${alias}.negative >= ${alias}.neutral AND ${alias}.negative >= ${alias}.positive THEN 1 ELSE 0 END) AS negative_count,
    SUM(CASE WHEN ${alias}.neutral > ${alias}.negative AND ${alias}.neutral >= ${alias}.positive THEN 1 ELSE 0 END) AS neutral_count,
    SUM(CASE WHEN ${alias}.positive > ${alias}.negative AND ${alias}.positive > ${alias}.neutral THEN 1 ELSE 0 END) AS positive_count
  `;
}

export class SentimentIndex {
  constructor({
    databaseProvider,
    textIndexReadyProvider = () => false,
    stateDirectory = STATE_DIRECTORY,
    classifierFactory,
    powerStateProvider = () => readPowerState({ pauseOnBattery: false }),
    powerPollMs = POWER_POLL_MS,
    sleepAssertionEnabled = true,
    coreMLRunnerPath = COREML_RUNNER_PATH,
    coreMLModelPath,
  } = {}) {
    this.databaseProvider = databaseProvider;
    this.textIndexReadyProvider = textIndexReadyProvider;
    this.stateDirectory = stateDirectory;
    this.modelDirectory = join(stateDirectory, "model");
    this.settingsPath = join(stateDirectory, "settings.json");
    this.markerPath = join(this.modelDirectory, "verified.json");
    mkdirSync(this.modelDirectory, { recursive: true, mode: 0o700 });
    this.enabled = this.readSettings().enabled !== false;
    this.phase = this.enabled ? "starting" : "off";
    this.error = null;
    this.downloadedBytes = this.installedBytes();
    this.downloadJob = null;
    this.downloadAbortController = null;
    this.analysisJob = null;
    this.analysisAbortController = null;
    this.classifier = null;
    this.classifierFactory = classifierFactory;
    this.coreMLRunnerPath = coreMLRunnerPath;
    this.coreMLModelPath = coreMLModelPath ?? join(stateDirectory, "coreml", "ToneClassifier.mlpackage");
    this.inferenceBackend = null;
    this.modelVerified = false;
    this.totalTurns = 0;
    this.analyzedTurns = 0;
    this.totalWindows = 0;
    this.analyzedWindows = 0;
    this.analysisRate = 0;
    this.analysisStartedAt = null;
    this.publishedEtaSeconds = null;
    this.etaPublishedAt = null;
    this.powerStateProvider = powerStateProvider;
    this.powerState = powerStateProvider();
    this.powerPollMs = powerPollMs;
    this.sleepAssertionEnabled = sleepAssertionEnabled;
    this.sleepAssertionProcess = null;
  }

  readSettings() {
    try { return safeJson(readFileSync(this.settingsPath, "utf8"), { enabled: true }); }
    catch { return { enabled: true }; }
  }

  writeSettings() {
    const temporaryPath = `${this.settingsPath}.tmp`;
    writeFileSync(temporaryPath, `${JSON.stringify({ enabled: this.enabled }, null, 2)}\n`, {
      mode: 0o600,
    });
    renameSync(temporaryPath, this.settingsPath);
  }

  modelPath(file) {
    return join(this.modelDirectory, file.path);
  }

  installedBytes() {
    return MODEL_FILES.reduce((total, file) => total + Math.min(file.bytes, bytesOnDisk(this.modelPath(file))), 0);
  }

  isModelInstalled() {
    if (!existsSync(this.markerPath)) return false;
    const marker = safeJson(readFileSync(this.markerPath, "utf8"), {});
    return marker.revision === MODEL_REVISION
      && MODEL_FILES.every((file) => bytesOnDisk(this.modelPath(file)) === file.bytes);
  }

  start() {
    if (!this.enabled) return;
    if (!this.isModelInstalled()) {
      this.phase = "not_downloaded";
    } else if (this.textIndexReadyProvider()) {
      this.startAnalysis();
    } else {
      this.phase = "waiting_for_index";
    }
  }

  status() {
    if (this.textIndexReadyProvider()) this.refreshCounts();
    return {
      enabled: this.enabled,
      installed: this.isModelInstalled(),
      phase: this.phase,
      pause_reason: this.phase === "paused" ? this.powerState.reason : null,
      preventing_sleep: Boolean(this.sleepAssertionProcess),
      downloaded_bytes: this.phase === "downloading" ? this.downloadedBytes : this.installedBytes(),
      total_download_bytes: TOTAL_DOWNLOAD_BYTES,
      analyzed_turns: this.analyzedTurns,
      total_turns: this.totalTurns,
      analyzed_windows: this.analyzedWindows,
      total_windows: this.totalWindows,
      eta_seconds: this.currentEtaSeconds(),
      inference_backend: this.inferenceBackend,
      model_revision: MODEL_REVISION,
      error: this.error,
    };
  }

  refreshCounts() {
    try {
      const database = this.databaseProvider();
      this.ensureSchema(database);
      this.totalTurns = Number(database.prepare("SELECT COUNT(*) AS count FROM sentiment_turns").get().count);
      this.analyzedTurns = Number(database.prepare(
        "SELECT COUNT(*) AS count FROM sentiment_turns WHERE positive IS NOT NULL",
      ).get().count);
      this.totalWindows = Number(database.prepare("SELECT COUNT(*) AS count FROM sentiment_windows").get().count);
      this.analyzedWindows = Number(database.prepare(
        "SELECT COUNT(*) AS count FROM sentiment_windows WHERE positive IS NOT NULL",
      ).get().count);
    } catch {
      // The sidecar may not exist until Messages permission is granted.
    }
  }

  async enable() {
    this.enabled = true;
    this.error = null;
    this.writeSettings();
    if (this.isModelInstalled()) this.start();
    else this.startDownload();
    return this.status();
  }

  async disable() {
    this.enabled = false;
    this.writeSettings();
    this.downloadAbortController?.abort();
    this.analysisAbortController?.abort();
    this.phase = "off";
    this.updateSleepAssertion(false);
    await this.disposeClassifier();
    return this.status();
  }

  async onTextIndexReady() {
    if (!this.enabled) return;
    if (this.downloadJob) await this.downloadJob.catch(() => {});
    if (!this.isModelInstalled()) return;
    return this.startAnalysis();
  }

  startDownload() {
    if (this.downloadJob) return this.downloadJob;
    this.downloadAbortController = new AbortController();
    this.phase = "downloading";
    this.error = null;
    this.downloadJob = this.downloadModel(this.downloadAbortController.signal)
      .then(() => {
        if (!this.enabled) this.phase = "off";
        else if (this.textIndexReadyProvider()) return this.startAnalysis();
        else this.phase = "waiting_for_index";
        return undefined;
      })
      .catch((error) => this.handleError(error))
      .finally(() => {
        this.downloadJob = null;
        this.downloadAbortController = null;
      });
    return this.downloadJob;
  }

  async downloadModel(signal) {
    rmSync(this.markerPath, { force: true });
    this.downloadedBytes = 0;
    for (const file of MODEL_FILES) {
      const destination = this.modelPath(file);
      const partial = `${destination}.part`;
      mkdirSync(dirname(destination), { recursive: true, mode: 0o700 });
      rmSync(partial, { force: true });
      const url = `https://huggingface.co/${MODEL_REPOSITORY}/resolve/${MODEL_REVISION}/${file.path}`;
      const response = await fetch(url, { signal, redirect: "follow" });
      if (!response.ok || !response.body) throw new Error(`Tone model download failed with HTTP ${response.status}`);
      const output = createWriteStream(partial, { flags: "wx", mode: 0o600 });
      const hash = createHash("sha256");
      let fileBytes = 0;
      try {
        for await (const chunk of response.body) {
          if (signal.aborted) throw new DOMException("Download cancelled", "AbortError");
          const buffer = Buffer.from(chunk);
          hash.update(buffer);
          if (!output.write(buffer)) await once(output, "drain");
          fileBytes += buffer.length;
          this.downloadedBytes += buffer.length;
        }
        output.end();
        await once(output, "close");
      } catch (error) {
        output.destroy();
        rmSync(partial, { force: true });
        throw error;
      }
      if (fileBytes !== file.bytes || hash.digest("hex") !== file.sha256) {
        rmSync(partial, { force: true });
        throw new Error("The downloaded tone model could not be verified");
      }
      renameSync(partial, destination);
    }
    writeFileSync(join(this.modelDirectory, "NOTICE.txt"), [
      "Twitter-roBERTa-base for Sentiment Analysis (latest)",
      "Original model: cardiffnlp/twitter-roberta-base-sentiment-latest",
      "ONNX conversion: Xenova/twitter-roberta-base-sentiment-latest",
      `Pinned conversion revision: ${MODEL_REVISION}`,
      "Upstream license: CC-BY-4.0",
      "https://huggingface.co/cardiffnlp/twitter-roberta-base-sentiment-latest",
      "",
    ].join("\n"), { mode: 0o600 });
    writeFileSync(this.markerPath, `${JSON.stringify({
      repository: MODEL_REPOSITORY,
      revision: MODEL_REVISION,
      files: MODEL_FILES,
      verified_at: new Date().toISOString(),
    }, null, 2)}\n`, { mode: 0o600 });
    this.modelVerified = true;
  }

  handleError(error) {
    this.updateSleepAssertion(false);
    if (error?.name === "AbortError") {
      this.phase = this.enabled ? "waiting_for_index" : "off";
      return;
    }
    this.phase = "error";
    this.error = error instanceof Error ? error.message : String(error);
    console.error("Local tone analysis failed", error);
  }

  ensureSchema(database) {
    database.exec(`
      CREATE TABLE IF NOT EXISTS sentiment_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS sentiment_conversations (
        conversation_id TEXT PRIMARY KEY,
        last_message_id INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS sentiment_turns (
        id INTEGER PRIMARY KEY,
        conversation_id TEXT NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,
        start_message_id INTEGER NOT NULL,
        end_message_id INTEGER NOT NULL,
        start_at TEXT,
        end_at TEXT,
        direction TEXT NOT NULL,
        speaker_key TEXT NOT NULL,
        message_count INTEGER NOT NULL,
        text TEXT NOT NULL,
        negative REAL,
        neutral REAL,
        positive REAL,
        valence REAL,
        confidence REAL,
        UNIQUE(conversation_id, start_message_id, end_message_id)
      );
      CREATE INDEX IF NOT EXISTS sentiment_turns_dates ON sentiment_turns(start_at, end_at);
      CREATE INDEX IF NOT EXISTS sentiment_turns_conversation ON sentiment_turns(conversation_id, start_message_id);
      CREATE INDEX IF NOT EXISTS sentiment_turns_pending ON sentiment_turns(end_at DESC, id DESC)
        WHERE positive IS NULL;
      CREATE TABLE IF NOT EXISTS sentiment_windows (
        id INTEGER PRIMARY KEY,
        conversation_id TEXT NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,
        start_message_id INTEGER NOT NULL,
        end_message_id INTEGER NOT NULL,
        start_at TEXT,
        end_at TEXT,
        turn_count INTEGER NOT NULL,
        directions TEXT NOT NULL,
        text TEXT NOT NULL,
        negative REAL,
        neutral REAL,
        positive REAL,
        valence REAL,
        confidence REAL,
        UNIQUE(conversation_id, start_message_id, end_message_id)
      );
      CREATE INDEX IF NOT EXISTS sentiment_windows_dates ON sentiment_windows(start_at, end_at);
      CREATE INDEX IF NOT EXISTS sentiment_windows_pending ON sentiment_windows(end_at DESC, id DESC)
        WHERE positive IS NULL;
    `);
    const storedVersion = database.prepare(
      "SELECT value FROM sentiment_metadata WHERE key = 'model_version'",
    ).get()?.value;
    const modelVersion = CoreMLToneClassifier.available({
      runnerPath: this.coreMLRunnerPath,
      modelPath: this.coreMLModelPath,
    }) ? COREML_MODEL_VERSION : ONNX_MODEL_VERSION;
    if (storedVersion && storedVersion !== modelVersion) {
      database.exec(`
        DELETE FROM sentiment_windows;
        DELETE FROM sentiment_turns;
        DELETE FROM sentiment_conversations;
      `);
    }
    database.prepare(
      "INSERT OR REPLACE INTO sentiment_metadata(key, value) VALUES ('model_version', ?)",
    ).run(modelVersion);
  }

  materializeUnits(database) {
    this.ensureSchema(database);
    const conversations = database.prepare(
      "SELECT conversation_id, last_message_id FROM conversations ORDER BY conversation_id",
    ).all();
    const storedConversation = database.prepare(
      "SELECT last_message_id FROM sentiment_conversations WHERE conversation_id = ?",
    );
    const latestTurn = database.prepare(`
      SELECT start_message_id FROM sentiment_turns
      WHERE conversation_id = ? ORDER BY end_message_id DESC LIMIT 1
    `);
    const deleteTurns = database.prepare(`
      DELETE FROM sentiment_turns WHERE conversation_id = ? AND start_message_id >= ?
    `);
    const deleteWindows = database.prepare(`
      DELETE FROM sentiment_windows WHERE conversation_id = ? AND end_message_id >= ?
    `);
    const messagesAfter = database.prepare(`
      SELECT conversation_id, message_id, sent_at, direction, sender_json, subject, text
      FROM messages WHERE conversation_id = ? AND message_id >= ?
      ORDER BY message_id
    `);
    const allTurns = database.prepare(`
      SELECT conversation_id, start_message_id, end_message_id, start_at, end_at,
             direction, speaker_key, message_count, text
      FROM sentiment_turns WHERE conversation_id = ? ORDER BY start_message_id
    `);
    const insertTurn = database.prepare(`
      INSERT OR IGNORE INTO sentiment_turns(
        conversation_id, start_message_id, end_message_id, start_at, end_at,
        direction, speaker_key, message_count, text
      ) VALUES (
        :conversation_id, :start_message_id, :end_message_id, :start_at, :end_at,
        :direction, :speaker_key, :message_count, :text
      )
    `);
    const insertWindow = database.prepare(`
      INSERT OR IGNORE INTO sentiment_windows(
        conversation_id, start_message_id, end_message_id, start_at, end_at,
        turn_count, directions, text
      ) VALUES (
        :conversation_id, :start_message_id, :end_message_id, :start_at, :end_at,
        :turn_count, :directions, :text
      )
    `);
    const saveConversation = database.prepare(`
      INSERT INTO sentiment_conversations(conversation_id, last_message_id) VALUES (?, ?)
      ON CONFLICT(conversation_id) DO UPDATE SET last_message_id = excluded.last_message_id
    `);

    for (const conversation of conversations) {
      const indexedThrough = Number(conversation.last_message_id ?? 0);
      const analyzedThrough = Number(storedConversation.get(conversation.conversation_id)?.last_message_id ?? 0);
      if (analyzedThrough >= indexedThrough) continue;
      const overlap = latestTurn.get(conversation.conversation_id)?.start_message_id ?? 0;
      database.exec("BEGIN IMMEDIATE");
      try {
        if (overlap > 0) {
          deleteTurns.run(conversation.conversation_id, overlap);
          deleteWindows.run(conversation.conversation_id, overlap);
        }
        const messages = messagesAfter.all(conversation.conversation_id, overlap);
        for (const turn of buildSpeakerTurns(messages)) insertTurn.run(turn);
        for (const window of buildConversationWindows(allTurns.all(conversation.conversation_id))) {
          insertWindow.run(window);
        }
        saveConversation.run(conversation.conversation_id, indexedThrough);
        database.exec("COMMIT");
      } catch (error) {
        database.exec("ROLLBACK");
        throw error;
      }
    }
    this.refreshCounts();
  }

  async verifyModel() {
    if (this.modelVerified) return;
    for (const file of MODEL_FILES) {
      const hash = createHash("sha256");
      for await (const chunk of createReadStream(this.modelPath(file))) hash.update(chunk);
      if (hash.digest("hex") !== file.sha256) throw new Error("The local tone model could not be verified");
    }
    this.modelVerified = true;
  }

  async loadClassifier() {
    if (this.classifier) return this.classifier;
    await this.verifyModel();
    if (this.classifierFactory) {
      this.classifier = await this.classifierFactory(this.modelDirectory);
      if (this.classifier.tokenizer) {
        this.classifier.tokenizer.model_max_length = MODEL_MAX_TOKENS;
      }
      this.inferenceBackend = "test";
      return this.classifier;
    }
    const { env, AutoTokenizer, pipeline } = await import("@huggingface/transformers");
    env.allowRemoteModels = false;
    env.allowLocalModels = true;
    if (CoreMLToneClassifier.available({
      runnerPath: this.coreMLRunnerPath,
      modelPath: this.coreMLModelPath,
    })) {
      const tokenizer = await AutoTokenizer.from_pretrained(this.modelDirectory);
      tokenizer.model_max_length = MODEL_MAX_TOKENS;
      this.classifier = new CoreMLToneClassifier({
        tokenizer,
        runnerPath: this.coreMLRunnerPath,
        modelPath: this.coreMLModelPath,
      });
      this.inferenceBackend = "coreml";
      return this.classifier;
    }
    this.classifier = await pipeline("text-classification", this.modelDirectory, { dtype: "q8" });
    // This conversion ships with an effectively unlimited tokenizer default even
    // though RoBERTa's position embeddings support 512 input tokens. Pinning the
    // tokenizer boundary prevents long conversation windows from reaching ONNX
    // with an invalid tensor shape.
    this.classifier.tokenizer.model_max_length = MODEL_MAX_TOKENS;
    this.inferenceBackend = "onnx";
    return this.classifier;
  }

  async disposeClassifier() {
    await this.classifier?.dispose?.();
    this.classifier = null;
    this.inferenceBackend = null;
  }

  startAnalysis() {
    if (this.analysisJob) return this.analysisJob;
    if (!this.enabled || !this.isModelInstalled() || !this.textIndexReadyProvider()) return undefined;
    this.analysisAbortController = new AbortController();
    this.analysisJob = this.analyze(this.analysisAbortController.signal)
      .catch((error) => this.handleError(error))
      .finally(async () => {
        await this.disposeClassifier();
        this.analysisJob = null;
        this.analysisAbortController = null;
      });
    return this.analysisJob;
  }

  async classifyBatch(texts) {
    const classifier = await this.loadClassifier();
    let raw;
    try {
      raw = classifier instanceof CoreMLToneClassifier
        ? await classifier.classify(texts)
        : await classifier(texts, { top_k: null });
    } catch (error) {
      if (!(classifier instanceof CoreMLToneClassifier)) throw error;
      throw new Error(`Core ML tone inference failed: ${error.message}`, { cause: error });
    }
    const groups = texts.length === 1 && Array.isArray(raw) && !Array.isArray(raw[0])
      ? [raw]
      : raw;
    return groups.map((scores) => {
      const values = Object.fromEntries(scores.map((item) => [String(item.label).toLowerCase(), Number(item.score)]));
      if (![values.negative, values.neutral, values.positive].every(Number.isFinite)) {
        throw new Error("The tone model returned an unexpected label set");
      }
      return {
        negative: values.negative,
        neutral: values.neutral,
        positive: values.positive,
        valence: values.positive - values.negative,
        confidence: Math.max(values.negative, values.neutral, values.positive),
      };
    });
  }

  async analyze(signal) {
    this.phase = "preparing";
    this.error = null;
    const database = this.databaseProvider();
    this.materializeUnits(database);
    const nextUnits = database.prepare(`
      SELECT kind, id, text FROM (
        SELECT 'turn' AS kind, id, text, end_at FROM sentiment_turns WHERE positive IS NULL
        UNION ALL
        SELECT 'window' AS kind, id, text, end_at FROM sentiment_windows WHERE positive IS NULL
      ) ORDER BY end_at DESC, id DESC LIMIT ${INFERENCE_FETCH_SIZE}
    `);
    const updateTurn = database.prepare(`
      UPDATE sentiment_turns SET negative = :negative, neutral = :neutral,
        positive = :positive, valence = :valence, confidence = :confidence WHERE id = :id
    `);
    const updateWindow = database.prepare(`
      UPDATE sentiment_windows SET negative = :negative, neutral = :neutral,
        positive = :positive, valence = :valence, confidence = :confidence WHERE id = :id
    `);
    this.phase = "analyzing";
    this.analysisRate = 0;
    this.analysisStartedAt = Date.now();
    this.publishedEtaSeconds = null;
    this.etaPublishedAt = null;
    this.updateSleepAssertion();
    while (true) {
      if (signal.aborted || !this.enabled) throw new DOMException("Tone analysis cancelled", "AbortError");
      await this.waitForPower(signal);
      const pendingRows = nextUnits.all();
      if (!pendingRows.length) break;
      const orderedRows = orderToneUnitsForInference(pendingRows);
      for (let offset = 0; offset < orderedRows.length; offset += INFERENCE_BATCH_SIZE) {
        if (signal.aborted || !this.enabled) throw new DOMException("Tone analysis cancelled", "AbortError");
        await this.waitForPower(signal);
        const rows = orderedRows.slice(offset, offset + INFERENCE_BATCH_SIZE);
        const batchStartedAt = performance.now();
        const results = await this.classifyBatch(rows.map((row) => row.text));
        database.exec("BEGIN IMMEDIATE");
        try {
          rows.forEach((row, index) => {
            const values = { id: row.id, ...results[index] };
            if (row.kind === "turn") updateTurn.run(values);
            else updateWindow.run(values);
          });
          database.exec("COMMIT");
        } catch (error) {
          database.exec("ROLLBACK");
          throw error;
        }
        this.analyzedTurns += rows.filter((row) => row.kind === "turn").length;
        this.analyzedWindows += rows.filter((row) => row.kind === "window").length;
        const elapsedSeconds = Math.max(0.001, (performance.now() - batchStartedAt) / 1_000);
        const instantaneousRate = rows.length / elapsedSeconds;
        this.analysisRate = this.analysisRate > 0
          ? this.analysisRate * 0.85 + instantaneousRate * 0.15
          : instantaneousRate;
        await yieldToEventLoop();
      }
    }
    this.phase = "ready";
    this.updateSleepAssertion(false);
    this.refreshCounts();
  }

  currentEtaSeconds() {
    if (this.phase !== "analyzing"
      || this.analysisRate <= 0
      || !this.analysisStartedAt
      || Date.now() - this.analysisStartedAt < 30_000) {
      return null;
    }
    const now = Date.now();
    if (this.publishedEtaSeconds === null
      || this.etaPublishedAt === null
      || now - this.etaPublishedAt >= 60_000) {
      const remaining = (this.totalTurns + this.totalWindows)
        - (this.analyzedTurns + this.analyzedWindows);
      this.publishedEtaSeconds = Math.max(0, Math.ceil(remaining / this.analysisRate));
      this.etaPublishedAt = now;
    }
    return this.publishedEtaSeconds;
  }

  updateSleepAssertion(shouldPrevent = (
    this.phase === "analyzing"
      && this.powerState.verified
      && this.powerState.onAC
      && !this.powerState.shouldPause
  )) {
    if (!this.sleepAssertionEnabled) shouldPrevent = false;
    if (shouldPrevent && !this.sleepAssertionProcess) {
      const child = spawn("/usr/bin/caffeinate", ["-i", "-w", String(process.pid)], { stdio: "ignore" });
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
    let paused = false;
    this.powerState = this.powerStateProvider();
    while (this.powerState.shouldPause) {
      paused = true;
      this.phase = "paused";
      this.updateSleepAssertion(false);
      await new Promise((resolve, reject) => {
        const abort = () => {
          clearTimeout(timer);
          reject(new DOMException("Tone analysis cancelled", "AbortError"));
        };
        const timer = setTimeout(() => {
          signal.removeEventListener("abort", abort);
          resolve();
        }, this.powerPollMs);
        if (signal.aborted) abort();
        else signal.addEventListener("abort", abort, { once: true });
      });
      this.powerState = this.powerStateProvider();
    }
    if (paused) {
      this.phase = "analyzing";
      this.analysisRate = 0;
      this.analysisStartedAt = Date.now();
      this.publishedEtaSeconds = null;
      this.etaPublishedAt = null;
    }
    this.updateSleepAssertion();
  }

  summary({
    conversation_id,
    person_ids = [],
    person_match = "any",
    since,
    until,
    bucket = "month",
  } = {}) {
    const database = this.databaseProvider();
    this.ensureSchema(database);
    const parameters = {};
    const clauses = ["t.positive IS NOT NULL"];
    const windowClauses = ["w.positive IS NOT NULL"];
    if (conversation_id) {
      clauses.push("t.conversation_id = :conversation_id");
      windowClauses.push("w.conversation_id = :conversation_id");
      parameters.conversation_id = conversation_id;
    }
    if (since) {
      parameters.since = new Date(since).toISOString();
      clauses.push("t.start_at >= :since");
      windowClauses.push("w.start_at >= :since");
    }
    if (until) {
      parameters.until = new Date(until).toISOString();
      clauses.push("t.start_at < :until");
      windowClauses.push("w.start_at < :until");
    }
    const safePeople = [...new Set(person_ids)].slice(0, 25);
    if (safePeople.length) {
      if (person_match === "all") {
        safePeople.forEach((personId, index) => {
          parameters[`person_${index}`] = personId;
          const predicate = `EXISTS (SELECT 1 FROM json_each(c.person_ids) WHERE value = :person_${index})`;
          clauses.push(predicate);
          windowClauses.push(predicate);
        });
      } else {
        const placeholders = safePeople.map((personId, index) => {
          parameters[`person_${index}`] = personId;
          return `:person_${index}`;
        });
        const predicate = `EXISTS (SELECT 1 FROM json_each(c.person_ids) WHERE value IN (${placeholders.join(", ")}))`;
        clauses.push(predicate);
        windowClauses.push(predicate);
      }
    }
    const turns = database.prepare(`
      SELECT ${aggregateSelect("t")} FROM sentiment_turns t
      JOIN conversations c ON c.conversation_id = t.conversation_id
      WHERE ${clauses.join(" AND ")}
    `).get(parameters);
    const byDirection = database.prepare(`
      SELECT t.direction, ${aggregateSelect("t")} FROM sentiment_turns t
      JOIN conversations c ON c.conversation_id = t.conversation_id
      WHERE ${clauses.join(" AND ")} GROUP BY t.direction
    `).all(parameters);
    const windows = database.prepare(`
      SELECT ${aggregateSelect("w")} FROM sentiment_windows w
      JOIN conversations c ON c.conversation_id = w.conversation_id
      WHERE ${windowClauses.join(" AND ")}
    `).get(parameters);
    const bucketExpression = bucket === "year"
      ? "substr(t.start_at, 1, 4)"
      : bucket === "quarter"
        ? "substr(t.start_at, 1, 4) || '-Q' || CAST(((CAST(substr(t.start_at, 6, 2) AS INTEGER) - 1) / 3 + 1) AS INTEGER)"
        : "substr(t.start_at, 1, 7)";
    const timeline = database.prepare(`
      SELECT * FROM (
        SELECT ${bucketExpression} AS period, ${aggregateSelect("t")}
        FROM sentiment_turns t
        JOIN conversations c ON c.conversation_id = t.conversation_id
        WHERE ${clauses.join(" AND ")}
        GROUP BY period ORDER BY period DESC LIMIT 120
      ) ORDER BY period
    `).all(parameters).map((row) => ({ period: row.period, ...publicAggregate(row) }));
    this.refreshCounts();
    const analyzed = this.analyzedTurns + this.analyzedWindows;
    const total = this.totalTurns + this.totalWindows;
    return {
      status: this.phase,
      model: "local three-way sentiment classifier",
      measurement_notes: [
        "Turn tone measures coherent same-speaker utterances assembled from adjacent message bubbles.",
        "Window tone measures the atmosphere across short multi-speaker exchanges and is not attributed to one person.",
        "Sentiment is evidence about textual tone, not a reliable measure of emotion, intent, sarcasm, or personality.",
      ],
      coverage_percent: total ? rounded(analyzed * 100 / total) : 0,
      turn_tone: {
        overall: publicAggregate(turns),
        by_direction: Object.fromEntries(byDirection.map((row) => [row.direction, publicAggregate(row)])),
      },
      window_tone: publicAggregate(windows),
      timeline,
    };
  }

  async close() {
    this.downloadAbortController?.abort();
    this.analysisAbortController?.abort();
    this.updateSleepAssertion(false);
    if (this.downloadJob) await this.downloadJob.catch(() => {});
    if (this.analysisJob) await this.analysisJob.catch(() => {});
    await this.disposeClassifier();
  }
}

export const sentimentDownloadBytes = TOTAL_DOWNLOAD_BYTES;
export const sentimentModelRevision = MODEL_REVISION;
