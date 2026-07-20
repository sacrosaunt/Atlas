#!/usr/bin/env node
import { spawn } from "node:child_process";
import { DatabaseSync } from "node:sqlite";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { env, AutoTokenizer } from "@huggingface/transformers";
import { SemanticIndex } from "../src/semantic-index.js";

const unitCount = Number(process.argv[2] ?? 200);
const supportDirectory = join(homedir(), "Library", "Application Support", "Atlas");
const semanticDirectory = join(supportDirectory, "SemanticSearch");
const database = new DatabaseSync(join(semanticDirectory, "search.sqlite"), { readOnly: true });
const rows = database.prepare(`
  SELECT text FROM documents WHERE embedding IS NULL ORDER BY end_at DESC, id DESC LIMIT ?
`).all(unitCount);
database.close();

function normalize(values) {
  const decoded = Buffer.isBuffer(values)
    ? new Float32Array(values.buffer, values.byteOffset, values.byteLength / Float32Array.BYTES_PER_ELEMENT)
    : values;
  const reduced = Array.from(decoded.slice(0, 384), Number);
  const length = Math.sqrt(reduced.reduce((sum, value) => sum + value * value, 0)) || 1;
  return reduced.map((value) => value / length);
}

function cosine(left, right) {
  return left.reduce((sum, value, index) => sum + value * right[index], 0);
}

function summarize(values) {
  const sorted = [...values].sort((left, right) => left - right);
  const quantile = (fraction) => sorted[Math.floor((sorted.length - 1) * fraction)];
  return {
    mean: values.reduce((sum, value) => sum + value, 0) / values.length,
    p05: quantile(0.05),
    p50: quantile(0.5),
    minimum: sorted[0],
  };
}

class CoreMLEmbedder {
  constructor(modelPath) {
    this.child = spawn(resolve("bin", "atlas-embedding-coreml-benchmark-runner"), [modelPath], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.pending = [];
    this.ready = new Promise((resolveReady, rejectReady) => {
      this.child.once("error", rejectReady);
      const reader = createInterface({ input: this.child.stdout });
      reader.on("line", (line) => {
        const response = JSON.parse(line);
        const request = this.pending.shift();
        if (!request) {
          if (response.error) rejectReady(new Error(response.error));
          else resolveReady();
        } else if (response.error) request.reject(new Error(response.error));
        else request.resolve(response.embedding);
      });
      this.reader = reader;
    });
    this.child.stderr.on("data", () => {});
  }

  async embed(payload) {
    await this.ready;
    return new Promise((resolveRequest, rejectRequest) => {
      this.pending.push({ resolve: resolveRequest, reject: rejectRequest });
      this.child.stdin.write(`${JSON.stringify(payload)}\n`);
    });
  }

  close() {
    this.reader.close();
    this.child.stdin.end();
    this.child.kill("SIGTERM");
  }
}

env.allowRemoteModels = false;
env.allowLocalModels = true;
const tokenizer = await AutoTokenizer.from_pretrained(join(semanticDirectory, "coreml-benchmark", "tokenizer"));
tokenizer.padding_side = "left";
const encodedRows = rows.map((row) => {
  const encoded = tokenizer(row.text, {
    padding: "max_length",
    truncation: true,
    max_length: 512,
  });
  const ids = Array.from(encoded.input_ids.data, Number);
  const mask = Array.from(encoded.attention_mask.data, Number);
  return {
    text: row.text,
    ids,
    mask,
    unpaddedIds: ids.filter((_, index) => mask[index] === 1),
  };
});

const index = new SemanticIndex({ store: {}, stateDirectory: semanticDirectory, sleepAssertionEnabled: false });
await index.loadModel();
const coreML = new CoreMLEmbedder(join(
  semanticDirectory,
  "coreml-benchmark",
  "compiled",
  "b1_s512.mlmodelc",
));
await coreML.embed({ input_ids: encodedRows[0].ids, attention_mask: encodedRows[0].mask });
await index.embed(encodedRows[0].text);

const coreVectors = [];
let startedAt = performance.now();
for (const row of encodedRows) {
  coreVectors.push(normalize(await coreML.embed({ input_ids: row.ids, attention_mask: row.mask })));
}
const coreMLSeconds = (performance.now() - startedAt) / 1_000;

const metalVectors = [];
startedAt = performance.now();
for (let offset = 0; offset < encodedRows.length; offset += 2) {
  metalVectors.push(...(await Promise.all(
    encodedRows.slice(offset, offset + 2).map((row) => index.embed(row.text)),
  )).map(normalize));
}
const metalSeconds = (performance.now() - startedAt) / 1_000;

const correctedMetalVectors = [];
startedAt = performance.now();
for (const row of encodedRows) {
  const embedding = await index.embeddingContexts[0].getEmbeddingFor(row.unpaddedIds);
  correctedMetalVectors.push(normalize(embedding.vector));
}
const correctedMetalSeconds = (performance.now() - startedAt) / 1_000;

console.log(JSON.stringify({
  units: encodedRows.length,
  coreml_seconds: Number(coreMLSeconds.toFixed(3)),
  coreml_units_per_second: Number((encodedRows.length / coreMLSeconds).toFixed(2)),
  metal_seconds: Number(metalSeconds.toFixed(3)),
  metal_units_per_second: Number((encodedRows.length / metalSeconds).toFixed(2)),
  coreml_speedup: Number((metalSeconds / coreMLSeconds).toFixed(2)),
  corrected_metal_seconds: Number(correctedMetalSeconds.toFixed(3)),
  coreml_vs_current_metal_cosine: summarize(coreVectors.map((vector, index) => cosine(vector, metalVectors[index]))),
  coreml_vs_same_tokens_metal_cosine: summarize(coreVectors.map((vector, index) => cosine(vector, correctedMetalVectors[index]))),
  current_vs_same_tokens_metal_cosine: summarize(metalVectors.map((vector, index) => cosine(vector, correctedMetalVectors[index]))),
}, null, 2));

coreML.close();
await index.close();
