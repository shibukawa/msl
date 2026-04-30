import XCTest

final class ImagewriterScriptTests: XCTestCase {
    func testImagewriterSetupScriptUsesStopSubcommand() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("scripts/imagewriter-setup.sh"), encoding: .utf8)

        XCTAssertFalse(script.contains("--instance \"$INSTANCE\" --stop"))
        XCTAssertFalse(script.contains("\"$MSL_BIN\" --stop"))
        XCTAssertTrue(script.contains("\"$MSL_BIN\" stop"))
        XCTAssertTrue(script.contains("\"$MSL_BIN\" --instance \"$INSTANCE\" stop"))
        XCTAssertTrue(script.contains("bootstrap_fs: ext4"))
        XCTAssertTrue(script.contains("\"$MSL_BIN\" list --all"))
        XCTAssertTrue(script.contains("uninstalling imagewriter instance only (keep cache): $INSTANCE"))
        XCTAssertFalse(script.contains("uninstalling instance (keep cache): $name"))
        XCTAssertTrue(script.contains("[ -f \"$(instance_disk_path)\" ]"))
    }

    func testImagewriterBuildScriptUsesStopSubcommand() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("scripts/imagewriter-build.sh"), encoding: .utf8)

        XCTAssertFalse(script.contains("--instance \"$INSTANCE\" --stop"))
        XCTAssertTrue(script.contains("\"$MSL_BIN\" stop --app >/dev/null 2>&1 || true"))
        XCTAssertTrue(script.contains("\"$MSL_BIN\" --instance \"$INSTANCE\" stop"))
        XCTAssertTrue(script.contains("IMAGE_SIZE_MB is required; msl install must pass an explicit size"))
        XCTAssertFalse(script.contains("IMAGE_SIZE_MB=\"${IMAGE_SIZE_MB:-65536}\""))
        XCTAssertTrue(script.contains("IMAGE_FS must be btrfs, erofs, or ext4"))
        XCTAssertTrue(script.contains("stage2_${IMAGE_FS}"))
        XCTAssertTrue(script.contains("ALLOW_SETUP_WHEN_MISSING"))
        XCTAssertTrue(script.contains("REQUIRED_IMAGEWRITER_FS"))
        XCTAssertTrue(script.contains("[ -f \"$(instance_disk_path)\" ]"))
        XCTAssertTrue(script.contains("required imagewriter instance is missing"))
        XCTAssertTrue(script.contains("verify_expected_fs_type \"$STAGE2_OUTPUT\" \"$IMAGE_FS\" \"$stage2_name\""))
        XCTAssertTrue(script.contains("verify_expected_fs_type \"$OUTPUT_RAW\" \"$IMAGE_FS\" \"final_output\""))
        XCTAssertTrue(script.contains("verify_guest_visible_fs_type \"$GUEST_FINAL_OUTPUT\" \"$IMAGE_FS\" \"final_output\""))
        XCTAssertTrue(script.contains("verify_guest_visible_fs_type \"$GUEST_IMAGEWRITER_DISK\" \"$REQUIRED_IMAGEWRITER_FS\" \"imagewriter_instance\""))
        XCTAssertTrue(script.contains("imagewriter_verified_fs context=$verify_context fs=$actual_fs path=$image_path"))
        XCTAssertTrue(script.contains("imagewriter_guest_verified_shared_output mode=$mode fs=$shared_output_fs output=$output"))
        XCTAssertTrue(script.contains("ROOTFS_DIR"))
        XCTAssertTrue(script.contains("OCI_LAYOUT_DIR"))
        XCTAssertTrue(script.contains("EXTRA_GUEST_FILES_BUNDLE"))
        XCTAssertTrue(script.contains("--rootfs-dir \"$input_path\""))
        XCTAssertTrue(script.contains("--oci-layout-dir \"$input_path\""))
        XCTAssertTrue(script.contains("--extra-files-bundle \"$extra_files_bundle\""))
        XCTAssertTrue(script.contains("single_pass_mode=\"stage2\""))
        XCTAssertTrue(script.contains("single_pass_packages=\"$IMAGEWRITER_PACKAGES\""))
        XCTAssertTrue(script.contains("manifest.lines"))
        XCTAssertTrue(script.contains("guest_tmp_image=\"${9}\""))
        XCTAssertTrue(script.contains("apk_retry_limit=\"${10}\""))
        XCTAssertTrue(script.contains("run_guest_worker \"$mode\" \"$guest_input\" \"$guest_output\" \"$fs_type\" \"$size_mb\" \"$guest_init\" \"$packages\" \"$apk_cache\" \"$GUEST_TMP_IMAGE\" \"$IMAGEWRITER_APK_RETRY_LIMIT\""))
        XCTAssertTrue(script.contains("imagewriter_guest_failure_detected mode=$mode"))
        XCTAssertTrue(script.contains("guest_stdout_log_for_mode()"))
        XCTAssertTrue(script.contains("guest_stderr_log_for_mode()"))
        XCTAssertTrue(script.contains("OUTPUT_STATE_RAW"))
        XCTAssertTrue(script.contains("OUTPUT_STATE_TEMPLATE_RAW"))
        XCTAssertTrue(script.contains("STATE_IMAGE_SIZE_MB"))
        XCTAssertTrue(script.contains("STATE_TEMPLATE_RAW=\"$OUTPUT_STATE_TEMPLATE_RAW\""))
        XCTAssertTrue(script.contains("mark_stage_start \"state_btrfs\""))
        XCTAssertTrue(script.contains("run_guest_worker_with_retry state"))
        XCTAssertTrue(script.contains("copy_sparse_file \"$STATE_TEMPLATE_RAW\" \"$OUTPUT_STATE_RAW\""))
    }

    func testImagewriterGuestBuilderRequiresExplicitSize() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("scripts/imagewriter-build-guest.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("size-mb is required; msl install must pass an explicit size"))
        XCTAssertFalse(script.contains("DEFAULT_SIZE_MB"))
        XCTAssertTrue(script.contains("--size-mb <n>"))
        XCTAssertTrue(script.contains("--fs-type <btrfs|erofs>"))
        XCTAssertTrue(script.contains("--rootfs-dir <rootfs-dir>"))
        XCTAssertTrue(script.contains("--oci-layout-dir <oci-layout-dir>"))
        XCTAssertTrue(script.contains("--extra-files-bundle <bundle-dir>"))
        XCTAssertTrue(script.contains("--mode state --output <output-image> --size-mb <n>"))
        XCTAssertTrue(script.contains("build_empty_state_image()"))
        XCTAssertTrue(script.contains("mkdir -p \"$OUTPUT_MOUNT_DIR/upper\" \"$OUTPUT_MOUNT_DIR/work\""))
        XCTAssertTrue(script.contains("mkfs.erofs"))
        XCTAssertTrue(script.contains("blkid -p -s TYPE -o value"))
        XCTAssertTrue(script.contains("imagewriter_guest_verified_fs mode=$MODE fs=$actual_fs output=$OUTPUT_IMAGE"))
        XCTAssertTrue(script.contains("install_extra_files()"))
        XCTAssertTrue(script.contains("resolve_injected_umoci()"))
        XCTAssertTrue(script.contains("manifest_lines=\"$EXTRA_FILES_BUNDLE/manifest.lines\""))
        XCTAssertTrue(script.contains("imagewriter_guest_failure stage="))
        XCTAssertTrue(script.contains("fail_guest_stage \"container_unpack\" 26"))
        XCTAssertTrue(script.contains("fail_guest_stage \"rootfs_copy\" 26"))
        XCTAssertTrue(script.contains("fail_guest_stage \"runtime_validation\" 26"))
    }

    func testBuildImagewriterTargetUsesErofs() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let makefile = try String(contentsOf: root.appendingPathComponent("Makefile"), encoding: .utf8)

        XCTAssertTrue(makefile.contains("two-stage ext4 -> erofs"))
        XCTAssertTrue(makefile.contains("readonly EROFS"))
        XCTAssertTrue(makefile.contains("IMAGE_FS=\"erofs\""))
        XCTAssertTrue(makefile.contains("_imagewriter のみを再作成し、他の distros は保持します"))
        XCTAssertTrue(makefile.contains("stage-container-tools"))
        XCTAssertTrue(makefile.contains("package-container-tools"))
    }

    func testBuildSignedScriptPackagesBundledContainerHelpersWhenStaged() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("scripts/build-signed.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("package-container-tools.sh"))
        XCTAssertTrue(script.contains("Container helper bundle not staged; skipping helper packaging."))
    }

    func testBuildDesktopAppCopiesContainerHelpersIntoResources() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("scripts/build-desktop-app.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("CONTAINER_TOOLS_DEST_DIR"))
        XCTAssertTrue(script.contains("container-tools"))
        XCTAssertTrue(script.contains("manifest.json"))
        XCTAssertTrue(script.contains("tool[\"relativePath\"]"))
        XCTAssertTrue(script.contains("os.makedirs(os.path.dirname(dst), exist_ok=True)"))
    }

    func testStageContainerToolsStagesGuestBuildctl() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("scripts/stage-container-tools.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("BUILDKIT_VERSION"))
        XCTAssertTrue(script.contains("YOUKI_VERSION"))
        XCTAssertTrue(script.contains("resolve_buildkit_asset_url"))
        XCTAssertTrue(script.contains("resolve_youki_asset_url"))
        XCTAssertTrue(script.contains("linux-arm64/buildctl"))
        XCTAssertTrue(script.contains("linux-arm64/youki"))
        XCTAssertTrue(script.contains("\"name\": \"buildctl\""))
        XCTAssertTrue(script.contains("\"name\": \"youki\""))
        XCTAssertTrue(script.contains("guest buildctl: $STAGE_DIR/linux-arm64/buildctl"))
        XCTAssertTrue(script.contains("guest youki: $STAGE_DIR/linux-arm64/youki"))
    }

    func testBuildContainerRuntimeTargetBuildsInternalContainerArtifact() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let makefile = try String(contentsOf: root.appendingPathComponent("Makefile"), encoding: .utf8)
        let script = try String(contentsOf: root.appendingPathComponent("scripts/build-container-runtime.sh"), encoding: .utf8)

        XCTAssertTrue(makefile.contains("build-container-runtime:"))
        XCTAssertTrue(makefile.contains("./scripts/build-container-runtime.sh"))
        XCTAssertTrue(script.contains("MSL_ALLOW_INTERNAL_CONTAINER_RUNTIME=1"))
        XCTAssertTrue(script.contains("install --rebuild --name \"$INSTANCE_NAME\" container-runtime"))
        XCTAssertTrue(script.contains("INSTANCE_NAME=\"${CONTAINER_RUNTIME_INSTANCE:-_container}\""))
        XCTAssertTrue(script.contains("tmp/container-runtime-artifact"))
        XCTAssertTrue(script.contains("base.erofs.raw"))
        XCTAssertTrue(script.contains("state.btrfs.template.raw"))
        XCTAssertFalse(script.contains("cp \"$INSTANCE_DIR/disk.raw\""))
        XCTAssertTrue(script.contains("metadata.json"))
        XCTAssertTrue(script.contains("source.json"))
    }

    func testImagewriterGuestReportsBeesPackageHint() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("scripts/imagewriter-build-guest.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("Alpine duperemove"))
        XCTAssertTrue(script.contains("community repository"))
    }

    func testImagewriterCanInjectContainerRuntimeEarlyInit() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let hostScript = try String(contentsOf: root.appendingPathComponent("scripts/imagewriter-build.sh"), encoding: .utf8)
        let guestScript = try String(contentsOf: root.appendingPathComponent("scripts/imagewriter-build-guest.sh"), encoding: .utf8)

        XCTAssertTrue(hostScript.contains("IMAGEWRITER_EARLY_INIT_BINARY"))
        XCTAssertTrue(hostScript.contains("--early-init-binary"))
        XCTAssertTrue(guestScript.contains("--early-init-binary"))
        XCTAssertTrue(guestScript.contains("mkdir -p \"$ROOTFS_DIR/run/msl/base\" \"$ROOTFS_DIR/run/msl/state\" \"$ROOTFS_DIR/run/msl/tmp\" \"$ROOTFS_DIR/sysroot\""))
        XCTAssertTrue(guestScript.contains("cp -f \"$EARLY_INIT_BINARY\" \"$ROOTFS_DIR/init\""))
        XCTAssertTrue(guestScript.contains("chmod 0755 \"$ROOTFS_DIR/init\""))
    }
}
