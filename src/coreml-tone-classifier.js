import { existsSync } from "node:fs";
import { createInterface } from "node:readline";
import { spawn } from "node:child_process";

const BATCH_SIZE = 24;
const SEQUENCE_LENGTHS = Object.freeze([32, 64, 128, 256, 512]);

function softmax(values) {
  const maximum = Math.max(...values);
  const exponentials = values.map((value) => Math.exp(value - maximum));
  const total = exponentials.reduce((sum, value) => sum + value, 0);
  return exponentials.map((value) => value / total);
}

export class CoreMLToneClassifier {
  constructor({ tokenizer, runnerPath, modelPath }) {
    this.tokenizer = tokenizer;
    this.runnerPath = runnerPath;
    this.modelPath = modelPath;
    this.child = null;
    this.reader = null;
    this.pending = [];
    this.readyPromise = null;
  }

  static available({ runnerPath, modelPath }) {
    return existsSync(runnerPath) && existsSync(modelPath);
  }

  async start() {
    if (this.readyPromise) return this.readyPromise;
    this.readyPromise = new Promise((resolve, reject) => {
      const child = spawn(this.runnerPath, [this.modelPath], { stdio: ["pipe", "pipe", "pipe"] });
      this.child = child;
      this.reader = createInterface({ input: child.stdout });
      const fail = (error) => {
        const pending = this.pending.splice(0);
        pending.forEach(({ reject: rejectRequest }) => rejectRequest(error));
        reject(error);
      };
      child.once("error", fail);
      child.once("exit", (code, signal) => {
        this.child = null;
        const error = new Error(`Core ML tone runner stopped (${signal ?? code ?? "unknown"})`);
        this.pending.splice(0).forEach(({ reject: rejectRequest }) => rejectRequest(error));
      });
      child.stderr.on("data", () => {});
      this.reader.on("line", (line) => {
        let response;
        try { response = JSON.parse(line); } catch { return; }
        const request = this.pending.shift();
        if (!request) {
          if (response.error) reject(new Error(response.error));
          else resolve();
          return;
        }
        if (response.error) request.reject(new Error(response.error));
        else request.resolve(response);
      });
    });
    return this.readyPromise;
  }

  request(payload) {
    return new Promise((resolve, reject) => {
      this.pending.push({ resolve, reject });
      this.child.stdin.write(`${JSON.stringify(payload)}\n`, (error) => {
        if (!error) return;
        const index = this.pending.findIndex((entry) => entry.resolve === resolve);
        if (index >= 0) this.pending.splice(index, 1);
        reject(error);
      });
    });
  }

  async classify(texts) {
    await this.start();
    const probe = this.tokenizer(texts, { padding: true, truncation: true, max_length: 512 });
    const tokenLength = Number(probe.input_ids.dims[1]);
    const sequenceLength = SEQUENCE_LENGTHS.find((value) => value >= tokenLength) ?? 512;
    const paddedTexts = [...texts, ...Array(BATCH_SIZE - texts.length).fill("")];
    const encoded = this.tokenizer(paddedTexts, {
      padding: "max_length",
      truncation: true,
      max_length: sequenceLength,
    });
    const response = await this.request({
      sequence_length: sequenceLength,
      batch_count: texts.length,
      input_ids: Array.from(encoded.input_ids.data, Number),
      attention_mask: Array.from(encoded.attention_mask.data, Number),
    });
    const groups = [];
    for (let index = 0; index < texts.length; index += 1) {
      const probabilities = softmax(response.logits.slice(index * 3, index * 3 + 3));
      groups.push([
        { label: "negative", score: probabilities[0] },
        { label: "neutral", score: probabilities[1] },
        { label: "positive", score: probabilities[2] },
      ]);
    }
    return groups;
  }

  async dispose() {
    this.reader?.close();
    this.reader = null;
    if (this.child) {
      this.child.stdin.end();
      this.child.kill("SIGTERM");
      this.child = null;
    }
    this.readyPromise = null;
  }
}
