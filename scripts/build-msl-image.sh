#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
MSL_BIN="${MSL_BIN:-$ROOT_DIR/.build/debug/msl}"

if [ ! -x "$MSL_BIN" ]; then
  echo "msl binary not found at $MSL_BIN; building..."
  (cd "$ROOT_DIR" && swift build)
fi

exec "$MSL_BIN" image build "$@"
