import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { resolveCodexPath } from "./codex-discovery.js";

function fakeExecutable(path) {
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, "#!/bin/sh\nexit 0\n");
  chmodSync(path, 0o700);
}

test("finds Codex on the user PATH when an explicit path is stale", () => {
  const directory = mkdtempSync(join(tmpdir(), "atlas-codex-path-test-"));
  try {
    const bin = join(directory, "custom-bin");
    const codex = join(bin, "codex");
    fakeExecutable(codex);
    assert.equal(resolveCodexPath({
      environment: { CODEX_CLI_PATH: join(directory, "missing"), PATH: bin },
      homeDirectory: join(directory, "home"),
      nodeExecutable: join(directory, "node-bin", "node"),
    }), codex);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
test("prefers a valid explicit Codex executable", () => {
  const directory = mkdtempSync(join(tmpdir(), "atlas-codex-explicit-test-"));
  try {
    const explicit = join(directory, "explicit", "codex");
    const onPath = join(directory, "path", "codex");
    fakeExecutable(explicit);
    fakeExecutable(onPath);
    assert.equal(resolveCodexPath({
      environment: { CODEX_CLI_PATH: explicit, PATH: join(directory, "path") },
      homeDirectory: join(directory, "home"),
      nodeExecutable: join(directory, "node-bin", "node"),
    }), explicit);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
