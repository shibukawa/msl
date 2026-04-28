#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STAGE_DIR="${CONTAINER_TOOLS_STAGE_DIR:-$HOME/Library/Application Support/msl/tools/bundled/darwin-arm64}"
REGCTL_VERSION="${REGCTL_VERSION:-latest}"
UMOCI_VERSION="${UMOCI_VERSION:-latest}"
BUILDKIT_VERSION="${BUILDKIT_VERSION:-latest}"
YOUKI_VERSION="${YOUKI_VERSION:-latest}"
UMOCI_BINARY="${UMOCI_BINARY:-}"
UMOCI_LINUX_BINARY="${UMOCI_LINUX_BINARY:-}"
BUILDKIT_LINUX_BUILDTL_BINARY="${BUILDKIT_LINUX_BUILDTL_BINARY:-}"
YOUKI_LINUX_BINARY="${YOUKI_LINUX_BINARY:-}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

resolve_release_api() {
  local repo="$1"
  local version="$2"
  if [[ "$version" == "latest" ]]; then
    printf 'https://api.github.com/repos/%s/releases/latest\n' "$repo"
  else
    printf 'https://api.github.com/repos/%s/releases/tags/%s\n' "$repo" "$version"
  fi
}

resolve_release_tag() {
  local repo="$1"
  local version="$2"
  local api_url
  api_url="$(resolve_release_api "$repo" "$version")"
  curl -fsSL "$api_url" | python3 -c '
import json, sys
data = json.load(sys.stdin)
tag = data.get("tag_name", "").strip()
if not tag:
    raise SystemExit(1)
print(tag)
'
}

resolve_asset_url() {
  local repo="$1"
  local version="$2"
  local tool="$3"
  local os="${4:-darwin}"
  local arch_input="${5:-}"
  local arch
  if [[ -n "$arch_input" ]]; then
    arch="$arch_input"
  else
    arch="$(uname -m)"
  fi
  case "$arch" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64) arch="amd64" ;;
    *)
      echo "error: unsupported macOS architecture: $arch" >&2
      exit 1
      ;;
  esac
  local api_url
  api_url="$(resolve_release_api "$repo" "$version")"
  curl -fsSL "$api_url" | python3 -c '
import json, re, sys
tool = sys.argv[1]
arch = sys.argv[2]
os = sys.argv[3]
data = json.load(sys.stdin)
patterns = {
    "regctl": [rf"^regctl-{os}-{arch}$", rf"^regctl-{os}-{arch}\.tar\.gz$"],
    "umoci": [
        rf"^umoci([._-]{os}[._-]{arch})?$",
        rf"^umoci[._-]{os}[._-]{arch}(\.gz)?$",
        rf"^umoci\.{os}[-._]{arch}(\.gz)?$",
        rf"^umoci-{os}[-._]{arch}(\.gz)?$",
    ],
}
for pattern in patterns[tool]:
    for asset in data.get("assets", []):
        name = asset.get("name", "")
        if re.match(pattern, name):
            print(asset["browser_download_url"])
            raise SystemExit(0)
raise SystemExit(1)
' "$tool" "$arch" "$os"
}

resolve_buildkit_asset_url() {
  local version="$1"
  local os="${2:-linux}"
  local arch="${3:-arm64}"
  local api_url
  api_url="$(resolve_release_api moby/buildkit "$version")"
  curl -fsSL "$api_url" | python3 -c '
import json, re, sys
os_name = sys.argv[1]
arch = sys.argv[2]
data = json.load(sys.stdin)
pattern = rf"^buildkit-.*\.{re.escape(os_name)}-{re.escape(arch)}\.tar\.gz$"
for asset in data.get("assets", []):
    name = asset.get("name", "")
    if re.match(pattern, name):
        print(asset["browser_download_url"])
        raise SystemExit(0)
raise SystemExit(1)
' "$os" "$arch"
}

resolve_youki_asset_url() {
  local version="$1"
  local api_url
  api_url="$(resolve_release_api containers/youki "$version")"
  curl -fsSL "$api_url" | python3 -c '
import json, re, sys
data = json.load(sys.stdin)
patterns = [
    r"^youki-.*-aarch64-musl\.tar\.gz$",
    r"^youki-.*-aarch64-gnu\.tar\.gz$",
    r"^youki-.*-(arm64|aarch64)([-._].*)?(\.tar\.gz|\.tgz)$",
    r"^youki.*linux.*(arm64|aarch64).*(\.tar\.gz|\.tgz)$",
]
for pattern in patterns:
    for asset in data.get("assets", []):
        name = asset.get("name", "")
        if re.match(pattern, name):
            print(asset["browser_download_url"])
            raise SystemExit(0)
raise SystemExit(1)
'
}

