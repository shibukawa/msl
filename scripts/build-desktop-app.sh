#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MSLDesktop.app"
APP_DIR="$ROOT_DIR/.build/debug/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
CONTAINER_TOOLS_SOURCE_DIR="$ROOT_DIR/.build/debug/tools"
CONTAINER_TOOLS_DEST_DIR="$RESOURCES_DIR/container-tools"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT_DIR/.build/debug/MSLDesktop" "$MACOS_DIR/MSLDesktop"
cp "$ROOT_DIR/.build/debug/msl" "$MACOS_DIR/msl"
rm -rf "$CONTAINER_TOOLS_DEST_DIR"
if [[ -f "$CONTAINER_TOOLS_SOURCE_DIR/manifest.json" ]]; then
  mkdir -p "$CONTAINER_TOOLS_DEST_DIR"
  cp "$CONTAINER_TOOLS_SOURCE_DIR/manifest.json" "$CONTAINER_TOOLS_DEST_DIR/manifest.json"
  cp "$CONTAINER_TOOLS_SOURCE_DIR/regctl" "$CONTAINER_TOOLS_DEST_DIR/regctl"
  cp "$CONTAINER_TOOLS_SOURCE_DIR/umoci" "$CONTAINER_TOOLS_DEST_DIR/umoci"
  chmod 0755 "$CONTAINER_TOOLS_DEST_DIR/regctl" "$CONTAINER_TOOLS_DEST_DIR/umoci"
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>MSLDesktop</string>
  <key>CFBundleIdentifier</key>
  <string>dev.msl.desktop</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>MSLDesktop</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "Built app bundle: $APP_DIR"
