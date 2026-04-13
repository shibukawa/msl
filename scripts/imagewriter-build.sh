#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
MSL_BIN="${MSL_BIN:-$ROOT_DIR/.build/debug/msl}"
INSTANCE="${IMAGEWRITER_INSTANCE:-_imagewriter}"
IMAGE_FS="${IMAGE_FS:-btrfs}"
FORCE_SETUP="${IMAGEWRITER_FORCE_SETUP:-0}"
ROOTFS_TARBALL="${ROOTFS_TARBALL:-}"
ROOTFS_DIR="${ROOTFS_DIR:-}"
INIT_BINARY_PATH="${IMAGEWRITER_INIT_BINARY:-}"
RUN_TIMEOUT="${IMAGEWRITER_RUN_TIMEOUT:-900}"
IMAGEWRITER_PACKAGES="${IMAGEWRITER_PACKAGES:-btrfs-progs e2fsprogs erofs-utils util-linux tar zstd xz coreutils}"
IMAGEWRITER_APK_CACHE_DIR="${IMAGEWRITER_APK_CACHE_DIR:-}"
IMAGEWRITER_APK_RETRY_LIMIT="${IMAGEWRITER_APK_RETRY_LIMIT:-5}"

TOTAL_STEPS=7
STEP_INDEX=0
STOP_ATTEMPTED=0

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

mark_stage_start() {
  stage_name="$1"
  input_path="$2"
  output_path="$3"
  echo "imagewriter_stage_start stage=${stage_name} input=${input_path} output=${output_path}"
}

mark_stage_complete() {
  stage_name="$1"
  echo "imagewriter_stage_complete stage=${stage_name}"
}

mark_stage_failed() {
  stage_name="$1"
  stage_code="$2"
  echo "imagewriter_stage_failed stage=${stage_name} exit_code=${stage_code}" >&2
}

stop_imagewriter_runtime() {
  if [ "$STOP_ATTEMPTED" -eq 1 ]; then
    return
  fi
  STOP_ATTEMPTED=1

  echo "imagewriter_runtime_stop_attempted instance=$INSTANCE"
  if "$MSL_BIN" --instance "$INSTANCE" stop >/dev/null 2>&1; then
    echo "imagewriter_runtime_stop_succeeded instance=$INSTANCE"
  else
    stop_code=$?
    if [ "$stop_code" -eq 64 ]; then
      echo "imagewriter_runtime_stop_skipped instance=$INSTANCE reason=not_running"
    else
      echo "imagewriter_runtime_stop_failed instance=$INSTANCE exit_code=$stop_code" >&2
    fi
  fi
}

trap '
script_exit=$?
if [ -n "${STAGE_TMP_IMAGE:-}" ]; then
  rm -f "$STAGE_TMP_IMAGE" >/dev/null 2>&1 || true
fi
stop_imagewriter_runtime
exit "$script_exit"
' EXIT

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

resolve_app_support() {
  if [ -n "${MSL_HOME:-}" ]; then
    printf '%s\n' "${MSL_HOME}/Library/Application Support/msl"
  else
    printf '%s\n' "${HOME}/Library/Application Support/msl"
  fi
}

APP_SUPPORT="$(resolve_app_support)"
ALLOW_SETUP_WHEN_MISSING="${IMAGEWRITER_ALLOW_SETUP_WHEN_MISSING:-1}"
REQUIRED_IMAGEWRITER_FS="${IMAGEWRITER_REQUIRED_FS:-}"

instance_disk_path() {
  printf '%s\n' "$APP_SUPPORT/distros/$INSTANCE/disk.raw"
}

instance_exists() {
  [ -f "$(instance_disk_path)" ]
}

if [ "$FORCE_SETUP" = "1" ]; then
  echo "running imagewriter setup..."
  "$SCRIPT_DIR/imagewriter-setup.sh"
elif ! instance_exists; then
  if [ "$ALLOW_SETUP_WHEN_MISSING" = "1" ]; then
    echo "running imagewriter setup..."
    "$SCRIPT_DIR/imagewriter-setup.sh"
  else
    echo "error: required imagewriter instance is missing: $INSTANCE" >&2
    echo "hint: run 'make build-imagewriter' or 'make imagewriter-setup && make build-imagewriter' first." >&2
    exit 25
  fi
