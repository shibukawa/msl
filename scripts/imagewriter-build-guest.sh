#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "error: imagewriter guest builder must run as root" >&2
  exit 1
fi

MODE="legacy"
ROOTFS_ARCHIVE=""
OUTPUT_IMAGE=""
FS_TYPE="btrfs"
SIZE_MB="0"
INIT_BINARY=""
PACKAGES=""
APK_CACHE_DIR=""

usage() {
  cat >&2 <<'EOF_USAGE'
usage:
  imagewriter-build-guest.sh --mode stage1 --rootfs <rootfs-archive> --output <output-image> [--size-mb N] [--init-binary <path>] [--packages "<apk packages>"]
  imagewriter-build-guest.sh --mode stage2 --rootfs <rootfs-archive> --output <output-image> [--size-mb N] [--init-binary <path>] [--packages "<apk packages>"]

legacy:
  imagewriter-build-guest.sh <rootfs-archive> <output-image> [btrfs|ext4] [size-mb] [init-binary]
EOF_USAGE
}

is_non_negative_int() {
  value="$1"
  case "$value" in
    ''|*[!0-9]*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

if [ "$#" -gt 0 ] && [ "${1#--}" != "$1" ]; then
  MODE=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode)
        MODE="${2:-}"
        shift 2
        ;;
      --rootfs)
        ROOTFS_ARCHIVE="${2:-}"
        shift 2
        ;;
      --output)
        OUTPUT_IMAGE="${2:-}"
        shift 2
        ;;
      --size-mb)
        SIZE_MB="${2:-}"
        shift 2
        ;;
      --init-binary)
        INIT_BINARY="${2:-}"
        shift 2
        ;;
      --packages)
        PACKAGES="${2:-}"
        shift 2
        ;;
      --apk-cache-dir)
        APK_CACHE_DIR="${2:-}"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "error: unknown option: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
  if [ -z "$MODE" ]; then
    echo "error: --mode is required" >&2
    usage
    exit 1
  fi
else
  ROOTFS_ARCHIVE="${1:-}"
  OUTPUT_IMAGE="${2:-}"
  FS_TYPE="${3:-btrfs}"
  SIZE_MB="${4:-0}"
  INIT_BINARY="${5:-}"
  MODE="legacy"
fi

if ! is_non_negative_int "$SIZE_MB"; then
  echo "error: size-mb must be a non-negative integer: $SIZE_MB" >&2
  exit 1
fi

case "$MODE" in
  stage1)
    FS_TYPE="ext4"
    if [ -z "$ROOTFS_ARCHIVE" ] || [ -z "$OUTPUT_IMAGE" ]; then
      echo "error: stage1 requires --rootfs and --output" >&2
      usage
      exit 1
    fi
    ;;
  stage2)
    FS_TYPE="btrfs"
    if [ -z "$ROOTFS_ARCHIVE" ] || [ -z "$OUTPUT_IMAGE" ]; then
      echo "error: stage2 requires --rootfs and --output" >&2
      usage
      exit 1
    fi
    ;;
  legacy)
    if [ -z "$ROOTFS_ARCHIVE" ] || [ -z "$OUTPUT_IMAGE" ]; then
      usage
      exit 1
    fi
    case "$FS_TYPE" in
      btrfs|ext4) ;;
      *)
        echo "error: unsupported fs type: $FS_TYPE (use btrfs|ext4)" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "error: unsupported mode: $MODE (use stage1|stage2)" >&2
    usage
    exit 1
    ;;
esac

if [ -n "$ROOTFS_ARCHIVE" ] && [ ! -f "$ROOTFS_ARCHIVE" ]; then
  echo "error: rootfs archive not found: $ROOTFS_ARCHIVE" >&2
  exit 1
fi
if [ -n "$INIT_BINARY" ] && [ ! -f "$INIT_BINARY" ]; then
  echo "error: init binary not found: $INIT_BINARY" >&2
  exit 1
fi

WORK_DIR="${MSL_IMAGEWRITER_WORK_DIR:-/tmp/msl-imagewriter-build}"
ROOTFS_DIR="$WORK_DIR/rootfs"
OUTPUT_MOUNT_DIR="$WORK_DIR/mnt-output"

TOTAL_STEPS=7
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

set_btrfs_compression() {
  target="$1"
  mode="$2"
  if ! btrfs property set "$target" compression "$mode" >/dev/null 2>&1; then
    echo "warning: failed to set btrfs compression '$mode' on $target" >&2
  fi
}

detect_service_manager() {
  if [ -f "$ROOTFS_DIR/etc/alpine-release" ] || [ -x "$ROOTFS_DIR/sbin/openrc-run" ] || [ -d "$ROOTFS_DIR/etc/runlevels" ]; then
    echo "openrc"
    return 0
  fi
  if [ -x "$ROOTFS_DIR/lib/systemd/systemd" ] || [ -x "$ROOTFS_DIR/usr/lib/systemd/systemd" ] || [ -d "$ROOTFS_DIR/etc/systemd" ]; then
    echo "systemd"
    return 0
  fi
  echo ""
}

