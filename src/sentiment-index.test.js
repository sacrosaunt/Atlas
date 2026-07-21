import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { SemanticIndex } from "./semantic-index.js";
import {
  buildConversationWindows,
  buildSpeakerTurns,
  orderToneUnitsForInference,
  SentimentIndex,
} from "./sentiment-index.js";

function message({ id, minute, direction, person = "person_a", text }) {
  return {
    conversation_id: "conv_a",
    message_id: id,
    sent_at: `2026-01-01T00:${String(minute).padStart(2, "0")}:00.000Z`,
    direction,
    sender_json: JSON.stringify({ person_id: direction === "from_me" ? "me" : person }),
    subject: null,
    text,
  };
}

test("adjacent bubbles become speaker turns and short alternating windows", () => {
  const messages = [
    message({ id: 1, minute: 0, direction: "from_me", text: "I really" }),
    message({ id: 2, minute: 1, direction: "from_me", text: "appreciate https://example.com" }),
    message({ id: 3, minute: 2, direction: "to_me", text: "Thank you" }),
    message({ id: 4, minute: 3, direction: "from_me", text: "Can we talk?" }),
    message({ id: 5, minute: 4, direction: "to_me", text: "Yes" }),
  ];
  const turns = buildSpeakerTurns(messages);
  assert.equal(turns.length, 4);
  assert.equal(turns[0].message_count, 2);
  assert.equal(turns[0].text, "I really\nappreciate http");
  const windows = buildConversationWindows(turns);
  assert.equal(windows.length, 1);
  assert.equal(windows[0].turn_count, 4);
  assert.deepEqual(JSON.parse(windows[0].directions), ["from_me", "to_me"]);
});

test("tone inference groups similarly sized text while preserving every unit", () => {
  const rows = [
    { id: 1, text: "medium length", end_at: "2026-01-03T00:00:00Z" },
    { id: 2, text: "x", end_at: "2026-01-02T00:00:00Z" },
    { id: 3, text: "the longest text here", end_at: "2026-01-01T00:00:00Z" },
    { id: 4, text: "y", end_at: "2026-01-04T00:00:00Z" },
  ];
  const ordered = orderToneUnitsForInference(rows);
  assert.deepEqual(ordered.map((row) => row.id), [4, 2, 1, 3]);
  assert.deepEqual(ordered.map((row) => row.text.length), [1, 1, 13, 21]);
  assert.deepEqual(rows.map((row) => row.id), [1, 2, 3, 4]);
});

