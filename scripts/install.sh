#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
atlas_home_dir="$HOME"
preferred_node="$atlas_home_dir/.nvm/versions/node/v24.8.0/bin/node"
node_bin="${ATLAS_NODE_PATH:-$preferred_node}"
if [[ ! -x "$node_bin" ]]; then node_bin="$(command -v node)"; fi
node_major="$($node_bin -p 'Number(process.versions.node.split(".")[0])')"
if (( node_major < 22 )); then
  echo "Atlas requires Node.js 22.5 or newer." >&2
  exit 1
fi
node_dir="$(dirname "$node_bin")"
npm_cli="$node_dir/../lib/node_modules/npm/bin/npm-cli.js"
codex_cli="${CODEX_CLI_PATH:-$node_dir/codex}"
agent_source="$project_dir/config/com.sacrosaunt.atlas.plist.template"
agent_target="$atlas_home_dir/Library/LaunchAgents/com.sacrosaunt.atlas.plist"
app_target="$atlas_home_dir/Applications/Atlas.app"
support_dir="$atlas_home_dir/Library/Application Support/Atlas"
codex_workspace="$support_dir/CodexWorkspace"

/bin/launchctl bootout "gui/$(id -u)" "$agent_target" 2>/dev/null || true

mkdir -p "$project_dir/bin" "$atlas_home_dir/Library/LaunchAgents" "$atlas_home_dir/Applications" "$codex_workspace"
/bin/chmod 700 "$codex_workspace"
"$node_bin" "$npm_cli" install --prefix "$project_dir"
/usr/bin/swiftc -target arm64-apple-macos14.0 "$project_dir/src/AttributedBodyDecoder.swift" -o "$project_dir/bin/atlas-attributed-decoder"
/usr/bin/swiftc -target arm64-apple-macos15.0 -parse-as-library "$project_dir/src/ToneCoreMLRunner.swift" -framework CoreML -o "$project_dir/bin/atlas-tone-coreml-runner"
/usr/bin/swiftc -target arm64-apple-macos14.0 -parse-as-library "$project_dir/src/AtlasApp.swift" -framework SwiftUI -framework LocalAuthentication -framework AppKit -o "$project_dir/bin/Atlas"
/usr/bin/plutil -lint "$project_dir/config/Info.plist"
/usr/bin/sed \
  -e "s|__NODE_BIN__|$node_bin|g" \
  -e "s|__NODE_DIR__|$node_dir|g" \
  -e "s|__CODEX_CLI__|$codex_cli|g" \
  -e "s|__PROJECT_DIR__|$project_dir|g" \
  -e "s|__ATLAS_HOME__|$atlas_home_dir|g" \
  "$agent_source" > "$agent_target"
/usr/bin/plutil -lint "$agent_target"
/bin/chmod 600 "$agent_target"
/bin/mkdir -p "$app_target/Contents/MacOS" "$app_target/Contents/Resources"
/bin/cp "$project_dir/bin/Atlas" "$app_target/Contents/MacOS/Atlas"
/bin/cp "$project_dir/config/Info.plist" "$app_target/Contents/Info.plist"
/bin/cp "$project_dir/assets/AppIcon.icns" "$app_target/Contents/Resources/AppIcon.icns"
/bin/cp "$project_dir/assets/AtlasLogo.png" "$app_target/Contents/Resources/AtlasLogo.png"
/usr/bin/codesign --force --deep --sign - "$app_target"

/bin/launchctl bootstrap "gui/$(id -u)" "$agent_target"
/bin/launchctl kickstart -k "gui/$(id -u)/com.sacrosaunt.atlas"

echo "Atlas installed at $app_target"
