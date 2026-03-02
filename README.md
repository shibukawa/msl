# msl (Step2 prototype)

This repository currently contains a Swift prototype for bootstrap/lifecycle + Step2 filesystem/PTY/port-forwarding work.

## What works now
- `msl` command entrypoint
- `msl --status`
- `msl --stop`
- `msl --list`
- `msl --set-default <instance>`
- `msl install --list` (canonical + aliases)
- `msl init workspace [--force]` (`.mslconfig` scaffold)
- `msl port add <hostPort>:<guestPort>`
- `msl port ls`
- `msl port rm <hostPort>`
- Host bootstrap state under `~/Library/Application Support/msl`
- Session tracking and idle auto-stop timer (10 seconds)
- VM attach path via `Virtualization.framework` + `msl-init` control channel
- First-run bootstrap creates writable `disk.raw` separate from base image
- First-run bootstrap generates cloud-init NoCloud seed (`user-data`, `meta-data`, `seed.iso`)
- Guest mount target `/mnt/macos` and bind mapping `/home/<user>` -> `/mnt/macos/Users/<mac-user>/msl-home`
- Guest system-control bind mount `/mnt/msl-system` -> `/mnt/macos/Users/<mac-user>/.msl-system`

## Prerequisites
- macOS (Apple Silicon expected)
- Xcode Command Line Tools
- Swift toolchain (SwiftPM)
- Docker Desktop (or compatible Docker Engine)
- Ubuntu RAW image file prepared locally
- Host environment where Virtualization is available to the binary

Install kernel-build dependencies:

```bash
brew install --cask docker
```

If you start from Ubuntu cloud image (`*.img`, qcow2), convert it:

```bash
brew install qemu
qemu-img info ubuntu-24.04-server-cloudimg-arm64.img
qemu-img convert -f qcow2 -O raw ubuntu-24.04-server-cloudimg-arm64.img ubuntu-24.04-server-cloudimg-arm64.raw
```

Optionally resize (sparse max size only):

```bash
qemu-img resize -f raw ubuntu-24.04-server-cloudimg-arm64.raw 256G
```

## Build

```bash
make build
```

`make build` now does:
- build guest `msl-init` (`aarch64-unknown-linux-musl`)
- build host ext4 helpers (`msl-ext4-mkfs`, `msl-ext4-image`) for rootfs disk creation
- build and sign host `msl` binary

Other build helpers:
- `make build-ext4-helper`: build ext4 image helpers only
- `make build-image`: run `scripts/build-msl-image.sh` (Step18 storage image build entrypoint)
- `make reset`: legacy cleanup for old `distros/default/disk.raw` path (typically no-op on current instance-based installs)
- `make clean-alpine`: uninstall all instances with `--keep-cache`, install fresh `alpine` (kernel selection is delegated to `msl install`), clear host logs, then launch `msl`
- `make update-distribution-list`: refresh embedded manifest + install alias catalog

## Step18 storage image build

Build storage image from TOML profile:

```bash
./scripts/build-msl-image.sh \
  --profile default \
  --config /path/to/msl-image.toml \
  --output /tmp/msl-storage.raw
```

Equivalent CLI:

```bash
./.build/debug/msl image build \
  --profile default \
  --config /path/to/msl-image.toml \
  --output /tmp/msl-storage.raw
```

Generated artifacts (same directory as output image):
- `*.metadata.json`: base image hash, resolved compression policy, cache toggles, uid/gid, env, trim policy
- `*.plan.json`: runtime/provision consumption用の構造化プラン
- `*.provision.sh`: guest 内適用用スクリプト（compression/mount/trim/user/env）

Cache preset catalog:
- `~/Library/Application Support/msl/compression-cache-policy-catalog.json`
- `caches.<name>=true` の項目だけ `compression.pathPolicies` にマージされます

Cache toggle config:

```bash
./.build/debug/msl config cache ls
./.build/debug/msl config set storageCacheToggles.apt false
./.build/debug/msl config set storageCacheToggles.docker true
```

## Step5 install/default-instance commands

List installable distributions (with aliases):

```bash
./.build/debug/msl install --list
```

Install from catalog:

```bash
./.build/debug/msl install ubuntu
./.build/debug/msl install ubuntu-latest --name test-next
./.build/debug/msl install ubuntu-questing --name test-questing
```

List installed instances:

```bash
./.build/debug/msl --list
```

Set runtime default instance:

```bash
./.build/debug/msl --set-default test-next
```

Uninstall instance:

```bash
./.build/debug/msl uninstall test-next
./.build/debug/msl uninstall --keep-cache test-questing
```

## Workspace config scaffold

Create `.mslconfig` in current directory:

```bash
./.build/debug/msl init workspace
```

Overwrite existing `.mslconfig`:

```bash
./.build/debug/msl init workspace --force
```

Notes:
- `.mslconfig` の存在自体で workspace mirror を有効化します。`[workspace] enabled = true` は不要です。
- `msl workspace init` 実行ディレクトリが shared-root 対象外の場合は、作成後に警告を表示します。
- Step10 では `msl share ...` コマンドはありません。shared-root は `msl/config.json` の `workspaceHostShareRoot` を手動編集して調整します。

