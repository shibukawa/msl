.PHONY: build installer build-init build-wayland build-ext4-helper build-image build-imagewriter build-imagewriter-help imagewriter-help imagewriter-setup imagewriter \
	build-container-runtime \
	stage-container-tools package-container-tools install-container-tools \
	reset reset-disk reset-full clean-alpine clean-ubuntu run \
	test test-regression \
	update-distribution-list \
	kernel-help kernel-fetch-source kernel-build kernel-build-docker kernel-stage \
	clean

MSL ?= ./.build/debug/msl
CONTAINER_TOOLS_STAGE_DIR ?= $(HOME)/Library/Application Support/msl/tools/bundled/darwin-arm64
REGCTL_VERSION ?= latest
UMOCI_VERSION ?= latest

build: build-init build-wayland build-ext4-helper
	./scripts/build-signed.sh

installer: build-init build-wayland build-ext4-helper package-container-tools kernel-stage build-imagewriter build-container-runtime
	./scripts/build-installer.sh

build-init:
	./scripts/build-msl-init.sh

build-wayland:
	./scripts/build-msl-wayland.sh

build-ext4-helper:
	./scripts/build-msl-ext4-image.sh

build-image:
	./scripts/build-msl-image.sh

stage-container-tools:
	CONTAINER_TOOLS_STAGE_DIR="$(CONTAINER_TOOLS_STAGE_DIR)" \
	REGCTL_VERSION="$(REGCTL_VERSION)" \
	UMOCI_VERSION="$(UMOCI_VERSION)" \
	./scripts/stage-container-tools.sh

package-container-tools:
	CONTAINER_TOOLS_STAGE_DIR="$(CONTAINER_TOOLS_STAGE_DIR)" \
	./scripts/package-container-tools.sh

install-container-tools: stage-container-tools

build-container-runtime:
	MSL_BIN="$(MSL)" \
	./scripts/build-container-runtime.sh

build-imagewriter-help:
	@echo "Imagewriter (Alpine instance for storage image build)"
	@echo ""
	@echo "Setup builder instance only:"
	@echo "  make imagewriter-setup"
	@echo "    # _imagewriter のみを再作成し、他の distros は保持します"
	@echo ""
	@echo "Build _imagewriter disk (two-stage ext4 -> erofs):"
	@echo "  make build-imagewriter"
	@echo "    # setup 後に _imagewriter/disk.raw を readonly EROFS として再生成します"
	@echo ""
	@echo "Optional env:"
	@echo "  IMAGEWRITER_PACKAGES=\"btrfs-progs e2fsprogs erofs-utils util-linux tar zstd xz coreutils\""
	@echo "  IMAGEWRITER_ROOTFS_PACKAGES=\"...\"  # default: IMAGEWRITER_PACKAGES for script/make callers"
	@echo "  IMAGEWRITER_CLEAN_DISTROS=1   # default: 1 (_imagewriter only)"
	@echo "  IMAGEWRITER_FORCE_SETUP=1     # default for make build-imagewriter: 1"
	@echo "  MSL_INIT_BOOTLOADER_BINARY_PATH=...  # default: $$HOME/.msl-system/msl-init-bootloader"
	@echo "  MSL_BIN=./.build/debug/msl"

imagewriter-setup:
	IMAGEWRITER_INSTANCE="$(IMAGEWRITER_INSTANCE)" \
	IMAGEWRITER_PACKAGES="$(IMAGEWRITER_PACKAGES)" \
	IMAGEWRITER_CLEAN_DISTROS="$(IMAGEWRITER_CLEAN_DISTROS)" \
	MSL_BIN="$(MSL)" \
	./scripts/imagewriter-setup.sh

