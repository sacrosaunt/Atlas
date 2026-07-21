import { accessSync, constants, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, dirname, join } from "node:path";

function executable(path) {
  if (!path) return false;
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function nvmCandidates(homeDirectory) {
  const root = join(homeDirectory, ".nvm", "versions", "node");
  try {
    return readdirSync(root, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort((left, right) => right.localeCompare(left, undefined, { numeric: true }))
      .map((version) => join(root, version, "bin", "codex"));
  } catch {
    return [];
  }
}

export function resolveCodexPath({
  environment = process.env,
  homeDirectory = homedir(),
  nodeExecutable = process.execPath,
} = {}) {
  const pathDirectories = String(environment.PATH ?? "")
    .split(delimiter)
    .map((path) => path.trim())
    .filter(Boolean);
  const candidates = [
    environment.CODEX_CLI_PATH,
    join(dirname(nodeExecutable), "codex"),
    ...pathDirectories.map((path) => join(path, "codex")),
    environment.npm_config_prefix ? join(environment.npm_config_prefix, "bin", "codex") : null,
    join(homeDirectory, ".local", "bin", "codex"),
    join(homeDirectory, ".npm-global", "bin", "codex"),
    join(homeDirectory, ".volta", "bin", "codex"),
    join(homeDirectory, ".bun", "bin", "codex"),
    join(homeDirectory, ".asdf", "shims", "codex"),
    join(homeDirectory, ".local", "share", "mise", "shims", "codex"),
    ...nvmCandidates(homeDirectory),
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex",
    "/usr/bin/codex",
  ];
  for (const candidate of new Set(candidates.filter(Boolean))) {
    if (executable(candidate)) return candidate;
  }
  return null;
}
