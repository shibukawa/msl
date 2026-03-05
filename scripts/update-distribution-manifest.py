#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GEN_DIR = ROOT / "Sources" / "mslCore" / "Generated"
SECURITY_DIR = ROOT / "Sources" / "mslCore" / "Security"

LINUXCONTAINERS_BASE_URL = "https://images.linuxcontainers.org/"
LINUXCONTAINERS_STREAMS_URL = "https://images.linuxcontainers.org/streams/v1/images.json"
OPENPGP_VKS_FPR_URL = "https://keys.openpgp.org/vks/v1/by-fingerprint/{fpr}"
UBUNTU_KEYSERVER_LOOKUP_URL = "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x{fpr}"

TARGET_RELEASES = [
    {
        "distro": "amazonlinux",
        "release": "2",
        "canonicalName": "amazonlinux-2",
        "aliases": ["amazonlinux"],
    },
    {
        "distro": "alpine",
        "release": "3.23",
        "canonicalName": "alpine-3.23",
        "aliases": ["alpine"],
    },
    {
        "distro": "debian",
        "release": "trixie",
        "canonicalName": "debian-trixie",
        "aliases": ["debian", "debian-latest"],
    },
    {
        "distro": "ubuntu",
        "release": "noble",
        "canonicalName": "ubuntu-noble",
        "aliases": ["ubuntu", "ubuntu-lts"],
    },
    {
        "distro": "ubuntu",
        "release": "questing",
        "canonicalName": "ubuntu-questing",
        "aliases": ["ubuntu-latest"],
    },
    {
        "distro": "fedora",
        "release": "43",
        "canonicalName": "fedora-43",
        "aliases": ["fedora", "fedora-latest"],
    },
    {
        "distro": "opensuse",
        "release": "16.0",
        "canonicalName": "opensuse-16.0",
        "aliases": ["opensuse"],
    },
]


class MissingPublicKeyError(RuntimeError):
    def __init__(self, fingerprint: str, detail: str):
        self.fingerprint = fingerprint.upper()
        super().__init__(detail)


def fetch_text(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "msl-step5-manifest-updater/1"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8", errors="replace")


def fetch_bytes(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "msl-step5-manifest-updater/1"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read()


def url_exists(url: str) -> bool:
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "msl-step5-manifest-updater/1"})
    try:
        with urllib.request.urlopen(req, timeout=20):
            return True
    except Exception:
        return False


def write_bytes(path: Path, data: bytes):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def run(cmd, env=None, tolerate_import_agent_error=False, tolerate_no_user_id=False):
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    res = subprocess.run(cmd, text=True, capture_output=True, env=merged_env)
    if res.returncode != 0:
        if tolerate_import_agent_error:
            err = (res.stderr or "")
            out = (res.stdout or "")
            # Homebrew gnupg on some macOS environments imports keys successfully
            # but exits non-zero when gpg-agent cannot be started.
            if (
                "can't connect to the gpg-agent" in err
                and "imported" in err
                and "Total number processed" in err
            ) or (
                "can't connect to the gpg-agent" in err
                and "imported" in out
            ):
                return res
        if tolerate_no_user_id:
            err = (res.stderr or "")
            if "no user ID" in err and "Total number processed" in err:
                # Some key sources (e.g. keys.openpgp.org) may provide
                # stripped keys without UID; treat as non-fatal and let
                # subsequent signature verification decide.
                return res
        raise RuntimeError(
            "command failed: {}\nstdout:\n{}\nstderr:\n{}".format(
                " ".join(cmd), res.stdout.strip(), res.stderr.strip()
            )
        )
    return res


def create_gpg_home(tmp_dir: Path, name: str) -> Path:
    home = tmp_dir / name
    home.mkdir(parents=True, exist_ok=True)
    os.chmod(home, 0o700)
    return home


def import_keys_to_gpg_home(gpg_home: Path, key_files):
    for key_file in key_files:
        run([
            "gpg",
            "--batch",
            "--no-autostart",
            "--homedir", str(gpg_home),
            "--import",
            str(key_file),
        ], tolerate_import_agent_error=True, tolerate_no_user_id=True)