build-imagewriter:
	@MSL_HOME_DIR="$${MSL_HOME:-$$HOME}"; \
	APP_SUPPORT_DIR="$$MSL_HOME_DIR/Library/Application Support/msl"; \
	INSTANCE_NAME="$${IMAGEWRITER_INSTANCE:-_imagewriter}"; \
	OUTPUT_PATH="$$APP_SUPPORT_DIR/distros/$$INSTANCE_NAME/disk.raw"; \
	INIT_BIN_PATH="$${MSL_INIT_BOOTLOADER_BINARY_PATH:-$$HOME/.msl-system/msl-init-bootloader}"; \
	IMAGE_SIZE_MB_VALUE="$${IMAGE_SIZE_MB:-2048}"; \
	echo "building imagewriter disk via two-stage pipeline: $$OUTPUT_PATH"; \
	echo "using init bootloader: $$INIT_BIN_PATH"; \
	echo "using image size (MB): $$IMAGE_SIZE_MB_VALUE"; \
	IMAGEWRITER_INSTANCE="$$INSTANCE_NAME" \
	IMAGEWRITER_PACKAGES="$(IMAGEWRITER_PACKAGES)" \
	IMAGEWRITER_CLEAN_DISTROS="$(IMAGEWRITER_CLEAN_DISTROS)" \
	IMAGEWRITER_FORCE_SETUP="$${IMAGEWRITER_FORCE_SETUP:-1}" \
	IMAGEWRITER_INIT_BINARY="$$INIT_BIN_PATH" \
	IMAGE_SIZE_MB="$$IMAGE_SIZE_MB_VALUE" \
	IMAGE_FS="erofs" \
	OUTPUT_RAW="$$OUTPUT_PATH" \
	MSL_BIN="$(MSL)" \
	./scripts/imagewriter-build.sh; \
	ARTIFACT_DIR="tmp/imagewriter-runtime-artifact/$$INSTANCE_NAME"; \
	mkdir -p "$$ARTIFACT_DIR"; \
	cp "$$APP_SUPPORT_DIR/distros/$$INSTANCE_NAME/disk.raw" "$$ARTIFACT_DIR/disk.raw"; \
	cp "$$APP_SUPPORT_DIR/distros/$$INSTANCE_NAME/metadata.json" "$$ARTIFACT_DIR/metadata.json"

reset: reset-disk

reset-disk:
	@MSL_HOME_DIR="$${MSL_HOME:-$$HOME}"; \
	DISK_PATH="$$MSL_HOME_DIR/Library/Application Support/msl/distros/default/disk.raw"; \
	if [ -f "$$DISK_PATH" ]; then \
		rm -f "$$DISK_PATH"; \
		echo "removed: $$DISK_PATH"; \
	else \
		echo "skip: $$DISK_PATH (not found)"; \
	fi

reset-full:
	@MSL_HOME_DIR="$${MSL_HOME:-$$HOME}"; \
	DISTRO_DIR="$$MSL_HOME_DIR/Library/Application Support/msl/distros/default"; \
	for F in disk.raw efi-variable-store seed.iso machine-identifier.bin metadata.json; do \
		if [ -f "$$DISTRO_DIR/$$F" ]; then \
			rm -f "$$DISTRO_DIR/$$F"; \
			echo "removed: $$DISTRO_DIR/$$F"; \
		fi; \
	done; \
	CLOUD_DIR="$$DISTRO_DIR/cloud-init"; \
	if [ -d "$$CLOUD_DIR" ]; then \
		rm -rf "$$CLOUD_DIR"; \
		echo "removed: $$CLOUD_DIR"; \
	fi; \
	RUNTIME_DIR="$$MSL_HOME_DIR/Library/Application Support/msl/runtime"; \
	for F in state.json sessions.json control.sock; do \
		if [ -f "$$RUNTIME_DIR/$$F" ] || [ -S "$$RUNTIME_DIR/$$F" ]; then \
			rm -f "$$RUNTIME_DIR/$$F"; \
			echo "removed: $$RUNTIME_DIR/$$F"; \
		fi; \
	done; \
	LOG_DIR="$$RUNTIME_DIR/logs"; \
	if [ -d "$$LOG_DIR" ]; then \
		rm -rf "$$LOG_DIR"; \
		echo "removed: $$LOG_DIR"; \
	fi

run:
	$(MAKE) build
	-$(MSL) --stop 2>/dev/null
	$(MAKE) reset
	$(MSL)

clean-alpine:
	$(MAKE) build
	-$(MSL) --stop 2>/dev/null
	@MSL_HOME_DIR="$${MSL_HOME:-$$HOME}"; \
	APP_SUPPORT_DIR="$$MSL_HOME_DIR/Library/Application Support/msl"; \
	INSTANCES="$$( $(MSL) --list 2>/dev/null | sed -e 's/ \[default\]$$//' | awk '{print $$1}' )"; \
	if [ -n "$$INSTANCES" ]; then \
		for name in $$INSTANCES; do \
			if [ "$$name" = "_imagewriter" ] || [ "$$name" = "_container" ]; then \
				echo "skip uninstall (reserved internal instance): $$name"; \
				continue; \
			fi; \
			echo "uninstalling instance (keep cache): $$name"; \
			$(MSL) uninstall --keep-cache "$$name" || exit $$?; \
		done; \
	else \
		echo "skip: no installed instances"; \
	fi; \
	echo "installing alpine..."; \
	$(MSL) install alpine || exit $$?; \
	RUNTIME_LOG_DIR="$$APP_SUPPORT_DIR/runtime/logs"; \
	APP_LOG_DIR="$$APP_SUPPORT_DIR/logs"; \
	INIT_BOOTSTRAP_LOG="$$MSL_HOME_DIR/.msl-system/init-bootstrap.log"; \
	if [ -d "$$RUNTIME_LOG_DIR" ]; then \
		rm -rf "$$RUNTIME_LOG_DIR"; \
		echo "removed: $$RUNTIME_LOG_DIR"; \
	fi; \
	if [ -d "$$APP_LOG_DIR" ]; then \
		rm -rf "$$APP_LOG_DIR"; \
		echo "removed: $$APP_LOG_DIR"; \
	fi; \
	if [ -f "$$INIT_BOOTSTRAP_LOG" ]; then \
		rm -f "$$INIT_BOOTSTRAP_LOG"; \
		echo "removed: $$INIT_BOOTSTRAP_LOG"; \
	fi; \
	echo "starting msl..."; \
	$(MSL)

