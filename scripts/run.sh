#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_PYTHON="$ROOT_DIR/.venv/bin/python3"

cd "$ROOT_DIR"

if [[ ! -x "$VENV_PYTHON" ]]; then
  echo "Python virtual environment not found at .venv." >&2
  echo "Run ./scripts/setup.sh first." >&2
  exit 1
fi

if ! "$VENV_PYTHON" -c "import faster_whisper" >/dev/null 2>&1; then
  echo "Missing Python dependencies (faster-whisper)." >&2
  echo "Run ./scripts/setup.sh first." >&2
  exit 1
fi

export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/tmp/swift-module-cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/clang-module-cache}"

swift run