def extract_missing_pubkey_fingerprint(text: str) -> str:
    patterns = [
        r"using [A-Z0-9]+ key ([0-9A-F]{16,40})",
        r"NO_PUBKEY ([0-9A-F]{16,40})",
        r"ERRSIG [0-9A-F]{16,40} .* ([0-9A-F]{16,40})",
    ]
    for pat in patterns:
        m = re.search(pat, text)
        if m:
            return m.group(1).upper()
    return ""


def verify_signature_and_get_fingerprint(gpg_home: Path, signature_path: Path, payload_path: Path) -> str:
    res = subprocess.run(
        [
            "gpg",
            "--batch",
            "--no-autostart",
            "--homedir", str(gpg_home),
            "--status-fd", "1",
            "--verify",
            str(signature_path),
            str(payload_path),
        ],
        text=True,
        capture_output=True,
        env=os.environ.copy(),
    )
    merged = (res.stdout or "") + "\n" + (res.stderr or "")
    if res.returncode != 0:
        missing = extract_missing_pubkey_fingerprint(merged)
        if missing:
            raise MissingPublicKeyError(missing, merged.strip())
        raise RuntimeError(
            "gpg verify failed\nstdout:\n{}\nstderr:\n{}".format(
                (res.stdout or "").strip(),
                (res.stderr or "").strip(),
            )
        )

    for line in merged.splitlines():
        if "VALIDSIG " in line:
            tail = line.split("VALIDSIG ", 1)[1].strip()
            if tail:
                return tail.split(" ", 1)[0].upper()
    raise RuntimeError("VALIDSIG fingerprint not found in gpg output")


def export_armored_key(gpg_home: Path, fingerprint: str) -> str:
    res = run([
        "gpg",
        "--batch",
        "--no-autostart",
        "--homedir", str(gpg_home),
        "--export",
        "--armor",
        fingerprint,
    ])
    text = res.stdout.strip() + "\n"
    if "BEGIN PGP PUBLIC KEY BLOCK" not in text:
        raise RuntimeError(f"failed to export armored key for {fingerprint}")
    return text


def parse_sha_line(text: str, filename: str) -> str:
    for line in text.splitlines():
        parts = line.strip().split()
        if len(parts) >= 2:
            digest = parts[0].strip()
            tail = parts[-1].strip().lstrip("*")
            if tail == filename or tail.endswith("/" + filename):
                return digest
    raise RuntimeError(f"sha256 for {filename} not found")


def fetch_linuxcontainers_streams():
    text = fetch_text(LINUXCONTAINERS_STREAMS_URL)
    data = json.loads(text)
    products = data.get("products")
    if not isinstance(products, dict):
        raise RuntimeError("invalid linuxcontainers streams payload: missing products")
    return products


def latest_version_key(versions: dict, context: str) -> str:
    keys = sorted(versions.keys())
    if not keys:
        raise RuntimeError(f"no build versions found: {context}")
    return keys[-1]


def parse_packages_manager(image_yaml_text: str) -> str:
    in_packages = False
    for line in image_yaml_text.splitlines():
        stripped = line.strip()
        if stripped == "packages:":
            in_packages = True
            continue
        if not in_packages:
            continue
        if stripped and not line.startswith((" ", "\t")):
            break
        m = re.match(r"\s*manager:\s*([^\s#]+)", line)
        if m:
            return m.group(1).strip().lower()
    return ""


def normalize_package_manager(raw: str) -> str:
    value = (raw or "").strip().lower()
    if value in ("apt", "apk", "zypper", "dnf"):
        return value
    if value == "yum":
        return "dnf"
    return ""


def service_manager_for_distro(distro: str) -> str:
    if distro == "alpine":
        return "openrc"
    return "systemd"


def vulnerability_db_target_for_distro(distro: str, release: str):
    family = distro
    if distro in ("amazonlinux", "fedora"):
        family = "redhat"
    return {
        "family": family,
        "release": release,
        "dictionary": "goval",
    }


