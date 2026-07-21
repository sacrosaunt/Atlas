import assert from "node:assert/strict";
import test from "node:test";
import { waitForInitialInsightInputs } from "./insight-readiness.js";

test("first insights wait for text and tone but not embeddings", async () => {
  let textPhase = "indexing";
  let tonePhase = "preparing";
  const waiting = waitForInitialInsightInputs({
    semanticIndex: { status: () => ({ text_index_phase: textPhase, phase: "embedding" }) },
    sentimentIndex: { status: () => ({ enabled: true, phase: tonePhase }) },
    pollMs: 2,
  });
  setTimeout(() => { textPhase = "ready"; }, 3);
  setTimeout(() => { tonePhase = "ready"; }, 7);
  assert.deepEqual(await waiting, { text_index_phase: "ready", tone_phase: "ready" });
});

test("first insights proceed after an explicit tone failure", async () => {
  const result = await waitForInitialInsightInputs({
    semanticIndex: { status: () => ({ text_index_phase: "ready", phase: "embedding" }) },
    sentimentIndex: { status: () => ({ enabled: true, phase: "error" }) },
  });
  assert.deepEqual(result, { text_index_phase: "ready", tone_phase: "error" });
});

test("a text-index failure does not leave first insights waiting for tone", async () => {
  const result = await waitForInitialInsightInputs({
    semanticIndex: { status: () => ({ text_index_phase: "error", phase: "off" }) },
    sentimentIndex: { status: () => ({ enabled: true, phase: "waiting_for_index" }) },
  });
  assert.deepEqual(result, { text_index_phase: "error", tone_phase: "waiting_for_index" });
});

test("first insight readiness can be cancelled when Atlas closes", async () => {
  const controller = new AbortController();
  const waiting = waitForInitialInsightInputs({
    semanticIndex: { status: () => ({ text_index_phase: "paused", phase: "paused" }) },
    sentimentIndex: { status: () => ({ enabled: true, phase: "waiting_for_app" }) },
    signal: controller.signal,
    pollMs: 10_000,
  });
  controller.abort();
  await assert.rejects(waiting, { name: "AbortError" });
});
