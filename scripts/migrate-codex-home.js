import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join, relative } from "node:path";
import { DatabaseSync } from "node:sqlite";
import {
  ATLAS_CODEX_HOME,
  SHARED_CODEX_HOME,
  deleteCodexConversation,
  prepareAtlasCodexHome,
  verifyCodexConversation,
} from "../src/codex-client.js";

const historyPath = join(
  homedir(),
  "Library",
  "Application Support",
  "Atlas",
  "atlas.sqlite",
);
const sourceSessions = join(SHARED_CODEX_HOME, "sessions");
const destinationSessions = join(ATLAS_CODEX_HOME, "sessions");

function walk(directory, visit) {
  if (!existsSync(directory)) return;
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) walk(path, visit);
    else visit(path, entry.name);
  }
}

function rolloutFor(threadId) {
  const matches = [];
  walk(sourceSessions, (path, name) => {
    if (name.includes(threadId) && name.endsWith(".jsonl")) matches.push(path);
  });
  if (matches.length !== 1) {
    throw new Error(`Expected one saved rollout for an Atlas thread; found ${matches.length}`);
  }
  return matches[0];
}

function atlasThreadIds() {
  const db = new DatabaseSync(historyPath, { readOnly: true });
  try {
    const ids = db.prepare(`
      SELECT codex_thread_id FROM chats WHERE codex_thread_id IS NOT NULL
      UNION
      SELECT codex_thread_id FROM insight_snapshots
      WHERE id = 1 AND codex_thread_id IS NOT NULL
    `).all().map((row) => row.codex_thread_id);
    return [...new Set(ids)];
  } finally {
    db.close();
  }
}

prepareAtlasCodexHome();
mkdirSync(destinationSessions, { recursive: true, mode: 0o700 });

const threadIds = atlasThreadIds();
let migrated = 0;
for (const threadId of threadIds) {
  const source = rolloutFor(threadId);
  const destination = join(destinationSessions, relative(sourceSessions, source));
  mkdirSync(dirname(destination), { recursive: true, mode: 0o700 });
  copyFileSync(source, destination);
  chmodSync(destination, 0o600);

  if (!await verifyCodexConversation({ threadId })) {
    throw new Error("Copied Atlas thread could not be resumed; original was not deleted");
  }

  await deleteCodexConversation({
    threadId,
    codexHome: SHARED_CODEX_HOME,
    mcpEnabled: false,
  });

  if (!await verifyCodexConversation({ threadId })) {
    throw new Error("Atlas thread failed verification after source deletion");
  }
  migrated += 1;
}

console.log(JSON.stringify({ discovered: threadIds.length, migrated, originals_deleted: migrated }));
