#!/usr/bin/env bash
set -euo pipefail

umask 077

log() {
  printf '[install-security-tools] %s\n' "$*"
}

fail() {
  printf '[install-security-tools] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "required command not found: $1"
  fi
}

extract_json_string_field() {
  local key="$1"
  sed -n "s/^[[:space:]]*\"${key}\":[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | sed -n '1p'
}

extract_json_first_sha() {
  sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p'
}

github_latest_release_tag() {
  local repo="$1"
  local json
  local tag
  json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${repo}/releases/latest")" \
    || fail "failed to query latest release for ${repo}"
  tag="$(printf '%s\n' "$json" | extract_json_string_field tag_name)"
  [ -n "$tag" ] || fail "failed to parse latest release tag for ${repo}"
  printf '%s\n' "$tag"
}

github_default_branch() {
  local repo="$1"
  local json
  local branch
  json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${repo}")" \
    || fail "failed to query repository metadata for ${repo}"
  branch="$(printf '%s\n' "$json" | extract_json_string_field default_branch)"
  [ -n "$branch" ] || fail "failed to parse default_branch for ${repo}"
  printf '%s\n' "$branch"
}

github_commit_sha() {
  local repo="$1"
  local ref="$2"
  local json
  local sha
  json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${repo}/commits/${ref}")" \
    || fail "failed to query commit sha for ${repo}@${ref}"
  sha="$(printf '%s\n' "$json" | extract_json_first_sha)"
  [ -n "$sha" ] || fail "failed to parse commit sha for ${repo}@${ref}"
  printf '%s\n' "$sha"
}

download_zip_branch() {
  local repo="$1"
  local branch="$2"
  local out="$3"
  curl -fsSL -H 'Accept: application/vnd.github+json' \
    "https://github.com/${repo}/archive/refs/heads/${branch}.zip" \
    -o "$out" || fail "failed to download zip for ${repo}@${branch}"
}

patch_vulsrepo_js() {
  local js_path="$1"
  local patched=0

  [ -f "$js_path" ] || fail "vulsrepo js file not found: $js_path"

  if grep -q 'result\["CVSS Score"\] = cveContent.cvss3Score.toFixed(1);' "$js_path"; then
    perl -0pi -e 's/result\["CVSS Score"\] = cveContent\.cvss3Score\.toFixed\(1\);/result["CVSS Score"] = parseFloat(cveContent.cvss3Score.toFixed(1));/g' "$js_path"
    patched=1
  fi
  if grep -q 'result\["CVSS Score"\] = cveContent.cvss2Score.toFixed(1);' "$js_path"; then
    perl -0pi -e 's/result\["CVSS Score"\] = cveContent\.cvss2Score\.toFixed\(1\);/result["CVSS Score"] = parseFloat(cveContent.cvss2Score.toFixed(1));/g' "$js_path"
    patched=1
  fi

  if ! grep -q 'result\["CVSS Score"\] = parseFloat(cveContent.cvss3Score.toFixed(1));' "$js_path"; then
    fail "vulsrepo patch verification failed (cvss3 parseFloat not found)"
  fi
  if [ "$patched" -ne 1 ]; then
    fail "vulsrepo patch was not applied"
  fi
}

install_sigstore_go() {
  local repo='sigstore/sigstore-go'
  local tag
  local sigstore_bin
  local go_bin_dir

  tag="$(github_latest_release_tag "$repo")"

  log "installing sigstore-go ${tag}"
  go_bin_dir="$WORK_DIR/gobin"
  mkdir -p "$go_bin_dir"
  GOBIN="$go_bin_dir" GO111MODULE=on go install "github.com/sigstore/sigstore-go/examples/sigstore-go-verification@${tag}" \
    || fail "failed to install sigstore-go-verification ${tag}"
  sigstore_bin="$go_bin_dir/sigstore-go-verification"
  [ -x "$sigstore_bin" ] || fail "sigstore-go verification binary not found after go install"

  rm -rf "$SIGSTORE_DIR"
  mkdir -p "$SIGSTORE_DIR"
  install -m 0755 "$sigstore_bin" "$SIGSTORE_DIR/sigstore-go-verification"

  cat >"$SIGSTORE_DIR/INSTALL_METADATA" <<EOF
repo=${repo}
tag=${tag}
binary=sigstore-go-verification
install_method=go_install
installed_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
}

install_vulsrepo() {
  local repo='ishiDACo/vulsrepo'
  local branch
  local commit_sha
  local zip_path
  local source_dir
  local zip_sha256
  local js_path
  local built_bin

  branch="$(github_default_branch "$repo")"
  commit_sha="$(github_commit_sha "$repo" "$branch")"
  zip_path="$WORK_DIR/vulsrepo-${branch}.zip"
  source_dir="$WORK_DIR/vulsrepo-src"
  built_bin="$WORK_DIR/vulsrepo"

  log "installing vulsrepo ${branch} (${commit_sha})"
  download_zip_branch "$repo" "$branch" "$zip_path"
  zip_sha256="$(shasum -a 256 "$zip_path" | awk '{print $1}')"

  mkdir -p "$source_dir"
  unzip -q "$zip_path" -d "$WORK_DIR"
  cp -R "$WORK_DIR/vulsrepo-${branch}/." "$source_dir/"

  js_path="$source_dir/dist/js/vulsrepo.js"
  patch_vulsrepo_js "$js_path"

  (
    cd "$source_dir/server"
    GO111MODULE=on go mod tidy
    GO111MODULE=on go build -o "$built_bin" ./main.go
  ) || fail "failed to build vulsrepo server binary"

  rm -rf "$VULSREPO_DIR"
  mkdir -p "$VULSREPO_DIR"
  install -m 0755 "$built_bin" "$VULSREPO_DIR/vulsrepo"
  cp -R "$source_dir/dist" "$VULSREPO_DIR/dist"
  cp -R "$source_dir/plugins" "$VULSREPO_DIR/plugins"
  cp -R "$source_dir/gallery" "$VULSREPO_DIR/gallery"
  cp "$source_dir/index.html" "$VULSREPO_DIR/index.html"
  cp "$source_dir/server/vulsrepo-config.toml.sample" "$VULSREPO_DIR/vulsrepo-config.toml.sample"

  cat >"$VULSREPO_DIR/INSTALL_METADATA" <<EOF
repo=${repo}
branch=${branch}
commit_sha=${commit_sha}
source_zip_sha256=${zip_sha256}
patched_js=dist/js/vulsrepo.js
installed_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
}

