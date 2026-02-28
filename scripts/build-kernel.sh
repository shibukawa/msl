#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

json_escape() {
  print -rn -- "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

fail() {
  print -u2 -- "error: $1"
  exit 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "required command not found: $1"
  fi
}

parse_make_version() {
  local cmd="$1"
  local first
  first="$("$cmd" --version 2>/dev/null | head -n1 || true)"
  if [[ "$first" =~ 'GNU Make' ]]; then
    # Expected format: GNU Make X.Y[.Z]
    local version="${first##*GNU Make }"
    version="${version%% *}"
    print -- "$version"
    return
  fi
  print -- ""
}

is_make_ge_4() {
  local cmd="$1"
  local ver
  ver="$(parse_make_version "$cmd")"
  if [[ -z "$ver" ]]; then
    return 1
  fi
  local major="${ver%%.*}"
  local rest="${ver#*.}"
  local minor="${rest%%.*}"
  [[ -z "$minor" ]] && minor=0
  if (( major > 4 )); then
    return 0
  fi
  if (( major == 4 )) && (( minor >= 0 )); then
    return 0
  fi
  return 1
}

resolve_kernel_make() {
  local explicit="${KERNEL_MAKE_BIN:-}"
  if [[ -n "$explicit" ]]; then
    if ! command -v "$explicit" >/dev/null 2>&1; then
      fail "KERNEL_MAKE_BIN is not executable: $explicit"
    fi
    if ! is_make_ge_4 "$explicit"; then
      fail "KERNEL_MAKE_BIN must be GNU Make >= 4.0: $explicit"
    fi
    print -- "$explicit"
    return
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    if command -v gmake >/dev/null 2>&1 && is_make_ge_4 gmake; then
      print -- "gmake"
      return
    fi
    fail "On macOS, GNU Make >= 4.0 is required. install it with 'brew install make'."
  fi

  local candidate
  for candidate in gmake make; do
    if command -v "$candidate" >/dev/null 2>&1 && is_make_ge_4 "$candidate"; then
      print -- "$candidate"
      return
    fi
  done

  fail "GNU Make >= 4.0 is required for Linux kernel build. install it (e.g. 'brew install make') and re-run with KERNEL_MAKE_BIN=gmake if needed."
}

resolve_toolchain_mode() {
  local mode="${KERNEL_TOOLCHAIN:-auto}"
  case "$mode" in
    auto)
      if [[ "$(uname -s)" == "Darwin" ]]; then
        print -- "llvm"
      else
        print -- "gnu"
      fi
      ;;
    llvm|gnu)
      print -- "$mode"
      ;;
    *)
      fail "KERNEL_TOOLCHAIN must be one of: auto, llvm, gnu"
      ;;
  esac
}

prepend_path_if_dir() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    export PATH="$dir:$PATH"
  fi
}

prepare_llvm_toolchain() {
  if command -v brew >/dev/null 2>&1; then
    local llvm_prefix
    local lld_prefix
    llvm_prefix="$(brew --prefix llvm 2>/dev/null || true)"
    lld_prefix="$(brew --prefix lld 2>/dev/null || true)"
    if [[ -n "$llvm_prefix" ]]; then
      prepend_path_if_dir "$llvm_prefix/bin"
    fi
    if [[ -n "$lld_prefix" ]]; then
      prepend_path_if_dir "$lld_prefix/bin"
    fi
  fi

  if [[ -n "${KERNEL_LLVM_BIN_DIR:-}" ]]; then
    prepend_path_if_dir "$KERNEL_LLVM_BIN_DIR"
  fi

  if ! command -v ld.lld >/dev/null 2>&1; then
    prepend_path_if_dir "/opt/homebrew/opt/llvm/bin"
    prepend_path_if_dir "/usr/local/opt/llvm/bin"
    prepend_path_if_dir "/opt/homebrew/opt/lld/bin"
    prepend_path_if_dir "/usr/local/opt/lld/bin"
  fi

  local tool
  for tool in clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-strip; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      fail "LLVM toolchain requires '$tool' in PATH. install dependencies (e.g. 'brew install llvm lld') or set KERNEL_LLVM_BIN_DIR."
    fi
  done
}

