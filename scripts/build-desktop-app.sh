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
  python3 - "$CONTAINER_TOOLS_SOURCE_DIR/manifest.json" "$CONTAINER_TOOLS_SOURCE_DIR" "$CONTAINER_TOOLS_DEST_DIR" <<'PY'
import json, os, shutil, sys
manifest_path, source_root, dest_root = sys.argv[1:]
with open(manifest_path, "r", encoding="utf-8") as fh:
    manifest = json.load(fh)
shutil.copy2(manifest_path, os.path.join(dest_root, "manifest.json"))
for tool in manifest.get("tools", []):
    src = os.path.join(source_root, tool["relativePath"])
    dst = os.path.join(dest_root, tool["relativePath"])
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    os.chmod(dst, 0o755)
PY
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