test("tone analysis waits for an Atlas window", async () => {
  const directory = mkdtempSync(join(tmpdir(), "atlas-tone-foreground-test-"));
  const sentiment = new SentimentIndex({
    databaseProvider: () => { throw new Error("database should not be opened"); },
    textIndexReadyProvider: () => false,
    stateDirectory: directory,
    sleepAssertionEnabled: false,
  });
  sentiment.isModelInstalled = () => true;
  try {
    sentiment.start();
    assert.equal(sentiment.status().phase, "waiting_for_app");
    assert.equal(sentiment.status().pause_reason, "app_not_active");
    sentiment.setForegroundActive(true);
    assert.equal(sentiment.status().phase, "waiting_for_index");
    sentiment.setForegroundActive(false);
    assert.equal(sentiment.status().phase, "waiting_for_app");
  } finally {
    await sentiment.close();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("tone analysis stores both measurements and returns scoped aggregates", async () => {
  const directory = mkdtempSync(join(tmpdir(), "atlas-tone-test-"));
  const searchDirectory = join(directory, "search");
  const toneDirectory = join(directory, "tone");
  const sourceMessages = [
    { ...message({ id: 1, minute: 0, direction: "from_me", text: "I really" }), sender: { person_id: "me", name: "You" } },
    { ...message({ id: 2, minute: 1, direction: "from_me", text: "appreciate that" }), sender: { person_id: "me", name: "You" } },
    { ...message({ id: 3, minute: 2, direction: "to_me", text: "Thank you" }), sender: { person_id: "person_a", name: "A Friend" } },
    { ...message({ id: 4, minute: 3, direction: "from_me", text: "Can we talk?" }), sender: { person_id: "me", name: "You" } },
    { ...message({ id: 5, minute: 4, direction: "to_me", text: "Yes, absolutely" }), sender: { person_id: "person_a", name: "A Friend" } },
  ];
  const store = {
    indexableConversations: () => [{
      conversation_id: "conv_a",
      name: "A Friend",
      person_ids: ["person_a"],
      message_count: sourceMessages.length,
    }],
    indexableMessages: ({ after_message_id }) => ({
      messages: sourceMessages.filter((item) => item.message_id > after_message_id),
      scanned_through_message_id: sourceMessages.at(-1).message_id,
      has_more: false,
    }),
  };
  const semantic = new SemanticIndex({
    store,
    stateDirectory: searchDirectory,
    sleepAssertionEnabled: false,
  });
  const classifier = async (texts) => texts.map(() => [
    { label: "negative", score: 0.1 },
    { label: "neutral", score: 0.2 },
    { label: "positive", score: 0.7 },
  ]);
  const sentiment = new SentimentIndex({
    databaseProvider: () => semantic.openDatabase(),
    textIndexReadyProvider: () => true,
    stateDirectory: toneDirectory,
    classifierFactory: async () => classifier,
    powerStateProvider: () => ({ shouldPause: false, onAC: true, verified: true, reason: null }),
    sleepAssertionEnabled: false,
  });
  sentiment.modelVerified = true;
  sentiment.isModelInstalled = () => true;
  semantic.foregroundActive = true;
  sentiment.foregroundActive = true;
  try {
    await semantic.indexMessages(new AbortController().signal);
    await sentiment.analyze(new AbortController().signal);
    const status = sentiment.status();
    assert.equal(status.total_turns, 4);
    assert.equal(status.analyzed_turns, 4);
    assert.equal(status.total_windows, 1);
    assert.equal(status.analyzed_windows, 1);

    const summary = sentiment.summary({ person_ids: ["person_a"], bucket: "month" });
    assert.equal(summary.coverage_percent, 100);
    assert.equal(summary.turn_tone.overall.count, 4);
    assert.equal(summary.window_tone.count, 1);
    assert.equal(summary.turn_tone.overall.average.valence, 0.6);
    assert.equal(summary.timeline[0].period, "2026-01");

    sourceMessages.push({
      ...message({ id: 6, minute: 5, direction: "to_me", text: "I would like that" }),
      sender: { person_id: "person_a", name: "A Friend" },
    });
    await semantic.indexMessages(new AbortController().signal);
    await sentiment.analyze(new AbortController().signal);
    const updated = sentiment.status();
    assert.equal(updated.total_turns, 4);
    assert.equal(updated.analyzed_turns, 4);
    const lastTurn = semantic.openDatabase().prepare(`
      SELECT end_message_id, message_count FROM sentiment_turns
      ORDER BY end_message_id DESC LIMIT 1
    `).get();
    assert.equal(lastTurn.end_message_id, 6);
    assert.equal(lastTurn.message_count, 2);
  } finally {
    await sentiment.close();
    await semantic.close();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("tone ETA stabilizes for 30 seconds and refreshes once per minute", async () => {
  const directory = mkdtempSync(join(tmpdir(), "atlas-tone-eta-test-"));
  const sentiment = new SentimentIndex({
    databaseProvider: () => { throw new Error("database should not be opened"); },
    textIndexReadyProvider: () => false,
    stateDirectory: directory,
    powerStateProvider: () => ({ shouldPause: false, onAC: true, verified: true, reason: null }),
    sleepAssertionEnabled: false,
  });
  try {
    sentiment.phase = "analyzing";
    sentiment.analysisRate = 10;
    sentiment.totalTurns = 1_000;
    sentiment.totalWindows = 0;
    sentiment.analyzedTurns = 100;
    sentiment.analyzedWindows = 0;
    sentiment.analysisStartedAt = Date.now();
    assert.equal(sentiment.currentEtaSeconds(), null);

    sentiment.analysisStartedAt = Date.now() - 31_000;
    assert.equal(sentiment.currentEtaSeconds(), 90);
    sentiment.analysisRate = 20;
    assert.equal(sentiment.currentEtaSeconds(), 90);

    sentiment.etaPublishedAt -= 61_000;
    assert.equal(sentiment.currentEtaSeconds(), 45);
  } finally {
    await sentiment.close();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("tone classifier clamps long inputs to the model token limit", async () => {
  const directory = mkdtempSync(join(tmpdir(), "atlas-tone-token-limit-test-"));
  const classifier = async () => [];
  classifier.tokenizer = { model_max_length: Number.MAX_SAFE_INTEGER };
  const sentiment = new SentimentIndex({
    databaseProvider: () => { throw new Error("database should not be opened"); },
    textIndexReadyProvider: () => false,
    stateDirectory: directory,
    classifierFactory: async () => classifier,
    powerStateProvider: () => ({ shouldPause: false, onAC: true, verified: true, reason: null }),
    sleepAssertionEnabled: false,
  });
  sentiment.modelVerified = true;
  try {
    await sentiment.loadClassifier();
    assert.equal(classifier.tokenizer.model_max_length, 512);
  } finally {
    await sentiment.close();
    rmSync(directory, { recursive: true, force: true });
  }
});
