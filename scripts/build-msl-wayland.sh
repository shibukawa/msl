#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$ROOT_DIR/Support/msl-wayland"
HOST_BUILD_DIR="$ROOT_DIR/.build/debug/wayland"
HOST_STAGE_DIR="${MSL_HOME:-$HOME}/.msl-system/wayland"
GUEST_TARGET="aarch64-unknown-linux-musl"
GUEST_LINKER="$ROOT_DIR/scripts/link-msl-init.sh"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo is required to build msl-wayland" >&2
  exit 1
fi

mkdir -p "$HOST_BUILD_DIR" "$HOST_STAGE_DIR"

cd "$WORKSPACE_DIR"

echo "building host wayland core library..."
cargo build -p msl-wayland-host-core --release

HOST_LIB="$WORKSPACE_DIR/target/release/libmsl_wayland_core.dylib"
if [ ! -f "$HOST_LIB" ]; then
  echo "error: host library was not produced at $HOST_LIB" >&2
  exit 1
fi
cp -f "$HOST_LIB" "$HOST_BUILD_DIR/libmsl_wayland_core.dylib"
cp -f "$HOST_LIB" "$HOST_STAGE_DIR/libmsl_wayland_core.dylib"

if command -v rustup >/dev/null 2>&1; then
  if ! rustup target list --installed | grep -q "^$GUEST_TARGET$"; then
    rustup target add "$GUEST_TARGET"
  fi
fi

echo "building guest wayland proxy..."
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="$GUEST_LINKER" \
  cargo build -p msl-wayland-guest-proxy --release --target "$GUEST_TARGET"

GUEST_BIN="$WORKSPACE_DIR/target/$GUEST_TARGET/release/msl-wayland-proxy"
if [ ! -f "$GUEST_BIN" ]; then
  echo "error: guest proxy was not produced at $GUEST_BIN" >&2
  exit 1
fi
if command -v file >/dev/null 2>&1; then
  FILE_OUT="$(file "$GUEST_BIN")"
  echo "$FILE_OUT"
  if ! echo "$FILE_OUT" | grep -q "ELF 64-bit.*ARM aarch64"; then
    echo "error: unexpected guest proxy binary format (expected Linux aarch64 ELF)." >&2
    exit 1
  fi
fi
cp -f "$GUEST_BIN" "$HOST_STAGE_DIR/msl-wayland-proxy"
chmod 0755 "$HOST_STAGE_DIR/msl-wayland-proxy"

echo "built host library: $HOST_BUILD_DIR/libmsl_wayland_core.dylib"
echo "staged host library: $HOST_STAGE_DIR/libmsl_wayland_core.dylib"
echo "staged guest proxy: $HOST_STAGE_DIR/msl-wayland-proxy"
