#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
MSL_BIN="${MSL_BIN:-$ROOT_DIR/.build/debug/msl}"
INSTANCE="${IMAGEWRITER_INSTANCE:-_imagewriter}"
PACKAGES="${IMAGEWRITER_PACKAGES:-btrfs-progs e2fsprogs util-linux tar zstd xz coreutils}"
CLEAN_DISTROS="${IMAGEWRITER_CLEAN_DISTROS:-1}"
REBUILD_BOOTSTRAP="${IMAGEWRITER_REBUILD_BOOTSTRAP:-1}"
RETRY_LIMIT="${IMAGEWRITER_RETRY_LIMIT:-1}"
APK_RETRY_LIMIT="${IMAGEWRITER_APK_RETRY_LIMIT:-5}"

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

msl_retry() {
  attempts=0
  while true; do
    if "$MSL_BIN" "$@"; then
      return 0
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$RETRY_LIMIT" ]; then
      return 1
    fi
    sleep 1
  done
}

instance_exists() {
  "$MSL_BIN" --list 2>/dev/null | sed -e 's/ \[default\]$//' | awk '{print $1}' | grep -Fx "$INSTANCE" >/dev/null 2>&1
}

if [ "$CLEAN_DISTROS" = "1" ]; then
  echo "cleaning distros before imagewriter setup..."
  "$MSL_BIN" stop >/dev/null 2>&1 || true
  INSTANCES="$($MSL_BIN --list 2>/dev/null | sed -e 's/ \[default\]$//' | awk '{print $1}')"
  if [ -n "$INSTANCES" ]; then
    for name in $INSTANCES; do
      echo "uninstalling instance (keep cache): $name"
      "$MSL_BIN" uninstall --keep-cache "$name"
    done
  else
    echo "no installed instances to clean"
  fi
fi

echo "resetting imagewriter instance: $INSTANCE"
"$MSL_BIN" stop >/dev/null 2>&1 || true
"$MSL_BIN" uninstall --keep-cache "$INSTANCE" >/dev/null 2>&1 || true

echo "creating imagewriter instance: $INSTANCE"
if instance_exists; then
  echo "imagewriter instance exists: $INSTANCE"
  if [ "$REBUILD_BOOTSTRAP" = "1" ]; then
    "$MSL_BIN" stop >/dev/null 2>&1 || true
    msl_retry _bootstrap-install --rebuild --name "$INSTANCE" alpine
  fi
else
  "$MSL_BIN" stop >/dev/null 2>&1 || true
  # Bootstrap invariant:
  # _imagewriter itself must be created by the legacy bootstrap path (ext4),
  # otherwise `install` would recursively depend on imagewriter.
  msl_retry _bootstrap-install --name "$INSTANCE" alpine
fi

# NOTE:
# MSL_RUNTIME_USER_ROOT is read by daemon startup context.
# If daemon is already running with host-user context, root-required setup
# commands (apk add) may fail. Force a daemon restart before root operations.
"$MSL_BIN" --instance "$INSTANCE" stop >/dev/null 2>&1 || true

MSL_RUNTIME_USER_ROOT=1 msl_retry --instance "$INSTANCE" run true >/dev/null

MSL_RUNTIME_USER_ROOT=1 msl_retry --instance "$INSTANCE" run -- sh -lc '
set -eu
pkgs="$1"
retry_limit="$2"

run_root() {
  cmd="$1"
  if [ "$(id -u)" -eq 0 ]; then
    sh -lc "$cmd"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo -n sh -lc "$cmd" 2>/dev/null || sudo sh -lc "$cmd"
    return
  fi
  if command -v doas >/dev/null 2>&1; then
    doas sh -lc "$cmd"
    return
  fi
  if command -v su >/dev/null 2>&1; then
    su -c "$cmd" || {
      echo "error: su failed (non-interactive). configure sudo/doas or run setup in an interactive shell." >&2
      exit 1
    }
    return
  fi
  echo "error: cannot escalate privileges to install apk packages" >&2
  exit 1
}

apk_add_with_retry() {
  attempts=0
  while true; do
    # shellcheck disable=SC2086
    if run_root "apk add --no-cache $pkgs"; then
      return 0
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$retry_limit" ]; then
      echo "error: apk add failed after $attempts attempts" >&2
      exit 1
    fi
    echo "warning: apk add failed (attempt $attempts/$retry_limit), retrying..." >&2
    sleep "$attempts"
  done
}

apk_add_with_retry

for p in $pkgs; do
  apk info -e "$p" >/dev/null
  echo "installed: $p"
done
' sh "$PACKAGES" "$APK_RETRY_LIMIT"

echo "imagewriter setup completed"
echo "instance: $INSTANCE"