def user_convergence_template_for_distro(distro: str):
    if distro == "alpine":
        return {
            "templateId": "alpine-busybox-v1",
            "commandFamily": "busybox_adduser",
            "adminGroup": "wheel",
            "sudoPolicy": {
                "enabled": True,
                "requireSudoBinary": False,
                "dropInPath": "/etc/sudoers.d/msl-user",
                "passwordless": True,
            },
            "suPolicy": {
                "enabled": True,
                "passwordless": True,
            },
            "shellFallbacks": ["/bin/ash", "/bin/sh"],
            "welcomePolicy": {
                "enabled": True,
                "frequency": "daily",
                "respectHushlogin": True,
            },
            "editable": False,
        }
    admin_group = "sudo" if distro in ("ubuntu", "debian") else "wheel"
    return {
        "templateId": f"{distro}-useradd-v1",
        "commandFamily": "useradd",
        "adminGroup": admin_group,
        "sudoPolicy": {
            "enabled": True,
            "requireSudoBinary": False,
            "dropInPath": "/etc/sudoers.d/msl-user",
            "passwordless": True,
        },
        "suPolicy": {
            "enabled": False,
            "passwordless": False,
        },
        "shellFallbacks": ["/bin/bash", "/bin/sh"],
        "welcomePolicy": {
            "enabled": True,
            "frequency": "daily",
            "respectHushlogin": True,
        },
        "editable": False,
    }


def cache_sharing_defaults_for_manager(normalized_manager: str):
    return {
        "enabled": True,
        "apt": normalized_manager == "apt",
        "apk": normalized_manager == "apk",
        "zypper": normalized_manager == "zypper",
        "dnf": normalized_manager == "dnf",
    }


def linuxcontainers_entry(target: dict, products: dict, tmp_dir: Path):
    distro = target["distro"]
    release = target["release"]
    product_key = f"{distro}:{release}:arm64:default"
    product = products.get(product_key)
    if not product:
        raise RuntimeError(f"linuxcontainers product not found: {product_key}")

    versions = product.get("versions")
    if not isinstance(versions, dict):
        raise RuntimeError(f"invalid versions map for product {product_key}")
    build_key = latest_version_key(versions, product_key)
    build = versions.get(build_key) or {}
    items = build.get("items") or {}
    root_item = items.get("root.tar.xz")
    if not isinstance(root_item, dict):
        raise RuntimeError(f"root.tar.xz item not found for product {product_key} build {build_key}")

    root_path = root_item.get("path", "").strip()
    sha256 = root_item.get("sha256", "").strip()
    if not root_path or not sha256:
        raise RuntimeError(f"root.tar.xz path/sha256 missing for product {product_key} build {build_key}")

    tar_url = urllib.parse.urljoin(LINUXCONTAINERS_BASE_URL, root_path)
    file_name = Path(root_path).name
    build_dir = root_path.rsplit("/", 1)[0] + "/"
    build_url = urllib.parse.urljoin(LINUXCONTAINERS_BASE_URL, build_dir)
    checksum_url = urllib.parse.urljoin(build_url, "SHA256SUMS")
    signature_url = urllib.parse.urljoin(build_url, "SHA256SUMS.asc")

    sums = tmp_dir / f"lc-{distro}-{release}-{build_key}-SHA256SUMS"
    sums_sig = tmp_dir / f"lc-{distro}-{release}-{build_key}-SHA256SUMS.asc"
    sums_text = fetch_text(checksum_url)
    write_bytes(sums, sums_text.encode("utf-8"))
    write_bytes(sums_sig, fetch_bytes(signature_url))

    parsed = parse_sha_line(sums_text, file_name)
    if parsed.lower() != sha256.lower():
        raise RuntimeError(
            f"sha256 mismatch for {product_key} build {build_key}: streams={sha256}, sums={parsed}"
        )

    gpg_home = create_gpg_home(tmp_dir, f"gpg-lc-{distro}-{release}-{build_key}".replace(":", "-"))
    discovered_fp = verify_with_key_recovery(gpg_home, sums_sig, sums, tmp_dir)
    armored = export_armored_key(gpg_home, discovered_fp)

    image_yaml_url = urllib.parse.urljoin(build_url, "image.yaml")
    image_yaml = fetch_text(image_yaml_url)
    normalized_manager = normalize_package_manager(parse_packages_manager(image_yaml))

    entry = {
        "id": f"{distro}-{release}-arm64",
        "distro": distro,
        "version": release,
        "arch": "arm64",
        "tarballURL": tar_url,
        "sha256": sha256,
        "signatureURL": signature_url,
        "checksumURL": checksum_url,
        "signatureTarget": "checksum",
        "keyFingerprint": discovered_fp,
        "serviceManager": service_manager_for_distro(distro),
        "userConvergenceTemplate": user_convergence_template_for_distro(distro),
        "cacheSharingDefaults": cache_sharing_defaults_for_manager(normalized_manager),
        "vulnerabilityDBTarget": vulnerability_db_target_for_distro(distro, release),
    }
    return entry, discovered_fp, armored


