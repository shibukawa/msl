#!/bin/zsh
set -euo pipefail

MSL_BIN="${MSL_BIN:-./.build/debug/msl}"
ARTIFACT_ROOT="${CONTAINER_RUNTIME_ARTIFACT_DIR:-$PWD/tmp/container-runtime-artifact}"
INSTANCE_NAME="${CONTAINER_RUNTIME_INSTANCE:-_container}"

if [[ ! -x "$MSL_BIN" ]]; then
  echo "error: msl binary not found or not executable: $MSL_BIN" >&2
  echo "build it first with ./scripts/build-signed.sh or make build" >&2
  exit 1
fi

APP_SUPPORT_DIR="${MSL_HOME:-$HOME}/Library/Application Support/msl"
INSTANCE_DIR="$APP_SUPPORT_DIR/distros/$INSTANCE_NAME"
ARTIFACT_DIR="$ARTIFACT_ROOT/$INSTANCE_NAME"

mkdir -p "$ARTIFACT_ROOT"

echo "building internal container runtime instance: $INSTANCE_NAME"
MSL_ALLOW_INTERNAL_CONTAINER_RUNTIME=1 "$MSL_BIN" install --rebuild --name "$INSTANCE_NAME" container-runtime

mkdir -p "$ARTIFACT_DIR"
cp "$INSTANCE_DIR/disk.raw" "$ARTIFACT_DIR/disk.raw"
cp "$INSTANCE_DIR/metadata.json" "$ARTIFACT_DIR/metadata.json"
cp "$INSTANCE_DIR/source.json" "$ARTIFACT_DIR/source.json"

echo "container runtime artifact ready: $ARTIFACT_DIR"
echo "  disk:     $ARTIFACT_DIR/disk.raw"
echo "  metadata: $ARTIFACT_DIR/metadata.json"
echo "  source:   $ARTIFACT_DIR/source.json"