else
  echo "skipping imagewriter setup (instance exists): $INSTANCE"
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

detect_image_fs_type() {
  image_path="$1"
  if [ ! -f "$image_path" ]; then
    echo ""
    return 1
  fi
  if command -v file >/dev/null 2>&1; then
    file_desc="$(file -b "$image_path" 2>/dev/null || true)"
    case "$file_desc" in
      *BTRFS*|*btrfs*)
        printf 'btrfs\n'
        return 0
        ;;
      *EROFS*|*erofs*)
        printf 'erofs\n'
        return 0
        ;;
      *ext4*)
        printf 'ext4\n'
        return 0
        ;;
    esac
  fi
  echo ""
  return 1
}

verify_expected_fs_type() {
  image_path="$1"
  expected_fs="$2"
  verify_context="$3"

  actual_fs="$(detect_image_fs_type "$image_path" || true)"
  if [ -z "$actual_fs" ]; then
    echo "error: could not determine filesystem type for $verify_context: $image_path" >&2
    exit 24
  fi
  if [ "$actual_fs" != "$expected_fs" ]; then
    echo "error: filesystem mismatch for $verify_context: expected=$expected_fs actual=$actual_fs path=$image_path" >&2
    exit 24
  fi
  echo "imagewriter_verified_fs context=$verify_context fs=$actual_fs path=$image_path"
}

verify_guest_visible_fs_type() {
  guest_path="$1"
  expected_fs="$2"
  verify_context="$3"

  if [ -z "$guest_path" ]; then
    echo "error: guest-visible path is required for $verify_context verification" >&2
    exit 24
  fi

  MSL_RUNTIME_USER_ROOT=1 "$MSL_BIN" --instance "$INSTANCE" run --timeout "$RUN_TIMEOUT" -- sh -lc '
set -eu
path="$1"
expected="$2"
context="$3"
actual=""
if command -v blkid >/dev/null 2>&1; then
  actual="$(blkid -p -s TYPE -o value "$path" 2>/dev/null || true)"
fi
if [ -z "$actual" ] && command -v file >/dev/null 2>&1; then
  file_desc="$(file -b "$path" 2>/dev/null || true)"
  case "$file_desc" in
    *BTRFS*|*btrfs*) actual="btrfs" ;;
    *EROFS*|*erofs*) actual="erofs" ;;
    *ext4*) actual="ext4" ;;
  esac
fi
if [ -z "$actual" ]; then
  echo "error: could not determine guest-visible filesystem type for $context: $path" >&2
  exit 24
fi
if [ "$actual" != "$expected" ]; then
  echo "error: guest-visible filesystem mismatch for $context: expected=$expected actual=$actual path=$path" >&2
  exit 24
fi
echo "imagewriter_verified_fs context=$context fs=$actual path=$path source=guest"
' sh "$guest_path" "$expected_fs" "$verify_context"
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

if [ -n "$ROOTFS_TARBALL" ] && [ -n "$ROOTFS_DIR" ]; then
  echo "error: specify only one of ROOTFS_TARBALL or ROOTFS_DIR" >&2
  exit 1
fi

if [ -n "$ROOTFS_DIR" ]; then
  echo "using provided rootfs directory: $ROOTFS_DIR"
elif [ -n "$ROOTFS_TARBALL" ]; then
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

if [ -n "$ROOTFS_TARBALL" ] && [ ! -f "$ROOTFS_TARBALL" ]; then
  echo "error: ROOTFS_TARBALL not found: $ROOTFS_TARBALL" >&2
  exit 1
fi
if [ -n "$ROOTFS_DIR" ] && [ ! -d "$ROOTFS_DIR" ]; then
  echo "error: ROOTFS_DIR not found: $ROOTFS_DIR" >&2
  exit 1
fi
if [ -n "$INIT_BINARY_PATH" ] && [ ! -f "$INIT_BINARY_PATH" ]; then
  echo "error: IMAGEWRITER_INIT_BINARY not found: $INIT_BINARY_PATH" >&2
  exit 1
fi

case "$IMAGE_FS" in
  btrfs|ext4|erofs) ;;
  *)
    echo "error: IMAGE_FS must be btrfs, erofs, or ext4" >&2
    exit 1
    ;;
