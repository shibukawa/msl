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

resolve_series_dir() {
  local version="$1"
  local major="${version%%.*}"
  if [[ "$version" == 2.6* ]]; then
    print -- "v2.6"
    return
  fi
  print -- "v${major}.x"
}

require_command curl
require_command tar
require_command shasum
require_command grep
require_command awk

: "${KERNEL_VERSION:=}"
if [[ -z "$KERNEL_VERSION" ]]; then
  fail "KERNEL_VERSION is required. example: make kernel-fetch-source KERNEL_VERSION=6.12.4"
fi

KERNEL_VERSION="${KERNEL_VERSION#linux-}"
if [[ ! "$KERNEL_VERSION" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?$' ]]; then
  fail "unsupported KERNEL_VERSION format: $KERNEL_VERSION (expected like 6.12.4 or 6.13-rc1)"
fi

KERNEL_FETCH_FORCE="${KERNEL_FETCH_FORCE:-0}"
KERNEL_FETCH_DRY_RUN="${KERNEL_FETCH_DRY_RUN:-0}"
KERNEL_MIRROR_ROOT="${KERNEL_MIRROR_ROOT:-https://cdn.kernel.org/pub/linux/kernel}"
SERIES_DIR="$(resolve_series_dir "$KERNEL_VERSION")"
TARBALL_NAME="linux-${KERNEL_VERSION}.tar.xz"
BASE_URL="${KERNEL_MIRROR_ROOT}/${SERIES_DIR}"
TARBALL_URL="${BASE_URL}/${TARBALL_NAME}"
SHA_URL="${BASE_URL}/sha256sums.asc"

CACHE_ROOT="${KERNEL_SOURCE_CACHE_DIR:-$ROOT_DIR/tmp/kernel-src/cache}"
OUT_ROOT="${KERNEL_SOURCE_OUT_DIR:-$ROOT_DIR/tmp/kernel-src}"
CACHE_DIR="${CACHE_ROOT}/${SERIES_DIR}"
TARBALL_PATH="${CACHE_DIR}/${TARBALL_NAME}"
SHA_PATH="${CACHE_DIR}/sha256sums.asc"
SRC_DIR="${OUT_ROOT}/linux-${KERNEL_VERSION}"

print -- "[resolve] kernel version: $KERNEL_VERSION"
print -- "[resolve] kernel.org series dir: $SERIES_DIR"
print -- "[resolve] tarball url: $TARBALL_URL"
print -- "[resolve] checksum url: $SHA_URL"
print -- "[resolve] cache dir: $CACHE_DIR"
print -- "[resolve] source dir: $SRC_DIR"

if [[ "$KERNEL_FETCH_DRY_RUN" == "1" ]]; then
  print -- "[dry-run] skip download and extraction"
  exit 0
fi

mkdir -p "$CACHE_DIR"
mkdir -p "$OUT_ROOT"

if [[ -f "$TARBALL_PATH" && "$KERNEL_FETCH_FORCE" != "1" ]]; then
  print -- "[download] reuse cached tarball: $TARBALL_PATH"
else
  print -- "[download] fetching tarball"
  curl -fL --retry 3 --retry-delay 1 -o "$TARBALL_PATH" "$TARBALL_URL"
fi

print -- "[download] fetching checksum index"
curl -fL --retry 3 --retry-delay 1 -o "$SHA_PATH" "$SHA_URL"

EXPECTED_SHA="$(awk -v name="$TARBALL_NAME" '$2 == name { print $1; exit }' "$SHA_PATH")"
if [[ -z "$EXPECTED_SHA" ]]; then
  local_series="${KERNEL_VERSION%.*}"
  nearby_versions="$(awk -v prefix="linux-${local_series}" '$2 ~ ("^" prefix "\\.") && $2 ~ /\\.tar\\.xz$/ { print "  - " $2 }' "$SHA_PATH" | head -n 5)"
  if [[ -z "$nearby_versions" ]]; then
    fail "could not find expected sha256 for ${TARBALL_NAME} in ${SHA_PATH}; this kernel version may not be published yet."
  fi
  fail "could not find expected sha256 for ${TARBALL_NAME} in ${SHA_PATH}; available nearby versions:\n${nearby_versions}"
fi
ACTUAL_SHA="$(shasum -a 256 "$TARBALL_PATH" | awk '{print $1}')"

if [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
  fail "sha256 mismatch for ${TARBALL_NAME}: expected=${EXPECTED_SHA} actual=${ACTUAL_SHA}"
fi
print -- "[verify] sha256 ok"

if [[ -d "$SRC_DIR" ]]; then
  if [[ "$KERNEL_FETCH_FORCE" == "1" ]]; then
    rm -rf "$SRC_DIR"
  else
    print -- "[extract] source already exists: $SRC_DIR"
    print -- "[done] use KERNEL_SRC=$SRC_DIR"
    exit 0
  fi
fi

print -- "[extract] extracting tarball"
tar -xJf "$TARBALL_PATH" -C "$OUT_ROOT"

if [[ ! -d "$SRC_DIR" ]]; then
  fail "extracted source directory not found: $SRC_DIR"
fi

print -- "[done] kernel source ready: $SRC_DIR"
print -- "[hint] build with: make kernel-build KERNEL_SRC=$SRC_DIR"