def discover_alpine_keys(tmp_dir: Path):
    explicit_file = os.environ.get("ALPINE_KEY_FILE", "").strip()
    if explicit_file:
        return [Path(explicit_file)]

    index_url = os.environ.get("ALPINE_KEYS_INDEX_URL", ALPINE_KEYS_INDEX)
    urls = []
    try:
        html_text = fetch_text(index_url)
        links = sorted(set(re.findall(r'href=["\']([^"\']+)["\']', html_text)))
        for link in links:
            lower = link.lower()
            if lower.startswith("mailto:"):
                continue
            if lower.endswith((".asc", ".pub", ".gpg", ".key")) or "key" in lower:
                urls.append(urllib.parse.urljoin(index_url, link))
    except Exception:
        pass

    if not urls:
        urls = [ALPINE_DEFAULT_KEY]

    key_files = []
    for idx, url in enumerate(dict.fromkeys(urls)):
        try:
            data = fetch_bytes(url)
        except Exception:
            continue
        if not data:
            continue
        ext = Path(urllib.parse.urlparse(url).path).suffix or ".asc"
        path = tmp_dir / f"alpine-key-{idx}{ext}"
        write_bytes(path, data)
        key_files.append(path)
    if not key_files:
        raise RuntimeError("failed to fetch alpine public keys from official key pages")
    return key_files


def fetch_missing_key_to_file(tmp_dir: Path, fingerprint: str) -> Path:
    errors = []
    urls = [
        UBUNTU_KEYSERVER_LOOKUP_URL.format(fpr=fingerprint),
        OPENPGP_VKS_FPR_URL.format(fpr=fingerprint),
    ]
    for url in urls:
        try:
            data = fetch_bytes(url)
            text = data.decode("utf-8", errors="ignore")
            if "BEGIN PGP PUBLIC KEY BLOCK" not in text:
                errors.append(f"{url}: response did not contain armored key block")
                continue
            key_file = tmp_dir / f"missing-{fingerprint}.asc"
            write_bytes(key_file, data)
            return key_file
        except Exception as exc:
            errors.append(f"{url}: {exc}")

    raise RuntimeError(
        "failed to fetch missing public key for {} via known sources:\n{}".format(
            fingerprint, "\n".join(errors)
        )
    )


def verify_with_key_recovery(gpg_home: Path, signature_path: Path, payload_path: Path, tmp_dir: Path) -> str:
    tried = set()
    while True:
        try:
            return verify_signature_and_get_fingerprint(gpg_home, signature_path, payload_path)
        except MissingPublicKeyError as missing:
            fpr = missing.fingerprint.upper()
            if fpr in tried:
                raise
            tried.add(fpr)
            extra_key = fetch_missing_key_to_file(tmp_dir, fpr)
            import_keys_to_gpg_home(gpg_home, [extra_key])