download_executable() {
  local url="$1"
  local out="$2"
  local tmp="$out.tmp"
  echo "downloading $(basename "$out"): $url"
  curl -fL "$url" -o "$tmp"
  case "$url" in
    *.gz)
      gzip -dc "$tmp" > "$out"
      rm -f "$tmp"
      ;;
    *.tar.gz)
      rm -rf "$tmp.dir"
      mkdir -p "$tmp.dir"
      tar -xzf "$tmp" -C "$tmp.dir"
      local extracted
      extracted="$(find "$tmp.dir" -type f -perm -111 | head -n 1)"
      if [[ -z "$extracted" ]]; then
        echo "error: failed to locate executable in archive: $url" >&2
        exit 1
      fi
      cp "$extracted" "$out"
      rm -rf "$tmp.dir" "$tmp"
      ;;
    *)
      mv "$tmp" "$out"
      ;;
  esac
  chmod 0755 "$out"
}

build_umoci_from_source() {
  local out="$1"
  local goos="${2:-$(uname | tr '[:upper:]' '[:lower:]')}"
  local goarch="${3:-arm64}"
  require_command go
  require_command tar
  local resolved_version source_url work_dir source_tar source_dir
  resolved_version="$(resolve_release_tag opencontainers/umoci "$UMOCI_VERSION")" || {
    echo "error: failed to resolve umoci release tag for source build" >&2
    exit 1
  }
  source_url="https://github.com/opencontainers/umoci/archive/refs/tags/${resolved_version}.tar.gz"
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/msl-umoci-build.XXXXXX")"
  source_tar="$work_dir/umoci-source.tar.gz"
  source_dir="$work_dir/source"
  trap 'if [[ -n "${work_dir:-}" ]]; then rm -rf "$work_dir"; fi' EXIT
  echo "building umoci from source: $resolved_version"
  curl -fsSL "$source_url" -o "$source_tar"
  mkdir -p "$source_dir"
  tar -xzf "$source_tar" -C "$source_dir" --strip-components=1
  (
    cd "$source_dir"
    GOOS="$goos" GOARCH="$goarch" go build -o "$out" ./cmd/umoci
  )
  chmod 0755 "$out"
}

download_buildctl_from_buildkit_release() {
  local url="$1"
  local out="$2"
  local work_dir archive
  require_command tar
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/msl-buildctl-stage.XXXXXX")"
  archive="$work_dir/buildkit.tar.gz"
  trap 'if [[ -n "${work_dir:-}" ]]; then rm -rf "$work_dir"; fi' EXIT
  echo "downloading buildctl: $url"
  curl -fL "$url" -o "$archive"
  tar -xzf "$archive" -C "$work_dir"
  local extracted="$work_dir/bin/buildctl"
  if [[ ! -f "$extracted" ]]; then
    extracted="$(find "$work_dir" -type f -path '*/bin/buildctl' | head -n 1)"
  fi
  if [[ -z "$extracted" || ! -f "$extracted" ]]; then
    echo "error: failed to locate buildctl in buildkit release archive" >&2
    exit 1
  fi
  cp "$extracted" "$out"
  chmod 0755 "$out"
  rm -rf "$work_dir"
  work_dir=""
}

