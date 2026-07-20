#!/usr/bin/env node
import { DatabaseSync } from "node:sqlite";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { env, AutoTokenizer, pipeline } from "@huggingface/transformers";
import { CoreMLToneClassifier } from "../src/coreml-tone-classifier.js";
import { orderToneUnitsForInference } from "../src/sentiment-index.js";

const unitCount = Number(process.argv[2] ?? 1_000);
const supportDirectory = join(homedir(), "Library", "Application Support", "Atlas");
const database = new DatabaseSync(join(supportDirectory, "SemanticSearch", "search.sqlite"), {
  readOnly: true,
});
const rows = database.prepare(`
  SELECT kind, id, text, end_at FROM (
    SELECT 'turn' AS kind, id, text, end_at FROM sentiment_turns WHERE positive IS NULL
    UNION ALL
    SELECT 'window' AS kind, id, text, end_at FROM sentiment_windows WHERE positive IS NULL
  ) ORDER BY end_at DESC, id DESC LIMIT ?
`).all(unitCount).map((row, originalIndex) => ({ ...row, originalIndex }));
database.close();

const ordered = [];
for (let offset = 0; offset < rows.length; offset += 240) {
  ordered.push(...orderToneUnitsForInference(rows.slice(offset, offset + 240)));
}
const batches = [];
for (let offset = 0; offset < ordered.length; offset += 24) {
  batches.push(ordered.slice(offset, offset + 24));
}

const modelPath = join(supportDirectory, "Sentiment", "model");
env.allowRemoteModels = false;
env.allowLocalModels = true;
const tokenizer = await AutoTokenizer.from_pretrained(modelPath);
tokenizer.model_max_length = 512;
const coreML = new CoreMLToneClassifier({
  tokenizer,
  runnerPath: resolve("bin", "atlas-tone-coreml-runner"),
  modelPath: process.env.COREML_TONE_MODEL_PATH
    ?? join(supportDirectory, "Sentiment", "coreml", "ToneClassifier.mlpackage"),
});
const onnx = await pipeline("text-classification", modelPath, { dtype: "q8" });
onnx.tokenizer.model_max_length = 512;

function sequenceLength(batch) {
  const encoded = tokenizer(batch.map((row) => row.text), {
    padding: true,
    truncation: true,
    max_length: 512,
  });
  const actual = Number(encoded.input_ids.dims[1]);
  return [32, 64, 128, 256, 512].find((value) => value >= actual) ?? 512;
}

const warmups = new Map();
for (const batch of batches) warmups.set(sequenceLength(batch), batch);
const coldStartedAt = performance.now();
for (const batch of warmups.values()) await coreML.classify(batch.map((row) => row.text));
const coreMLColdStartSeconds = (performance.now() - coldStartedAt) / 1_000;
await onnx(batches[0].map((row) => row.text), { top_k: null });

async function benchmark(label, classify) {
  const results = new Map();
  const startedAt = performance.now();
  for (const batch of batches) {
    const output = await classify(batch.map((row) => row.text));
    batch.forEach((row, index) => results.set(row.originalIndex, output[index]));
  }
  const seconds = (performance.now() - startedAt) / 1_000;
  return { label, results, seconds, rate: rows.length / seconds };
}

const coreMLResult = await benchmark("coreml", (texts) => coreML.classify(texts));
const onnxResult = await benchmark("onnx", (texts) => onnx(texts, { top_k: null }));
let agreements = 0;
let probabilityDelta = 0;
let probabilityCount = 0;
let maximumDelta = 0;
for (const [index, coreScores] of coreMLResult.results) {
  const onnxScores = onnxResult.results.get(index);
  const core = Object.fromEntries(coreScores.map((item) => [item.label.toLowerCase(), item.score]));
  const ort = Object.fromEntries(onnxScores.map((item) => [item.label.toLowerCase(), item.score]));
  const coreLabel = Object.entries(core).sort((left, right) => right[1] - left[1])[0][0];
  const onnxLabel = Object.entries(ort).sort((left, right) => right[1] - left[1])[0][0];
  if (coreLabel === onnxLabel) agreements += 1;
  for (const label of ["negative", "neutral", "positive"]) {
    const delta = Math.abs(core[label] - ort[label]);
    probabilityDelta += delta;
    probabilityCount += 1;
    maximumDelta = Math.max(maximumDelta, delta);
  }
}

console.log(JSON.stringify({
  units: rows.length,
  batches: batches.length,
  shapes: [...warmups.keys()].sort((left, right) => left - right),
  coreml_cold_start_seconds: Number(coreMLColdStartSeconds.toFixed(3)),
  coreml_seconds: Number(coreMLResult.seconds.toFixed(3)),
  coreml_units_per_second: Number(coreMLResult.rate.toFixed(2)),
  onnx_seconds: Number(onnxResult.seconds.toFixed(3)),
  onnx_units_per_second: Number(onnxResult.rate.toFixed(2)),
  coreml_speedup: Number((onnxResult.seconds / coreMLResult.seconds).toFixed(2)),
  label_agreement: Number((agreements / rows.length).toFixed(4)),
  mean_absolute_probability_delta: Number((probabilityDelta / probabilityCount).toFixed(6)),
  maximum_probability_delta: Number(maximumDelta.toFixed(6)),
}, null, 2));

await coreML.dispose();
await onnx.dispose?.();
