import assert from "node:assert/strict";
import { mkdtempSync, rmSync, truncateSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { SemanticIndex } from "./semantic-index.js";

const MODEL_BYTES = 639_150_592;

function temporaryIndex(store = {}, options = {}) {
  const directory = mkdtempSync(join(tmpdir(), "atlas-semantic-test-"));
  const index = new SemanticIndex({
    store,
    stateDirectory: directory,
    sleepAssertionEnabled: false,
    powerStateProvider: () => ({
      shouldPause: false,
      onAC: true,
      verified: true,
      reason: null,
    }),
    ...options,
  });
  return {
    directory,
    index,
    installSparsePlaceholder() {
      const path = join(directory, "semantic-search.gguf");
      writeFileSync(path, "", { mode: 0o600 });
      truncateSync(path, MODEL_BYTES);
    },
    async cleanup() {
      await index.close();
      rmSync(directory, { recursive: true, force: true });
    },
  };
}

function testVector() {
  const values = new Float32Array(384);
  values[0] = 1;
  return Buffer.from(values.buffer);
}

test("enhanced search is disabled and does not download by default", async () => {
  const fixture = temporaryIndex();
  try {
    const status = fixture.index.status();
    assert.equal(status.enabled, false);
    assert.equal(status.installed, false);
    assert.equal(status.downloaded_bytes, 0);
    assert.equal(status.total_download_bytes, MODEL_BYTES);
  } finally {
    await fixture.cleanup();
  }
});

test("background indexing creates private chunks that hybrid search can filter", async () => {
  const messages = Array.from({ length: 10 }, (_, index) => ({
    message_id: index + 1,
    sent_at: `2026-01-${String(index + 1).padStart(2, "0")}T00:00:00.000Z`,
    direction: index % 2 ? "to_me" : "from_me",
    sender: index % 2
      ? { person_id: "person_a", name: "A Friend" }
      : { person_id: "me", name: "You" },
    text: `message ${index + 1} about a shared trip`,
    subject: null,
  }));
  const store = {
    indexableConversations: () => [{
      conversation_id: "conv_a",
      name: "A Friend",
      person_ids: ["person_a"],
      message_count: messages.length,
    }],
    indexableMessages: ({ after_message_id }) => {
      const page = messages.filter((message) => message.message_id > after_message_id);
      return {
        messages: page,
        scanned_through_message_id: page.at(-1)?.message_id ?? after_message_id,
        has_more: false,
      };
    },
  };
  const fixture = temporaryIndex(store);
  try {
    fixture.installSparsePlaceholder();
    fixture.index.enabled = true;
    const vector = testVector();
    const embeddedTexts = [];
    const processingOrder = [];
    fixture.index.setPreEmbeddingTask(async () => { processingOrder.push("tone"); });
    fixture.index.embed = async (text) => {
      if (!processingOrder.includes("embedding")) processingOrder.push("embedding");
      embeddedTexts.push(text);
      return vector;
    };
    await fixture.index.indexMessages(new AbortController().signal);

    const status = fixture.index.status();
    assert.equal(status.phase, "ready");
    assert.equal(status.indexed_messages, 10);
    assert.equal(status.indexed_documents, 2);
    assert.deepEqual(processingOrder, ["tone", "embedding"]);
    assert.match(embeddedTexts[0], /message 10/);

    const result = await fixture.index.search({
      query: "trip planning",
      person_ids: ["person_a"],
      direction: "to_me",
    });
    assert.equal(result.passages.length, 2);
    assert.equal(result.passages[0].conversation_id, "conv_a");
    assert.equal("embedding" in result.passages[0], false);
    assert.equal(result.semantic_coverage_percent, 100);
    assert.equal(result.semantic_fully_covered_after, null);

    await fixture.index.disable();
    const literalResults = fixture.index.searchMessages({
      query: "shared trip",
      person_ids: ["person_a"],
      direction: "to_me",
    });
    assert.equal(fixture.index.textPhase, "ready");
    assert.equal(literalResults.length, 5);
    assert.equal(literalResults[0].message_id, 10);
  } finally {
    await fixture.cleanup();
  }
});

test("optimization pauses on battery and resumes when power returns", async () => {
  let onBattery = true;
  const fixture = temporaryIndex({}, {
    powerStateProvider: () => ({
      shouldPause: onBattery,
      reason: onBattery ? "battery" : null,
    }),
    powerPausePollMs: 5,
  });
  try {
    const waiting = fixture.index.waitForPower(new AbortController().signal);
    assert.equal(fixture.index.phase, "paused");
    assert.equal(fixture.index.status().pause_reason, "battery");
    onBattery = false;
    await waiting;
    assert.equal(fixture.index.phase, "embedding");
  } finally {
    await fixture.cleanup();
  }
});

test("ETA is withheld for two minutes and then updates once per minute", async () => {
  const fixture = temporaryIndex();
  try {
    fixture.index.phase = "embedding";
    fixture.index.embeddingRate = 10;
    fixture.index.totalDocuments = 1_000;
    fixture.index.embeddedDocuments = 100;
    fixture.index.embeddingStartedAt = Date.now();
    assert.equal(fixture.index.currentEtaSeconds(), null);

    fixture.index.embeddingStartedAt = Date.now() - 121_000;
    assert.equal(fixture.index.currentEtaSeconds(), 90);
    fixture.index.embeddingRate = 20;
    assert.equal(fixture.index.currentEtaSeconds(), 90);

    fixture.index.etaPublishedAt -= 61_000;
    assert.equal(fixture.index.currentEtaSeconds(), 45);
  } finally {
    await fixture.cleanup();
  }
});
