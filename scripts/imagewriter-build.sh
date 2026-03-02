#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
MSL_BIN="${MSL_BIN:-$ROOT_DIR/.build/debug/msl}"
INSTANCE="${IMAGEWRITER_INSTANCE:-_imagewriter}"
IMAGE_FS="${IMAGE_FS:-btrfs}"
FORCE_SETUP="${IMAGEWRITER_FORCE_SETUP:-0}"
ROOTFS_TARBALL="${ROOTFS_TARBALL:-}"
INIT_BINARY_PATH="${IMAGEWRITER_INIT_BINARY:-}"
RUN_TIMEOUT="${IMAGEWRITER_RUN_TIMEOUT:-900}"

TOTAL_STEPS=5
STEP_INDEX=0

progress_step() {
  STEP_INDEX=$((STEP_INDEX + 1))
  percent=$((STEP_INDEX * 100 / TOTAL_STEPS))
  filled=$((percent / 5))
  bar=""
  i=0
  while [ "$i" -lt 20 ]; do
    if [ "$i" -lt "$filled" ]; then
      bar="${bar}#"
    else
      bar="${bar}-"
    fi
    i=$((i + 1))
  done
  echo "imagewriter progress: [${bar}] ${percent}% - $1"
}

if [ ! -x "$MSL_BIN" ]; then
  echo "msl binary not found at $MSL_BIN; building..."
  (cd "$ROOT_DIR" && swift build)
fi

ensure_virtualization_entitlement() {
  if [ "$(uname -s)" != "Darwin" ]; then
    return 0
  fi
  if ! command -v codesign >/dev/null 2>&1; then
    return 0
  fi
  if codesign -d --entitlements :- "$MSL_BIN" 2>/dev/null | grep -q "<key>com.apple.security.virtualization</key>"; then
    return 0
  fi
  if [ -x "$ROOT_DIR/scripts/build-signed.sh" ]; then
    echo "msl binary is missing virtualization entitlement; running build-signed..."
    "$ROOT_DIR/scripts/build-signed.sh"
  fi
  if ! codesign -d --entitlements :- "$MSL_BIN" 2>/dev/null | grep -q "<key>com.apple.security.virtualization</key>"; then
    echo "error: msl binary is missing virtualization entitlement. run ./scripts/build-signed.sh" >&2
    exit 1
  fi
}

ensure_virtualization_entitlement

instance_exists() {
  "$MSL_BIN" --list 2>/dev/null | sed -e 's/ \[default\]$//' | awk '{print $1}' | grep -Fx "$INSTANCE" >/dev/null 2>&1
}

if [ "$FORCE_SETUP" = "1" ] || ! instance_exists; then
  echo "running imagewriter setup..."
  "$SCRIPT_DIR/imagewriter-setup.sh"
else
  echo "skipping imagewriter setup (instance exists): $INSTANCE"
fi

if [ -n "${MSL_HOME:-}" ]; then
  APP_SUPPORT="${MSL_HOME}/Library/Application Support/msl"
else
  APP_SUPPORT="${HOME}/Library/Application Support/msl"
fi

resolve_share_root() {
  if [ -n "${MSL_HOST_SHARE_ROOT:-}" ]; then
    printf '%s\n' "$MSL_HOST_SHARE_ROOT"
    return 0
  fi
  cfg="$APP_SUPPORT/config.json"
  if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
    root="$(jq -r '.workspaceHostShareRoot // empty' "$cfg" 2>/dev/null || true)"
    if [ -n "$root" ] && [ "$root" != "null" ]; then
      printf '%s\n' "$root"
      return 0
    fi
  fi
  printf '%s\n' "$HOME"
}

