#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_PATH="$ROOT_DIR/.build/debug/msl"
DESKTOP_BIN_PATH="$ROOT_DIR/.build/debug/MSLDesktop"
APP_BUNDLE_PATH="$ROOT_DIR/.build/debug/MSL.app"
FULL_ENTITLEMENTS_PATH="$ROOT_DIR/msl.entitlements"
DEV_ENTITLEMENTS_PATH="$ROOT_DIR/msl.dev.entitlements"
SWIFTPM_HOME="$ROOT_DIR/.build/swiftpm-home"
MODULE_CACHE="$ROOT_DIR/.build/modulecache"
SIGNING_IDENTITY="${MSL_SIGNING_IDENTITY:-}"

cd "$ROOT_DIR"

mkdir -p "$SWIFTPM_HOME" "$MODULE_CACHE"

HOME="$SWIFTPM_HOME" \
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
swift build --disable-sandbox

DEFAULT_CONTAINER_TOOLS_STAGE_DIR="${CONTAINER_TOOLS_STAGE_DIR:-$HOME/Library/Application Support/msl/tools/bundled/darwin-arm64}"

if [[ -f "$DEFAULT_CONTAINER_TOOLS_STAGE_DIR/manifest.json" ]]; then
  CONTAINER_TOOLS_STAGE_DIR="$DEFAULT_CONTAINER_TOOLS_STAGE_DIR" \
    CONTAINER_TOOLS_OUTPUT_DIR="$ROOT_DIR/.build/debug/tools" \
    ./scripts/package-container-tools.sh
else
  rm -rf "$ROOT_DIR/.build/debug/tools"
  echo "Container helper bundle not staged; skipping helper packaging."
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  ENTITLEMENTS_PATH="$FULL_ENTITLEMENTS_PATH"
  echo "Using signing identity: $SIGNING_IDENTITY"
  echo "Applying full entitlements including com.apple.vm.networking."
else
  SIGNING_IDENTITY="-"
  ENTITLEMENTS_PATH="$DEV_ENTITLEMENTS_PATH"
  echo "Using ad-hoc signing with development entitlements (virtualization only)."
  echo "vmnet will be unavailable in this build."
fi

codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS_PATH" "$BIN_PATH"
codesign --force --sign "$SIGNING_IDENTITY" "$DESKTOP_BIN_PATH"
./scripts/build-desktop-app.sh
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS_PATH" "$APP_BUNDLE_PATH"

echo "Signed binary: $BIN_PATH"
echo "Signed desktop app: $APP_BUNDLE_PATH"
echo "Entitlements file: $ENTITLEMENTS_PATH"
echo "Entitlements:"
codesign -d --entitlements - "$BIN_PATH"