clean-ubuntu:
	$(MAKE) build
	-$(MSL) --stop 2>/dev/null
	@MSL_HOME_DIR="$${MSL_HOME:-$$HOME}"; \
	APP_SUPPORT_DIR="$$MSL_HOME_DIR/Library/Application Support/msl"; \
	INSTANCES="$$( $(MSL) --list 2>/dev/null | sed -e 's/ \[default\]$$//' | awk '{print $$1}' )"; \
	if [ -n "$$INSTANCES" ]; then \
		for name in $$INSTANCES; do \
			if [ "$$name" = "_imagewriter" ] || [ "$$name" = "_container" ]; then \
				echo "skip uninstall (reserved internal instance): $$name"; \
				continue; \
			fi; \
			echo "uninstalling instance (keep cache): $$name"; \
			$(MSL) uninstall --keep-cache "$$name" || exit $$?; \
		done; \
	else \
		echo "skip: no installed instances"; \
	fi; \
	echo "installing ubuntu..."; \
	$(MSL) install ubuntu || exit $$?; \
	RUNTIME_LOG_DIR="$$APP_SUPPORT_DIR/runtime/logs"; \
	APP_LOG_DIR="$$APP_SUPPORT_DIR/logs"; \
	INIT_BOOTSTRAP_LOG="$$MSL_HOME_DIR/.msl-system/init-bootstrap.log"; \
	if [ -d "$$RUNTIME_LOG_DIR" ]; then \
		rm -rf "$$RUNTIME_LOG_DIR"; \
		echo "removed: $$RUNTIME_LOG_DIR"; \
	fi; \
	if [ -d "$$APP_LOG_DIR" ]; then \
		rm -rf "$$APP_LOG_DIR"; \
		echo "removed: $$APP_LOG_DIR"; \
	fi; \
	if [ -f "$$INIT_BOOTSTRAP_LOG" ]; then \
		rm -f "$$INIT_BOOTSTRAP_LOG"; \
		echo "removed: $$INIT_BOOTSTRAP_LOG"; \
	fi; \
	echo "starting msl..."; \
	$(MSL)

test:
	swift test

test-regression: build
	MSL="$(MSL)" bash Tests/regression/runner.sh

update-distribution-list:
	python3 scripts/update-distribution-manifest.py

kernel-help:
	@echo "Kernel build/stage"
	@echo ""
	@echo "Fetch kernel source from kernel.org:"
	@echo "  make kernel-fetch-source KERNEL_VERSION=7.0.1 [KERNEL_FETCH_FORCE=1]"
	@echo ""
	@echo "Build:"
	@echo "  make kernel-build KERNEL_VERSION=7.0.1"
	@echo "    # default backend: Docker (Linux build env, workspace mount)"
	@echo "    # source is fetched inside container from kernel.org"
	@echo ""
	@echo "Stage for packaging:"
	@echo "  make kernel-stage [KERNEL_PROFILE=<id>]"
	@echo ""
	@echo "Optional env:"
	@echo '  MSL_HOME=<home-dir>            # default: $$HOME'
	@echo "  KERNEL_VERSION=<version>       # required for kernel-build"
	@echo "  KERNEL_PROFILE=<id>            # default: slim (artifact ref is unified with this name)"
	@echo "  KERNEL_EXPERIMENT_LTO=1        # optional size experiment with CONFIG_LTO_CLANG"
	@echo "  KERNEL_DOCKER_WORK_VOLUME=<v>  # default: msl-kernel-work (source/build/ccache cache)"
	@echo "  KERNEL_DOCKER_CCACHE=1         # default: 1 (ccache enabled)"
	@echo "  KERNEL_DOCKER_CCACHE_MAXSIZE=20G"

kernel-fetch-source:
	./scripts/fetch-kernel-source.sh

kernel-build:
	./scripts/build-kernel-docker.sh

kernel-build-docker:
	./scripts/build-kernel-docker.sh

kernel-stage:
	./scripts/stage-kernel-artifacts.sh

clean:
	rm -rf .build