def alpine_entry(tmp_dir: Path):
    page = fetch_text(ALPINE_INDEX)
    versions = sorted(set(re.findall(r"alpine-minirootfs-([0-9]+\.[0-9]+\.[0-9]+)-aarch64\.tar\.gz", page)))
    if not versions:
        raise RuntimeError("failed to resolve alpine latest tarball from index page")

    version = versions[-1]
    file_name = f"alpine-minirootfs-{version}-aarch64.tar.gz"
    tar_url = ALPINE_INDEX + file_name
    sha_url = tar_url + ".sha256"
    sig_candidates = [tar_url + ".asc", tar_url + ".sig"]
    sig_url = next((u for u in sig_candidates if url_exists(u)), "")
    if not sig_url:
        raise RuntimeError("failed to resolve alpine signature file (.asc/.sig)")

    sha_text = fetch_text(sha_url)
    sha256 = parse_sha_line(sha_text, file_name)

    tar_file = tmp_dir / file_name
    sig_file = tmp_dir / (file_name + ".asc")
    write_bytes(tar_file, fetch_bytes(tar_url))
    write_bytes(sig_file, fetch_bytes(sig_url))

    gpg_home = create_gpg_home(tmp_dir, "gpg-alpine")
    key_files = discover_alpine_keys(tmp_dir)
    import_keys_to_gpg_home(gpg_home, key_files)

    discovered_fp = verify_with_key_recovery(gpg_home, sig_file, tar_file, tmp_dir)

    expected_fp = os.environ.get("ALPINE_KEY_FINGERPRINT", "").strip().upper()
    if expected_fp and expected_fp != discovered_fp:
        raise RuntimeError(f"alpine signer mismatch: expected {expected_fp}, got {discovered_fp}")

    armored = export_armored_key(gpg_home, discovered_fp)
    entry = {
        "id": "alpine-latest-aarch64",
        "distro": "alpine",
        "version": "latest",
        "arch": "aarch64",
        "tarballURL": tar_url,
        "sha256": sha256,
        "signatureURL": sig_url,
        "checksumURL": sha_url,
        "signatureTarget": "artifact",
        "keyFingerprint": discovered_fp,
        "serviceManager": "openrc",
        "defaultInitMode": "direct-init",
        "userConvergenceTemplate": {
            "templateId": "alpine-busybox-v1",
            "commandFamily": "busybox_adduser",
            "adminGroup": "wheel",
            "sudoPolicy": {
                "enabled": True,
                "requireSudoBinary": False,
                "dropInPath": "/etc/sudoers.d/msl-user",
                "passwordless": True,
            },
            "suPolicy": {
                "enabled": True,
                "passwordless": True,
            },
            "shellFallbacks": ["/bin/ash", "/bin/sh"],
            "welcomePolicy": {
                "enabled": True,
                "frequency": "daily",
                "respectHushlogin": True,
            },
            "editable": False,
        },
        "cacheSharingDefaults": {
            "enabled": True,
            "apt": False,
            "apk": True,
        },
        "vulnerabilityDBTarget": vulnerability_db_target_for_distro("alpine", "latest"),
    }
    return entry, discovered_fp, armored


def discover_ubuntu_key_file(tmp_dir: Path) -> Path:
    explicit_file = os.environ.get("UBUNTU_KEY_FILE", "").strip()
    if explicit_file:
        return Path(explicit_file)
    key_url = os.environ.get("UBUNTU_KEYRING_URL", UBUNTU_KEYRING_URL)
    path = tmp_dir / "ubuntu-archive-keyring.gpg"
    write_bytes(path, fetch_bytes(key_url))
    return path