build_make_common_args() {
  MAKE_COMMON_ARGS=("ARCH=$KERNEL_ARCH")
  if [[ "$TOOLCHAIN_MODE" == "llvm" ]]; then
    MAKE_COMMON_ARGS+=("LLVM=1" "LLVM_IAS=1")
  else
    if [[ -n "${KERNEL_CROSS_COMPILE:-}" ]]; then
      MAKE_COMMON_ARGS+=("CROSS_COMPILE=${KERNEL_CROSS_COMPILE}")
    fi
  fi
}

resolve_jobs() {
  local is_positive_int='^[1-9][0-9]*$'

  if [[ -n "${KERNEL_JOBS:-}" ]]; then
    if [[ ! "$KERNEL_JOBS" =~ $is_positive_int ]]; then
      fail "KERNEL_JOBS must be a positive integer: '$KERNEL_JOBS'"
    fi
    print -- "$KERNEL_JOBS"
    return
  fi

  if command -v sysctl >/dev/null 2>&1; then
    local n
    n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
    if [[ "$n" =~ $is_positive_int ]]; then
      print -- "$n"
      return
    fi
  fi
  if command -v getconf >/dev/null 2>&1; then
    local n
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    if [[ "$n" =~ $is_positive_int ]]; then
      print -- "$n"
      return
    fi
  fi

  if command -v nproc >/dev/null 2>&1; then
    local n
    n="$(nproc 2>/dev/null || true)"
    if [[ "$n" =~ $is_positive_int ]]; then
      print -- "$n"
      return
    fi
  fi

  print -- "4"
}

get_config_value() {
  local key="$1"
  if grep -q "^${key}=y$" "$BUILD_DIR/.config"; then
    print -- "y"
    return
  fi
  if grep -q "^${key}=m$" "$BUILD_DIR/.config"; then
    print -- "m"
    return
  fi
  if grep -q "^# ${key} is not set$" "$BUILD_DIR/.config"; then
    print -- "n"
    return
  fi
  print -- "missing"
}

check_expected() {
  local expected="$1"
  local actual="$2"
  case "$expected" in
    y)
      [[ "$actual" == "y" ]]
      ;;
    y_or_m)
      [[ "$actual" == "y" || "$actual" == "m" ]]
      ;;
    present)
      [[ "$actual" != "n" && "$actual" != "missing" ]]
      ;;
    n)
      [[ "$actual" == "n" || "$actual" == "missing" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

file_size_bytes() {
  local path="$1"
  local size
  size="$(stat -c%s "$path" 2>/dev/null || true)"
  if [[ "$size" =~ '^[0-9]+$' ]]; then
    print -- "$size"
    return
  fi
  size="$(stat -f%z "$path" 2>/dev/null || true)"
  if [[ "$size" =~ '^[0-9]+$' ]]; then
    print -- "$size"
    return
  fi
  print -- "0"
}

resolve_kernel_profile() {
  local profile="${KERNEL_PROFILE:-slim}"
  if [[ ! "$profile" =~ '^[A-Za-z0-9._-]+$' ]]; then
    fail "KERNEL_PROFILE may contain only [A-Za-z0-9._-]: $profile"
  fi
  print -- "$profile"
}

resolve_default_config_fragment() {
  local profile="$1"
  case "$profile" in
    minimal-builtins-v1)
      print -- "$ROOT_DIR/Support/kernel/config/msl-minimal-builtins-v1.fragment"
      return
      ;;
    minimum-defconfig)
      print -- "$ROOT_DIR/Support/kernel/config/msl-minimum-defconfig.fragment"
      return
      ;;
    apple-containerization-6.1.68)
      print -- "$ROOT_DIR/Support/kernel/config/msl-apple-containerization-6.1.68.fragment"
      return
      ;;
    legacy-defconfig)
      print -- "$ROOT_DIR/Support/kernel/config/msl-virtio.fragment"
      return
      ;;
  esac

  local direct="$ROOT_DIR/Support/kernel/config/msl-${profile}.fragment"
  if [[ -f "$direct" ]]; then
    print -- "$direct"
    return
  fi

  local defconfig_named="$ROOT_DIR/Support/kernel/config/msl-${profile}-defconfig.fragment"
  if [[ -f "$defconfig_named" ]]; then
    print -- "$defconfig_named"
    return
  fi

  fail "KERNEL_CONFIG_FRAGMENT is not set and no fragment was found for KERNEL_PROFILE=$profile (looked for $direct and $defconfig_named)"
}

