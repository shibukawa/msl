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

safe_remove_dir() {
  local target="$1"
  if [[ -z "$target" || "$target" == "/" ]]; then
    fail "refusing to remove unsafe path: '$target'"
  fi
  rm -rf "$target"
}

require_command docker
require_command rsync
require_command id

: "${KERNEL_VERSION:=}"
if [[ -z "$KERNEL_VERSION" ]]; then
  fail "KERNEL_VERSION is required. example: make kernel-build KERNEL_VERSION=7.0.0"
fi

KERNEL_VERSION="${KERNEL_VERSION#linux-}"
if [[ ! "$KERNEL_VERSION" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?(-rc[0-9]+)?$' ]]; then
  fail "unsupported KERNEL_VERSION format: $KERNEL_VERSION (expected like 7.0.0 or 7.1-rc1)"
fi

if [[ -n "${KERNEL_ID:-}" && -z "${KERNEL_PROFILE:-}" ]]; then
  KERNEL_PROFILE="$KERNEL_ID"
  print -u2 -- "warning: KERNEL_ID is deprecated; use KERNEL_PROFILE. mapped KERNEL_PROFILE=$KERNEL_PROFILE"
fi
KERNEL_PROFILE="${KERNEL_PROFILE:-slim}"
if [[ ! "$KERNEL_PROFILE" =~ '^[A-Za-z0-9._-]+$' ]]; then
  fail "KERNEL_PROFILE may contain only [A-Za-z0-9._-]: $KERNEL_PROFILE"
fi
KERNEL_EXPERIMENT_LTO="${KERNEL_EXPERIMENT_LTO:-0}"
KERNEL_TOOLCHAIN="${KERNEL_TOOLCHAIN:-auto}"
KERNEL_DOCKER_IMAGE="msl-kernel-builder:latest"
KERNEL_DOCKERFILE="$ROOT_DIR/Support/kernel/docker/Dockerfile"
KERNEL_DOCKER_WORK_VOLUME="${KERNEL_DOCKER_WORK_VOLUME:-msl-kernel-work}"
KERNEL_DOCKER_CCACHE="${KERNEL_DOCKER_CCACHE:-1}"
KERNEL_DOCKER_CCACHE_MAXSIZE="${KERNEL_DOCKER_CCACHE_MAXSIZE:-20G}"

CONTAINER_MSL_HOME="/workspace/tmp/docker-msl-home"
CONTAINER_WORK_ROOT="/var/tmp/msl-kernel-work"
CONTAINER_SOURCE_CACHE_DIR="$CONTAINER_WORK_ROOT/kernel-src/cache"
CONTAINER_SOURCE_OUT_DIR="$CONTAINER_WORK_ROOT/kernel-src"
CONTAINER_KERNEL_SRC="$CONTAINER_SOURCE_OUT_DIR/linux-$KERNEL_VERSION"
CONTAINER_BUILD_KEY="$KERNEL_VERSION-$KERNEL_PROFILE"
CONTAINER_BUILD_DIR="$CONTAINER_WORK_ROOT/kernel-build/$CONTAINER_BUILD_KEY/build"
CONTAINER_MODULES_STAGING="$CONTAINER_WORK_ROOT/kernel-build/$CONTAINER_BUILD_KEY/modules-root"
CONTAINER_CCACHE_DIR="$CONTAINER_WORK_ROOT/ccache"

HOST_DOCKER_OUTPUT="$ROOT_DIR/tmp/docker-msl-home/Library/Application Support/msl/kernels/$KERNEL_PROFILE"
HOST_FINAL_OUTPUT="${MSL_HOME:-$HOME}/Library/Application Support/msl/kernels/$KERNEL_PROFILE"

if [[ ! -f "$KERNEL_DOCKERFILE" ]]; then
  fail "dockerfile not found: $KERNEL_DOCKERFILE"
fi

need_rebuild=0
if ! docker image inspect "$KERNEL_DOCKER_IMAGE" >/dev/null 2>&1; then
  need_rebuild=1
elif ! docker run --rm "$KERNEL_DOCKER_IMAGE" python3 --version >/dev/null 2>&1; then
  need_rebuild=1
fi

if [[ "$need_rebuild" == "1" ]]; then
  print -- "[docker] building image: $KERNEL_DOCKER_IMAGE"
  DOCKER_BUILDKIT=1 docker build --build-arg "KERNEL_VERSION=$KERNEL_VERSION" -f "$KERNEL_DOCKERFILE" -t "$KERNEL_DOCKER_IMAGE" "$ROOT_DIR"
fi

print -- "[docker] run kernel build in container"
print -- "[docker] image: $KERNEL_DOCKER_IMAGE"
print -- "[docker] source version: $KERNEL_VERSION"
print -- "[docker] profile/artifact ref: $KERNEL_PROFILE lto_experiment=$KERNEL_EXPERIMENT_LTO"
print -- "[docker] work volume: $KERNEL_DOCKER_WORK_VOLUME"
print -- "[docker] ccache: enabled=$KERNEL_DOCKER_CCACHE maxsize=$KERNEL_DOCKER_CCACHE_MAXSIZE"

if [[ -d "$HOST_DOCKER_OUTPUT" ]]; then
  safe_remove_dir "$HOST_DOCKER_OUTPUT"
fi
if [[ -d "$HOST_FINAL_OUTPUT" ]]; then
  safe_remove_dir "$HOST_FINAL_OUTPUT"
fi

uid="$(id -u)"
gid="$(id -g)"

if ! docker volume inspect "$KERNEL_DOCKER_WORK_VOLUME" >/dev/null 2>&1; then
  print -- "[docker] creating work volume: $KERNEL_DOCKER_WORK_VOLUME"
  docker volume create "$KERNEL_DOCKER_WORK_VOLUME" >/dev/null
fi

print -- "[docker] preparing work volume ownership for uid:gid ${uid}:${gid}"
docker run --rm \
  --user 0:0 \
  -v "$KERNEL_DOCKER_WORK_VOLUME:$CONTAINER_WORK_ROOT" \
  "$KERNEL_DOCKER_IMAGE" \
  /bin/zsh -lc "mkdir -p '$CONTAINER_WORK_ROOT' && chown -R ${uid}:${gid} '$CONTAINER_WORK_ROOT'"

CONTAINER_BUILD_CMD='
set -euo pipefail
if [[ "${KERNEL_EXPERIMENT_LTO:-0}" == "1" && "${KERNEL_TOOLCHAIN:-auto}" == "auto" ]]; then
  export KERNEL_TOOLCHAIN=llvm
fi
if [[ "${KERNEL_DOCKER_CCACHE:-1}" == "1" ]] && command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${CCACHE_DIR:-/var/tmp/msl-kernel-work/ccache}"
  export CCACHE_BASEDIR="/workspace"
  export CCACHE_COMPRESS=1
  export CCACHE_SLOPPINESS=time_macros
  ccache -M "${KERNEL_DOCKER_CCACHE_MAXSIZE:-20G}" >/dev/null 2>&1 || true
  if [[ "${KERNEL_TOOLCHAIN:-auto}" == "llvm" ]]; then
    export CC="ccache clang"
  else
    export CC="ccache gcc"
  fi
fi
/workspace/scripts/fetch-kernel-source.sh
/workspace/scripts/build-kernel.sh
if [[ "${KERNEL_DOCKER_CCACHE:-1}" == "1" ]] && command -v ccache >/dev/null 2>&1; then
  ccache -s || true
fi
'

docker run --rm \
  --user "${uid}:${gid}" \
  -e HOME=/tmp \
  -e MSL_HOME="$CONTAINER_MSL_HOME" \
  -e KERNEL_DOCKER_CCACHE="$KERNEL_DOCKER_CCACHE" \
  -e KERNEL_DOCKER_CCACHE_MAXSIZE="$KERNEL_DOCKER_CCACHE_MAXSIZE" \
  -e CCACHE_DIR="$CONTAINER_CCACHE_DIR" \
  -e KERNEL_VERSION="$KERNEL_VERSION" \
  -e KERNEL_SOURCE_CACHE_DIR="$CONTAINER_SOURCE_CACHE_DIR" \
  -e KERNEL_SOURCE_OUT_DIR="$CONTAINER_SOURCE_OUT_DIR" \
  -e KERNEL_SRC="$CONTAINER_KERNEL_SRC" \
  -e KERNEL_PROFILE="$KERNEL_PROFILE" \
  -e KERNEL_EXPERIMENT_LTO="$KERNEL_EXPERIMENT_LTO" \
  -e KERNEL_TOOLCHAIN="$KERNEL_TOOLCHAIN" \
  -e KERNEL_ARCH=arm64 \
  -e KERNEL_SOURCE_REF="v$KERNEL_VERSION" \
  -e KERNEL_FORCE=1 \
  -e KERNEL_JOBS=4 \
  -e KBUILD_BUILD_USER=msl \
  -e KBUILD_BUILD_HOST=docker \
  -e KERNEL_BUILD_DIR="$CONTAINER_BUILD_DIR" \
  -e KERNEL_MODULES_STAGING="$CONTAINER_MODULES_STAGING" \
  -v "$KERNEL_DOCKER_WORK_VOLUME:$CONTAINER_WORK_ROOT" \
  -v "$ROOT_DIR:/workspace" \
  -w /workspace \
  "$KERNEL_DOCKER_IMAGE" \
  /bin/zsh -lc "$CONTAINER_BUILD_CMD"

if [[ ! -d "$HOST_DOCKER_OUTPUT" ]]; then
  fail "container output not found: $HOST_DOCKER_OUTPUT"
fi

mkdir -p "$(dirname "$HOST_FINAL_OUTPUT")"
rsync -a --delete "$HOST_DOCKER_OUTPUT/" "$HOST_FINAL_OUTPUT/"

print -- "[done] host artifacts: $HOST_FINAL_OUTPUT"
print -- "[done] workspace copy: $HOST_DOCKER_OUTPUT"