def ubuntu_entry(version: str, page_url: str, tmp_dir: Path):
    page = fetch_text(page_url)
    escaped = re.escape(version)
    pat = rf"ubuntu-{escaped}-minimal-cloudimg-arm64-root\.tar\.xz"
    files = sorted(set(re.findall(pat, page)))
    if not files:
        raise RuntimeError(
            f"failed to resolve ubuntu {version} minimal root tarball from {page_url}"
        )

    file_name = files[-1]
    tar_url = page_url + file_name
    checksum_url = page_url + "SHA256SUMS"
    signature_url = page_url + "SHA256SUMS.gpg"
    if not url_exists(signature_url):
        raise RuntimeError(f"missing ubuntu signature file: {signature_url}")

    sha_text = fetch_text(checksum_url)
    sha256 = parse_sha_line(sha_text, file_name)

    sums = tmp_dir / f"SHA256SUMS-{version}"
    sums_sig = tmp_dir / f"SHA256SUMS-{version}.gpg"
    write_bytes(sums, fetch_bytes(checksum_url))
    write_bytes(sums_sig, fetch_bytes(signature_url))

    gpg_home = create_gpg_home(tmp_dir, f"gpg-ubuntu-{version}")
    key_file = discover_ubuntu_key_file(tmp_dir)
    import_keys_to_gpg_home(gpg_home, [key_file])
    discovered_fp = verify_with_key_recovery(gpg_home, sums_sig, sums, tmp_dir)

    expected_fp = os.environ.get("UBUNTU_KEY_FINGERPRINT", "").strip().upper()
    if expected_fp and expected_fp != discovered_fp:
        raise RuntimeError(f"ubuntu signer mismatch: expected {expected_fp}, got {discovered_fp}")

    armored = export_armored_key(gpg_home, discovered_fp)
    entry = {
        "id": f"ubuntu-{version}-arm64",
        "distro": "ubuntu",
        "version": version,
        "arch": "arm64",
        "tarballURL": tar_url,
        "sha256": sha256,
        "signatureURL": signature_url,
        "checksumURL": checksum_url,
        "signatureTarget": "checksum",
        "keyFingerprint": discovered_fp,
        "serviceManager": "systemd",
        "userConvergenceTemplate": {
            "templateId": "ubuntu-useradd-v1",
            "commandFamily": "useradd",
            "adminGroup": "sudo",
            "sudoPolicy": {
                "enabled": True,
                "requireSudoBinary": False,
                "dropInPath": "/etc/sudoers.d/msl-user",
                "passwordless": True,
            },
            "suPolicy": {
                "enabled": False,
                "passwordless": False,
            },
            "shellFallbacks": ["/bin/bash", "/bin/sh"],
            "welcomePolicy": {
                "enabled": True,
                "frequency": "daily",
                "respectHushlogin": True,
            },
            "editable": False,
        },
        "cacheSharingDefaults": {
            "enabled": True,
            "apt": True,
            "apk": False,
        },
        "vulnerabilityDBTarget": vulnerability_db_target_for_distro("ubuntu", version),
    }
    return entry, discovered_fp, armored


def swift_string(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\r", "\\r")
        .replace("\n", "\\n")
    )
    return f"\"{escaped}\""


