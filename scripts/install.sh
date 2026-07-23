#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
atlas_home_dir="$HOME"
agent_target="$atlas_home_dir/Library/LaunchAgents/com.sacrosaunt.atlas.plist"
app_target="$atlas_home_dir/Applications/Atlas.app"
support_dir="$atlas_home_dir/Library/Application Support/Atlas"
codex_workspace="$support_dir/CodexWorkspace"

require_executable() {
  if [[ ! -x "$1" ]]; then
    echo "error: required tool is missing: $1" >&2
    exit 1
  fi
}

for tool in /usr/bin/swift /usr/bin/swiftc /usr/bin/lipo /usr/bin/plutil /usr/bin/codesign; do
  require_executable "$tool"
done

swift_version="$(/usr/bin/swift --version 2>/dev/null | /usr/bin/sed -n 's/.*Apple Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | /usr/bin/head -1)"
swift_major="${swift_version%%.*}"
swift_minor="${swift_version#*.}"
if [[ -z "$swift_version" || "$swift_major" -lt 6 || ( "$swift_major" -eq 6 && "$swift_minor" -lt 2 ) ]]; then
  echo "error: Atlas requires Apple Swift 6.2 or newer; found ${swift_version:-an unknown version}." >&2
  exit 1
fi

if ! /usr/bin/swift -e 'import Foundation' >/dev/null 2>&1; then
  echo "error: the installed Swift compiler and macOS SDK do not match." >&2
  echo "Install or update Xcode Command Line Tools, then run this installer again." >&2
  exit 1
fi

if [[ "$(/usr/bin/uname -m)" != "arm64" ]]; then
  echo "error: Atlas currently requires an Apple silicon Mac." >&2
  exit 1
fi

for resource in \
  "$project_dir/Package.swift" \
  "$project_dir/Package.resolved" \
  "$project_dir/config/Info.plist" \
  "$project_dir/assets/AppIcon.icns" \
  "$project_dir/assets/AtlasLogo.png" \
  "$project_dir/scripts/prepare-tone-coreml.sh" \
  "$project_dir/scripts/convert-tone-coreml.py" \
  "$project_dir/scripts/compile-tone-coreml.swift" \
  "$project_dir/scripts/requirements-tone-coreml.txt"; do
  if [[ ! -e "$resource" ]]; then
    echo "error: required repository file is missing: $resource" >&2
    exit 1
  fi
done

/bin/launchctl bootout "gui/$(id -u)" "$agent_target" 2>/dev/null || true

mkdir -p "$project_dir/bin" "$atlas_home_dir/Applications" "$codex_workspace"
/bin/chmod 700 "$codex_workspace"
cd "$project_dir"
/usr/bin/swift build -c release --product AtlasBackend
/bin/cp "$project_dir/.build/release/AtlasBackend" "$project_dir/bin/atlas-backend"
/bin/rm -rf "$project_dir/bin/llama.framework"
/bin/cp -R "$project_dir/.build/arm64-apple-macosx/release/llama.framework" "$project_dir/bin/llama.framework"
/usr/bin/lipo -thin arm64 "$project_dir/.build/arm64-apple-macosx/release/libonnxruntime.1.20.1.dylib" -output "$project_dir/bin/libonnxruntime.1.20.1.dylib"
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
/bin/rm -rf "$app_target/Contents/Resources/CoreMLSetup"
/bin/mkdir -p "$app_target/Contents/Resources/CoreMLSetup"
for setup_file in prepare-tone-coreml.sh convert-tone-coreml.py compile-tone-coreml.swift requirements-tone-coreml.txt; do
  /bin/cp "$project_dir/scripts/$setup_file" "$app_target/Contents/Resources/CoreMLSetup/$setup_file"
done
/bin/chmod 700 "$app_target/Contents/Resources/CoreMLSetup/prepare-tone-coreml.sh"
/usr/bin/codesign --force --deep --sign - "$app_target"

/bin/rm -f "$agent_target"

echo "Atlas installed at $app_target"
