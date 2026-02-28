#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

cd "$ROOT_DIR/Support/msl-init"
TARGET="aarch64-unknown-linux-musl"

if command -v rustup >/dev/null 2>&1; then
  if ! rustup target list --installed | grep -q "^$TARGET$"; then
    rustup target add "$TARGET"
  fi
else
  echo "error: rustup not found. install rustup to build Linux arm64 target ($TARGET)." >&2
  echo "hint: as a temporary check, run: cargo build --release" >&2
  exit 1
fi

cargo build --release --target "$TARGET"
OUT="$ROOT_DIR/Support/msl-init/target/$TARGET/release/msl-init"
if command -v file >/dev/null 2>&1; then
  FILE_OUT="$(file "$OUT")"
  echo "$FILE_OUT"
  if ! echo "$FILE_OUT" | grep -q "ELF 64-bit.*ARM aarch64"; then
    echo "error: unexpected msl-init binary format (expected Linux aarch64 ELF)." >&2
    exit 1
  fi
fi
echo "built: $OUT"