def render_entry(entry):
    template = entry.get("userConvergenceTemplate")
    cache_sharing_defaults = entry.get("cacheSharingDefaults")
    vulnerability_db_target = entry.get("vulnerabilityDBTarget")
    service_manager = entry.get("serviceManager")
    default_init_mode = entry.get("defaultInitMode")
    if template:
        shell_fallbacks = ", ".join(swift_string(v) for v in template["shellFallbacks"])
        template_code = (
            "UserConvergencePolicyTemplate(\n"
            f"                templateId: {swift_string(template['templateId'])},\n"
            f"                commandFamily: {swift_string(template['commandFamily'])},\n"
            f"                adminGroup: {swift_string(template['adminGroup'])},\n"
            "                sudoPolicy: SudoPolicyTemplate(\n"
            f"                    enabled: {'true' if template['sudoPolicy']['enabled'] else 'false'},\n"
            f"                    requireSudoBinary: {'true' if template['sudoPolicy']['requireSudoBinary'] else 'false'},\n"
            f"                    dropInPath: {swift_string(template['sudoPolicy']['dropInPath'])},\n"
            f"                    passwordless: {'true' if template['sudoPolicy'].get('passwordless', True) else 'false'}\n"
            "                ),\n"
            "                suPolicy: SuPolicyTemplate(\n"
            f"                    enabled: {'true' if template.get('suPolicy', {}).get('enabled', False) else 'false'},\n"
            f"                    passwordless: {'true' if template.get('suPolicy', {}).get('passwordless', False) else 'false'}\n"
            "                ),\n"
            f"                shellFallbacks: [{shell_fallbacks}],\n"
            "                welcomePolicy: WelcomePolicyTemplate(\n"
            f"                    enabled: {'true' if template['welcomePolicy']['enabled'] else 'false'},\n"
            f"                    frequency: {swift_string(template['welcomePolicy']['frequency'])},\n"
            f"                    respectHushlogin: {'true' if template['welcomePolicy']['respectHushlogin'] else 'false'}\n"
            "                ),\n"
            f"                editable: {'true' if template.get('editable') else 'false'}\n"
            "            )"
        )
    else:
        template_code = "nil"

    if cache_sharing_defaults:
        cache_sharing_code = (
            "CacheSharingConfig(\n"
            f"                enabled: {'true' if cache_sharing_defaults.get('enabled', False) else 'false'},\n"
            f"                apt: {'true' if cache_sharing_defaults.get('apt', True) else 'false'},\n"
            f"                apk: {'true' if cache_sharing_defaults.get('apk', True) else 'false'},\n"
            f"                zypper: {'true' if cache_sharing_defaults.get('zypper', False) else 'false'},\n"
            f"                dnf: {'true' if cache_sharing_defaults.get('dnf', False) else 'false'}\n"
            "            )"
        )
    else:
        cache_sharing_code = "nil"

    if vulnerability_db_target:
        vulnerability_db_target_code = (
            "DistributionManifestEntry.VulnerabilityDBTarget(\n"
            f"                family: {swift_string(vulnerability_db_target['family'])},\n"
            f"                release: {swift_string(vulnerability_db_target.get('release') or '')},\n"
            f"                dictionary: {swift_string(vulnerability_db_target['dictionary'])}\n"
            "            )"
        )
    else:
        vulnerability_db_target_code = "nil"

    return (
        "        DistributionManifestEntry(\n"
        f"            id: {swift_string(entry['id'])},\n"
        f"            distro: {swift_string(entry['distro'])},\n"
        f"            version: {swift_string(entry['version'])},\n"
        f"            arch: {swift_string(entry['arch'])},\n"
        f"            tarballURL: {swift_string(entry['tarballURL'])},\n"
        f"            sha256: {swift_string(entry['sha256'])},\n"
        f"            signatureURL: {swift_string(entry['signatureURL'])},\n"
        f"            checksumURL: {swift_string(entry['checksumURL'])},\n"
        f"            signatureTarget: {swift_string(entry['signatureTarget'])},\n"
        f"            keyFingerprint: {swift_string(entry['keyFingerprint'])},\n"
        "            supportState: .supported,\n"
        f"            serviceManager: {swift_string(service_manager) if service_manager else 'nil'},\n"
        f"            defaultInitMode: {swift_string(default_init_mode) if default_init_mode else 'nil'},\n"
        f"            userConvergenceTemplate: {template_code},\n"
        f"            cacheSharingDefaults: {cache_sharing_code},\n"
        f"            vulnerabilityDBTarget: {vulnerability_db_target_code}\n"
        "        )"
    )


def render_install_descriptor(item):
    aliases = ", ".join(swift_string(a) for a in item["aliases"])
    return (
        "        DistributionInstallDescriptor(\n"
        f"            canonicalName: {swift_string(item['canonicalName'])},\n"
        f"            aliases: [{aliases}],\n"
        f"            manifestId: {swift_string(item['manifestId'])}\n"
        "        )"
    )


def build_install_catalog(targets, entries):
    install_items = []
    entry_by_key = {
        f"{entry['distro']}:{entry['version']}": entry for entry in entries
    }
    for target in targets:
        key = f"{target['distro']}:{target['release']}"
        manifest = entry_by_key.get(key)
        if not manifest:
            raise RuntimeError(f"missing manifest entry for install catalog target {key}")
        install_items.append(
            {
                "canonicalName": target["canonicalName"],
                "aliases": target["aliases"],
                "manifestId": manifest["id"],
            }
        )

    seen_tokens = {}
    for item in install_items:
        tokens = [item["canonicalName"]] + item["aliases"]
        for token in tokens:
            normalized = token.strip().lower()
            if not normalized:
                raise RuntimeError(f"empty install token in {item['canonicalName']}")
            if normalized in seen_tokens:
                raise RuntimeError(
                    f"duplicate install token '{token}' in "
                    f"{item['canonicalName']} and {seen_tokens[normalized]}"
                )
            seen_tokens[normalized] = item["canonicalName"]

    return install_items


