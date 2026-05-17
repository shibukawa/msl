#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MSL.app"
APP_DIR="$ROOT_DIR/.build/debug/$APP_NAME"
LEGACY_APP_DIR="$ROOT_DIR/.build/debug/MSLDesktop.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
CONTAINER_TOOLS_SOURCE_DIR="$ROOT_DIR/.build/debug/tools"
PREBUILDS_DIR="$RESOURCES_DIR/prebuilds"
CONTAINER_TOOLS_DEST_DIR="$PREBUILDS_DIR/container-tools"
WAYLAND_SOURCE_LIB="$ROOT_DIR/.build/debug/wayland/libmsl_wayland_core.dylib"
APP_ICON_SOURCE="$ROOT_DIR/Support/assets/msl-app-icon.png"
ICONSET_DIR="$ROOT_DIR/.build/debug/MSL.iconset"

rm -rf "$LEGACY_APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"
rm -rf "$PREBUILDS_DIR"
mkdir -p "$PREBUILDS_DIR"

cp "$ROOT_DIR/.build/debug/MSLDesktop" "$MACOS_DIR/MSLDesktop"
cp "$ROOT_DIR/.build/debug/msl" "$MACOS_DIR/msl"
if [[ -f "$WAYLAND_SOURCE_LIB" ]]; then
  cp "$WAYLAND_SOURCE_LIB" "$FRAMEWORKS_DIR/libmsl_wayland_core.dylib"
fi
mkdir -p "$PREBUILDS_DIR/host-tools" "$PREBUILDS_DIR/guest-tools" "$PREBUILDS_DIR/scripts"
for tool in msl-ext4-mkfs msl-ext4-image; do
  if [[ -x "$HOME/.msl-system/$tool" ]]; then
    cp "$HOME/.msl-system/$tool" "$PREBUILDS_DIR/host-tools/$tool"
  fi
done
for tool in msl-init msl-init-bootloader msl-early-init; do
  if [[ -x "$HOME/.msl-system/$tool" ]]; then
    cp "$HOME/.msl-system/$tool" "$PREBUILDS_DIR/guest-tools/$tool"
  fi
done
if [[ -x "$HOME/.msl-system/wayland/msl-wayland-proxy" ]]; then
  cp "$HOME/.msl-system/wayland/msl-wayland-proxy" "$PREBUILDS_DIR/guest-tools/msl-wayland-proxy"
fi
cp "$ROOT_DIR/scripts/imagewriter-build.sh" "$PREBUILDS_DIR/scripts/imagewriter-build.sh"
cp "$ROOT_DIR/scripts/imagewriter-build-guest.sh" "$PREBUILDS_DIR/scripts/imagewriter-build-guest.sh"
cp "$ROOT_DIR/scripts/imagewriter-setup.sh" "$PREBUILDS_DIR/scripts/imagewriter-setup.sh"

if [[ -d "$ROOT_DIR/tmp/distribution-kernel/slim" ]]; then
  mkdir -p "$PREBUILDS_DIR/kernels"
  cp -R "$ROOT_DIR/tmp/distribution-kernel/slim" "$PREBUILDS_DIR/kernels/slim"
fi
if [[ -d "$ROOT_DIR/tmp/container-runtime-artifact/_container" ]]; then
  mkdir -p "$PREBUILDS_DIR/internal-runtimes"
  mkdir -p "$PREBUILDS_DIR/internal-runtimes/_container"
  for artifact in base.erofs.raw state.btrfs.template.raw.gz metadata.json source.json; do
    if [[ -f "$ROOT_DIR/tmp/container-runtime-artifact/_container/$artifact" ]]; then
      cp "$ROOT_DIR/tmp/container-runtime-artifact/_container/$artifact" "$PREBUILDS_DIR/internal-runtimes/_container/$artifact"
    fi
  done
fi
if [[ -d "$ROOT_DIR/tmp/imagewriter-runtime-artifact/_imagewriter" ]]; then
  mkdir -p "$PREBUILDS_DIR/internal-runtimes"
  cp -R "$ROOT_DIR/tmp/imagewriter-runtime-artifact/_imagewriter" "$PREBUILDS_DIR/internal-runtimes/_imagewriter"
fi
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

if [[ -f "$APP_ICON_SOURCE" ]]; then
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$APP_ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$APP_ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/MSL.icns"
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
  <string>MSL</string>
  <key>CFBundleIconFile</key>
  <string>MSL</string>
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