esac

OUTPUT_RAW="${OUTPUT_RAW:-$APP_SUPPORT/images/imagewriter-${IMAGE_FS}.raw}"
IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-}"
TWO_STAGE_IMAGEWRITER=0

case "$OUTPUT_RAW" in
  */distros/_imagewriter/disk.raw)
    if [ "$IMAGE_FS" != "ext4" ]; then
      TWO_STAGE_IMAGEWRITER=1
    fi
    ;;
esac

if [ "$TWO_STAGE_IMAGEWRITER" -eq 1 ] && [ -z "$INIT_BINARY_PATH" ]; then
  echo "error: IMAGEWRITER_INIT_BINARY is required for _imagewriter disk builds (missing /sbin/msl-init-bootloader risk)." >&2
  echo "hint: export MSL_INIT_BOOTLOADER_BINARY_PATH or run ./scripts/build-msl-init.sh, then re-run make build-imagewriter." >&2
  exit 1
fi

if [ -z "$IMAGE_SIZE_MB" ]; then
  echo "error: IMAGE_SIZE_MB is required; msl install must pass an explicit size." >&2
  exit 1
fi

if [ "$IMAGE_FS" = "ext4" ] || [ "$TWO_STAGE_IMAGEWRITER" -eq 0 ]; then
  TOTAL_STEPS=5
else
  TOTAL_STEPS=7
fi