safe_remove_dir() {
  local target="$1"
  if [[ -z "$target" || "$target" == "/" ]]; then
    fail "refusing to remove unsafe path: '$target'"
  fi
  rm -rf "$target"
}

run_with_heartbeat() {
  local phase="$1"
  shift

  "$@" &
  local cmd_pid=$!
  local elapsed=0

  while kill -0 "$cmd_pid" >/dev/null 2>&1; do
    sleep 30
    elapsed=$((elapsed + 30))
    if kill -0 "$cmd_pid" >/dev/null 2>&1; then
      print -- "[$phase] still running (${elapsed}s elapsed)"
    fi
  done

  wait "$cmd_pid"
}

host_compiler_has_header() {
  local header="$1"
  local extra_cflags="${2:-}"
  local cc="${HOSTCC:-cc}"
  if ! command -v "$cc" >/dev/null 2>&1; then
    return 1
  fi

  local -a extra_args
  extra_args=()
  if [[ -n "$extra_cflags" ]]; then
    extra_args=("${(@z)extra_cflags}")
  fi

  local src
  src="$(mktemp "${TMPDIR:-/tmp}/msl-header-check.XXXXXX.c")"
  cat > "$src" <<EOF
#include <$header>
int main(void) { return 0; }
EOF
  "$cc" "${extra_args[@]}" -x c -fsyntax-only "$src" >/dev/null 2>&1
  local rc=$?
  rm -f "$src"
  return "$rc"
}

host_compiler_has_usable_elf_h() {
  local extra_cflags="${1:-}"
  local cc="${HOSTCC:-cc}"
  if ! command -v "$cc" >/dev/null 2>&1; then
    return 1
  fi

  local -a extra_args
  extra_args=()
  if [[ -n "$extra_cflags" ]]; then
    extra_args=("${(@z)extra_cflags}")
  fi

  local src
  src="$(mktemp "${TMPDIR:-/tmp}/msl-elf-api-check.XXXXXX.c")"
  cat > "$src" <<'EOF'
#include <elf.h>
int main(void) {
  unsigned long v = 0;
  v += (unsigned long)ELF64_ST_TYPE(0);
  v += (unsigned long)ELF64_ST_BIND(0);
  v += (unsigned long)STT_SPARC_REGISTER;
  v += (unsigned long)STT_LOPROC;
  v += (unsigned long)R_ARM_CALL;
  v += (unsigned long)R_386_32;
  v += (unsigned long)SHN_XINDEX;
  v += (unsigned long)SHT_SYMTAB_SHNDX;
  return (int)v;
}
EOF
  "$cc" "${extra_args[@]}" -x c -fsyntax-only "$src" >/dev/null 2>&1
  local rc=$?
  rm -f "$src"
  return "$rc"
}

find_libelf_include_dir() {
  typeset -a candidates
  candidates=()
  if [[ -n "${KERNEL_LIBELF_INCLUDE_DIR:-}" ]]; then
    candidates+=("${KERNEL_LIBELF_INCLUDE_DIR}")
  fi
  if command -v brew >/dev/null 2>&1; then
    local prefix
    prefix="$(brew --prefix libelf 2>/dev/null || true)"
    if [[ -n "$prefix" ]]; then
      candidates+=("$prefix/include")
    fi
  fi
  candidates+=(
    "/opt/homebrew/include"
    "/usr/local/include"
    "/opt/homebrew/opt/libelf/include"
    "/usr/local/opt/libelf/include"
  )

  local dir
  for dir in "${candidates[@]}"; do
    if [[ -f "$dir/elf.h" ]]; then
      print -- "$dir"
      return 0
    fi
  done
  return 1
}

