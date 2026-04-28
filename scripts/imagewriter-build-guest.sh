#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "error: imagewriter guest builder must run as root" >&2
  exit 1
fi

MODE="legacy"
ROOTFS_ARCHIVE=""
ROOTFS_SOURCE_DIR=""
OCI_LAYOUT_DIR=""
EXTRA_FILES_BUNDLE=""
OUTPUT_IMAGE=""
FS_TYPE="btrfs"
SIZE_MB="0"
INIT_BINARY=""
PACKAGES=""
APK_CACHE_DIR=""
APK_RETRY_LIMIT="5"
RUNTIME_SUMMARY_PATH=""
DEFAULT_EXEC_ARGV_B64=""
DEFAULT_EXEC_ENV_B64=""
DEFAULT_EXEC_WORKDIR=""
DEFAULT_EXEC_USER=""

usage() {
  cat >&2 <<'EOF_USAGE'
usage:
  imagewriter-build-guest.sh --mode stage1 (--rootfs <rootfs-archive> | --rootfs-dir <rootfs-dir>) --output <output-image> --size-mb <n> [--init-binary <path>] [--packages "<apk packages>"]
  imagewriter-build-guest.sh --mode stage2 --fs-type <btrfs|erofs> (--rootfs <rootfs-archive> | --rootfs-dir <rootfs-dir> | --oci-layout-dir <oci-layout-dir>) [--extra-files-bundle <bundle-dir>] --output <output-image> --size-mb <n> [--init-binary <path>] [--packages "<apk packages>"]

legacy:
  imagewriter-build-guest.sh <rootfs-archive> <output-image> [btrfs|erofs|ext4] <size-mb> [init-binary]
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
      --rootfs-dir)
        ROOTFS_SOURCE_DIR="${2:-}"
        shift 2
        ;;
      --oci-layout-dir)
        OCI_LAYOUT_DIR="${2:-}"
        shift 2
        ;;
      --extra-files-bundle)
        EXTRA_FILES_BUNDLE="${2:-}"
        shift 2
        ;;
      --output)
        OUTPUT_IMAGE="${2:-}"
        shift 2
        ;;
      --fs-type)
        FS_TYPE="${2:-}"
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
      --retry-limit)
        APK_RETRY_LIMIT="${2:-}"
        shift 2
        ;;
      --runtime-summary)
        RUNTIME_SUMMARY_PATH="${2:-}"
        shift 2
        ;;
      --default-exec-argv-b64)
        DEFAULT_EXEC_ARGV_B64="${2:-}"
        shift 2
        ;;
      --default-exec-env-b64)
        DEFAULT_EXEC_ENV_B64="${2:-}"
        shift 2
        ;;
      --default-exec-workdir)
        DEFAULT_EXEC_WORKDIR="${2:-}"
        shift 2
        ;;
      --default-exec-user)
        DEFAULT_EXEC_USER="${2:-}"
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
if ! is_non_negative_int "$APK_RETRY_LIMIT" || [ "$APK_RETRY_LIMIT" -le 0 ]; then
  echo "error: retry-limit must be a positive integer: $APK_RETRY_LIMIT" >&2
  exit 1
fi

case "$MODE" in
  stage1)
    FS_TYPE="ext4"
    if { [ -z "$ROOTFS_ARCHIVE" ] && [ -z "$ROOTFS_SOURCE_DIR" ]; } || [ -z "$OUTPUT_IMAGE" ]; then
      echo "error: stage1 requires --rootfs/--rootfs-dir and --output" >&2
      usage
      exit 1
    fi
    ;;
  stage2)
    FS_TYPE="${FS_TYPE:-erofs}"
    if { [ -z "$ROOTFS_ARCHIVE" ] && [ -z "$ROOTFS_SOURCE_DIR" ] && [ -z "$OCI_LAYOUT_DIR" ]; } || [ -z "$OUTPUT_IMAGE" ]; then
      echo "error: stage2 requires --rootfs/--rootfs-dir/--oci-layout-dir and --output" >&2
      usage
      exit 1
    fi
    case "$FS_TYPE" in
      btrfs|erofs) ;;
      *)
        echo "error: stage2 fs type must be btrfs or erofs" >&2
        exit 1
        ;;
    esac
    ;;
  legacy)
    if [ -z "$ROOTFS_ARCHIVE" ] || [ -z "$OUTPUT_IMAGE" ]; then
      usage
      exit 1
    fi
    case "$FS_TYPE" in
      btrfs|erofs|ext4) ;;
      *)
        echo "error: unsupported fs type: $FS_TYPE (use btrfs|erofs|ext4)" >&2
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