def write_generated_swift(entries, install_catalog):
    GEN_DIR.mkdir(parents=True, exist_ok=True)
    alpine_path = GEN_DIR / "DistributionManifest+Alpine.swift"
    alpine_code = (
        "import Foundation\n\n"
        "enum EmbeddedDistributionManifestAlpine {\n"
        "    static let entries: [DistributionManifestEntry] = []\n"
        "}\n"
    )
    alpine_path.write_text(alpine_code, encoding="utf-8")

    manifest_items = ",\n".join(render_entry(e) for e in entries)
    ubuntu_path = GEN_DIR / "DistributionManifest+Ubuntu.swift"
    ubuntu_code = (
        "import Foundation\n\n"
        "enum EmbeddedDistributionManifestUbuntu {\n"
        "    static let entries: [DistributionManifestEntry] = [\n"
        + manifest_items
        + "\n    ]\n}\n"
    )
    ubuntu_path.write_text(ubuntu_code, encoding="utf-8")

    index_path = GEN_DIR / "DistributionManifest+Index.swift"
    index_code = (
        "import Foundation\n\n"
        "enum EmbeddedDistributionManifest {\n"
        "    static let entries: [DistributionManifestEntry] =\n"
        "        EmbeddedDistributionManifestAlpine.entries +\n"
        "        EmbeddedDistributionManifestUbuntu.entries\n"
        "}\n"
    )
    index_path.write_text(index_code, encoding="utf-8")

    install_catalog_path = GEN_DIR / "DistributionInstallCatalog+Index.swift"
    install_items = ",\n".join(render_install_descriptor(item) for item in install_catalog)
    install_catalog_code = (
        "import Foundation\n\n"
        "enum EmbeddedDistributionInstallCatalog {\n"
        "    static let descriptors: [DistributionInstallDescriptor] = [\n"
        + install_items
        + "\n    ]\n}\n"
    )
    install_catalog_path.write_text(install_catalog_code, encoding="utf-8")

    return [alpine_path, ubuntu_path, index_path, install_catalog_path]


def write_trusted_keys(keys_by_fp):
    SECURITY_DIR.mkdir(parents=True, exist_ok=True)
    trusted_keys_path = SECURITY_DIR / "TrustedOpenPGPKeys.swift"
    pairs = sorted(keys_by_fp.items(), key=lambda kv: kv[0])
    lines = [
        "import Foundation",
        "",
        "enum TrustedOpenPGPKeys {",
        "    static let armoredByFingerprint: [String: String] = [",
    ]
    for i, (fp, key) in enumerate(pairs):
        comma = "," if i < len(pairs) - 1 else ""
        lines.append(f"        {swift_string(fp)}: {swift_string(key)}{comma}")
    lines.extend(["    ]", "}"])
    trusted_keys_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return trusted_keys_path


def main():
    with tempfile.TemporaryDirectory(prefix="msl-manifest-update-") as tmp:
        tmp_dir = Path(tmp)
        products = fetch_linuxcontainers_streams()
        entries = []
        keys = {}
        for target in TARGET_RELEASES:
            entry, fp, key = linuxcontainers_entry(target, products, tmp_dir)
            entries.append(entry)
            keys[fp] = key

        install_catalog = build_install_catalog(TARGET_RELEASES, entries)
        generated_paths = write_generated_swift(entries, install_catalog)
        trusted_keys_path = write_trusted_keys(keys)

    print("updated embedded distribution manifest")
    print("generated files:")
    for path in generated_paths:
        print(f"  - {path}")
    print(f"  - {trusted_keys_path}")
    print("signer fingerprints:")
    for fp in sorted(keys.keys()):
        print(f"  - {fp}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