setup_host_elf_compat() {
  HOST_ELF_COMPAT_MODE="system"
  HOST_BYTESWAP_COMPAT_MODE="system"
  HOST_COMPAT_SHIMS=""
  HOST_COMPAT_INCLUDE_DIR=""

  local base_host_cflags="${KERNEL_HOST_CFLAGS:-${KERNEL_HOSTCFLAGS:-${HOSTCFLAGS:-}}}"
  local effective_host_cflags="$base_host_cflags"
  local libelf_include=""

  if ! host_compiler_has_usable_elf_h "$effective_host_cflags"; then
    libelf_include="$(find_libelf_include_dir || true)"
    if [[ -n "$libelf_include" ]]; then
      if [[ -n "$effective_host_cflags" ]]; then
        effective_host_cflags="$effective_host_cflags -I$libelf_include"
      else
        effective_host_cflags="-I$libelf_include"
      fi
      if host_compiler_has_usable_elf_h "$effective_host_cflags"; then
        HOST_ELF_COMPAT_MODE="libelf"
      else
        fail "found $libelf_include/elf.h but it is not sufficient for kernel host tools. install/update libelf (brew install libelf)."
      fi
    else
      fail "usable <elf.h> not found for kernel host tools. On macOS install dependency: brew install libelf"
    fi
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    if [[ -n "$effective_host_cflags" ]]; then
      effective_host_cflags="$effective_host_cflags -D_UUID_T"
    else
      effective_host_cflags="-D_UUID_T"
    fi
  fi

  local compat_dir="$BUILD_DIR/.msl-host-compat/include"
  typeset -a installed_shims
  installed_shims=()

  if ! host_compiler_has_header "byteswap.h" "$effective_host_cflags"; then
    mkdir -p "$compat_dir"
    cat > "$compat_dir/byteswap.h" <<'EOF'
#ifndef __MSL_COMPAT_BYTESWAP_H__
#define __MSL_COMPAT_BYTESWAP_H__

#include <stdint.h>

#ifndef bswap_16
#define bswap_16(x) __builtin_bswap16((uint16_t)(x))
#endif
#ifndef bswap_32
#define bswap_32(x) __builtin_bswap32((uint32_t)(x))
#endif
#ifndef bswap_64
#define bswap_64(x) __builtin_bswap64((uint64_t)(x))
#endif

#endif /* __MSL_COMPAT_BYTESWAP_H__ */
EOF
    if [[ -n "$effective_host_cflags" ]]; then
      effective_host_cflags="$effective_host_cflags -I$compat_dir"
    else
      effective_host_cflags="-I$compat_dir"
    fi
    HOST_BYTESWAP_COMPAT_MODE="shim"
    HOST_COMPAT_INCLUDE_DIR="$compat_dir"
    installed_shims+=("byteswap.h")
  fi

  if [[ "$effective_host_cflags" != "$base_host_cflags" ]]; then
    MAKE_COMMON_ARGS+=("HOSTCFLAGS=$effective_host_cflags")
  fi
  HOST_COMPAT_SHIMS="${(j:, :)installed_shims}"
}

can_use_merge_config_script() {
  local script_path="$1"
  if [[ ! -x "$script_path" ]]; then
    return 1
  fi
  # Linux's merge_config.sh requires GNU readlink (-m). BSD readlink (macOS) lacks it.
  if ! readlink -m / >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

select_kernel_image() {
  local -a candidates
  case "$KERNEL_ARCH" in
    arm64|aarch64)
      candidates=(
        "$BUILD_DIR/arch/arm64/boot/Image"
      )
      ;;
    x86_64|x86)
      candidates=(
        "$BUILD_DIR/arch/x86/boot/bzImage"
        "$BUILD_DIR/arch/x86_64/boot/bzImage"
      )
      ;;
    *)
      candidates=(
        "$BUILD_DIR/arch/$KERNEL_ARCH/boot/Image"
        "$BUILD_DIR/arch/$KERNEL_ARCH/boot/Image.gz"
        "$BUILD_DIR/arch/$KERNEL_ARCH/boot/bzImage"
      )
      ;;
  esac

  local path
  for path in "${candidates[@]}"; do
    if [[ -f "$path" ]]; then
      print -- "$path"
      return
    fi
  done
  fail "unable to find built kernel image for ARCH=$KERNEL_ARCH"
}