source_count=0
[ -n "$ROOTFS_ARCHIVE" ] && source_count=$((source_count + 1))
[ -n "$ROOTFS_SOURCE_DIR" ] && source_count=$((source_count + 1))
[ -n "$OCI_LAYOUT_DIR" ] && source_count=$((source_count + 1))
if [ "$source_count" -gt 1 ]; then
  echo "error: specify only one of --rootfs, --rootfs-dir, or --oci-layout-dir" >&2
  exit 1
fi
if [ -n "$ROOTFS_ARCHIVE" ] && [ ! -f "$ROOTFS_ARCHIVE" ]; then
  echo "error: rootfs archive not found: $ROOTFS_ARCHIVE" >&2
  exit 1
fi
if [ -n "$ROOTFS_SOURCE_DIR" ] && [ ! -d "$ROOTFS_SOURCE_DIR" ]; then
  echo "error: rootfs directory not found: $ROOTFS_SOURCE_DIR" >&2
  exit 1
fi
if [ -n "$OCI_LAYOUT_DIR" ] && [ ! -d "$OCI_LAYOUT_DIR" ]; then
  echo "error: OCI layout directory not found: $OCI_LAYOUT_DIR" >&2
  exit 1
fi
if [ -n "$EXTRA_FILES_BUNDLE" ] && [ ! -d "$EXTRA_FILES_BUNDLE" ]; then
  echo "error: extra files bundle not found: $EXTRA_FILES_BUNDLE" >&2
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

fail_guest_stage() {
  stage="$1"
  code="${2:-1}"
  shift 2
  message="$*"
  echo "imagewriter_guest_failure stage=$stage code=$code message=$message" >&2
  exit "$code"
}