host_to_guest_path() {
  host_path="$1"
  share_root="$2"
  case "$host_path" in
    "$share_root")
      printf '/mnt/macos\n'
      ;;
    "$share_root"/*)
      suffix="${host_path#"$share_root"}"
      printf '/mnt/macos%s\n' "$suffix"
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_default_alpine_tarball() {
  base="$APP_SUPPORT/caches/rootfs/alpine"
  if [ ! -d "$base" ]; then
    base="$APP_SUPPORT/cache/downloads/alpine"
    if [ ! -d "$base" ]; then
      return 1
    fi
  fi

  best=""
  best_mtime=0
  while IFS= read -r line; do
    mtime="${line%% *}"
    path="${line#* }"
    if [ "$mtime" -gt "$best_mtime" ] 2>/dev/null; then
      best_mtime="$mtime"
      best="$path"
    fi
  done <<EOF_CANDIDATES
$(find "$base" -type f -name 'alpine-minirootfs-*-aarch64.tar.gz' -exec stat -f '%m %N' {} \; 2>/dev/null)
EOF_CANDIDATES

  if [ -n "$best" ]; then
    printf '%s\n' "$best"
    return 0
  fi
  return 1
}

if [ -n "$ROOTFS_TARBALL" ]; then
  echo "using provided rootfs: $ROOTFS_TARBALL"
else
  if ROOTFS_TARBALL="$(resolve_default_alpine_tarball)"; then
    echo "using alpine cached rootfs: $ROOTFS_TARBALL"
  else
    echo "alpine cached rootfs not found, fetching into cache..."
    "$MSL_BIN" cache fetch alpine >/dev/null
    if ROOTFS_TARBALL="$(resolve_default_alpine_tarball)"; then
      echo "using fetched alpine cached rootfs: $ROOTFS_TARBALL"
    else
      echo "error: alpine rootfs fetch completed but cache tarball was not found." >&2
      echo "expected under: $APP_SUPPORT/caches/rootfs/alpine/<version>/aarch64/" >&2
      exit 1
    fi
  fi
fi

if [ ! -f "$ROOTFS_TARBALL" ]; then
  echo "error: ROOTFS_TARBALL not found: $ROOTFS_TARBALL" >&2
  exit 1
fi
if [ -n "$INIT_BINARY_PATH" ] && [ ! -f "$INIT_BINARY_PATH" ]; then
  echo "error: IMAGEWRITER_INIT_BINARY not found: $INIT_BINARY_PATH" >&2
  exit 1
fi

case "$IMAGE_FS" in
  btrfs|ext4) ;;
  *)
    echo "error: IMAGE_FS must be btrfs or ext4" >&2
    exit 1
    ;;
esac

OUTPUT_RAW="${OUTPUT_RAW:-$APP_SUPPORT/images/imagewriter-${IMAGE_FS}.raw}"
IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-0}"

SHARE_ROOT="$(resolve_share_root)"
case "$SHARE_ROOT" in
  /*) ;;
  *)
    echo "error: resolved host share root is not absolute: $SHARE_ROOT" >&2
    exit 1
    ;;
esac

STAGE_ROOT="$SHARE_ROOT/.msl-imagewriter"
STAGE_IN_DIR="$STAGE_ROOT/in"
STAGE_OUT_DIR="$STAGE_ROOT/out"
mkdir -p "$STAGE_IN_DIR" "$STAGE_OUT_DIR" "$(dirname "$OUTPUT_RAW")"

STAGE_ROOTFS="$STAGE_IN_DIR/$(basename "$ROOTFS_TARBALL")"
STAGE_OUTPUT="$STAGE_OUT_DIR/imagewriter-${IMAGE_FS}.raw"
STAGE_INIT=""
progress_step "preparing staging area"
cp -f "$ROOTFS_TARBALL" "$STAGE_ROOTFS"
rm -f "$STAGE_OUTPUT"
if [ -n "$INIT_BINARY_PATH" ]; then
  STAGE_INIT="$STAGE_IN_DIR/$(basename "$INIT_BINARY_PATH")"
  cp -f "$INIT_BINARY_PATH" "$STAGE_INIT"
fi
progress_step "staged rootfs/init artifacts"

if ! GUEST_ROOTFS="$(host_to_guest_path "$STAGE_ROOTFS" "$SHARE_ROOT")"; then
  echo "error: staging rootfs path is outside host share root: $STAGE_ROOTFS (share_root=$SHARE_ROOT)" >&2
  exit 1
fi
if ! GUEST_OUTPUT="$(host_to_guest_path "$STAGE_OUTPUT" "$SHARE_ROOT")"; then
  echo "error: staging output path is outside host share root: $STAGE_OUTPUT (share_root=$SHARE_ROOT)" >&2
  exit 1
fi
GUEST_INIT=""
if [ -n "$STAGE_INIT" ]; then
  if ! GUEST_INIT="$(host_to_guest_path "$STAGE_INIT" "$SHARE_ROOT")"; then
    echo "error: staging init path is outside host share root: $STAGE_INIT (share_root=$SHARE_ROOT)" >&2
    exit 1
  fi
fi

HOST_WORKER="$ROOT_DIR/scripts/imagewriter-build-guest.sh"
if [ ! -f "$HOST_WORKER" ]; then
  echo "error: host worker script not found: $HOST_WORKER" >&2
  exit 1
fi
WORKER_B64="$(base64 < "$HOST_WORKER" | tr -d '\n')"

run_guest_worker() {
MSL_RUNTIME_USER_ROOT=1 "$MSL_BIN" --instance "$INSTANCE" run --timeout "$RUN_TIMEOUT" sh -lc '
set -eu
worker_b64="$1"
rootfs="$2"
output="$3"
fs_type="$4"
size_mb="$5"
init_bin="$6"
worker="/tmp/msl-imagewriter-build-guest.sh"
local_output="/tmp/msl-imagewriter-output.raw"

if ! command -v base64 >/dev/null 2>&1; then
  echo "error: base64 command is required in guest" >&2
  exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "error: imagewriter build requires root runtime user. ensure MSL_RUNTIME_USER_ROOT=1 is applied." >&2
  exit 1
fi

printf "%s" "$worker_b64" | base64 -d > "$worker"
chmod 0700 "$worker"
rm -f "$local_output"
sh "$worker" "$rootfs" "$local_output" "$fs_type" "$size_mb" "$init_bin"
cp -f "$local_output" "$output"
sync
rm -f "$local_output"
' sh "$WORKER_B64" "$GUEST_ROOTFS" "$GUEST_OUTPUT" "$IMAGE_FS" "$IMAGE_SIZE_MB" "$GUEST_INIT"
}

if ! run_guest_worker; then
  echo "imagewriter: first guest run failed; stopping active VM and retrying once..." >&2
  "$MSL_BIN" --stop >/dev/null 2>&1 || true
  run_guest_worker
fi
progress_step "guest image build completed"

mv -f "$STAGE_OUTPUT" "$OUTPUT_RAW"
progress_step "moved built image to output path"

echo "imagewriter build completed"
echo "instance: $INSTANCE"
echo "fs: $IMAGE_FS"
echo "rootfs: $ROOTFS_TARBALL"
echo "output: $OUTPUT_RAW"
progress_step "done"