## Step6 kernel artifacts

Step6 builds kernel artifacts outside distro rootfs (WSL2-like ownership boundary).

Show usage:

```bash
make kernel-help
```

Fetch kernel source from kernel.org:

```bash
make kernel-fetch-source KERNEL_VERSION=6.12.4
```

Optional:
- `KERNEL_FETCH_FORCE=1`: force re-download and re-extract
- `KERNEL_SOURCE_CACHE_DIR=<path>`: override tarball/checksum cache dir
- `KERNEL_SOURCE_OUT_DIR=<path>`: override extract destination root

Build artifacts:

```bash
make kernel-build \
  KERNEL_VERSION=6.12.4 \
  KERNEL_PROFILE=slim
```

Default profile (Step8):
- `KERNEL_PROFILE=slim` (default)
- moduleless build for default runtime path (`Image` only)
- required runtime keys are built-in (`=y`)

Optional profile/env:
- `KERNEL_PROFILE=legacy-defconfig` (rollback/compat path)
- `KERNEL_PROFILE=minimum-defconfig` (legacy-defconfig 起点の初期削減トライアル)
- `KERNEL_PROFILE=apple-containerization-6.1.68` (Apple containerization `config-arm64` ベース)
- `KERNEL_PROFILE=<id>` (任意の profile id を利用可能。`Support/kernel/config/msl-<id>.fragment` または `msl-<id>-defconfig.fragment` を自動探索)
- `KERNEL_EXPERIMENT_LTO=1` (size experiment with `CONFIG_LTO_CLANG`)
- artifact directory key is unified with `KERNEL_PROFILE` (`~/Library/Application Support/msl/kernels/<KERNEL_PROFILE>/`)

Note:
- `kernel-build` は Docker コンテナ内 Linux 環境で実行される（ワークスペースを `/workspace` にマウント）。
- `kernel-build` は `KERNEL_VERSION` を元に、コンテナ内で kernel.org からソースを取得してビルドする。
- kernel source / build tree / ccache は Docker volume (`msl-kernel-work`) 側で保持し、ホスト側は成果物の同期のみ行う。
- つまり再ビルド時は `.o` 再利用（ccache + volume 上 build tree）で高速化できる。
- 必要なら `KERNEL_DOCKER_WORK_VOLUME=<name>` で volume 名を分離できる。
- `KERNEL_DOCKER_CCACHE=0` で ccache を無効化できる（デフォルトは有効）。
- 既存 `~/Library/Application Support/msl/kernels/<kernel-profile>/` は毎回置き換える（強制上書き）。
- コンテナ内成果物は `tmp/docker-msl-home/Library/Application Support/msl/kernels/<kernel-profile>/` にも残る。
- default profile では `modules/` が存在しない場合がある（runtime/stage は許容）。
- `ISO9660` は seed-ISO 起動経路が残っている間は維持する。

Stage artifacts for packaging:

```bash
make kernel-stage KERNEL_PROFILE=slim
```

Outputs:
- Host artifacts: `~/Library/Application Support/msl/kernels/<kernel-profile>/`
- Package staging: `tmp/distribution-kernel/<kernel-profile>/`

Step6 profile notes:
- default boot-critical path is initrd-independent (`ext4`/`virtio*` built-in policy)
- Ubuntu compatibility target includes AppArmor-capable kernel baseline
- container/eBPF baseline is enabled for modern workloads
- virtio-gpu / virtio-snd are built-in in Step8 default profile
- NPU acceleration is investigation-only (not a Step6 guarantee)

Rollback example (temporary compatibility path):

```bash
make kernel-build \
  KERNEL_VERSION=6.12.4 \
  KERNEL_PROFILE=legacy-defconfig
```

Binary path:

```bash
./.build/debug/msl
```

## Signing and Entitlements (required for VM backend)

`swift build` does not apply Xcode project's Signing & Capabilities settings.
Even if you have an Xcode project/workspace, `swift build` only uses `Package.swift`.
So you must sign the built binary explicitly when running via SwiftPM.

This repo includes:
- `msl.entitlements` (contains `com.apple.security.virtualization=true`)
- `scripts/build-signed.sh` (build + codesign + entitlement check)
- `scripts/build-msl-init.sh` (build guest `msl-init`)
- `Makefile` (`make build` runs init build + signed host build, with `make reset` helper)

Use:

```bash
make build
```

Manual equivalent:

```bash
swift build
codesign --force --sign - --entitlements ./msl.entitlements ./.build/debug/msl
codesign -d --entitlements - ./.build/debug/msl
```

## Quick start (safe test mode)

Use a local temporary home and explicit image path so you do not touch your real `~/Library/Application Support/msl` during initial testing.

```bash
export MSL_HOME="$PWD/.tmp-msl-home"
export MSL_IMAGE_PATH="$PWD/ubuntu-24.04-server-cloudimg-arm64.raw"
```

Optional first-boot user overrides:

```bash
export MSL_DEFAULT_USER="$(id -un)"
export MSL_DEFAULT_PASSWORD="optional-password"
```

