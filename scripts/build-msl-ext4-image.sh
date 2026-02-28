#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found. install rust toolchain to build ext4 helpers." >&2
  exit 1
fi

cd "$ROOT_DIR/Support/msl-ext4-mkfs"
cargo build --release

OUT_MKFS="$ROOT_DIR/Support/msl-ext4-mkfs/target/release/msl-ext4-mkfs"
if [ ! -x "$OUT_MKFS" ]; then
  echo "error: build completed but binary not found at $OUT_MKFS" >&2
  exit 1
fi

cd "$ROOT_DIR/Support/msl-ext4-image"
cargo build --release

OUT_POPULATE="$ROOT_DIR/Support/msl-ext4-image/target/release/msl-ext4-image"
if [ ! -x "$OUT_POPULATE" ]; then
  echo "error: build completed but binary not found at $OUT_POPULATE" >&2
  exit 1
fi

echo "built: $OUT_MKFS"
echo "built: $OUT_POPULATE"
