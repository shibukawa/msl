#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
  print -u2 -- "error: $1"
  exit 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "required command not found: $1"
  fi
}

require_command rsync

if [[ -n "${KERNEL_ID:-}" && -z "${KERNEL_PROFILE:-}" ]]; then
  KERNEL_PROFILE="$KERNEL_ID"
  print -u2 -- "warning: KERNEL_ID is deprecated; use KERNEL_PROFILE. mapped KERNEL_PROFILE=$KERNEL_PROFILE"
fi

KERNEL_PROFILE="${KERNEL_PROFILE:-slim}"
if [[ ! "$KERNEL_PROFILE" =~ '^[A-Za-z0-9._-]+$' ]]; then
  fail "KERNEL_PROFILE may contain only [A-Za-z0-9._-]"
fi

MSL_HOME_DIR="${MSL_HOME:-$HOME}"
SOURCE_DIR="$MSL_HOME_DIR/Library/Application Support/msl/kernels/$KERNEL_PROFILE"
STAGE_DIR="$ROOT_DIR/tmp/distribution-kernel/$KERNEL_PROFILE"
LOG_FILE="$STAGE_DIR/stage.log"

if [[ ! -d "$SOURCE_DIR" ]]; then
  fail "kernel artifact directory not found: $SOURCE_DIR"
fi

for required in vmlinuz metadata.json capabilities.json; do
  if [[ ! -e "$SOURCE_DIR/$required" ]]; then
    fail "missing required artifact: $SOURCE_DIR/$required"
  fi
done

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

print -- "[stage] source: $SOURCE_DIR"
print -- "[stage] target: $STAGE_DIR"

cp "$SOURCE_DIR/vmlinuz" "$STAGE_DIR/vmlinuz"
cp "$SOURCE_DIR/metadata.json" "$STAGE_DIR/metadata.json"
cp "$SOURCE_DIR/capabilities.json" "$STAGE_DIR/capabilities.json"

if [[ -f "$SOURCE_DIR/kernel.config" ]]; then
  cp "$SOURCE_DIR/kernel.config" "$STAGE_DIR/kernel.config"
fi

if [[ -f "$SOURCE_DIR/initrd.img" ]]; then
  cp "$SOURCE_DIR/initrd.img" "$STAGE_DIR/initrd.img"
fi

if [[ -d "$SOURCE_DIR/modules" ]]; then
  mkdir -p "$STAGE_DIR/modules"
  rsync -a --delete "$SOURCE_DIR/modules/" "$STAGE_DIR/modules/"
else
  print -- "[stage] modules/ not present (allowed for minimal profile)"
fi

print -- "[stage] staged artifacts:"
find "$STAGE_DIR" -mindepth 1 -maxdepth 3 | sed "s|$STAGE_DIR|.|"

print -- "[done] staged kernel artifacts at $STAGE_DIR"