If not set, defaults are:
- user: current macOS username (`id -un`, normalized for Linux username rules)
- password: none

## Environment variable defaults

- `MSL_HOME`:
  - default is your macOS home directory (`$HOME`)
  - runtime paths become `$HOME/Library/Application Support/msl/...`
- `MSL_IMAGE_PATH`:
  - default is `~/Library/Application Support/msl/distros/ubuntu-24.04-server-cloudimg-arm64.raw`
  - set this only when your RAW image is stored elsewhere
- `MSL_HOST_SHARE_ROOT`:
  - default is `/` (host root mounted in guest at `/mnt/macos`)
  - set this if you want to limit host shared scope
- `MSL_GUEST_IP`:
  - optional override for guest IP used by `msl port` runtime forwarding
  - if unset, msl auto-discovers guest candidate IPs from host ARP/vmnet information
- `MSL_INIT_ATTACH_TIMEOUT_SEC`:
  - timeout for waiting `msl-init` control-channel readiness at attach
  - default is adaptive: `300` seconds before first successful bootstrap log, then `120` seconds
- `MSL_MEMORY_MB`:
  - optional VM memory max override (MiB)
  - if unset, max defaults to `min(host RAM / 2, 8GiB)`
- `MSL_MEMORY_START_MB`:
  - optional startup guest memory target (MiB) requested via virtio balloon
  - default: `256` MiB
- `MSL_MEMORY_HEADROOM_MB`:
  - optional adaptive balloon controller headroom (MiB)
  - default: `256` MiB
- `MSL_MEMORY_BALLOON_POLL_SEC`:
  - optional meminfo sampling interval for adaptive ballooning
  - default: `5` seconds
- `MSL_MEMORY_BALLOON_MIN_DELTA_MB`:
  - optional minimum target change threshold (MiB) to avoid oscillation
  - default: `64` MiB
- `MSL_KERNEL_PROFILE`:
  - optional Step6 kernel profile id
  - if set, runtime uses `~/Library/Application Support/msl/kernels/<id>/vmlinuz` via `VZLinuxBootLoader`
  - if unset, runtime defaults to `slim` (`~/Library/Application Support/msl/kernels/slim/vmlinuz`)
- `MSL_KERNEL_CMDLINE`:
  - optional full kernel command line override when kernel profile is set
- `MSL_KERNEL_ROOT`:
  - optional root device override used when `MSL_KERNEL_CMDLINE` is not set
  - default: `/dev/vda`

For file locations with a custom `MSL_HOME`, replace `~` with `$MSL_HOME`.

Check status:

```bash
./.build/debug/msl --status
```

Stop runtime:

```bash
./.build/debug/msl --stop
```

Port forwarding:

- Runtime daemon auto-forwards guest TCP listeners (`0.0.0.0` / non-loopback IPv4, ports `1...65535`) to `localhost:<same-port>`.
- Manual mappings still work and take precedence over auto mappings when host ports overlap.
- If host already uses a port, the entry stays `inactive` and `msl port ls` shows a detail message with guest IP direct-access hint (when available).

```bash
./.build/debug/msl port
./.build/debug/msl port add 8080:8080
./.build/debug/msl port ls
./.build/debug/msl port rm 8080
```

`msl port` is a shortcut for `msl port ls`.

Run default command (interactive shell attach path):

```bash
./.build/debug/msl
```

Serial-console fallback (diagnostics only):

```bash
./.build/debug/msl --serial-console
```

If virtualization is unavailable on your host, `msl` prints a clear error.
For lifecycle debugging without VM backend:

```bash
MSL_FORCE_LOCAL_SHELL=1 ./.build/debug/msl
```

## Run with real home paths

Unset test overrides:

```bash
unset MSL_HOME
unset MSL_IMAGE_PATH
```

Then place your RAW image at:

```text
~/Library/Application Support/msl/distros/ubuntu-24.04-server-cloudimg-arm64.raw
```

or set `MSL_IMAGE_PATH` to any absolute RAW path.

## Bootstrap and user behavior

Current runtime is instance-based:
- Writable VM disk is per instance:
  - `~/Library/Application Support/msl/distros/<instance>/disk.raw`
- Runtime attach path uses `msl-init` control channel.
- Default login user is your macOS username.
  - serial fallback (`--serial-console`) still configures `hvc0`/`ttyS0` autologin
  - terminal type defaults to your host `TERM` when safe, with fallback to `xterm-256color` for compatibility
- If you set `MSL_DEFAULT_PASSWORD`, password authentication is provisioned for that user.

Install/build helper artifacts (cloud-init seed inputs) are staged under:
- `~/Library/Application Support/msl/bootstrap/cloud-init/user-data`
- `~/Library/Application Support/msl/bootstrap/cloud-init/meta-data`
- `~/Library/Application Support/msl/bootstrap/seed.iso`

Package installs (`apt-get install ...`) are persisted to the selected instance `disk.raw`, not the base image.

## Logs and state

When running, the prototype writes state files under:

```text
~/Library/Application Support/msl/runtime/
```

Main log file:

```text
~/Library/Application Support/msl/runtime/logs/msl.log
```

## Tests

```bash
swift test
```