write_manifest() {
  local dest="$1"
  local regctl_checksum umoci_checksum umoci_linux_checksum buildctl_linux_checksum youki_linux_checksum bundle_version generated_at
  regctl_checksum="$(shasum -a 256 "$STAGE_DIR/regctl" | awk '{print $1}')"
  umoci_checksum="$(shasum -a 256 "$STAGE_DIR/umoci" | awk '{print $1}')"
  umoci_linux_checksum="$(shasum -a 256 "$STAGE_DIR/linux-arm64/umoci" | awk '{print $1}')"
  buildctl_linux_checksum="$(shasum -a 256 "$STAGE_DIR/linux-arm64/buildctl" | awk '{print $1}')"
  youki_linux_checksum="$(shasum -a 256 "$STAGE_DIR/linux-arm64/youki" | awk '{print $1}')"
  bundle_version="darwin-arm64-regctl-${REGCTL_VERSION}_umoci-${UMOCI_VERSION}_buildkit-${BUILDKIT_VERSION}_youki-${YOUKI_VERSION}"
  generated_at="$(date +%s000)"
  python3 - "$dest" "$bundle_version" "$generated_at" "$REGCTL_VERSION" "$regctl_checksum" "$UMOCI_VERSION" "$umoci_checksum" "$umoci_linux_checksum" "$BUILDKIT_VERSION" "$buildctl_linux_checksum" "$YOUKI_VERSION" "$youki_linux_checksum" <<'PY'
import json, sys
dest, bundle_version, generated_at, regctl_version, regctl_checksum, umoci_version, umoci_checksum, umoci_linux_checksum, buildkit_version, buildctl_linux_checksum, youki_version, youki_linux_checksum = sys.argv[1:]
payload = {
    "bundleVersion": bundle_version,
    "generatedAtEpochMs": int(generated_at),
    "tools": [
        {
            "name": "regctl",
            "platform": "darwin-arm64",
            "version": regctl_version,
            "checksum": regctl_checksum,
            "relativePath": "regctl",
        },
        {
            "name": "umoci",
            "platform": "darwin-arm64",
            "version": umoci_version,
            "checksum": umoci_checksum,
            "relativePath": "umoci",
        },
        {
            "name": "umoci",
            "platform": "linux-arm64",
            "version": umoci_version,
            "checksum": umoci_linux_checksum,
            "relativePath": "linux-arm64/umoci",
        },
        {
            "name": "buildctl",
            "platform": "linux-arm64",
            "version": buildkit_version,
            "checksum": buildctl_linux_checksum,
            "relativePath": "linux-arm64/buildctl",
        },
        {
            "name": "youki",
            "platform": "linux-arm64",
            "version": youki_version,
            "checksum": youki_linux_checksum,
            "relativePath": "linux-arm64/youki",
        },
    ],
}
with open(dest, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

require_command curl
require_command python3
require_command shasum

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
mkdir -p "$STAGE_DIR/linux-arm64"

regctl_url="$(resolve_asset_url regclient/regclient "$REGCTL_VERSION" regctl darwin)" || {
  echo "error: failed to resolve regctl asset from GitHub Releases" >&2
  exit 1
}
download_executable "$regctl_url" "$STAGE_DIR/regctl"

if [[ -n "$UMOCI_BINARY" ]]; then
  echo "using UMOCI_BINARY: $UMOCI_BINARY"
  cp "$UMOCI_BINARY" "$STAGE_DIR/umoci"
  chmod 0755 "$STAGE_DIR/umoci"
else
  umoci_url="$(resolve_asset_url opencontainers/umoci "$UMOCI_VERSION" umoci darwin)" || umoci_url=""
  if [[ -n "$umoci_url" ]]; then
    download_executable "$umoci_url" "$STAGE_DIR/umoci"
  else
    build_umoci_from_source "$STAGE_DIR/umoci" darwin arm64
  fi
fi

if [[ -n "$UMOCI_LINUX_BINARY" ]]; then
  echo "using UMOCI_LINUX_BINARY: $UMOCI_LINUX_BINARY"
  cp "$UMOCI_LINUX_BINARY" "$STAGE_DIR/linux-arm64/umoci"
  chmod 0755 "$STAGE_DIR/linux-arm64/umoci"
else
  umoci_linux_url="$(resolve_asset_url opencontainers/umoci "$UMOCI_VERSION" umoci linux arm64)" || umoci_linux_url=""
  if [[ -n "$umoci_linux_url" ]]; then
    download_executable "$umoci_linux_url" "$STAGE_DIR/linux-arm64/umoci"
  else
    build_umoci_from_source "$STAGE_DIR/linux-arm64/umoci" linux arm64
  fi
fi

if [[ -n "$BUILDKIT_LINUX_BUILDTL_BINARY" ]]; then
  echo "using BUILDKIT_LINUX_BUILDTL_BINARY: $BUILDKIT_LINUX_BUILDTL_BINARY"
  cp "$BUILDKIT_LINUX_BUILDTL_BINARY" "$STAGE_DIR/linux-arm64/buildctl"
  chmod 0755 "$STAGE_DIR/linux-arm64/buildctl"
else
  buildkit_url="$(resolve_buildkit_asset_url "$BUILDKIT_VERSION" linux arm64)" || {
    echo "error: failed to resolve buildctl asset from BuildKit GitHub Releases" >&2
    exit 1
  }
  download_buildctl_from_buildkit_release "$buildkit_url" "$STAGE_DIR/linux-arm64/buildctl"
fi

if [[ -n "$YOUKI_LINUX_BINARY" ]]; then
  echo "using YOUKI_LINUX_BINARY: $YOUKI_LINUX_BINARY"
  cp "$YOUKI_LINUX_BINARY" "$STAGE_DIR/linux-arm64/youki"
  chmod 0755 "$STAGE_DIR/linux-arm64/youki"
else
  youki_url="$(resolve_youki_asset_url "$YOUKI_VERSION")" || {
    echo "error: failed to resolve youki asset from GitHub Releases" >&2
    exit 1
  }
  download_executable "$youki_url" "$STAGE_DIR/linux-arm64/youki"
fi

write_manifest "$STAGE_DIR/manifest.json"
echo "staged container helpers in: $STAGE_DIR"
echo "  manifest: $STAGE_DIR/manifest.json"
echo "  regctl:   $STAGE_DIR/regctl"
echo "  umoci:    $STAGE_DIR/umoci"
echo "  guest umoci: $STAGE_DIR/linux-arm64/umoci"
echo "  guest buildctl: $STAGE_DIR/linux-arm64/buildctl"
echo "  guest youki: $STAGE_DIR/linux-arm64/youki"
