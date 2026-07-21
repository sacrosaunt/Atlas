#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
atlas_home_dir="$HOME"
agent_target="$atlas_home_dir/Library/LaunchAgents/com.sacrosaunt.atlas.plist"
app_target="$atlas_home_dir/Applications/Atlas.app"
support_dir="$atlas_home_dir/Library/Application Support/Atlas"
codex_workspace="$support_dir/CodexWorkspace"
tone_asset="$project_dir/assets/ToneClassifier.mlpackage"
tone_target="$support_dir/Sentiment/coreml/ToneClassifier.mlpackage"

/bin/launchctl bootout "gui/$(id -u)" "$agent_target" 2>/dev/null || true

mkdir -p "$project_dir/bin" "$atlas_home_dir/Applications" "$codex_workspace"
/bin/chmod 700 "$codex_workspace"
cd "$project_dir"
/usr/bin/swift build -c release --product AtlasBackend
/bin/cp "$project_dir/.build/release/AtlasBackend" "$project_dir/bin/atlas-backend"
/bin/rm -rf "$project_dir/bin/llama.framework"
/bin/cp -R "$project_dir/.build/arm64-apple-macosx/release/llama.framework" "$project_dir/bin/llama.framework"
/usr/bin/lipo -thin arm64 "$project_dir/.build/arm64-apple-macosx/release/libonnxruntime.1.20.1.dylib" -output "$project_dir/bin/libonnxruntime.1.20.1.dylib"
if [[ -d "$tone_asset" ]]; then
  /bin/mkdir -p "$(dirname "$tone_target")"
  /bin/rm -rf "$tone_target"
  /bin/cp -R "$tone_asset" "$tone_target"
fi
/usr/bin/swiftc -target arm64-apple-macos15.0 -parse-as-library "$project_dir/src/CalendarBridge.swift" "$project_dir/src/AtlasApp.swift" -framework SwiftUI -framework Charts -framework LocalAuthentication -framework AppKit -framework UserNotifications -framework EventKit -o "$project_dir/bin/Atlas"
/usr/bin/plutil -lint "$project_dir/config/Info.plist"
/bin/mkdir -p "$app_target/Contents/MacOS" "$app_target/Contents/Resources"
/bin/cp "$project_dir/bin/Atlas" "$app_target/Contents/MacOS/Atlas"
/bin/cp "$project_dir/bin/atlas-backend" "$app_target/Contents/MacOS/atlas-backend"
/bin/rm -rf "$app_target/Contents/MacOS/llama.framework"
/bin/cp -R "$project_dir/bin/llama.framework" "$app_target/Contents/MacOS/llama.framework"
/bin/cp "$project_dir/bin/libonnxruntime.1.20.1.dylib" "$app_target/Contents/MacOS/libonnxruntime.1.20.1.dylib"
/bin/cp "$project_dir/config/Info.plist" "$app_target/Contents/Info.plist"
/bin/cp "$project_dir/assets/AppIcon.icns" "$app_target/Contents/Resources/AppIcon.icns"
/bin/cp "$project_dir/assets/AtlasLogo.png" "$app_target/Contents/Resources/AtlasLogo.png"
/usr/bin/codesign --force --deep --sign - "$app_target"

/bin/rm -f "$agent_target"

echo "Atlas installed at $app_target"