is_gzip_file() {
  local path="$1"
  gzip -t "$path" >/dev/null 2>&1
}

install_kernel_image() {
  local source="$1"
  local target="$2"
  if is_gzip_file "$source"; then
    print -- "[install] kernel image is gzip-compressed; expanding to uncompressed vmlinuz"
    gzip -dc "$source" > "$target"
  else
    cp "$source" "$target"
  fi

  if is_gzip_file "$target"; then
    fail "output kernel image is still gzip-compressed: $target"
  fi
}

require_command rsync
require_command sed
require_command grep
require_command date
require_command uname
require_command mktemp
require_command gzip

: "${KERNEL_SRC:=}"

if [[ -z "$KERNEL_SRC" ]]; then
  fail "KERNEL_SRC is required. example: make kernel-build KERNEL_SRC=/path/to/linux [KERNEL_PROFILE=<id>]"
fi

KERNEL_ARCH="${KERNEL_ARCH:-arm64}"
KERNEL_SOURCE_REF="${KERNEL_SOURCE_REF:-unknown}"
KERNEL_FORCE="${KERNEL_FORCE:-0}"
KERNEL_INITRD_PATH="${KERNEL_INITRD_PATH:-}"
KERNEL_EXPERIMENT_LTO="${KERNEL_EXPERIMENT_LTO:-0}"
if [[ -n "${KERNEL_ID:-}" && -z "${KERNEL_PROFILE:-}" ]]; then
  KERNEL_PROFILE="$KERNEL_ID"
  print -u2 -- "warning: KERNEL_ID is deprecated; use KERNEL_PROFILE. mapped KERNEL_PROFILE=$KERNEL_PROFILE"
fi
KERNEL_PROFILE="$(resolve_kernel_profile)"
if [[ -z "${KERNEL_DEFCONFIG:-}" ]]; then
  if [[ "$KERNEL_PROFILE" == "minimal-builtins-v1" || "$KERNEL_PROFILE" == "apple-containerization-6.1.68" ]]; then
    KERNEL_DEFCONFIG="allnoconfig"
  else
    KERNEL_DEFCONFIG="defconfig"
  fi
else
  KERNEL_DEFCONFIG="${KERNEL_DEFCONFIG}"
fi
if [[ -z "${KERNEL_CONFIG_FRAGMENT:-}" ]]; then
  KERNEL_CONFIG_FRAGMENT="$(resolve_default_config_fragment "$KERNEL_PROFILE")"
else
  KERNEL_CONFIG_FRAGMENT="${KERNEL_CONFIG_FRAGMENT}"
fi
KERNEL_JOBS="$(resolve_jobs)"

if [[ ! -d "$KERNEL_SRC" ]]; then
  fail "KERNEL_SRC does not exist: $KERNEL_SRC"
fi
KERNEL_SRC="$(cd "$KERNEL_SRC" && pwd -P)"

if [[ ! -f "$KERNEL_SRC/Makefile" ]]; then
  fail "KERNEL_SRC does not look like a Linux kernel source tree: missing Makefile"
fi
if [[ ! -f "$KERNEL_CONFIG_FRAGMENT" ]]; then
  fail "KERNEL_CONFIG_FRAGMENT not found: $KERNEL_CONFIG_FRAGMENT"
fi
if [[ "$KERNEL_EXPERIMENT_LTO" != "0" && "$KERNEL_EXPERIMENT_LTO" != "1" ]]; then
  fail "KERNEL_EXPERIMENT_LTO must be 0 or 1"
fi

KERNEL_MAKE_BIN="$(resolve_kernel_make)"
TOOLCHAIN_MODE="$(resolve_toolchain_mode)"
if [[ "$TOOLCHAIN_MODE" == "llvm" ]]; then
  prepare_llvm_toolchain
