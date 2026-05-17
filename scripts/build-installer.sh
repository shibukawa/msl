#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/.build/debug/MSL.app"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$ROOT_DIR/.build/installer-staging"
DMG_PATH="$DIST_DIR/MSLDesktop.dmg"

cd "$ROOT_DIR"
./scripts/build-signed.sh

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app bundle missing after build: $APP_PATH" >&2
  exit 1
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$DIST_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/MSL.app"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH"

# DMG source folders can contain sparse VM images. Size the temporary image
# from apparent bytes, not allocated bytes, or hdiutil under-sizes the volume.
APPARENT_KIB="$(du -sk -A "$STAGING_DIR" | awk '{print $1}')"
DMG_SIZE_MIB="$(( (APPARENT_KIB + 1023) / 1024 + 1024 ))"
hdiutil create \
  -size "${DMG_SIZE_MIB}m" \
  -volname MSLDesktop \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
echo "Built installer: $DMG_PATH"
