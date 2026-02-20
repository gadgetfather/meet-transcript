#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="MeetTranscript"
VENV_PYTHON="$ROOT_DIR/.venv/bin/python3"
APP_ICON_ICNS="$ROOT_DIR/Brand/MeetTranscript.icns"
VARIANT="lite"
MODEL_NAME="base.en"
RELEASE_BINARY=""

usage() {
  cat <<EOF
Usage: ./scripts/build_dmg.sh [options]

Options:
  --variant <lite|full|both>  Build variant (default: lite)
  --model <name>              Whisper model for full variant (default: base.en)
  -h, --help                  Show this message

Examples:
  ./scripts/build_dmg.sh --variant lite
  ./scripts/build_dmg.sh --variant full --model base.en
  ./scripts/build_dmg.sh --variant both
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant)
      if [[ $# -lt 2 ]]; then
        echo "--variant requires a value." >&2
        exit 1
      fi
      VARIANT="$2"
      shift 2
      ;;
    --model)
      if [[ $# -lt 2 ]]; then
        echo "--model requires a value." >&2
        exit 1
      fi
      MODEL_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$VARIANT" != "lite" && "$VARIANT" != "full" && "$VARIANT" != "both" ]]; then
  echo "Invalid variant: $VARIANT (expected lite, full, or both)." >&2
  exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "DMG build is only supported on macOS." >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "swift not found. Install Xcode Command Line Tools first." >&2
  exit 1
fi

if ! command -v hdiutil >/dev/null 2>&1; then
  echo "hdiutil not found." >&2
  exit 1
fi

if [[ ! -x "$VENV_PYTHON" ]]; then
  echo "Missing .venv runtime. Run ./scripts/setup.sh first." >&2
  exit 1
fi

if ! "$VENV_PYTHON" -c "import faster_whisper" >/dev/null 2>&1; then
  echo "Missing faster-whisper in .venv. Run ./scripts/setup.sh first." >&2
  exit 1
fi

cd "$ROOT_DIR"

build_release_binary() {
  echo "Building release binary ..."
  SWIFT_MODULECACHE_PATH=/tmp/swift-module-cache \
  CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache \
  swift build \
    -c release \
    --disable-sandbox \
    --scratch-path /tmp/meet-transcript-build \
    --cache-path /tmp/meet-transcript-cache

  local bin_dir
  bin_dir="$(SWIFT_MODULECACHE_PATH=/tmp/swift-module-cache \
  CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache \
  swift build \
    -c release \
    --disable-sandbox \
    --scratch-path /tmp/meet-transcript-build \
    --cache-path /tmp/meet-transcript-cache \
    --show-bin-path)"

  RELEASE_BINARY="$bin_dir/$APP_NAME"
  if [[ ! -f "$RELEASE_BINARY" ]]; then
    echo "Release binary not found at $RELEASE_BINARY" >&2
    exit 1
  fi
}

bundle_model() {
  local model_target_dir="$1"

  mkdir -p "$model_target_dir"
  echo "Bundling Whisper model: $MODEL_NAME ..."
  "$VENV_PYTHON" - <<PY
from faster_whisper.utils import download_model
download_model("$MODEL_NAME", output_dir=r"$model_target_dir")
print("Model ready at: " + r"$model_target_dir")
PY
}

write_launcher() {
  local launcher_path="$1"
  cat > "$launcher_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONTENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_DIR="$CONTENTS_DIR/Resources/runtime_assets"
STATE_DIR="$HOME/Library/Application Support/MeetTranscript"
RUNTIME_DIR="$STATE_DIR/runtime"
OUTPUT_DIR="$HOME/Documents/MeetTranscript"
MODEL_NAME="__MODEL_NAME__"

mkdir -p "$STATE_DIR" "$OUTPUT_DIR"
mkdir -p "$RUNTIME_DIR"

# Keep scripts in sync with each app update.
mkdir -p "$RUNTIME_DIR/scripts"
ditto "$ASSETS_DIR/scripts" "$RUNTIME_DIR/scripts"

# Install bundled Python runtime once.
if [[ ! -x "$RUNTIME_DIR/.venv/bin/python3" ]]; then
  ditto "$ASSETS_DIR/.venv" "$RUNTIME_DIR/.venv"
fi

# Keep bundled model in sync when using full variant.
if [[ -d "$ASSETS_DIR/models/$MODEL_NAME" ]]; then
  mkdir -p "$RUNTIME_DIR/models"
  ditto "$ASSETS_DIR/models/$MODEL_NAME" "$RUNTIME_DIR/models/$MODEL_NAME"
fi

export MEET_TRANSCRIPT_RUNTIME_DIR="$RUNTIME_DIR"
export MEET_TRANSCRIPT_OUTPUT_DIR="$OUTPUT_DIR"
if [[ -d "$RUNTIME_DIR/models/$MODEL_NAME" ]]; then
  export MEET_TRANSCRIPT_WHISPER_MODEL_DIR="$RUNTIME_DIR/models/$MODEL_NAME"
fi

exec "$CONTENTS_DIR/MacOS/MeetTranscript-bin"
EOF
  # Replace placeholder without expanding launcher runtime variables.
  /usr/bin/sed -i '' "s|__MODEL_NAME__|$MODEL_NAME|g" "$launcher_path"
  chmod +x "$launcher_path"
}

write_info_plist() {
  local plist_path="$1"
  local icon_xml=""
  if [[ -f "$APP_ICON_ICNS" ]]; then
    icon_xml=$'  <key>CFBundleIconFile</key>\n  <string>MeetTranscript</string>'
  fi

  cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>MeetTranscript</string>
  <key>CFBundleDisplayName</key>
  <string>MeetTranscript</string>
  <key>CFBundleIdentifier</key>
  <string>com.meettranscript.app</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleExecutable</key>
  <string>MeetTranscript</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
${icon_xml}
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>MeetTranscript needs microphone access to record your voice.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>MeetTranscript uses speech recognition for live microphone captions.</string>
</dict>
</plist>
EOF
}

build_variant() {
  local variant="$1"
  local suffix="-$variant"
  local app_bundle="$DIST_DIR/$APP_NAME$suffix.app"
  local dmg_root="$DIST_DIR/dmg-root-$variant"
  local dmg_path="$DIST_DIR/$APP_NAME$suffix.dmg"

  echo "Preparing $variant app bundle ..."
  rm -rf "$app_bundle" "$dmg_root" "$dmg_path"
  mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources/runtime_assets"

  cp "$RELEASE_BINARY" "$app_bundle/Contents/MacOS/$APP_NAME-bin"
  chmod +x "$app_bundle/Contents/MacOS/$APP_NAME-bin"
  write_launcher "$app_bundle/Contents/MacOS/$APP_NAME"
  write_info_plist "$app_bundle/Contents/Info.plist"

  echo "Bundling runtime assets (.venv + scripts) ..."
  cp -R "$ROOT_DIR/scripts" "$app_bundle/Contents/Resources/runtime_assets/scripts"
  cp -R "$ROOT_DIR/.venv" "$app_bundle/Contents/Resources/runtime_assets/.venv"
  if [[ -f "$ROOT_DIR/requirements.txt" ]]; then
    cp "$ROOT_DIR/requirements.txt" "$app_bundle/Contents/Resources/runtime_assets/requirements.txt"
  fi

  if [[ "$variant" == "full" ]]; then
    bundle_model "$app_bundle/Contents/Resources/runtime_assets/models/$MODEL_NAME"
  fi

  if [[ -f "$APP_ICON_ICNS" ]]; then
    cp "$APP_ICON_ICNS" "$app_bundle/Contents/Resources/MeetTranscript.icns"
  fi

  echo "Creating DMG for $variant variant ..."
  mkdir -p "$dmg_root"
  cp -R "$app_bundle" "$dmg_root/$APP_NAME.app"
  ln -s /Applications "$dmg_root/Applications"

  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$dmg_root" \
    -ov \
    -format UDZO \
    "$dmg_path" >/dev/null

  rm -rf "$dmg_root"
  echo "DMG ready: $dmg_path"
}

build_release_binary

if [[ "$VARIANT" == "both" ]]; then
  build_variant "lite"
  build_variant "full"
else
  build_variant "$VARIANT"
fi
