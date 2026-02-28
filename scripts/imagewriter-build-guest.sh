#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "error: imagewriter guest builder must run as root" >&2
  exit 1
fi

ROOTFS_ARCHIVE="${1:-}"
OUTPUT_IMAGE="${2:-}"
FS_TYPE="${3:-btrfs}"
SIZE_MB="${4:-0}"
INIT_BINARY="${5:-}"

if [ -z "$ROOTFS_ARCHIVE" ] || [ -z "$OUTPUT_IMAGE" ]; then
  echo "usage: imagewriter-build-guest.sh <rootfs-archive> <output-image> [btrfs|ext4] [size-mb] [init-binary]" >&2
  exit 1
fi
if [ ! -f "$ROOTFS_ARCHIVE" ]; then
  echo "error: rootfs archive not found: $ROOTFS_ARCHIVE" >&2
  exit 1
fi
if [ -n "$INIT_BINARY" ] && [ ! -f "$INIT_BINARY" ]; then
  echo "error: init binary not found: $INIT_BINARY" >&2
  exit 1
fi

case "$FS_TYPE" in
  btrfs|ext4) ;;
  *)
    echo "error: unsupported fs type: $FS_TYPE (use btrfs|ext4)" >&2
    exit 1
    ;;
esac

WORK_DIR="/tmp/msl-imagewriter-build"
ROOTFS_DIR="$WORK_DIR/rootfs"
MOUNT_DIR="$WORK_DIR/mnt"

TOTAL_STEPS=6
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
  echo "imagewriter guest progress: [${bar}] ${percent}% - $1"
}

cleanup() {
  umount "$MOUNT_DIR" >/dev/null 2>&1 || true
}

rm -rf "$ROOTFS_DIR" "$MOUNT_DIR"
mkdir -p "$ROOTFS_DIR" "$MOUNT_DIR" "$(dirname "$OUTPUT_IMAGE")"
progress_step "prepared workspace"

case "$ROOTFS_ARCHIVE" in
  *.tar.gz|*.tgz)
    tar -xzf "$ROOTFS_ARCHIVE" -C "$ROOTFS_DIR"
    ;;
  *.tar.xz)
    tar -xJf "$ROOTFS_ARCHIVE" -C "$ROOTFS_DIR"
    ;;
  *.tar.zst|*.tzst)
    tar --zstd -xf "$ROOTFS_ARCHIVE" -C "$ROOTFS_DIR"
    ;;
  *)
    tar -xf "$ROOTFS_ARCHIVE" -C "$ROOTFS_DIR"
    ;;
esac
progress_step "extracted rootfs archive"

if [ -n "$INIT_BINARY" ]; then
  mkdir -p "$ROOTFS_DIR/sbin" "$ROOTFS_DIR/usr/local/bin"
  cp -f "$INIT_BINARY" "$ROOTFS_DIR/sbin/msl-init"
  cp -f "$INIT_BINARY" "$ROOTFS_DIR/usr/local/bin/msl-init"
  chmod 0755 "$ROOTFS_DIR/sbin/msl-init" "$ROOTFS_DIR/usr/local/bin/msl-init"
  ln -snf msl-init "$ROOTFS_DIR/usr/local/bin/msl"
fi

if [ "$SIZE_MB" -le 0 ] 2>/dev/null; then
  ROOTFS_MB="$(du -sm "$ROOTFS_DIR" | awk '{print $1}')"
  if [ -z "$ROOTFS_MB" ] || [ "$ROOTFS_MB" -le 0 ]; then
    ROOTFS_MB=256
  fi
  SIZE_MB=$((ROOTFS_MB + ROOTFS_MB / 2 + 512))
  if [ "$SIZE_MB" -lt 1024 ]; then
    SIZE_MB=1024
  fi
fi

truncate -s "${SIZE_MB}M" "$OUTPUT_IMAGE"
progress_step "allocated output image"

case "$FS_TYPE" in
  btrfs)
    mkfs.btrfs -f "$OUTPUT_IMAGE" >/dev/null
    mount -o loop "$OUTPUT_IMAGE" "$MOUNT_DIR"
    ;;
  ext4)
    mkfs.ext4 -q -F -E lazy_itable_init=1,lazy_journal_init=1 "$OUTPUT_IMAGE"
    mount -o loop "$OUTPUT_IMAGE" "$MOUNT_DIR"
    ;;
esac
trap cleanup EXIT INT TERM
progress_step "formatted and mounted filesystem"

tar -C "$ROOTFS_DIR" -cf - . | tar -C "$MOUNT_DIR" -xf -
progress_step "copied rootfs into image"

if [ "$FS_TYPE" = "btrfs" ]; then
  mkdir -p \
    "$MOUNT_DIR/usr" \
    "$MOUNT_DIR/usr/local" \
    "$MOUNT_DIR/opt" \
    "$MOUNT_DIR/var/lib" \
    "$MOUNT_DIR/var/cache/apt" \
    "$MOUNT_DIR/var/log"

  set_btrfs_compression() {
    target="$1"
    mode="$2"
    if ! btrfs property set "$target" compression "$mode" >/dev/null 2>&1; then
      echo "warning: failed to set btrfs compression '$mode' on $target" >&2
    fi
  }

  set_btrfs_compression "$MOUNT_DIR/usr" zstd
  set_btrfs_compression "$MOUNT_DIR/usr/local" zstd
  set_btrfs_compression "$MOUNT_DIR/opt" zstd
  set_btrfs_compression "$MOUNT_DIR/var/lib" zstd
  set_btrfs_compression "$MOUNT_DIR/var/cache/apt" none
  set_btrfs_compression "$MOUNT_DIR/var/log" zstd

  # Re-compress /usr with a high zstd level to make the base image denser.
  if ! btrfs filesystem defrag -r -czstd -L 15 "$MOUNT_DIR/usr" >/dev/null 2>&1; then
    if ! btrfs filesystem defrag -r -czstd "$MOUNT_DIR/usr" >/dev/null 2>&1; then
      echo "warning: failed to defrag/recompress /usr with zstd" >&2
    fi
  fi
fi

sync
umount "$MOUNT_DIR"
trap - EXIT INT TERM

# NOTE:
# Do not run hole-punching (fallocate -d) for the generated raw image here.
# The output is written under /mnt/macos (virtiofs host share), and punching
# holes through this path can corrupt guest-visible data extents.

echo "imagewriter guest build completed: $OUTPUT_IMAGE"
echo "fs: $FS_TYPE"
echo "size_mb: $SIZE_MB"
progress_step "finalized image"
