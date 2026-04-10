#!/bin/sh
set -eu

if command -v clang >/dev/null 2>&1; then
  CLANG_BIN="$(command -v clang)"
elif command -v cc >/dev/null 2>&1; then
  CLANG_BIN="$(command -v cc)"
else
  echo "error: clang is required to link msl-init for aarch64-unknown-linux-musl" >&2
  exit 1
fi

if command -v ld.lld >/dev/null 2>&1; then
  LLD_BIN="$(command -v ld.lld)"
elif command -v lld >/dev/null 2>&1; then
  LLD_BIN="$(command -v lld)"
else
  echo "error: lld is required to link msl-init for aarch64-unknown-linux-musl" >&2
  echo "hint: brew install llvm" >&2
  exit 1
fi

exec "$CLANG_BIN" \
  --target=aarch64-unknown-linux-musl \
  -fuse-ld="$LLD_BIN" \
  "$@"