fi
if [[ "$KERNEL_EXPERIMENT_LTO" == "1" && "$TOOLCHAIN_MODE" != "llvm" ]]; then
  fail "KERNEL_EXPERIMENT_LTO=1 requires LLVM toolchain mode"
fi
typeset -a MAKE_COMMON_ARGS
build_make_common_args

KERNEL_ARTIFACT_REF="$KERNEL_PROFILE"

MSL_HOME_DIR="${MSL_HOME:-$HOME}"
OUTPUT_DIR="$MSL_HOME_DIR/Library/Application Support/msl/kernels/$KERNEL_ARTIFACT_REF"
BUILD_DIR="${KERNEL_BUILD_DIR:-$ROOT_DIR/tmp/kernel-build/$KERNEL_ARTIFACT_REF/build}"
MODULES_STAGING="${KERNEL_MODULES_STAGING:-$ROOT_DIR/tmp/kernel-build/$KERNEL_ARTIFACT_REF/modules-root}"
BUILD_LOG="$OUTPUT_DIR/build.log"
START_EPOCH="$(date +%s)"

if [[ "$BUILD_DIR" == *" "* ]]; then
  fail "KERNEL_BUILD_DIR must not contain spaces: $BUILD_DIR"
fi
if [[ "$MODULES_STAGING" == *" "* ]]; then
  fail "KERNEL_MODULES_STAGING must not contain spaces: $MODULES_STAGING"
fi

if [[ -d "$OUTPUT_DIR" ]]; then
  if [[ "$KERNEL_FORCE" == "1" ]]; then
    safe_remove_dir "$OUTPUT_DIR"
  else
    fail "output already exists: $OUTPUT_DIR (set KERNEL_FORCE=1 to replace)"
  fi
fi

mkdir -p "$OUTPUT_DIR"
mkdir -p "$BUILD_DIR"

: > "$BUILD_LOG"
exec > >(tee -a "$BUILD_LOG") 2>&1

print -- "[validate] kernel source: $KERNEL_SRC"
print -- "[validate] kernel profile/artifact ref: $KERNEL_ARTIFACT_REF"
print -- "[validate] arch=$KERNEL_ARCH defconfig=$KERNEL_DEFCONFIG jobs=$KERNEL_JOBS"
print -- "[validate] kernel make: $KERNEL_MAKE_BIN"
print -- "[validate] toolchain mode: $TOOLCHAIN_MODE"
print -- "[validate] profile: $KERNEL_PROFILE lto_experiment=$KERNEL_EXPERIMENT_LTO"
print -- "[validate] fragment: $KERNEL_CONFIG_FRAGMENT"
print -- "[validate] output: $OUTPUT_DIR"

print -- "[configure] base defconfig"
"$KERNEL_MAKE_BIN" -C "$KERNEL_SRC" O="$BUILD_DIR" "${MAKE_COMMON_ARGS[@]}" "$KERNEL_DEFCONFIG"

if can_use_merge_config_script "$KERNEL_SRC/scripts/kconfig/merge_config.sh"; then
  print -- "[configure] merge fragment using scripts/kconfig/merge_config.sh"
  (
    cd "$KERNEL_SRC"
    scripts/kconfig/merge_config.sh -O "$BUILD_DIR" "$BUILD_DIR/.config" "$KERNEL_CONFIG_FRAGMENT"
  )
else
  print -- "[configure] merge fragment by append fallback (merge_config.sh needs readlink -m)"
  cat "$KERNEL_CONFIG_FRAGMENT" >> "$BUILD_DIR/.config"
fi

if [[ "$KERNEL_EXPERIMENT_LTO" == "1" ]]; then
  print -- "[configure] apply LTO experiment settings"
  cat >> "$BUILD_DIR/.config" <<'EOF'
CONFIG_LTO_CLANG=y
# CONFIG_LTO_NONE is not set
EOF
fi

print -- "[configure] olddefconfig"
"$KERNEL_MAKE_BIN" -C "$KERNEL_SRC" O="$BUILD_DIR" "${MAKE_COMMON_ARGS[@]}" olddefconfig

