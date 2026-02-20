#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="$ROOT_DIR/.venv"
PYTHON_BIN="$VENV_DIR/bin/python3"
SKIP_PYTHON_DEPS=0
SKIP_BUILD=0

usage() {
  cat <<EOF
Usage: ./scripts/setup.sh [options]

Options:
  --skip-python-deps   Skip pip install (use if deps are already installed)
  --skip-build         Skip swift build preflight
  -h, --help           Show this message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-python-deps)
      SKIP_PYTHON_DEPS=1
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
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

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This app currently supports macOS only." >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "swift not found. Install Xcode Command Line Tools first:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found. Install Python 3.10+ first." >&2
  exit 1
fi

cd "$ROOT_DIR"

if [[ ! -d "$VENV_DIR" ]]; then
  echo "Creating virtual environment at .venv ..."
  python3 -m venv "$VENV_DIR"
fi

if [[ $SKIP_PYTHON_DEPS -eq 0 ]]; then
  echo "Installing Python dependencies ..."
  "$PYTHON_BIN" -m pip install --upgrade pip
  "$PYTHON_BIN" -m pip install -r "$ROOT_DIR/requirements.txt"
else
  echo "Skipping Python dependency installation."
fi

if [[ $SKIP_BUILD -eq 0 ]]; then
  echo "Running Swift build preflight ..."
  SWIFT_MODULECACHE_PATH=/tmp/swift-module-cache \
  CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache \
  swift build
else
  echo "Skipping Swift build preflight."
fi

echo
echo "Setup complete."
echo "Run the app with:"
echo "  ./scripts/run.sh"