detect_image_fs_type() {
  image_path="$1"
  if [ ! -f "$image_path" ]; then
    echo ""
    return 1
  fi
  if command -v blkid >/dev/null 2>&1; then
    blkid_type="$(blkid -p -s TYPE -o value "$image_path" 2>/dev/null || true)"
    if [ -n "$blkid_type" ]; then
      printf '%s\n' "$blkid_type"
      return 0
    fi
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

verify_output_fs_type() {
  expected_fs="$1"
  actual_fs="$(detect_image_fs_type "$OUTPUT_IMAGE" || true)"
  if [ -z "$actual_fs" ]; then
    echo "error: could not determine output filesystem type: $OUTPUT_IMAGE" >&2
    exit 1
  fi
  if [ "$actual_fs" != "$expected_fs" ]; then
    echo "error: built image filesystem mismatch: expected=$expected_fs actual=$actual_fs output=$OUTPUT_IMAGE" >&2
    exit 1
  fi
  echo "imagewriter_guest_verified_fs mode=$MODE fs=$actual_fs output=$OUTPUT_IMAGE"
}

set_btrfs_compression() {
  target="$1"
  mode="$2"
  if ! btrfs property set "$target" compression "$mode" >/dev/null 2>&1; then
    echo "warning: failed to set btrfs compression '$mode' on $target" >&2
  fi
}

defrag_with_zstd() {
  target="$1"
  if [ ! -e "$target" ]; then
    return 0
  fi
  if ! btrfs filesystem defrag -r -czstd -L 15 "$target" >/dev/null 2>&1; then
    if ! btrfs filesystem defrag -r -czstd "$target" >/dev/null 2>&1; then
      echo "warning: failed to defrag/recompress $target with zstd" >&2
    fi
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
          print "/dev/vda / auto defaults,nodiscard 0 1"
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
ExecStart=/usr/local/bin/msl-init-bootloader
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
command="/usr/local/bin/msl-init-bootloader"
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

prepare_btrfs_policy() {
  mount_dir="$1"
  mkdir -p \
    "$mount_dir/bin" \
    "$mount_dir/etc" \
    "$mount_dir/lib" \
    "$mount_dir/lib64" \
    "$mount_dir/root" \
    "$mount_dir/sbin" \
    "$mount_dir/usr" \
    "$mount_dir/usr/local" \
    "$mount_dir/opt" \
    "$mount_dir/var/lib" \
    "$mount_dir/var/cache/apk" \
    "$mount_dir/var/cache/apt" \
    "$mount_dir/var/log"

  set_btrfs_compression "$mount_dir" zstd
  set_btrfs_compression "$mount_dir/bin" zstd
  set_btrfs_compression "$mount_dir/etc" zstd
  set_btrfs_compression "$mount_dir/lib" zstd
  set_btrfs_compression "$mount_dir/lib64" zstd
  set_btrfs_compression "$mount_dir/root" zstd
  set_btrfs_compression "$mount_dir/sbin" zstd
  set_btrfs_compression "$mount_dir/usr" zstd
  set_btrfs_compression "$mount_dir/usr/local" zstd
  set_btrfs_compression "$mount_dir/opt" zstd
  set_btrfs_compression "$mount_dir/var/lib" zstd
  set_btrfs_compression "$mount_dir/var/cache/apk" none
  set_btrfs_compression "$mount_dir/var/cache/apt" none
  set_btrfs_compression "$mount_dir/var/log" zstd
}

apply_btrfs_policy() {
  mount_dir="$1"
  prepare_btrfs_policy "$mount_dir"

  # Re-compress the whole rootfs after copy to densify the base image.
  # Cache directories are switched back to `none` for future writes, but the
  # initial bootstrap contents can stay compressed in the base image.
  defrag_with_zstd "$mount_dir"
  set_btrfs_compression "$mount_dir/var/cache/apk" none
  set_btrfs_compression "$mount_dir/var/cache/apt" none
}

resolve_size() {
  if [ -z "$SIZE_MB" ]; then
    echo "error: size-mb is required; msl install must pass an explicit size" >&2
    exit 1
  fi
  if [ "$SIZE_MB" -le 0 ] 2>/dev/null; then
    echo "error: size-mb must be a positive integer" >&2
    exit 1
  fi
}

install_packages() {
  if [ -z "$PACKAGES" ]; then
    return
  fi
  # The source rootfs may be Debian/Ubuntu/Fedora/openSUSE and must not be
  # mutated with Alpine packages. Keep package installation scoped to Alpine
  # rootfs only (imagewriter runtime dependencies are prepared separately).
  if [ ! -f "$ROOTFS_DIR/etc/alpine-release" ]; then
    echo "imagewriter_guest_skip_apk_root_install reason=non_alpine_rootfs"
    return
  fi
  if ! command -v apk >/dev/null 2>&1; then
    echo "error: apk command not found in guest worker environment" >&2
    exit 1
  fi
  attempts=0
  while true; do
    if [ -n "$APK_CACHE_DIR" ]; then
      mkdir -p "$APK_CACHE_DIR"
      # shellcheck disable=SC2086
      if apk --root "$ROOTFS_DIR" --initdb --update-cache --cache-dir "$APK_CACHE_DIR" add $PACKAGES; then
        break
      fi
    else
      # shellcheck disable=SC2086
      if apk --root "$ROOTFS_DIR" --initdb --update-cache add $PACKAGES; then
        break
      fi
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$APK_RETRY_LIMIT" ]; then
      echo "error: apk add failed after $attempts attempts" >&2
      exit 1
    fi
    echo "warning: apk add failed (attempt $attempts/$APK_RETRY_LIMIT), retrying..." >&2
    sleep "$attempts"
  done
  rootfs_kib="$(du -sk "$ROOTFS_DIR" | awk '{print $1}')"
  echo "imagewriter_rootfs_size_kib mode=$MODE size_kib=$rootfs_kib"
}

extract_rootfs() {
  rm -rf "$ROOTFS_DIR"
  mkdir -p "$ROOTFS_DIR"
  if [ -n "$OCI_LAYOUT_DIR" ]; then
    bundle_dir="$WORK_DIR/oci-bundle"
    rm -rf "$bundle_dir"
    umoci_bin="$(resolve_injected_umoci)"
    if [ -z "$umoci_bin" ]; then
      fail_guest_stage "container_unpack" 26 "umoci command not found in guest worker environment"
    fi
    if ! "$umoci_bin" unpack --rootless --image "$OCI_LAYOUT_DIR:image" "$bundle_dir"; then
      fail_guest_stage "container_unpack" 26 "guest umoci unpack failed for OCI layout: $OCI_LAYOUT_DIR"
    fi
    if [ ! -d "$bundle_dir/rootfs" ]; then
      fail_guest_stage "container_unpack" 26 "guest umoci unpack completed without rootfs: $OCI_LAYOUT_DIR"
    fi
    if [ -x "$bundle_dir/rootfs/bin/sh" ]; then
      echo "imagewriter_runtime_probe shell=/bin/sh exists=true"
    else
      echo "imagewriter_runtime_probe shell=/bin/sh exists=false"
    fi
    if ! tar -C "$bundle_dir/rootfs" -cf - . | tar -C "$ROOTFS_DIR" -xf -; then
      fail_guest_stage "rootfs_copy" 26 "failed to copy unpacked OCI rootfs into guest work dir"
    fi
    normalize_root_fstab
    return
  fi
  if [ -n "$ROOTFS_SOURCE_DIR" ]; then
    cp -R "$ROOTFS_SOURCE_DIR"/. "$ROOTFS_DIR"/
    normalize_root_fstab
    return
  fi
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

install_extra_files() {
  if [ -z "$EXTRA_FILES_BUNDLE" ]; then
    return 0
  fi
  manifest_lines="$EXTRA_FILES_BUNDLE/manifest.lines"
  if [ ! -f "$manifest_lines" ]; then
    fail_guest_stage "extra_files" 26 "extra files manifest is missing staged line spec: $manifest_lines"
  fi
  while IFS="$(printf '\t')" read -r source_rel guest_path mode; do
    [ -n "$source_rel" ] || continue
    source_path="$EXTRA_FILES_BUNDLE/$source_rel"
    if [ ! -f "$source_path" ]; then
      fail_guest_stage "extra_files" 26 "extra file source missing: $source_path"
    fi
    case "$guest_path" in
      /*) target_path="$guest_path" ;;
      *) target_path="$WORK_DIR/$guest_path" ;;
    esac
    case "$target_path" in
      "$WORK_DIR"/*) ;;
      *)
        fail_guest_stage "extra_files" 26 "extra file guestPath must stay under work dir: $guest_path"
        ;;
    esac
    mkdir -p "$(dirname "$target_path")"
    cp -f "$source_path" "$target_path"
    chmod "$mode" "$target_path"
  done < "$manifest_lines"
}

resolve_injected_umoci() {
  candidate="$WORK_DIR/extras/umoci"
  if [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if command -v umoci >/dev/null 2>&1; then
    command -v umoci
    return 0
  fi
  printf '%s\n' ""
}

decode_b64() {
  value="$1"
  if [ -z "$value" ]; then
    return 0
  fi
  printf '%s' "$value" | base64 -d
}

resolve_default_exec_to_file() {
  output_file="$1"
  : > "$output_file"
  if [ -z "$DEFAULT_EXEC_ARGV_B64" ]; then
    return 1
  fi

  argv_file="$WORK_DIR/default-exec.argv"
  env_file="$WORK_DIR/default-exec.env"
  decode_b64 "$DEFAULT_EXEC_ARGV_B64" > "$argv_file"
  decode_b64 "$DEFAULT_EXEC_ENV_B64" > "$env_file"

  cmd0=""
  rest_file="$WORK_DIR/default-exec-rest.argv"
  : > "$rest_file"
  first=1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" -eq 1 ]; then
      cmd0="$line"
      first=0
    else
      printf '%s\n' "$line" >> "$rest_file"
    fi
  done < "$argv_file"

  [ -n "$cmd0" ] || return 1
  path_value="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  while IFS= read -r env_line || [ -n "$env_line" ]; do
    case "$env_line" in
      PATH=*)
        path_value="${env_line#PATH=}"
        ;;
    esac
  done < "$env_file"

  resolved=""
  case "$cmd0" in
    /*)
      candidate="$ROOTFS_DIR${cmd0}"
      if [ -f "$candidate" ] && [ -x "$candidate" ]; then
        resolved="$cmd0"
      fi
      ;;
    *)
      old_ifs="${IFS}"
      IFS=':'
      set -- $path_value
      IFS="${old_ifs}"
      for entry in "$@"; do
        [ -n "$entry" ] || entry="."
        case "$entry" in
          /*) rel="${entry#/}" ;;
          *) rel="$entry" ;;
        esac
        candidate="$ROOTFS_DIR/$rel/$cmd0"
        if [ -f "$candidate" ] && [ -x "$candidate" ]; then
          case "$entry" in
            /*) resolved="$entry/$cmd0" ;;
            *) resolved="/$entry/$cmd0" ;;
          esac
          break
        fi
      done
      ;;
  esac

  [ -n "$resolved" ] || return 1
  echo "imagewriter_default_exec_resolved command=$cmd0 path=$resolved"
  printf '%s\n' "$resolved" > "$output_file"
  cat "$rest_file" >> "$output_file"
  return 0
}

write_runtime_summary() {
  if [ -z "$RUNTIME_SUMMARY_PATH" ]; then
    return 0
  fi
  shell_available=0
  for shell in /bin/sh /bin/bash /bin/ash; do
    if [ -x "$ROOTFS_DIR${shell}" ]; then
      shell_available=1
      break
    fi
  done

  resolved_argv_file="$WORK_DIR/default-exec-resolved.argv"
  resolved_env_file="$WORK_DIR/default-exec.env"
  has_default_exec=0
  if resolve_default_exec_to_file "$resolved_argv_file"; then
    has_default_exec=1
  fi

  if [ "$shell_available" -eq 0 ] && [ "$has_default_exec" -eq 0 ]; then
    fail_guest_stage "runtime_validation" 26 "container rootfs has no usable shell and no resolvable default command"
  fi

  mkdir -p "$(dirname "$RUNTIME_SUMMARY_PATH")"
  if [ "$has_default_exec" -eq 1 ]; then
    default_exec_argv_b64="$(base64 < "$resolved_argv_file" | tr -d '\n')"
    default_exec_env_b64="$(base64 < "$resolved_env_file" | tr -d '\n')"
  else
    default_exec_argv_b64=""
    default_exec_env_b64=""
  fi
  {
    printf 'SHELL_AVAILABLE=%s\n' "$([ "$shell_available" -eq 1 ] && echo true || echo false)"
    printf 'DEFAULT_EXEC_ARGV_B64=%s\n' "$default_exec_argv_b64"
    printf 'DEFAULT_EXEC_ENV_B64=%s\n' "$default_exec_env_b64"
    printf 'DEFAULT_EXEC_WORKDIR=%s\n' "$DEFAULT_EXEC_WORKDIR"
    printf 'DEFAULT_EXEC_USER=%s\n' "$DEFAULT_EXEC_USER"
  } > "$RUNTIME_SUMMARY_PATH"
}

install_init_binary() {
  if [ -z "$INIT_BINARY" ]; then
    return
  fi
  mkdir -p "$ROOTFS_DIR/sbin" "$ROOTFS_DIR/usr/local/bin" || fail_guest_stage "init_injection" 1 "failed to create init target directories"
  cp -f "$INIT_BINARY" "$ROOTFS_DIR/sbin/msl-init-bootloader" || fail_guest_stage "init_injection" 1 "failed to install init bootloader into /sbin"
  cp -f "$INIT_BINARY" "$ROOTFS_DIR/usr/local/bin/msl-init-bootloader" || fail_guest_stage "init_injection" 1 "failed to install init bootloader into /usr/local/bin"
  chmod 0755 "$ROOTFS_DIR/sbin/msl-init-bootloader" "$ROOTFS_DIR/usr/local/bin/msl-init-bootloader" || fail_guest_stage "init_injection" 1 "failed to chmod init bootloader"

  SERVICE_MANAGER="$(detect_service_manager)"
  case "$SERVICE_MANAGER" in
    systemd)
      install_systemd_contracts
      ;;
    openrc)
      install_openrc_contracts
      ;;
    *)
      echo "warning: could not detect service manager in rootfs; skipping msl-init-bootloader service/NTP contract install" >&2
      ;;
  esac
}

build_from_source_dir() {
  source_dir="$1"
  case "$FS_TYPE" in
    btrfs)
      truncate -s "${SIZE_MB}M" "$OUTPUT_IMAGE" || fail_guest_stage "image_build" 1 "failed to allocate btrfs output image"
      progress_step "allocated output image"
      mkfs.btrfs -f "$OUTPUT_IMAGE" >/dev/null || fail_guest_stage "image_build" 1 "mkfs.btrfs failed"
      mount -o loop "$OUTPUT_IMAGE" "$OUTPUT_MOUNT_DIR" || fail_guest_stage "image_build" 1 "failed to mount btrfs output image"
      prepare_btrfs_policy "$OUTPUT_MOUNT_DIR"
      ;;
    ext4)
      truncate -s "${SIZE_MB}M" "$OUTPUT_IMAGE" || fail_guest_stage "image_build" 1 "failed to allocate ext4 output image"
      progress_step "allocated output image"
      mkfs.ext4 -q -F -E lazy_itable_init=1,lazy_journal_init=1 "$OUTPUT_IMAGE" || fail_guest_stage "image_build" 1 "mkfs.ext4 failed"
      mount -o loop "$OUTPUT_IMAGE" "$OUTPUT_MOUNT_DIR" || fail_guest_stage "image_build" 1 "failed to mount ext4 output image"
      ;;
    erofs)
      rm -f "$OUTPUT_IMAGE"
      progress_step "prepared erofs output path"
      if ! command -v mkfs.erofs >/dev/null 2>&1; then
        fail_guest_stage "image_build" 1 "mkfs.erofs command not found"
      fi
      mkfs.erofs "$OUTPUT_IMAGE" "$source_dir" >/dev/null || fail_guest_stage "image_build" 1 "mkfs.erofs failed"
      progress_step "built erofs image"
      max_bytes=$((SIZE_MB * 1024 * 1024))
      actual_bytes="$(stat -c %s "$OUTPUT_IMAGE" 2>/dev/null || stat -f %z "$OUTPUT_IMAGE" 2>/dev/null || echo 0)"
      case "$actual_bytes" in
        ''|*[!0-9]*)
          actual_bytes=0
          ;;
      esac
      if [ "$actual_bytes" -gt "$max_bytes" ]; then
        fail_guest_stage "image_build" 1 "erofs image exceeds requested size-mb: actual_bytes=$actual_bytes limit_bytes=$max_bytes"
      fi
      verify_output_fs_type "erofs"
      return
      ;;
  esac
  progress_step "formatted and mounted output filesystem"

  if ! tar -C "$source_dir" -cf - . | tar -C "$OUTPUT_MOUNT_DIR" -xf -; then
    fail_guest_stage "image_build" 1 "failed to copy source contents into output image"
  fi
  progress_step "copied source contents into image"

  if [ "$FS_TYPE" = "btrfs" ]; then
    apply_btrfs_policy "$OUTPUT_MOUNT_DIR"
  fi
  verify_output_fs_type "$FS_TYPE"
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
    install_extra_files
    extract_rootfs
    progress_step "extracted rootfs archive"
    write_runtime_summary
    install_init_binary
    install_packages
    progress_step "installed stage packages"
    resolve_size
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
