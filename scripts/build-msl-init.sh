#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

cd "$ROOT_DIR/Support/msl-init"
TARGET="aarch64-unknown-linux-musl"
STAGING_DIR="${MSL_HOME:-$HOME}/.msl-system"
STAGING_OUT="$STAGING_DIR/msl-init"
STAGING_VERSION_OUT="$STAGING_DIR/msl-init.version"
BUILD_GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
BUILD_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VERSION_STRING="msl-init git=$BUILD_GIT_COMMIT built_at=$BUILD_TIMESTAMP target=$TARGET"

if command -v rustup >/dev/null 2>&1; then
  if ! rustup target list --installed | grep -q "^$TARGET$"; then
    rustup target add "$TARGET"
  fi
else
  echo "error: rustup not found. install rustup to build Linux arm64 target ($TARGET)." >&2
  echo "hint: as a temporary check, run: cargo build --release" >&2
  exit 1
fi

MSL_INIT_BUILD_GIT_COMMIT="$BUILD_GIT_COMMIT" \
MSL_INIT_BUILD_TIMESTAMP="$BUILD_TIMESTAMP" \
MSL_INIT_BUILD_TARGET="$TARGET" \
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
mkdir -p "$STAGING_DIR"
cp -f "$OUT" "$STAGING_OUT"
chmod 0755 "$STAGING_OUT"
printf '%s\n' "$VERSION_STRING" > "$STAGING_VERSION_OUT"
echo "staged: $STAGING_OUT"
echo "staged-version: $VERSION_STRING"