normalize_root_fstab() {
  fstab="$ROOTFS_DIR/etc/fstab"
  if [ ! -f "$fstab" ]; then
    return 0
  fi
  tmp="$fstab.tmp"
  awk '
    BEGIN { root_done=0 }
    /^[[:space:]]*#/ || NF < 2 { print; next }
    {
      if ($2 == "/") {
        if (root_done == 0) {
          print "/dev/vda / auto defaults 0 1"
          root_done = 1
        }
        next
      }
      print
    }
  ' "$fstab" > "$tmp"
  if cmp -s "$fstab" "$tmp"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$fstab"
  fi
}

install_systemd_contracts() {
  mkdir -p "$ROOTFS_DIR/etc/systemd/system" "$ROOTFS_DIR/etc/systemd/timesyncd.conf.d"
  cat > "$ROOTFS_DIR/etc/systemd/system/msl-init.service" <<'EOF_SYSTEMD_UNIT'
[Unit]
Description=msl init control server
After=network.target local-fs.target
Before=docker.service containerd.service

[Service]
Type=simple
Environment=MSL_VSOCK_PORT=1024
Environment=MSL_INIT_LOG_FILE=/var/log/msl-init.log
ExecStart=/usr/local/bin/msl-init
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD_UNIT

  mkdir -p "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants"
  ln -snf ../msl-init.service "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/msl-init.service"

  cat > "$ROOTFS_DIR/etc/systemd/timesyncd.conf.d/90-msl.conf" <<'EOF_TIMESYNCD'
[Time]
NTP=127.0.0.1
FallbackNTP=
EOF_TIMESYNCD

  if [ -f "$ROOTFS_DIR/lib/systemd/system/systemd-timesyncd.service" ] || [ -f "$ROOTFS_DIR/usr/lib/systemd/system/systemd-timesyncd.service" ]; then
    mkdir -p "$ROOTFS_DIR/etc/systemd/system/sysinit.target.wants"
    if [ -f "$ROOTFS_DIR/lib/systemd/system/systemd-timesyncd.service" ]; then
      ln -snf /lib/systemd/system/systemd-timesyncd.service "$ROOTFS_DIR/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service"
    else
      ln -snf /usr/lib/systemd/system/systemd-timesyncd.service "$ROOTFS_DIR/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service"
    fi
  fi
}

install_openrc_contracts() {
  mkdir -p "$ROOTFS_DIR/etc/init.d" "$ROOTFS_DIR/etc/runlevels/default" "$ROOTFS_DIR/etc/conf.d"
  cat > "$ROOTFS_DIR/etc/init.d/msl-init" <<'EOF_OPENRC_SERVICE'
#!/sbin/openrc-run
name="msl-init"
description="msl init control server"
command="/usr/local/bin/msl-init"
command_background="yes"
pidfile="/run/msl-init.pid"
output_log="/var/log/msl-init.log"
error_log="/var/log/msl-init.log"
supervisor=supervise-daemon
respawn_delay=1
respawn_max=0
respawn_period=0

depend() {
  need localmount
  after bootmisc
  before docker
}

start_pre() {
  checkpath --file --mode 0644 /var/log/msl-init.log
}
EOF_OPENRC_SERVICE
  chmod 0755 "$ROOTFS_DIR/etc/init.d/msl-init"
  ln -snf /etc/init.d/msl-init "$ROOTFS_DIR/etc/runlevels/default/msl-init"

  cat > "$ROOTFS_DIR/etc/conf.d/ntpd" <<'EOF_NTPD_CONF'
NTPD_OPTS="-p 127.0.0.1"
EOF_NTPD_CONF
}

apply_btrfs_policy() {
  mount_dir="$1"
  mkdir -p \
    "$mount_dir/usr" \
    "$mount_dir/usr/local" \
    "$mount_dir/opt" \
    "$mount_dir/var/lib" \
    "$mount_dir/var/cache/apt" \
    "$mount_dir/var/log"

  set_btrfs_compression "$mount_dir/usr" zstd
  set_btrfs_compression "$mount_dir/usr/local" zstd
  set_btrfs_compression "$mount_dir/opt" zstd
  set_btrfs_compression "$mount_dir/var/lib" zstd
  set_btrfs_compression "$mount_dir/var/cache/apt" none
  set_btrfs_compression "$mount_dir/var/log" zstd

  # Re-compress /usr with a high zstd level to make the base image denser.
  if ! btrfs filesystem defrag -r -czstd -L 15 "$mount_dir/usr" >/dev/null 2>&1; then
    if ! btrfs filesystem defrag -r -czstd "$mount_dir/usr" >/dev/null 2>&1; then
      echo "warning: failed to defrag/recompress /usr with zstd" >&2
    fi
  fi
}

