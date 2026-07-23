#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_dir="$(cd "$script_dir/.." && pwd -P)"
atlas_home_dir="${HOME:?Atlas needs a home directory}"
support_dir="${ATLAS_SUPPORT_DIR:-$atlas_home_dir/Library/Application Support/Atlas}"
coreml_dir="$support_dir/Sentiment/coreml"
package_target="$coreml_dir/ToneClassifier.mlpackage"
compiled_target="$coreml_dir/ToneClassifier.mlmodelc"
progress_file="$coreml_dir/setup-progress.json"
bundled_package="${ATLAS_TONE_BUNDLED_PACKAGE:-$project_dir/assets/ToneClassifier.mlpackage}"
requirements="$script_dir/requirements-tone-coreml.txt"
converter="$script_dir/convert-tone-coreml.py"
compiler="$script_dir/compile-tone-coreml.swift"
cache_dir="${ATLAS_TONE_BUILD_CACHE:-$atlas_home_dir/Library/Caches/Atlas/ToneCoreML}"
venv_dir="$cache_dir/venv"
model_cache="$cache_dir/model"
requirements_marker="$venv_dir/.atlas-requirements-sha256"
setup_succeeded=0

write_progress() {
  local phase="$1" completed="$2" total="$3" detail="$4"
  local temporary="$progress_file.tmp"
  /usr/bin/printf '{"phase":"%s","completed":%s,"total":%s,"detail":"%s"}\n' \
    "$phase" "$completed" "$total" "$detail" > "$temporary"
  /bin/mv -f "$temporary" "$progress_file"
}

finish_progress() {
  if [[ "$setup_succeeded" != 1 ]]; then
    write_progress "failed" 0 1 "Core ML setup failed; Atlas will use ONNX Runtime"
  fi
}

trap finish_progress EXIT

package_is_valid() {
  local candidate="$1"
  [[ -f "$candidate/Manifest.json" && -d "$candidate/Data" ]] || return 1
  [[ -n "$(/usr/bin/find "$candidate/Data" -type f -size +1048576c -print -quit 2>/dev/null)" ]]
}

compiled_model_is_valid() {
  local candidate="$1"
  [[ -d "$candidate" ]] || return 1
  [[ -n "$(/usr/bin/find "$candidate" -type f -size +1024c -print -quit 2>/dev/null)" ]]
}

cleanup_after_success() {
  /bin/rm -rf \
    "$coreml_dir/.tone-coreml-functions" \
    "$coreml_dir/ToneClassifier.building.mlpackage" \
    "$coreml_dir/.ToneClassifier.mlmodelc.building"
  case "$cache_dir" in
    "$atlas_home_dir/Library/Caches/Atlas/ToneCoreML"|/tmp/*|/private/tmp/*|/private/var/folders/*)
      /bin/rm -rf "$venv_dir" "$model_cache" "$cache_dir/swift-module-cache"
      /bin/rmdir "$cache_dir" 2>/dev/null || true
      ;;
    *)
      echo "warning: refusing to remove unexpected Core ML cache path: $cache_dir" >&2
      ;;
  esac
  if compiled_model_is_valid "$compiled_target"; then
    # The compiled bundle is self-contained. Keeping the source package would
    # duplicate the model weights and is unnecessary at runtime.
    /bin/rm -rf "$package_target"
  fi
}

compile_package_if_needed() {
  if compiled_model_is_valid "$compiled_target"; then
    echo "Core ML tone model is already compiled."
    return 0
  fi
  echo "Compiling the Core ML tone model for this Mac…"
  write_progress "compiling" 95 100 "Compiling the model for this Mac"
  local module_cache="$cache_dir/swift-module-cache"
  /bin/mkdir -p "$module_cache"
  if /usr/bin/swift -module-cache-path "$module_cache" "$compiler" "$package_target" "$compiled_target"; then
    return 0
  fi
  local compatibility_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
  if [[ -d "$compatibility_sdk" ]] && \
     /usr/bin/swift -sdk "$compatibility_sdk" -module-cache-path "$module_cache" "$compiler" "$package_target" "$compiled_target"; then
    return 0
  fi
  if ! compiled_model_is_valid "$compiled_target"; then
    echo "warning: Core ML precompilation failed; Atlas will compile the package when it first loads it." >&2
  fi
}

/bin/mkdir -p "$coreml_dir" "$cache_dir" "$model_cache"
/bin/chmod 700 "$coreml_dir" "$cache_dir" "$model_cache"

if compiled_model_is_valid "$compiled_target"; then
  echo "Core ML tone model is already compiled."
  cleanup_after_success
  write_progress "ready" 100 100 "Core ML acceleration is ready"
  setup_succeeded=1
  exit 0
fi

if package_is_valid "$package_target"; then
  echo "Core ML tone package is already installed."
  compile_package_if_needed
  cleanup_after_success
  write_progress "ready" 100 100 "Core ML acceleration is ready"
  setup_succeeded=1
  exit 0
fi

if package_is_valid "$bundled_package"; then
  echo "Installing the bundled Core ML tone package…"
  /bin/rm -rf "$package_target" "$compiled_target"
  /bin/cp -R "$bundled_package" "$package_target"
  compile_package_if_needed
  cleanup_after_success
  write_progress "ready" 100 100 "Core ML acceleration is ready"
  setup_succeeded=1
  exit 0
fi

python_executable=""
for candidate in "${ATLAS_PYTHON:-}" "$(command -v python3 2>/dev/null || true)" /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  if "$candidate" -c 'import sys; raise SystemExit(0 if (3, 9) <= sys.version_info[:2] < (3, 13) else 1)' 2>/dev/null; then
    python_executable="$candidate"
    break
  fi
done

if [[ -z "$python_executable" ]]; then
  echo "error: Core ML conversion needs Python 3.9 through 3.12." >&2
  exit 1
fi

requirements_hash="$(/usr/bin/shasum -a 256 "$requirements" | /usr/bin/awk '{print $1}')"
installed_hash="$(/bin/cat "$requirements_marker" 2>/dev/null || true)"
if [[ ! -x "$venv_dir/bin/python" || "$requirements_hash" != "$installed_hash" ]]; then
  echo "Preparing Atlas's private Core ML conversion environment…"
  write_progress "dependencies" 5 100 "Downloading Core ML conversion tools"
  /bin/rm -rf "$venv_dir"
  "$python_executable" -m venv "$venv_dir"
  "$venv_dir/bin/python" -m pip install --disable-pip-version-check --upgrade "pip==25.1.1"
  "$venv_dir/bin/python" -m pip install --disable-pip-version-check --requirement "$requirements"
  print -r -- "$requirements_hash" > "$requirements_marker"
fi

echo "Downloading the pinned tone model and converting it to Core ML…"
"$venv_dir/bin/python" "$converter" \
  --output "$package_target" \
  --cache "$model_cache" \
  --progress "$progress_file"

if ! package_is_valid "$package_target"; then
  echo "error: Core ML conversion completed without producing a valid model package." >&2
  exit 1
fi

/bin/rm -rf "$compiled_target"
compile_package_if_needed
cleanup_after_success
write_progress "ready" 100 100 "Core ML acceleration is ready"
setup_succeeded=1
echo "Core ML tone model is ready."
