#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_PATH="$ROOT_DIR/.build/debug/msl"
ENTITLEMENTS_PATH="$ROOT_DIR/msl.entitlements"
SWIFTPM_HOME="$ROOT_DIR/.build/swiftpm-home"
MODULE_CACHE="$ROOT_DIR/.build/modulecache"

cd "$ROOT_DIR"

mkdir -p "$SWIFTPM_HOME" "$MODULE_CACHE"

HOME="$SWIFTPM_HOME" \
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
swift build --disable-sandbox

codesign --force --sign - --entitlements "$ENTITLEMENTS_PATH" "$BIN_PATH"

echo "Signed binary: $BIN_PATH"
echo "Entitlements:"
codesign -d --entitlements - "$BIN_PATH"