resolve_size_from_rootfs() {
  if [ "$SIZE_MB" -le 0 ] 2>/dev/null; then
    rootfs_mb="$(du -sm "$ROOTFS_DIR" | awk '{print $1}')"
    if [ -z "$rootfs_mb" ] || [ "$rootfs_mb" -le 0 ]; then
      rootfs_mb=256
    fi
    SIZE_MB=$((rootfs_mb + rootfs_mb / 2 + 512))
    if [ "$SIZE_MB" -lt 1024 ]; then
      SIZE_MB=1024
    fi
  fi
}

install_packages() {
  if [ -z "$PACKAGES" ]; then
    return
  fi
  if ! command -v apk >/dev/null 2>&1; then
    echo "error: apk command not found in guest worker environment" >&2
    exit 1
  fi
  if [ -n "$APK_CACHE_DIR" ]; then
    mkdir -p "$APK_CACHE_DIR"
    # shellcheck disable=SC2086
    apk --root "$ROOTFS_DIR" --initdb --update-cache --cache-dir "$APK_CACHE_DIR" add $PACKAGES
  else
    # shellcheck disable=SC2086
    apk --root "$ROOTFS_DIR" --initdb --update-cache add $PACKAGES
  fi
}

extract_rootfs() {
  rm -rf "$ROOTFS_DIR"
  mkdir -p "$ROOTFS_DIR"
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
  normalize_root_fstab
}

install_init_binary() {
  if [ -z "$INIT_BINARY" ]; then
    return
  fi
  mkdir -p "$ROOTFS_DIR/sbin" "$ROOTFS_DIR/usr/local/bin"
  cp -f "$INIT_BINARY" "$ROOTFS_DIR/sbin/msl-init"
  cp -f "$INIT_BINARY" "$ROOTFS_DIR/usr/local/bin/msl-init"
  chmod 0755 "$ROOTFS_DIR/sbin/msl-init" "$ROOTFS_DIR/usr/local/bin/msl-init"
  ln -snf msl-init "$ROOTFS_DIR/usr/local/bin/msl"

  SERVICE_MANAGER="$(detect_service_manager)"
  case "$SERVICE_MANAGER" in
    systemd)
      install_systemd_contracts
      ;;
    openrc)
      install_openrc_contracts
      ;;
    *)
      echo "warning: could not detect service manager in rootfs; skipping msl-init service/NTP contract install" >&2
      ;;
  esac
}

build_from_source_dir() {
  source_dir="$1"
  truncate -s "${SIZE_MB}M" "$OUTPUT_IMAGE"
  progress_step "allocated output image"

  case "$FS_TYPE" in
    btrfs)
      mkfs.btrfs -f "$OUTPUT_IMAGE" >/dev/null
      mount -o loop "$OUTPUT_IMAGE" "$OUTPUT_MOUNT_DIR"
      ;;
    ext4)
      mkfs.ext4 -q -F -E lazy_itable_init=1,lazy_journal_init=1 "$OUTPUT_IMAGE"
      mount -o loop "$OUTPUT_IMAGE" "$OUTPUT_MOUNT_DIR"
      ;;
  esac
  progress_step "formatted and mounted output filesystem"

  tar -C "$source_dir" -cf - . | tar -C "$OUTPUT_MOUNT_DIR" -xf -
  progress_step "copied source contents into image"

  if [ "$FS_TYPE" = "btrfs" ]; then
    apply_btrfs_policy "$OUTPUT_MOUNT_DIR"
  fi
}

cleanup() {
  umount "$OUTPUT_MOUNT_DIR" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR" >/dev/null 2>&1 || true
}

rm -rf "$ROOTFS_DIR" "$OUTPUT_MOUNT_DIR"
mkdir -p "$OUTPUT_MOUNT_DIR" "$ROOTFS_DIR" "$(dirname "$OUTPUT_IMAGE")"
progress_step "prepared workspace"
trap cleanup EXIT INT TERM

echo "imagewriter_guest_stage_start mode=$MODE fs=$FS_TYPE output=$OUTPUT_IMAGE"
case "$MODE" in
  stage1|stage2|legacy)
    extract_rootfs
    progress_step "extracted rootfs archive"
    install_init_binary
    install_packages
    progress_step "installed stage packages"
    resolve_size_from_rootfs
    build_from_source_dir "$ROOTFS_DIR"
    ;;
esac

sync
cleanup
trap - EXIT INT TERM

# NOTE:
# Do not run hole-punching (fallocate -d) for the generated raw image here.
# The output is written under /mnt/macos (virtiofs host share), and punching
# holes through this path can corrupt guest-visible data extents.

echo "imagewriter_guest_stage_complete mode=$MODE fs=$FS_TYPE output=$OUTPUT_IMAGE"
echo "imagewriter guest build completed: $OUTPUT_IMAGE"
echo "fs: $FS_TYPE"
echo "size_mb: $SIZE_MB"
progress_step "finalized image"