SHARE_ROOT="$(resolve_share_root)"
case "$SHARE_ROOT" in
  /*) ;;
  *)
    echo "error: resolved host share root is not absolute: $SHARE_ROOT" >&2
    exit 1
    ;;
esac

GUEST_FINAL_OUTPUT=""
if GUEST_FINAL_OUTPUT_RESOLVED="$(host_to_guest_path "$OUTPUT_RAW" "$SHARE_ROOT" 2>/dev/null)"; then
  GUEST_FINAL_OUTPUT="$GUEST_FINAL_OUTPUT_RESOLVED"
fi

if [ "$FORCE_SETUP" != "1" ] && [ -n "$REQUIRED_IMAGEWRITER_FS" ]; then
  IMAGEWRITER_DISK="$(instance_disk_path)"
  if [ ! -f "$IMAGEWRITER_DISK" ]; then
    echo "error: required imagewriter disk is missing: $IMAGEWRITER_DISK" >&2
    exit 25
  fi
  imagewriter_disk_fs="$(detect_image_fs_type "$IMAGEWRITER_DISK" || true)"
  if [ -n "$imagewriter_disk_fs" ]; then
    if [ "$imagewriter_disk_fs" != "$REQUIRED_IMAGEWRITER_FS" ]; then
      echo "error: imagewriter instance filesystem mismatch: expected=$REQUIRED_IMAGEWRITER_FS actual=$imagewriter_disk_fs path=$IMAGEWRITER_DISK" >&2
      exit 24
    fi
    echo "imagewriter_verified_fs context=imagewriter_instance fs=$imagewriter_disk_fs path=$IMAGEWRITER_DISK source=host"
  else
    GUEST_IMAGEWRITER_DISK=""
    if GUEST_IMAGEWRITER_DISK_RESOLVED="$(host_to_guest_path "$IMAGEWRITER_DISK" "$SHARE_ROOT" 2>/dev/null)"; then
      GUEST_IMAGEWRITER_DISK="$GUEST_IMAGEWRITER_DISK_RESOLVED"
    fi
    if [ -z "$GUEST_IMAGEWRITER_DISK" ]; then
      echo "error: could not resolve guest-visible path for imagewriter disk: $IMAGEWRITER_DISK" >&2
      exit 24
    fi
    verify_guest_visible_fs_type "$GUEST_IMAGEWRITER_DISK" "$REQUIRED_IMAGEWRITER_FS" "imagewriter_instance"
  fi
fi

STAGE_ROOT="$SHARE_ROOT/.msl-imagewriter"
STAGE_IN_DIR="$STAGE_ROOT/in"
STAGE_OUT_DIR="$STAGE_ROOT/out"
STAGE_TMP_DIR="$STAGE_ROOT/tmp"
mkdir -p "$STAGE_IN_DIR" "$STAGE_OUT_DIR" "$STAGE_TMP_DIR" "$(dirname "$OUTPUT_RAW")"

HOST_APK_CACHE="$IMAGEWRITER_APK_CACHE_DIR"
if [ -z "$HOST_APK_CACHE" ]; then
  HOST_APK_CACHE="$APP_SUPPORT/caches/apk/cache"
fi
if ! mkdir -p "$HOST_APK_CACHE" 2>/dev/null; then
  HOST_APK_CACHE="$STAGE_ROOT/apk-cache"
  mkdir -p "$HOST_APK_CACHE"
fi
if ! GUEST_APK_CACHE="$(host_to_guest_path "$HOST_APK_CACHE" "$SHARE_ROOT")"; then
  HOST_APK_CACHE="$STAGE_ROOT/apk-cache"
  mkdir -p "$HOST_APK_CACHE"
  if ! GUEST_APK_CACHE="$(host_to_guest_path "$HOST_APK_CACHE" "$SHARE_ROOT")"; then
    echo "error: apk cache path is outside host share root: $HOST_APK_CACHE (share_root=$SHARE_ROOT)" >&2
    exit 1
  fi
fi

STAGE_ROOTFS=""
STAGE_ROOTFS_DIR=""
if [ -n "$ROOTFS_TARBALL" ]; then
  STAGE_ROOTFS="$STAGE_IN_DIR/$(basename "$ROOTFS_TARBALL")"
else
  STAGE_ROOTFS_DIR="$STAGE_IN_DIR/rootfs-dir"
fi
STAGE_OUTPUT="$STAGE_OUT_DIR/imagewriter-${IMAGE_FS}.raw"
STAGE1_OUTPUT="$STAGE_OUT_DIR/stage1-ext4.raw"
STAGE2_OUTPUT="$STAGE_OUT_DIR/stage2-${IMAGE_FS}.raw"
STAGE_TMP_IMAGE="$STAGE_TMP_DIR/guest-tmp-work.raw"
STAGE_INIT=""
progress_step "preparing staging area"
copy_if_needed() {
  src="$1"
  dst="$2"
  if [ "$src" = "$dst" ]; then
    return 0
  fi
  if [ -e "$dst" ]; then
    if [ "$src" -ef "$dst" ] 2>/dev/null; then
      return 0
    fi
  fi
  if cp --help 2>/dev/null | grep -q -- '--sparse'; then
    cp --sparse=always -f "$src" "$dst"
  else
    cp -f "$src" "$dst"
  fi
}

if [ -n "$ROOTFS_TARBALL" ]; then
  copy_if_needed "$ROOTFS_TARBALL" "$STAGE_ROOTFS"
else
  rm -rf "$STAGE_ROOTFS_DIR"
  mkdir -p "$STAGE_ROOTFS_DIR"
  cp -R "$ROOTFS_DIR"/. "$STAGE_ROOTFS_DIR"/
fi
rm -f "$STAGE_OUTPUT" "$STAGE1_OUTPUT" "$STAGE2_OUTPUT" "$STAGE_TMP_IMAGE"
if [ -n "$INIT_BINARY_PATH" ]; then
  STAGE_INIT="$STAGE_IN_DIR/$(basename "$INIT_BINARY_PATH")"
  copy_if_needed "$INIT_BINARY_PATH" "$STAGE_INIT"
fi
progress_step "staged rootfs/init artifacts"

ROOTFS_INPUT_PATH="$STAGE_ROOTFS"
if [ -n "$STAGE_ROOTFS_DIR" ]; then
  ROOTFS_INPUT_PATH="$STAGE_ROOTFS_DIR"
fi
if ! GUEST_ROOTFS="$(host_to_guest_path "$ROOTFS_INPUT_PATH" "$SHARE_ROOT")"; then
  echo "error: staging rootfs path is outside host share root: $ROOTFS_INPUT_PATH (share_root=$SHARE_ROOT)" >&2
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
mode="$1"
guest_input="$2"
guest_output="$3"
fs_type="$4"
size_mb="$5"
guest_init="$6"
packages="$7"
apk_cache="$8"
apk_retry_limit="$9"
guest_tmp_image="${10}"

MSL_RUNTIME_USER_ROOT=1 "$MSL_BIN" --instance "$INSTANCE" run --timeout "$RUN_TIMEOUT" -- sh -lc '
set -eu
worker_b64="$1"
mode="$2"
input_path="$3"
output="$4"
fs_type="$5"
size_mb="$6"
init_bin="$7"
packages="$8"
apk_cache="$9"
tmp_image="${10}"
apk_retry_limit="${11}"
tmp_mount="/mnt/msl-imagewriter-tmp"
tmp_work_dir="$tmp_mount/work"
worker="$tmp_mount/msl-imagewriter-build-guest.sh"
local_output="$tmp_mount/msl-imagewriter-output.raw"
tmp_image_mb=8192
tmp_image_min_mb=4096
tmp_image_overhead_mb=4096

if ! command -v base64 >/dev/null 2>&1; then
  echo "error: base64 command is required in guest" >&2
  exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "error: imagewriter build requires root runtime user. ensure MSL_RUNTIME_USER_ROOT=1 is applied." >&2
  exit 1
fi

report_file_allocation() {
  label="$1"
  path="$2"
  if [ ! -f "$path" ]; then
    echo "imagewriter_file_alloc mode=$mode label=$label path=$path status=missing"
    return 0
  fi
  stat_line="$(stat -c "blocks=%b size=%s blksize=%o" "$path" 2>/dev/null || true)"
  du_kib="$(du -sk "$path" 2>/dev/null | cut -f1 || true)"
  if [ -z "$du_kib" ]; then
    du_kib=0
  fi
  echo "imagewriter_file_alloc mode=$mode label=$label path=$path $stat_line du_kib=$du_kib"
}

compact_sparse_file() {
  path="$1"
  if [ ! -f "$path" ]; then
    return 0
  fi
  if ! command -v fallocate >/dev/null 2>&1; then
    echo "imagewriter_file_compact_skipped mode=$mode path=$path reason=fallocate_missing"
    return 0
  fi
  if fallocate -d "$path" >/dev/null 2>&1; then
    echo "imagewriter_file_compacted mode=$mode path=$path method=fallocate_d"
  else
    echo "imagewriter_file_compact_skipped mode=$mode path=$path reason=fallocate_failed"
  fi
}

cleanup_guest_artifacts() {
  sync >/dev/null 2>&1 || true
  if grep -qs " $tmp_mount " /proc/mounts; then
    umount "$tmp_mount" >/dev/null 2>&1 || true
  fi
  if rm -f "$tmp_image" >/dev/null 2>&1; then
    echo "tmp_reset_succeeded context=imagewriter_tmp path=$tmp_image"
  else
    echo "tmp_reset_failed context=imagewriter_tmp path=$tmp_image" >&2
  fi
  rmdir "$tmp_mount" >/dev/null 2>&1 || true
  sync >/dev/null 2>&1 || true
  fstrim -v / >/dev/null 2>&1 || true
}
trap cleanup_guest_artifacts EXIT INT TERM

if [ -z "$tmp_image" ]; then
  echo "error: temporary work image path is empty" >&2
  exit 1
fi
case "$size_mb" in
  ""|*[!0-9]*)
    tmp_image_mb=$((tmp_image_min_mb + tmp_image_overhead_mb))
    ;;
  *)
    if [ "$size_mb" -gt 0 ]; then
      tmp_image_mb=$((size_mb + tmp_image_overhead_mb))
    else
      tmp_image_mb=$((tmp_image_min_mb + tmp_image_overhead_mb))
    fi
    ;;
esac
if [ "$tmp_image_mb" -lt "$tmp_image_min_mb" ]; then
  tmp_image_mb="$tmp_image_min_mb"
fi
echo "imagewriter_guest_tmp_image_mb=$tmp_image_mb mode=$mode size_mb=$size_mb"
mkdir -p "$(dirname "$tmp_image")"
rm -f "$tmp_image"
truncate -s "${tmp_image_mb}M" "$tmp_image"
mkfs.ext4 -q -F -E lazy_itable_init=1,lazy_journal_init=1 "$tmp_image"
echo "tmp_image_created context=imagewriter_tmp path=$tmp_image size_mib=$tmp_image_mb"
mkdir -p "$tmp_mount"
mount -o loop "$tmp_image" "$tmp_mount"
mkdir -p "$tmp_work_dir"

printf "%s" "$worker_b64" | base64 -d > "$worker"
chmod 0700 "$worker"
rm -f "$local_output"
case "$mode" in
  stage1)
    if [ -n "$init_bin" ]; then
      if [ -d "$input_path" ]; then
        MSL_IMAGEWRITER_WORK_DIR="$tmp_work_dir" sh "$worker" --mode stage1 --rootfs-dir "$input_path" --output "$local_output" --size-mb "$size_mb" --init-binary "$init_bin" --packages "$packages" --apk-cache-dir "$apk_cache" --retry-limit "$apk_retry_limit"
      else
        MSL_IMAGEWRITER_WORK_DIR="$tmp_work_dir" sh "$worker" --mode stage1 --rootfs "$input_path" --output "$local_output" --size-mb "$size_mb" --init-binary "$init_bin" --packages "$packages" --apk-cache-dir "$apk_cache" --retry-limit "$apk_retry_limit"
      fi
    else
      if [ -d "$input_path" ]; then
        MSL_IMAGEWRITER_WORK_DIR="$tmp_work_dir" sh "$worker" --mode stage1 --rootfs-dir "$input_path" --output "$local_output" --size-mb "$size_mb" --packages "$packages" --apk-cache-dir "$apk_cache" --retry-limit "$apk_retry_limit"
      else
        MSL_IMAGEWRITER_WORK_DIR="$tmp_work_dir" sh "$worker" --mode stage1 --rootfs "$input_path" --output "$local_output" --size-mb "$size_mb" --packages "$packages" --apk-cache-dir "$apk_cache" --retry-limit "$apk_retry_limit"
      fi
    fi
    ;;
  stage2)
    if [ -n "$init_bin" ]; then
      if [ -d "$input_path" ]; then
        MSL_IMAGEWRITER_WORK_DIR="$tmp_work_dir" sh "$worker" --mode stage2 --fs-type "$fs_type" --rootfs-dir "$input_path" --output "$local_output" --size-mb "$size_mb" --init-binary "$init_bin" --packages "$packages" --apk-cache-dir "$apk_cache" --retry-limit "$apk_retry_limit"
      else
        MSL_IMAGEWRITER_WORK_DIR="$tmp_work_dir" sh "$worker" --mode stage2 --fs-type "$fs_type" --rootfs "$input_path" --output "$local_output" --size-mb "$size_mb" --init-binary "$init_bin" --packages "$packages" --apk-cache-dir "$apk_cache" --retry-limit "$apk_retry_limit"
      fi
    else
      if [ -d "$input_path" ]; then
        MSL_IMAGEWRITER_WORK_DIR="$tmp_work_dir" sh "$worker" --mode stage2 --fs-type "$fs_type" --rootfs-dir "$input_path" --output "$local_output" --size-mb "$size_mb" --packages "$packages" --apk-cache-dir "$apk_cache" --retry-limit "$apk_retry_limit"
      else
        MSL_IMAGEWRITER_WORK_DIR="$tmp_work_dir" sh "$worker" --mode stage2 --fs-type "$fs_type" --rootfs "$input_path" --output "$local_output" --size-mb "$size_mb" --packages "$packages" --apk-cache-dir "$apk_cache" --retry-limit "$apk_retry_limit"
      fi
    fi
    ;;
  legacy)
    MSL_IMAGEWRITER_WORK_DIR="$tmp_work_dir" sh "$worker" "$input_path" "$local_output" "$fs_type" "$size_mb" "$init_bin"
    ;;
  *)
    echo "error: unknown worker mode: $mode" >&2
    exit 1
    ;;
esac
report_file_allocation "guest_local_output_before_compact" "$local_output"
compact_sparse_file "$local_output"
report_file_allocation "guest_local_output" "$local_output"
if cp --help 2>/dev/null | grep -q -- '--sparse'; then
  cp --sparse=always -f "$local_output" "$output"
else
  cp -f "$local_output" "$output"
fi
report_file_allocation "guest_shared_output" "$output"
shared_output_fs="$(blkid -p -s TYPE -o value "$output" 2>/dev/null || true)"
if [ -z "$shared_output_fs" ] && command -v file >/dev/null 2>&1; then
  shared_output_desc="$(file -b "$output" 2>/dev/null || true)"
  case "$shared_output_desc" in
    *BTRFS*|*btrfs*) shared_output_fs="btrfs" ;;
    *EROFS*|*erofs*) shared_output_fs="erofs" ;;
    *ext4*) shared_output_fs="ext4" ;;
  esac
fi
if [ -z "$shared_output_fs" ]; then
  echo "error: could not determine shared output filesystem type: $output" >&2
  exit 24
fi
if [ "$shared_output_fs" != "$fs_type" ]; then
  echo "error: shared output filesystem mismatch: expected=$fs_type actual=$shared_output_fs output=$output" >&2
  exit 24
fi
echo "imagewriter_guest_verified_shared_output mode=$mode fs=$shared_output_fs output=$output"
sync
cleanup_guest_artifacts
trap - EXIT INT TERM
' sh "$WORKER_B64" "$mode" "$guest_input" "$guest_output" "$fs_type" "$size_mb" "$guest_init" "$packages" "$apk_cache" "$guest_tmp_image" "$apk_retry_limit"
}

run_guest_worker_with_retry() {
  mode="$1"
  guest_input="$2"
  guest_output="$3"
  fs_type="$4"
  size_mb="$5"
  guest_init="$6"
  packages="$7"
  apk_cache="$8"

  if run_guest_worker "$mode" "$guest_input" "$guest_output" "$fs_type" "$size_mb" "$guest_init" "$packages" "$apk_cache" "$IMAGEWRITER_APK_RETRY_LIMIT" "$GUEST_TMP_IMAGE"; then
    return 0
  fi

  echo "imagewriter: first guest run failed for mode=$mode; stopping instance and retrying once..." >&2
  "$MSL_BIN" --instance "$INSTANCE" stop >/dev/null 2>&1 || true
  run_guest_worker "$mode" "$guest_input" "$guest_output" "$fs_type" "$size_mb" "$guest_init" "$packages" "$apk_cache" "$IMAGEWRITER_APK_RETRY_LIMIT" "$GUEST_TMP_IMAGE"
}

if [ "$TWO_STAGE_IMAGEWRITER" -eq 1 ]; then
  echo "imagewriter_pipeline mode=two-stage target=$OUTPUT_RAW"
  if ! GUEST_STAGE1_OUTPUT="$(host_to_guest_path "$STAGE1_OUTPUT" "$SHARE_ROOT")"; then
    echo "error: stage1 output path is outside host share root: $STAGE1_OUTPUT (share_root=$SHARE_ROOT)" >&2
    exit 1
  fi
  if ! GUEST_STAGE2_OUTPUT="$(host_to_guest_path "$STAGE2_OUTPUT" "$SHARE_ROOT")"; then
    echo "error: stage2 output path is outside host share root: $STAGE2_OUTPUT (share_root=$SHARE_ROOT)" >&2
    exit 1
  fi
  if ! GUEST_TMP_IMAGE="$(host_to_guest_path "$STAGE_TMP_IMAGE" "$SHARE_ROOT")"; then
    echo "error: temp image path is outside host share root: $STAGE_TMP_IMAGE (share_root=$SHARE_ROOT)" >&2
    exit 1
  fi

  mark_stage_start "stage1_ext4" "$GUEST_ROOTFS" "$GUEST_STAGE1_OUTPUT"
  if run_guest_worker_with_retry stage1 "$GUEST_ROOTFS" "$GUEST_STAGE1_OUTPUT" "ext4" "$IMAGE_SIZE_MB" "$GUEST_INIT" "$IMAGEWRITER_PACKAGES" "$GUEST_APK_CACHE"; then
    mark_stage_complete "stage1_ext4"
  else
    stage_code=$?
    mark_stage_failed "stage1_ext4" "$stage_code"
    exit 21
  fi
  progress_step "stage1 ext4 image build completed"

  stage2_name="stage2_${IMAGE_FS}"
  mark_stage_start "$stage2_name" "$GUEST_ROOTFS" "$GUEST_STAGE2_OUTPUT"
  if run_guest_worker_with_retry stage2 "$GUEST_ROOTFS" "$GUEST_STAGE2_OUTPUT" "$IMAGE_FS" "$IMAGE_SIZE_MB" "$GUEST_INIT" "$IMAGEWRITER_PACKAGES" "$GUEST_APK_CACHE"; then
    mark_stage_complete "$stage2_name"
  else
    stage_code=$?
    mark_stage_failed "$stage2_name" "$stage_code"
    exit 22
  fi
  progress_step "stage2 ${IMAGE_FS} image build completed"
  if [ "$IMAGE_FS" != "erofs" ]; then
    verify_expected_fs_type "$STAGE2_OUTPUT" "$IMAGE_FS" "$stage2_name"
  fi

  if ! mv -f "$STAGE2_OUTPUT" "$OUTPUT_RAW"; then
    echo "error: failed to move stage2 output into final path: $OUTPUT_RAW" >&2
    exit 23
  fi
  progress_step "moved stage2 output to final output path"
  if [ -n "$GUEST_FINAL_OUTPUT" ]; then
    verify_guest_visible_fs_type "$GUEST_FINAL_OUTPUT" "$IMAGE_FS" "final_output"
  else
    verify_expected_fs_type "$OUTPUT_RAW" "$IMAGE_FS" "final_output"
  fi

  rm -f "$STAGE1_OUTPUT"
  if [ -e "$STAGE1_OUTPUT" ]; then
    echo "error: failed to remove stage1 output: $STAGE1_OUTPUT" >&2
    exit 23
  fi
  echo "imagewriter_stage1_deleted path=$STAGE1_OUTPUT"
  progress_step "removed stage1 intermediate image"
else
  echo "imagewriter_pipeline mode=single-pass target=$OUTPUT_RAW fs=$IMAGE_FS"
  if ! GUEST_OUTPUT="$(host_to_guest_path "$STAGE_OUTPUT" "$SHARE_ROOT")"; then
    echo "error: staging output path is outside host share root: $STAGE_OUTPUT (share_root=$SHARE_ROOT)" >&2
    exit 1
  fi
  if ! GUEST_TMP_IMAGE="$(host_to_guest_path "$STAGE_TMP_IMAGE" "$SHARE_ROOT")"; then
    echo "error: temp image path is outside host share root: $STAGE_TMP_IMAGE (share_root=$SHARE_ROOT)" >&2
    exit 1
  fi

  stage_name="single_pass_${IMAGE_FS}"
  stage_fail_exit=22
  single_pass_mode="legacy"
  single_pass_packages=""
  if [ "$IMAGE_FS" = "ext4" ]; then
    stage_name="stage1_ext4"
    stage_fail_exit=21
  else
    single_pass_mode="stage2"
    single_pass_packages="$IMAGEWRITER_PACKAGES"
  fi

  mark_stage_start "$stage_name" "$GUEST_ROOTFS" "$GUEST_OUTPUT"
  if run_guest_worker_with_retry "$single_pass_mode" "$GUEST_ROOTFS" "$GUEST_OUTPUT" "$IMAGE_FS" "$IMAGE_SIZE_MB" "$GUEST_INIT" "$single_pass_packages" "$GUEST_APK_CACHE"; then
    mark_stage_complete "$stage_name"
  else
    stage_code=$?
    mark_stage_failed "$stage_name" "$stage_code"
    exit "$stage_fail_exit"
  fi
  progress_step "guest image build completed"
  if [ "$IMAGE_FS" != "erofs" ]; then
    verify_expected_fs_type "$STAGE_OUTPUT" "$IMAGE_FS" "$stage_name"
  fi

  if ! mv -f "$STAGE_OUTPUT" "$OUTPUT_RAW"; then
    echo "error: failed to move built image to output path: $OUTPUT_RAW" >&2
    exit 23
  fi
  progress_step "moved built image to output path"
  if [ -n "$GUEST_FINAL_OUTPUT" ]; then
    verify_guest_visible_fs_type "$GUEST_FINAL_OUTPUT" "$IMAGE_FS" "final_output"
  else
    verify_expected_fs_type "$OUTPUT_RAW" "$IMAGE_FS" "final_output"
  fi
fi

echo "imagewriter build completed"
echo "instance: $INSTANCE"
echo "fs: $IMAGE_FS"
if [ -n "$ROOTFS_DIR" ]; then
  echo "rootfs_dir: $ROOTFS_DIR"
else
  echo "rootfs: $ROOTFS_TARBALL"
fi
echo "output: $OUTPUT_RAW"
progress_step "done"