print -- "[configure] host elf.h check"
setup_host_elf_compat
print -- "[configure] host header mode: elf=$HOST_ELF_COMPAT_MODE byteswap=$HOST_BYTESWAP_COMPAT_MODE"
if [[ -n "$HOST_COMPAT_SHIMS" ]]; then
  print -- "[configure] installed host compatibility shims: $HOST_COMPAT_SHIMS"
fi
if [[ -n "$HOST_COMPAT_INCLUDE_DIR" ]]; then
print -- "[configure] host compatibility include dir: $HOST_COMPAT_INCLUDE_DIR"
fi

typeset -a BUILD_TARGETS
if grep -q '^CONFIG_MODULES=y$' "$BUILD_DIR/.config"; then
  BUILD_TARGETS=(Image modules)
else
  BUILD_TARGETS=(Image)
fi
print -- "[build] kernel targets: ${BUILD_TARGETS[*]}"
run_with_heartbeat "build" "$KERNEL_MAKE_BIN" -C "$KERNEL_SRC" O="$BUILD_DIR" "${MAKE_COMMON_ARGS[@]}" -j"$KERNEL_JOBS" "${BUILD_TARGETS[@]}"

KERNEL_IMAGE_PATH="$(select_kernel_image)"
print -- "[install] kernel image: $KERNEL_IMAGE_PATH"
install_kernel_image "$KERNEL_IMAGE_PATH" "$OUTPUT_DIR/vmlinuz"
cp "$BUILD_DIR/.config" "$OUTPUT_DIR/kernel.config"

if grep -q '^CONFIG_MODULES=y$' "$BUILD_DIR/.config"; then
  print -- "[install] modules_install"
  mkdir -p "$MODULES_STAGING"
  "$KERNEL_MAKE_BIN" -C "$KERNEL_SRC" O="$BUILD_DIR" "${MAKE_COMMON_ARGS[@]}" INSTALL_MOD_PATH="$MODULES_STAGING" modules_install
  mkdir -p "$OUTPUT_DIR/modules"
  if [[ -d "$MODULES_STAGING/lib/modules" ]]; then
    rsync -a --delete "$MODULES_STAGING/lib/modules/" "$OUTPUT_DIR/modules/"
  fi
else
  print -- "[install] skip modules output for profile=$KERNEL_PROFILE"
fi
if [[ -d "$MODULES_STAGING" ]]; then
  safe_remove_dir "$MODULES_STAGING"
fi

if [[ -n "$KERNEL_INITRD_PATH" ]]; then
  if [[ ! -f "$KERNEL_INITRD_PATH" ]]; then
    fail "KERNEL_INITRD_PATH does not exist: $KERNEL_INITRD_PATH"
  fi
  print -- "[install] optional initrd from $KERNEL_INITRD_PATH"
  cp "$KERNEL_INITRD_PATH" "$OUTPUT_DIR/initrd.img"
else
  print -- "[install] optional initrd not provided (default profile remains initrd-independent)"
fi

print -- "[verify] capability profile"
virtio_fs_actual="$(get_config_value "CONFIG_VIRTIO_FS")"
fuse_fs_actual="$(get_config_value "CONFIG_FUSE_FS")"
required_passed="true"
if [[ "$virtio_fs_actual" != "y" || "$fuse_fs_actual" != "y" ]]; then
  required_passed="false"
fi
forbidden_passed="true"