install_vuls_cli() {
  local repo='future-architect/vuls'
  local release_json
  local tag
  local asset_url
  local asset_name
  local digest
  local archive_path
  local extract_dir
  local binary_path
  local archive_sha256

  release_json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${repo}/releases/latest")" \
    || fail "failed to query latest release for ${repo}"
  tag="$(printf '%s\n' "$release_json" | extract_json_string_field tag_name)"
  [ -n "$tag" ] || fail "failed to parse release tag for ${repo}"

  asset_name="$(printf '%s\n' "$release_json" | sed -n 's/^[[:space:]]*"name":[[:space:]]*"\(vuls_[^"]*_darwin_arm64\.tar\.gz\)",$/\1/p' | sed -n '1p')"
  [ -n "$asset_name" ] || fail "failed to resolve darwin_arm64 asset name for ${repo}@${tag}"
  asset_url="$(awk -v target="$asset_name" '
    $0 ~ "\"name\":" {
      line=$0
      sub(/^[[:space:]]*"name":[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      hit = (line == target)
      next
    }
    hit && $0 ~ "\"browser_download_url\":" {
      line=$0
      sub(/^.*"browser_download_url":[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      print line
      exit
    }
  ' <<< "$release_json")"
  [ -n "$asset_url" ] || fail "failed to resolve asset download URL for ${asset_name}"
  digest="$(awk -v target="$asset_name" '
    $0 ~ "\"name\":" {
      line=$0
      sub(/^[[:space:]]*"name":[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      hit = (line == target)
      next
    }
    hit && $0 ~ "\"digest\":" {
      line=$0
      sub(/^.*"digest":[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      print line
      exit
    }
  ' <<< "$release_json")"

  log "installing vuls cli ${tag}"
  archive_path="$WORK_DIR/${asset_name}"
  extract_dir="$WORK_DIR/vuls-cli-extract"
  curl -fsSL "$asset_url" -o "$archive_path" || fail "failed to download ${asset_name}"
  archive_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
  if [ -n "$digest" ]; then
    expected="${digest#sha256:}"
    [ "$expected" = "$archive_sha256" ] || fail "vuls archive digest mismatch: expected=${expected} actual=${archive_sha256}"
  fi

  mkdir -p "$extract_dir"
  tar -xzf "$archive_path" -C "$extract_dir" || fail "failed to extract ${asset_name}"
  binary_path="$(find "$extract_dir" -type f -name vuls | sed -n '1p')"
  [ -n "$binary_path" ] || fail "vuls binary not found in archive"
  [ -x "$binary_path" ] || fail "vuls binary not found in archive"

  rm -rf "$VULSCLI_DIR"
  mkdir -p "$VULSCLI_DIR"
  install -m 0755 "$binary_path" "$VULSCLI_DIR/vuls"

  cat >"$VULSCLI_DIR/INSTALL_METADATA" <<EOF
repo=${repo}
tag=${tag}
asset_name=${asset_name}
asset_digest=${digest}
download_sha256=${archive_sha256}
installed_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
}

main() {
  require_command curl
  require_command tar
  require_command shasum
  require_command awk
  require_command sed
  require_command perl
  require_command unzip
  require_command go

  MSL_HOME_DIR="${MSL_HOME:-$HOME}"
  APP_SUPPORT_DIR="${MSL_HOME_DIR}/Library/Application Support/msl"
  SECURITY_DIR="${APP_SUPPORT_DIR}/security"
  TOOLS_DIR="${SECURITY_DIR}/tools"
  SIGSTORE_DIR="${TOOLS_DIR}/sigstore-go"
  VULSREPO_DIR="${TOOLS_DIR}/vulsrepo"
  VULSCLI_DIR="${TOOLS_DIR}/vuls-cli"
  STATE_DIR="${SECURITY_DIR}/state"
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/msl-security-tools.XXXXXX")"
  trap 'rm -rf "$WORK_DIR"' EXIT

  mkdir -p "$TOOLS_DIR" "$STATE_DIR"
  install_sigstore_go
  install_vulsrepo
  install_vuls_cli

  cat >"$STATE_DIR/security-tools-index.json" <<EOF
{
  "schemaVersion": 1,
  "sigstoreGoMetadataPath": "${SIGSTORE_DIR}/INSTALL_METADATA",
  "vulsrepoMetadataPath": "${VULSREPO_DIR}/INSTALL_METADATA",
  "vulsCLIMetadataPath": "${VULSCLI_DIR}/INSTALL_METADATA",
  "updatedAtUTC": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

  log "installed:"
  log "  ${SIGSTORE_DIR}"
  log "  ${VULSREPO_DIR}"
  log "  ${VULSCLI_DIR}"
  log "done"
}

main "$@"
