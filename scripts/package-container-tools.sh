#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STAGE_DIR="${CONTAINER_TOOLS_STAGE_DIR:-$ROOT_DIR/tmp/container-tools/darwin-arm64}"
OUTPUT_DIR="${CONTAINER_TOOLS_OUTPUT_DIR:-$ROOT_DIR/.build/debug/tools}"

if [[ ! -f "$STAGE_DIR/manifest.json" ]]; then
  echo "error: staged container helper manifest not found: $STAGE_DIR/manifest.json" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to verify staged container helpers" >&2
  exit 1
fi

python3 - "$STAGE_DIR/manifest.json" "$STAGE_DIR" <<'PY'
import hashlib, json, os, sys

manifest_path, root = sys.argv[1:]
with open(manifest_path, "r", encoding="utf-8") as fh:
    manifest = json.load(fh)
for tool in manifest.get("tools", []):
    path = os.path.join(root, tool["relativePath"])
    if not os.path.exists(path):
        raise SystemExit(f"error: bundled helper missing: {tool['name']}")
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    if h.hexdigest().lower() != tool["checksum"].lower():
        raise SystemExit(f"error: helper checksum mismatch: {tool['name']}")
PY

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
python3 - "$STAGE_DIR/manifest.json" "$STAGE_DIR" "$OUTPUT_DIR" <<'PY'
import json, os, shutil, sys
manifest_path, root, out = sys.argv[1:]
with open(manifest_path, "r", encoding="utf-8") as fh:
    manifest = json.load(fh)
shutil.copy2(manifest_path, os.path.join(out, "manifest.json"))
for tool in manifest.get("tools", []):
    src = os.path.join(root, tool["relativePath"])
    dst = os.path.join(out, tool["relativePath"])
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    os.chmod(dst, 0o755)
PY

echo "packaged container helpers into: $OUTPUT_DIR"