CAPABILITIES_FILE="$OUTPUT_DIR/capabilities.json"
{
  print -- "{"
  print -- "  \"profileVersion\": \"2026-02-18.step8.v1\","
  print -- "  \"profile\": \"$(json_escape "$KERNEL_PROFILE")\","
  print -- "  \"required\": { \"passed\": ${required_passed} },"
  print -- "  \"forbidden\": { \"passed\": ${forbidden_passed} },"
  print -- "  \"checks\": ["
  print -- "    {\"name\":\"virtio fs\",\"config\":\"CONFIG_VIRTIO_FS\",\"expected\":\"y\",\"actual\":\"$(json_escape "$virtio_fs_actual")\",\"level\":\"required\",\"class\":\"boot-critical\",\"passed\":$([[ "$virtio_fs_actual" == "y" ]] && print -- "true" || print -- "false")},"
  print -- "    {\"name\":\"fuse fs\",\"config\":\"CONFIG_FUSE_FS\",\"expected\":\"y\",\"actual\":\"$(json_escape "$fuse_fs_actual")\",\"level\":\"required\",\"class\":\"boot-critical\",\"passed\":$([[ "$fuse_fs_actual" == "y" ]] && print -- "true" || print -- "false")}"
  print -- "  ],"
  print -- "  \"forbiddenChecks\": ["
  print -- "  ]"
  print -- "}"
} > "$CAPABILITIES_FILE"

KERNEL_RELEASE="$("$KERNEL_MAKE_BIN" -s -C "$KERNEL_SRC" O="$BUILD_DIR" "${MAKE_COMMON_ARGS[@]}" kernelrelease)"
BUILT_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
ELAPSED_SEC="$(( $(date +%s) - START_EPOCH ))"
BUILDER_HOST="$(sw_vers -productVersion 2>/dev/null || print -- unknown)-$(uname -m)"
VMLINUX_SIZE="$(file_size_bytes "$OUTPUT_DIR/vmlinuz")"
VMLINUX_UNCOMPRESSED_SIZE="$VMLINUX_SIZE"
MODULES_PRESENT="false"
if [[ -d "$OUTPUT_DIR/modules" ]]; then
  MODULES_PRESENT="true"
fi
INITRD_PRESENT="false"
if [[ -f "$OUTPUT_DIR/initrd.img" ]]; then
  INITRD_PRESENT="true"
fi
LTO_ENABLED_JSON="false"
if [[ "$KERNEL_EXPERIMENT_LTO" == "1" ]]; then
  LTO_ENABLED_JSON="true"
fi

METADATA_FILE="$OUTPUT_DIR/metadata.json"
{
  print -- "{"
  print -- "  \"kernelId\": \"$(json_escape "$KERNEL_ARTIFACT_REF")\","
  print -- "  \"arch\": \"$(json_escape "$KERNEL_ARCH")\","
  print -- "  \"builtAt\": \"$(json_escape "$BUILT_AT")\","
  print -- "  \"sourcePath\": \"$(json_escape "$KERNEL_SRC")\","
  print -- "  \"sourceRef\": \"$(json_escape "$KERNEL_SOURCE_REF")\","
  print -- "  \"profile\": \"$(json_escape "$KERNEL_PROFILE")\","
  print -- "  \"ltoEnabled\": $LTO_ENABLED_JSON,"
  print -- "  \"defconfig\": \"$(json_escape "$KERNEL_DEFCONFIG")\","
  print -- "  \"fragmentPath\": \"$(json_escape "$KERNEL_CONFIG_FRAGMENT")\","
  print -- "  \"kernelRelease\": \"$(json_escape "$KERNEL_RELEASE")\","
  print -- "  \"builderHost\": \"$(json_escape "$BUILDER_HOST")\","
  print -- "  \"elapsedSeconds\": $ELAPSED_SEC,"
  print -- "  \"artifacts\": {"
  print -- "    \"vmlinuzBytes\": $VMLINUX_SIZE,"
  print -- "    \"vmlinuzUncompressedBytes\": $VMLINUX_UNCOMPRESSED_SIZE,"
  print -- "    \"modulesPresent\": $MODULES_PRESENT,"
  print -- "    \"initrdPresent\": $INITRD_PRESENT"
  print -- "  }"
  print -- "}"
} > "$METADATA_FILE"

if [[ "$required_passed" != "true" || "$forbidden_passed" != "true" ]]; then
  fail "capability checks failed; inspect $CAPABILITIES_FILE"
fi

print -- "[done] kernel artifacts prepared at $OUTPUT_DIR"
print -- "[done] metadata: $METADATA_FILE"
print -- "[done] capabilities: $CAPABILITIES_FILE"
